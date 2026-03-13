import Foundation

final class TranscriptionService: @unchecked Sendable {
    private var backend: WhisperCppBackend?

    private func resolveBackend() -> WhisperCppBackend {
        if let backend {
            return backend
        }
        let newBackend = WhisperCppBackend()
        backend = newBackend
        return newBackend
    }

    func fetchAvailableModels() async throws -> [String] {
        try await WhisperCppBackend.fetchAvailableModels()
    }

    func loadModel(name: String) async throws {
        let backend = resolveBackend()
        try await backend.loadModel(name: name)
    }

    func transcribe(audioBuffer: [Float]) async throws -> String {
        guard let backend else {
            throw TranscriptionError.modelNotLoaded
        }
        return try await backend.transcribe(audioBuffer: audioBuffer)
    }

    func unloadModel() {
        backend?.unloadModel()
        backend = nil
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case modelDownloadFailed
    case modelLoadFailed
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model is not loaded"
        case .modelDownloadFailed:
            return "Failed to download model"
        case .modelLoadFailed:
            return "Failed to load model"
        case .transcriptionFailed:
            return "Transcription failed"
        }
    }
}
