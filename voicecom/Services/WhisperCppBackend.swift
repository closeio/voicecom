import Foundation
import LocalWhisper

final class WhisperCppBackend: TranscriptionBackend, @unchecked Sendable {
    /// Lock protecting `context` and `loadedModel` from concurrent access.
    /// We use a lock instead of an actor because `whisper_full` blocks for seconds
    /// and we don't want to serialize model load/unload behind a long transcription.
    private let lock = NSLock()
    private var context: OpaquePointer? // whisper_context *
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
        lock.lock()
        defer { lock.unlock() }
        return loadedModel == name && context != nil
    }

    /// Stores a newly created context under the lock.
    private func storeContext(_ ctx: OpaquePointer, name: String) {
        lock.lock()
        context = ctx
        loadedModel = name
        lock.unlock()
    }

    /// Acquires the context pointer for transcription, incrementing the active count.
    /// Returns nil if no model is loaded.
    private func acquireContextForTranscription() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        guard let ctx = context else { return nil }
        activeTranscriptionCount += 1
        return ctx
    }

    /// Releases the context after transcription completes.
    private func releaseContextAfterTranscription() {
        lock.lock()
        activeTranscriptionCount -= 1
        lock.unlock()
    }

    // MARK: - Public API

    func loadModel(name: String) async throws {
        if isModelAlreadyLoaded(name: name) { return }

        // Unload any previously loaded model
        unloadModel()

        let modelFileName = "\(name).bin"
        let modelFileURL = Self.modelsDirectory.appendingPathComponent(modelFileName)

        // Download ggml model if not already cached locally
        if !FileManager.default.fileExists(atPath: modelFileURL.path) {
            guard let downloadURL = URL(string: "\(Self.modelBaseURL)/\(modelFileName)") else {
                throw TranscriptionError.modelDownloadFailed
            }
            print("[voicecom] Downloading whisper.cpp model '\(name)' from \(downloadURL)")

            let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw TranscriptionError.modelDownloadFailed
            }
            try FileManager.default.moveItem(at: tempURL, to: modelFileURL)
            print("[voicecom] whisper.cpp model '\(name)' downloaded to \(modelFileURL.path)")
        }

        // Download CoreML encoder model for ANE acceleration if not already cached.
        // whisper.cpp automatically loads this from alongside the .bin file.
        let coremlDirName = "\(name)-encoder.mlmodelc"
        let coremlDirURL = Self.modelsDirectory.appendingPathComponent(coremlDirName)
        if !FileManager.default.fileExists(atPath: coremlDirURL.path) {
            await Self.downloadCoreMLEncoder(name: name, coremlDirName: coremlDirName)
        }

        // Initialize whisper context from the model file
        let params = whisper_context_default_params()
        let ctx = modelFileURL.path.withCString { path in
            whisper_init_from_file_with_params(path, params)
        }
        guard let ctx else {
            throw TranscriptionError.modelLoadFailed
        }

        storeContext(ctx, name: name)
        print("[voicecom] whisper.cpp model '\(name)' loaded successfully")
    }

    func transcribe(audioBuffer: [Float]) async throws -> String {
        // Acquire the context pointer under the lock and mark as in-use
        guard let ctx = acquireContextForTranscription() else {
            throw TranscriptionError.modelNotLoaded
        }

        // Ensure we decrement the counter when done, even on failure
        defer { releaseContextAfterTranscription() }

        // Run transcription on a background thread since whisper_full blocks.
        // `ctx` is safe to use here because unloadModel() waits for activeTranscriptionCount == 0.
        // OpaquePointer is not Sendable, so we use nonisolated(unsafe) to bridge it to the
        // detached task. The activeTranscriptionCount ensures the pointer remains valid.
        nonisolated(unsafe) let sendableCtx = ctx
        let audio = audioBuffer
        let operation: @Sendable () throws -> String = {
            try Self.runTranscription(context: sendableCtx, audioBuffer: audio)
        }
        return try await Task.detached(priority: .userInitiated) {
            try operation()
        }.value
    }

    private nonisolated static func runTranscription(context: OpaquePointer, audioBuffer: [Float]) throws -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.no_timestamps = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false

        // Safety: params.language points into the "en" string literal's storage,
        // which is valid for the entire duration of whisper_full since the literal
        // has static lifetime.
        let result = "en".withCString { langPtr in
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

        // Strip emojis and other non-text symbols that Whisper can hallucinate
        return raw.unicodeScalars
            .filter { !$0.properties.isEmoji || $0.isASCII }
            .map { Character($0) }
            .map { String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unloadModel() {
        lock.lock()
        // Wait for any active transcription to finish before freeing context
        while activeTranscriptionCount > 0 {
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.01)
            lock.lock()
        }
        let ctx = context
        context = nil
        loadedModel = nil
        lock.unlock()

        if let ctx {
            whisper_free(ctx)
        }
    }

    // Note: No deinit needed — unloadModel() handles cleanup, and the backend
    // lifetime is managed by TranscriptionService which calls unloadModel() before releasing.

    // MARK: - CoreML Encoder Download

    /// Downloads and unzips the CoreML encoder model for ANE acceleration.
    /// Failures are non-fatal — whisper.cpp falls back to CPU automatically.
    private static func downloadCoreMLEncoder(name: String, coremlDirName: String) async {
        let coremlZipName = "\(coremlDirName).zip"
        guard let coremlDownloadURL = URL(string: "\(modelBaseURL)/\(coremlZipName)") else {
            print("[voicecom] Could not construct CoreML download URL, skipping ANE support")
            return
        }
        print("[voicecom] Downloading CoreML encoder for '\(name)' from \(coremlDownloadURL)")

        do {
            let (tempZipURL, coremlResponse) = try await URLSession.shared.download(from: coremlDownloadURL)
            guard let httpResp = coremlResponse as? HTTPURLResponse, httpResp.statusCode == 200 else {
                print("[voicecom] CoreML encoder not available for '\(name)', using CPU fallback")
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
            try process.run()
            process.waitUntilExit()

            try? FileManager.default.removeItem(at: tempZipDest)

            if process.terminationStatus == 0 {
                print("[voicecom] CoreML encoder for '\(name)' ready for ANE acceleration")
            } else {
                print("[voicecom] Failed to unzip CoreML encoder, using CPU fallback")
            }
        } catch {
            print("[voicecom] CoreML encoder download failed: \(error.localizedDescription), using CPU fallback")
        }
    }
}
