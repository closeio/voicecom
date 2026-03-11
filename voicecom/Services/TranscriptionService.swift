import Foundation

final class TranscriptionService: @unchecked Sendable {
    private var backend: (any TranscriptionBackend)?
    private var currentBackendType: TranscriptionBackendType?

    /// Creates or returns the backend for the given type.
    private func resolveBackend(for type: TranscriptionBackendType) -> any TranscriptionBackend {
        if let backend, currentBackendType == type {
            return backend
        }
        // Switching backends: unload the old one
        backend?.unloadModel()

        let newBackend: any TranscriptionBackend
        switch type {
        case .whisperKit:
            newBackend = WhisperKitBackend()
        case .whisperCpp:
            newBackend = WhisperCppBackend()
        }
        backend = newBackend
        currentBackendType = type
        return newBackend
    }

    func fetchAvailableModels(for type: TranscriptionBackendType) async throws -> [String] {
        switch type {
        case .whisperKit:
            return try await WhisperKitBackend.fetchAvailableModels()
        case .whisperCpp:
            return try await WhisperCppBackend.fetchAvailableModels()
        }
    }

    func loadModel(name: String, backendType: TranscriptionBackendType) async throws {
        let backend = resolveBackend(for: backendType)
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
        currentBackendType = nil
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case modelDownloadFailed

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model is not loaded"
        case .modelDownloadFailed:
            return "Failed to download model"
        }
    }
}
