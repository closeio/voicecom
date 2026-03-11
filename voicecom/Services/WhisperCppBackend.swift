import Foundation
import whisper

final class WhisperCppBackend: TranscriptionBackend, @unchecked Sendable {
    private var context: OpaquePointer? // whisper_context *
    private var loadedModel: String?

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

    func loadModel(name: String) async throws {
        if loadedModel == name, context != nil { return }

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

        context = ctx
        loadedModel = name
        print("[voicecom] whisper.cpp model '\(name)' loaded successfully")
    }

    func transcribe(audioBuffer: [Float]) async throws -> String {
        guard let context else {
            throw TranscriptionError.modelNotLoaded
        }

        // Run transcription on a background thread since whisper_full blocks
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                params.no_timestamps = true
                params.print_special = false
                params.print_progress = false
                params.print_realtime = false
                params.print_timestamps = false
                params.language = "en".withCString { strdup($0) }

                let result = audioBuffer.withUnsafeBufferPointer { bufferPointer in
                    whisper_full(context, params, bufferPointer.baseAddress, Int32(audioBuffer.count))
                }

                // Free the strdup'd language string
                if let lang = params.language {
                    free(UnsafeMutablePointer(mutating: lang))
                }

                guard result == 0 else {
                    continuation.resume(throwing: TranscriptionError.transcriptionFailed)
                    return
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
                let cleaned = raw.unicodeScalars
                    .filter { !$0.properties.isEmoji || $0.isASCII }
                    .map { Character($0) }
                    .map { String($0) }
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                continuation.resume(returning: cleaned)
            }
        }
    }

    func unloadModel() {
        if let context {
            whisper_free(context)
        }
        context = nil
        loadedModel = nil
    }

    deinit {
        if let context {
            whisper_free(context)
        }
    }

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
            process.standardOutput = nil
            process.standardError = nil
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
