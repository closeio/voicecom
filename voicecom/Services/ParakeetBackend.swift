import Foundation
import LocalWhisper
import Metal

/// Transcription backend for NVIDIA Parakeet models via whisper.cpp's `parakeet_*` C API
/// (added in whisper.cpp v1.9.0). Parakeet runs entirely on ggml, so it uses the Metal GPU
/// backend on Apple Silicon (`use_gpu = true`) with CPU fallback. Unlike Whisper there is no
/// CoreML/ANE encoder path — a single GGUF `.bin` is all that's downloaded.
nonisolated final class ParakeetBackend: TranscriptionBackend, @unchecked Sendable {
    /// Condition variable protecting `context`, `loadedModel`, and `activeTranscriptionCount`.
    /// Mirrors WhisperCppBackend: NSCondition lets `unloadModel()` wait for in-flight
    /// transcriptions to finish without spin-waiting.
    private let condition = NSCondition()
    /// Stored as an `Int` (bit pattern of the pointer) so it can be accessed from `deinit` —
    /// `OpaquePointer` is not `Sendable`.
    private var contextBits: Int = 0 // parakeet_context * bit pattern, 0 means nil

    private var context: OpaquePointer? {
        get { contextBits == 0 ? nil : OpaquePointer(bitPattern: contextBits) }
        set { contextBits = newValue.map { Int(bitPattern: $0) } ?? 0 }
    }
    private var loadedModel: String?
    /// Tracks whether a transcription is currently using `context`.
    /// `parakeet_full` is not thread-safe for the same context, so at most one runs at a time.
    private var activeTranscriptionCount = 0

    private static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("voicecom/models/parakeet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Curated list of available Parakeet models. whisper.cpp has no dynamic discovery API.
    /// The plain `parakeet-tdt-0.6b-v3` entry maps to the f16 weights; quantized variants
    /// are offered for a smaller download / memory footprint.
    static func fetchAvailableModels() async throws -> [String] {
        return [
            "parakeet-tdt-0.6b-v3",
            "parakeet-tdt-0.6b-v3-q8_0",
            "parakeet-tdt-0.6b-v3-q4_k",
        ]
    }

    /// HuggingFace repo hosting the converted GGML Parakeet weights.
    private static let modelBaseURL = "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main"

    /// Maps a curated model name to its remote `.bin` file name.
    /// The bare `parakeet-tdt-0.6b-v3` resolves to the f16 weights; explicit quantization
    /// suffixes (e.g. `-q8_0`, `-q4_k`) map directly.
    private static func remoteFileName(for model: String) -> String {
        if model == "parakeet-tdt-0.6b-v3" {
            return "ggml-parakeet-tdt-0.6b-v3-f16.bin"
        }
        return "ggml-\(model).bin"
    }

    // MARK: - Synchronous lock helpers

    private func isModelAlreadyLoaded(name: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return loadedModel == name && context != nil
    }

    private func storeContext(_ ctx: OpaquePointer, name: String) {
        condition.lock()
        context = ctx
        loadedModel = name
        condition.unlock()
    }

    /// Acquires the context for transcription, incrementing the active count.
    /// Returns nil if no model is loaded or another transcription is already running.
    private func acquireContextForTranscription() -> OpaquePointer? {
        condition.lock()
        defer { condition.unlock() }
        guard let ctx = context, activeTranscriptionCount == 0 else { return nil }
        activeTranscriptionCount += 1
        return ctx
    }

    private func releaseContextAfterTranscription() {
        condition.lock()
        activeTranscriptionCount -= 1
        condition.signal()
        condition.unlock()
    }

    // MARK: - Public API

    func loadModel(name: String, onPhaseChange: (@Sendable (ModelLoadPhase) -> Void)? = nil) async throws {
        if isModelAlreadyLoaded(name: name) { return }

        // Unload any previously loaded model on a non-cooperative thread since
        // unloadModel() may block waiting for active transcriptions to finish.
        let s = self
        await Task.detached(priority: .userInitiated) { s.unloadModel() }.value

        let modelFileName = "\(name).bin"
        let modelFileURL = Self.modelsDirectory.appendingPathComponent(modelFileName)

        // Download GGML model if not already cached locally
        if !FileManager.default.fileExists(atPath: modelFileURL.path) {
            onPhaseChange?(.downloading)
            guard let downloadURL = URL(string: "\(Self.modelBaseURL)/\(Self.remoteFileName(for: name))") else {
                throw TranscriptionError.modelDownloadFailed
            }
            print("[voicecom] Downloading Parakeet model '\(name)' from \(downloadURL)")

            // Parakeet weights are large (~1.2 GB f16); use a generous resource timeout.
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = 1200 // 20 minutes for full download
            config.timeoutIntervalForRequest = 60
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }

            let (tempURL, response) = try await session.download(from: downloadURL)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw TranscriptionError.modelDownloadFailed
            }
            try? FileManager.default.removeItem(at: modelFileURL)
            try FileManager.default.moveItem(at: tempURL, to: modelFileURL)
            print("[voicecom] Parakeet model '\(name)' downloaded to \(modelFileURL.path)")
        }

        // Bail early if the caller's task was cancelled during download
        try Task.checkCancellation()

        // Verify downloaded file isn't empty/corrupt (minimum sanity check)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: modelFileURL.path),
           let fileSize = attrs[.size] as? UInt64, fileSize < 1024 {
            try? FileManager.default.removeItem(at: modelFileURL)
            throw TranscriptionError.modelDownloadFailed
        }

        // Initialize the parakeet context. Run on a detached thread — reading hundreds of MBs
        // and building the Metal pipelines can block for seconds.
        onPhaseChange?(.loading)
        let modelPath = modelFileURL.path
        let ctxBits: Int = await Task.detached(priority: .userInitiated) {
            var params = parakeet_context_default_params()
            params.use_gpu = true // Metal on Apple Silicon
            let ptr = modelPath.withCString { path in
                parakeet_init_from_file_with_params(path, params)
            }
            if let ptr { return Int(bitPattern: ptr) }
            return 0
        }.value
        let ctx: OpaquePointer? = ctxBits == 0 ? nil : OpaquePointer(bitPattern: ctxBits)
        guard let ctx else {
            // Model file is corrupt or incompatible — delete cache so next attempt re-downloads
            print("[voicecom] Failed to load Parakeet model from \(modelFileURL.path), removing cached file")
            try? FileManager.default.removeItem(at: modelFileURL)
            throw TranscriptionError.modelLoadFailed
        }

        // If cancelled after context was created, free it immediately instead of storing
        if Task.isCancelled {
            parakeet_free(ctx)
            throw CancellationError()
        }

        storeContext(ctx, name: name)
        Self.logDiagnostics(modelName: name)
    }

    /// Transcribes audio. Parakeet-tdt-0.6b-v3 is multilingual/auto-detecting and exposes no
    /// per-call language parameter, so `language` is accepted for protocol conformance but ignored.
    func transcribe(audioBuffer: [Float], language: String = "en") async throws -> String {
        guard let ctx = acquireContextForTranscription() else {
            throw TranscriptionError.modelNotLoaded
        }

        nonisolated(unsafe) let sendableCtx = ctx
        let audio = audioBuffer
        let operation: @Sendable () throws -> String = {
            try Self.runTranscription(context: sendableCtx, audioBuffer: audio)
        }
        do {
            let result = try await Task.detached(priority: .userInitiated) { try operation() }.value
            releaseContextAfterTranscription()
            return result
        } catch {
            releaseContextAfterTranscription()
            throw error
        }
    }

    /// Number of performance cores to use for inference. Mirrors WhisperCppBackend: using only
    /// P-cores avoids scheduling work on slower E-cores.
    private static let inferenceThreadCount: Int32 = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu_max", &count, &size, nil, 0) == 0, count > 0 {
            return count
        }
        let total = Int32(ProcessInfo.processInfo.activeProcessorCount)
        return max(total / 2, 1)
    }()

    private nonisolated static func runTranscription(context: OpaquePointer, audioBuffer: [Float]) throws -> String {
        var params = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY)
        params.n_threads = inferenceThreadCount
        params.no_context = true

        let result = audioBuffer.withUnsafeBufferPointer { bufferPointer in
            parakeet_full(context, params, bufferPointer.baseAddress, Int32(audioBuffer.count))
        }
        guard result == 0 else {
            throw TranscriptionError.transcriptionFailed
        }

        let segmentCount = parakeet_full_n_segments(context)
        var texts: [String] = []
        for i in 0..<segmentCount {
            if let cStr = parakeet_full_get_segment_text(context, i) {
                texts.append(String(cString: cStr))
            }
        }

        let raw = texts
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip bracketed markers and hallucinated emoji, matching WhisperCppBackend behavior.
        let deBracketed = raw.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return deBracketed.unicodeScalars
            .filter { scalar in
                if scalar.isASCII { return true }
                if !scalar.properties.isEmoji { return true }
                if !scalar.properties.isEmojiPresentation { return true }
                return false
            }
            .map { String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unloadModel() {
        condition.lock()
        while activeTranscriptionCount > 0 {
            condition.wait()
        }
        let ctx = context
        context = nil
        loadedModel = nil
        condition.unlock()

        if let ctx {
            parakeet_free(ctx)
        }
    }

    // MARK: - Diagnostics

    private static func logDiagnostics(modelName: String) {
        print("[voicecom] ═══════════════════════════════════════════")
        print("[voicecom] Parakeet model '\(modelName)' loaded")
        if let sysInfo = parakeet_print_system_info() {
            print("[voicecom] System info: \(String(cString: sysInfo))")
        }
        print("[voicecom] CPU threads: \(inferenceThreadCount) (performance cores only)")
        if let device = MTLCreateSystemDefaultDevice() {
            print("[voicecom] Metal GPU: \(device.name) (ENABLED for Parakeet inference)")
        } else {
            print("[voicecom] Metal GPU: NOT AVAILABLE (Parakeet will use CPU only)")
        }
        print("[voicecom] ═══════════════════════════════════════════")
    }

    deinit {
        unloadModel()
    }
}
