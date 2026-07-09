import Foundation

nonisolated final class TranscriptionService: @unchecked Sendable {
    /// Lock protecting `backend`/`backendIsParakeet` from concurrent access.
    private let lock = NSLock()
    private var backend: (any TranscriptionBackend)?
    /// Tracks the concrete type of the current backend so we know when a model
    /// selection requires swapping to the other backend.
    private var backendIsParakeet = false

    /// Parakeet models are routed to `ParakeetBackend`; everything else (the `ggml-*`
    /// Whisper models) goes to `WhisperCppBackend`.
    private static func isParakeet(_ name: String) -> Bool { name.hasPrefix("parakeet") }

    /// Merges both backends' curated model lists so Whisper and Parakeet models
    /// both appear in the picker.
    func fetchAvailableModels() async throws -> [String] {
        async let whisper = WhisperCppBackend.fetchAvailableModels()
        async let parakeet = ParakeetBackend.fetchAvailableModels()
        return try await whisper + parakeet
    }

    func loadModel(name: String, onPhaseChange: (@Sendable (ModelLoadPhase) -> Void)? = nil) async throws {
        let backend = await prepareBackend(for: name)
        try await backend.loadModel(name: name, onPhaseChange: onPhaseChange)
    }

    func transcribe(audioBuffer: [Float], language: String = "en") async throws -> String {
        let backend = try getBackendForTranscription()
        return try await backend.transcribe(audioBuffer: audioBuffer, language: language)
    }

    /// Returns the backend appropriate for `name`, swapping backend type if the
    /// selected model belongs to the other backend. Unloading the old backend may
    /// block, so it runs on a non-cooperative thread.
    private func prepareBackend(for name: String) async -> any TranscriptionBackend {
        let wantParakeet = Self.isParakeet(name)
        if let current = currentBackend(matchingParakeet: wantParakeet) {
            return current
        }
        // Wrong (or no) backend loaded — tear down the old one before creating the new.
        if let old = extractAndClearBackend() {
            await Task.detached(priority: .userInitiated) { old.unloadModel() }.value
        }
        let newBackend: any TranscriptionBackend = wantParakeet ? ParakeetBackend() : WhisperCppBackend()
        storeBackend(newBackend, isParakeet: wantParakeet)
        return newBackend
    }

    /// Returns the current backend if it exists and matches the requested type.
    private func currentBackend(matchingParakeet wantParakeet: Bool) -> (any TranscriptionBackend)? {
        lock.lock()
        defer { lock.unlock() }
        guard let backend, backendIsParakeet == wantParakeet else { return nil }
        return backend
    }

    private func storeBackend(_ b: any TranscriptionBackend, isParakeet: Bool) {
        lock.lock()
        backend = b
        backendIsParakeet = isParakeet
        lock.unlock()
    }

    /// Reads the current backend under the lock, synchronously.
    /// Extracted to a non-async method so NSLock can be used safely.
    private func getBackendForTranscription() throws -> any TranscriptionBackend {
        lock.lock()
        defer { lock.unlock() }
        guard let backend else {
            throw TranscriptionError.modelNotLoaded
        }
        return backend
    }

    func unloadModel() async {
        let b = extractAndClearBackend()
        if let b {
            // Run on a non-cooperative thread since unloadModel() may block
            await Task.detached(priority: .userInitiated) { b.unloadModel() }.value
        }
    }

    /// Extracts and nils the backend reference under the lock.
    /// Separate sync method so NSLock is not used from an async context.
    private func extractAndClearBackend() -> (any TranscriptionBackend)? {
        lock.lock()
        defer { lock.unlock() }
        let b = backend
        backend = nil
        backendIsParakeet = false
        return b
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
