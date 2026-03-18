import Foundation

final class TranscriptionService: @unchecked Sendable {
    /// Lock protecting `backend` from concurrent access.
    private let lock = NSLock()
    private var backend: WhisperCppBackend?

    private func resolveBackend() -> WhisperCppBackend {
        lock.lock()
        defer { lock.unlock() }
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
        let backend = try getBackendForTranscription()
        return try await backend.transcribe(audioBuffer: audioBuffer)
    }

    /// Reads the current backend under the lock, synchronously.
    /// Extracted to a non-async method so NSLock can be used safely.
    private func getBackendForTranscription() throws -> WhisperCppBackend {
        lock.lock()
        defer { lock.unlock() }
        guard let backend else {
            throw TranscriptionError.modelNotLoaded
        }
        return backend
    }

    func unloadModel() {
        lock.lock()
        let b = backend
        backend = nil
        lock.unlock()
        b?.unloadModel()
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
