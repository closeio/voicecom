import Foundation
import WhisperKit

final class TranscriptionService: @unchecked Sendable {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    static func fetchAvailableModels() async throws -> [String] {
        try await WhisperKit.fetchAvailableModels()
    }

    func loadModel(name: String) async throws {
        if loadedModel == name, whisperKit != nil { return }

        let config = WhisperKitConfig(
            model: name,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: true
        )
        whisperKit = try await WhisperKit(config)
        loadedModel = name
    }

    func transcribe(audioBuffer: [Float]) async throws -> String {
        guard let whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

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

enum TranscriptionError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model is not loaded"
        }
    }
}
