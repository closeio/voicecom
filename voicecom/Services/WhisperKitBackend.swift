import Foundation
import WhisperKit

final class WhisperKitBackend: TranscriptionBackend, @unchecked Sendable {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    private static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("voicecom/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fetchAvailableModels() async throws -> [String] {
        try await WhisperKit.fetchAvailableModels()
    }

    func loadModel(name: String) async throws {
        if loadedModel == name, whisperKit != nil { return }

        // Unload any previously loaded model
        unloadModel()

        let modelsDir = Self.modelsDirectory
        let config = WhisperKitConfig(
            model: name,
            downloadBase: modelsDir,
            verbose: true,
            logLevel: .debug,
            prewarm: false,
            load: true,
            download: true
        )
        do {
            whisperKit = try await WhisperKit(config)
            loadedModel = name
            print("[voicecom] WhisperKit model '\(name)' loaded successfully")
        } catch {
            print("[voicecom] WhisperKit model '\(name)' failed to load: \(error)")
            throw error
        }
    }

    func transcribe(audioBuffer: [Float]) async throws -> String {
        guard let kit = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }
        nonisolated(unsafe) let whisperKit = kit

        let options = DecodingOptions(
            verbose: false,
            temperature: 0.0,
            temperatureFallbackCount: 0,
            sampleLength: 224,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )

        let results = try await whisperKit.transcribe(audioArray: audioBuffer, decodeOptions: options)
        let raw = results
            .map(\.text)
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
        whisperKit = nil
        loadedModel = nil
    }
}
