import Foundation
import LocalWhisper
import Metal

nonisolated final class WhisperCppBackend: TranscriptionBackend, @unchecked Sendable {
    /// Condition variable protecting `context`, `loadedModel`, and `activeTranscriptionCount`.
    /// We use NSCondition instead of NSLock so that `unloadModel()` can efficiently wait
    /// for active transcriptions to finish without spin-waiting.
    private let condition = NSCondition()
    /// Stored as an `Int` (bit pattern of the pointer) so it can be accessed from
    /// `deinit` — `OpaquePointer` and `UnsafeMutableRawPointer` are not `Sendable`.
    private var contextBits: Int = 0 // whisper_context * bit pattern, 0 means nil

    /// Convenience accessor that converts to/from the OpaquePointer whisper.cpp expects.
    private var context: OpaquePointer? {
        get { contextBits == 0 ? nil : OpaquePointer(bitPattern: contextBits) }
        set {
            if let newValue {
                contextBits = Int(bitPattern: newValue)
            } else {
                contextBits = 0
            }
        }
    }
    private var loadedModel: String?
    /// Tracks whether a transcription is currently using `context`.
    /// `unloadModel()` waits for this to reach 0 before freeing.
    private var activeTranscriptionCount = 0

    private static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("voicecom/models/whispercpp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Curated list of available ggml models.
    /// whisper.cpp has no dynamic model discovery API, so this is maintained manually.
    static func fetchAvailableModels() async throws -> [String] {
        return [
            "ggml-tiny.en",
            "ggml-tiny",
            "ggml-base.en",
            "ggml-base",
            "ggml-small.en",
            "ggml-small",
            "ggml-medium.en",
            "ggml-medium",
            "ggml-large-v3-turbo",
            "ggml-large-v3",
        ]
    }

    /// HuggingFace base URL for whisper.cpp ggml model files.
    private static let modelBaseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    // MARK: - Synchronous lock helpers (cannot use NSLock from async contexts)

    /// Returns true if the model is already loaded with the given name.
    private func isModelAlreadyLoaded(name: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return loadedModel == name && context != nil
    }

    /// Stores a newly created context under the lock.
    private func storeContext(_ ctx: OpaquePointer, name: String) {
        condition.lock()
        context = ctx
        loadedModel = name
        condition.unlock()
    }

    /// Acquires the context pointer for transcription, incrementing the active count.
    /// Returns nil if no model is loaded or another transcription is already running
    /// (whisper_full is not thread-safe for the same context).
    private func acquireContextForTranscription() -> OpaquePointer? {
        condition.lock()
        defer { condition.unlock() }
        guard let ctx = context, activeTranscriptionCount == 0 else { return nil }
        activeTranscriptionCount += 1
        return ctx
    }
    
    /// Releases the context after transcription completes and signals any waiters.
    private func releaseContextAfterTranscription() {
        condition.lock()
        activeTranscriptionCount -= 1
        condition.signal()
        condition.unlock()
    }

    // MARK: - Public API

    func loadModel(name: String, onPhaseChange: (@Sendable (ModelLoadPhase) -> Void)? = nil) async throws {
        if isModelAlreadyLoaded(name: name) { return }

        // Unload any previously loaded model.
        // Run on a non-cooperative thread since unloadModel() may block
        // waiting for active transcriptions to finish.
        let s = self
        await Task.detached(priority: .userInitiated) { s.unloadModel() }.value

        let modelFileName = "\(name).bin"
        let modelFileURL = Self.modelsDirectory.appendingPathComponent(modelFileName)

        // Download ggml model if not already cached locally
        if !FileManager.default.fileExists(atPath: modelFileURL.path) {
            onPhaseChange?(.downloading)
            guard let downloadURL = URL(string: "\(Self.modelBaseURL)/\(modelFileName)") else {
                throw TranscriptionError.modelDownloadFailed
            }
            print("[voicecom] Downloading whisper.cpp model '\(name)' from \(downloadURL)")

            let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw TranscriptionError.modelDownloadFailed
            }
            // Remove any partial download from a previous attempt
            try? FileManager.default.removeItem(at: modelFileURL)
            try FileManager.default.moveItem(at: tempURL, to: modelFileURL)
            print("[voicecom] whisper.cpp model '\(name)' downloaded to \(modelFileURL.path)")
        }

        // Bail early if the caller's task was cancelled during download
        try Task.checkCancellation()

        // Download CoreML encoder model for ANE acceleration if not already cached.
        // whisper.cpp automatically loads this from alongside the .bin file.
        let coremlDirName = "\(name)-encoder.mlmodelc"
        let coremlDirURL = Self.modelsDirectory.appendingPathComponent(coremlDirName)
        if !FileManager.default.fileExists(atPath: coremlDirURL.path) {
            await Self.downloadCoreMLEncoder(name: name, coremlDirName: coremlDirName)
        }

        // Verify downloaded file isn't empty/corrupt (minimum sanity check)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: modelFileURL.path),
           let fileSize = attrs[.size] as? UInt64, fileSize < 1024 {
            // File is suspiciously small (< 1KB) — likely a corrupt/partial download
            try? FileManager.default.removeItem(at: modelFileURL)
            throw TranscriptionError.modelDownloadFailed
        }

        // Bail early if the caller's task was cancelled during CoreML download
        try Task.checkCancellation()

        // Log whether CoreML encoder is available for this model
        let coremlAvailable = FileManager.default.fileExists(atPath: coremlDirURL.path)
        if coremlAvailable {
            print("[voicecom] CoreML encoder found at \(coremlDirURL.lastPathComponent) — will use ANE acceleration")
        } else {
            print("[voicecom] CoreML encoder not found for '\(name)' — using CPU-only inference")
        }

        // Initialize whisper context from the model file.
        // Run on a detached thread — whisper_init_from_file_with_params reads
        // hundreds of MBs and may compile the CoreML encoder, blocking for seconds.
        onPhaseChange?(.loading)
        let modelPath = modelFileURL.path
        let ctxBits: Int = await Task.detached(priority: .userInitiated) {
            var params = whisper_context_default_params()
            params.flash_attn = true
            let ptr = modelPath.withCString { path in
                whisper_init_from_file_with_params(path, params)
            }
            if let ptr { return Int(bitPattern: ptr) }
            return 0
        }.value
        let ctx: OpaquePointer? = ctxBits == 0 ? nil : OpaquePointer(bitPattern: ctxBits)
        guard let ctx else {
            // Model file is corrupt or incompatible — delete cache so next attempt re-downloads
            print("[voicecom] Failed to load model from \(modelFileURL.path), removing cached file")
            try? FileManager.default.removeItem(at: modelFileURL)
            throw TranscriptionError.modelLoadFailed
        }

        // If cancelled after context was created, free it immediately instead of storing
        if Task.isCancelled {
            whisper_free(ctx)
            throw CancellationError()
        }

        storeContext(ctx, name: name)

        // Log diagnostics about hardware acceleration status
        Self.logDiagnostics(modelName: name, coremlAvailable: coremlAvailable)
    }

    func transcribe(audioBuffer: [Float], language: String = "en") async throws -> String {
        // Acquire the context pointer under the lock and mark as in-use
        guard let ctx = acquireContextForTranscription() else {
            throw TranscriptionError.modelNotLoaded
        }

        // Run transcription on a background thread since whisper_full blocks.
        // `ctx` is safe to use here because unloadModel() waits for activeTranscriptionCount == 0.
        // OpaquePointer is not Sendable, so we use nonisolated(unsafe) to bridge it to the
        // detached task. The activeTranscriptionCount ensures the pointer remains valid.
        nonisolated(unsafe) let sendableCtx = ctx
        let audio = audioBuffer
        let lang = language
        let operation: @Sendable () throws -> String = {
            try Self.runTranscription(context: sendableCtx, audioBuffer: audio, language: lang)
        }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try operation()
            }.value
            releaseContextAfterTranscription()
            return result
        } catch {
            releaseContextAfterTranscription()
            throw error
        }
    }

    /// Number of performance cores to use for whisper.cpp inference.
    /// Using only performance (P) cores avoids scheduling work on efficiency (E) cores,
    /// which are slower and can increase overall latency due to thread synchronization.
    private static let inferenceThreadCount: Int32 = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // hw.perflevel0.logicalcpu_max gives the number of P-cores on Apple Silicon
        if sysctlbyname("hw.perflevel0.logicalcpu_max", &count, &size, nil, 0) == 0, count > 0 {
            return count
        }
        // Fallback: use half the total cores as a rough P-core estimate (Intel or unknown)
        let total = Int32(ProcessInfo.processInfo.activeProcessorCount)
        return max(total / 2, 1)
    }()

    private nonisolated static func runTranscription(context: OpaquePointer, audioBuffer: [Float], language: String) throws -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = inferenceThreadCount
        params.no_context = true
        params.no_timestamps = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_nst = true

        let result = language.withCString { langPtr in
            params.language = langPtr
            return audioBuffer.withUnsafeBufferPointer { bufferPointer in
                whisper_full(context, params, bufferPointer.baseAddress, Int32(audioBuffer.count))
            }
        }

        guard result == 0 else {
            throw TranscriptionError.transcriptionFailed
        }

        let segmentCount = whisper_full_n_segments(context)
        var texts: [String] = []
        for i in 0..<segmentCount {
            if let cStr = whisper_full_get_segment_text(context, i) {
                texts.append(String(cString: cStr))
            }
        }

        let raw = texts
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip Whisper hallucination markers in brackets (e.g. [Música], [Music], [BLANK_AUDIO])
        let deBracketed = raw.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip emojis that Whisper can hallucinate while preserving valid symbols
        // like ©, ®, ™ that have isEmoji but are legitimate text characters.
        return deBracketed.unicodeScalars
            .filter { scalar in
                if scalar.isASCII { return true }
                if !scalar.properties.isEmoji { return true }
                // Keep text-like symbols that Unicode marks as emoji but are
                // commonly used in dictated/written text (©, ®, ™, etc.)
                if !scalar.properties.isEmojiPresentation { return true }
                return false
            }
            .map { String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unloadModel() {
        condition.lock()
        // Wait for any active transcription to finish before freeing context.
        while activeTranscriptionCount > 0 {
            condition.wait()
        }
        let ctx = context
        context = nil
        loadedModel = nil
        condition.unlock()

        if let ctx {
            whisper_free(ctx)
        }
    }

    // MARK: - Diagnostics

    private static func logDiagnostics(modelName: String, coremlAvailable: Bool) {
        print("[voicecom] ═══════════════════════════════════════════")
        print("[voicecom] whisper.cpp model '\(modelName)' loaded")

        // System info (compiled-in features)
        if let sysInfo = whisper_print_system_info() {
            print("[voicecom] System info: \(String(cString: sysInfo))")
        }

        // Thread count
        print("[voicecom] CPU threads: \(inferenceThreadCount) (performance cores only)")

        // CoreML encoder status
        if coremlAvailable {
            print("[voicecom] CoreML encoder: AVAILABLE (ANE/GPU acceleration for encoder)")
        } else {
            print("[voicecom] CoreML encoder: NOT FOUND (encoder will use CPU)")
        }

        // Metal GPU status
        if let device = MTLCreateSystemDefaultDevice() {
            print("[voicecom] Metal GPU: \(device.name) (ENABLED for decoder acceleration)")
        } else {
            print("[voicecom] Metal GPU: NOT AVAILABLE (decoder will use CPU only)")
        }

        print("[voicecom] ═══════════════════════════════════════════")
    }

    deinit {
        // Wait for any active transcription to finish, then free the context.
        // Safe in deinit because no other strong references exist, and the
        // blocking wait is bounded by the transcription duration.
        unloadModel()
    }

    // MARK: - CoreML Encoder Download

    /// Creates a URLSession configured with a generous timeout for large CoreML encoder downloads
    /// (up to ~1.2 GB). The caller must invalidate the session after use.
    private static func makeDownloadSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 600 // 10 minutes for full download
        config.timeoutIntervalForRequest = 60   // 60s between data chunks
        return URLSession(configuration: config)
    }

    /// Downloads and unzips the CoreML encoder model for ANE acceleration.
    /// Failures are non-fatal — whisper.cpp falls back to CPU automatically.
    private static func downloadCoreMLEncoder(name: String, coremlDirName: String) async {
        let coremlZipName = "\(coremlDirName).zip"
        guard let coremlDownloadURL = URL(string: "\(modelBaseURL)/\(coremlZipName)") else {
            print("[voicecom] Could not construct CoreML download URL, skipping ANE support")
            return
        }
        print("[voicecom] Downloading CoreML encoder for '\(name)' from \(coremlDownloadURL)")

        let session = makeDownloadSession()
        defer { session.finishTasksAndInvalidate() }

        do {
            let (tempZipURL, coremlResponse) = try await session.download(from: coremlDownloadURL)
            guard let httpResp = coremlResponse as? HTTPURLResponse, httpResp.statusCode == 200 else {
                let code = (coremlResponse as? HTTPURLResponse)?.statusCode ?? -1
                print("[voicecom] CoreML encoder not available for '\(name)' (HTTP \(code)), using CPU fallback")
                return
            }

            // Unzip the CoreML model into the models directory
            let tempZipDest = modelsDirectory.appendingPathComponent(coremlZipName)
            try? FileManager.default.removeItem(at: tempZipDest)
            try FileManager.default.moveItem(at: tempZipURL, to: tempZipDest)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", tempZipDest.path, "-d", modelsDirectory.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            // Wait for the process without blocking the cooperative thread pool
            let terminationStatus = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { p in
                    continuation.resume(returning: p.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            try? FileManager.default.removeItem(at: tempZipDest)

            if terminationStatus == 0 {
                print("[voicecom] CoreML encoder for '\(name)' ready for ANE acceleration")
            } else {
                print("[voicecom] Failed to unzip CoreML encoder (exit \(terminationStatus)), using CPU fallback")
            }
        } catch {
            print("[voicecom] CoreML encoder download failed: \(error.localizedDescription), using CPU fallback")
        }
    }
}
