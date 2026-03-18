import Foundation

/// Phases reported during model loading.
enum ModelLoadPhase: Sendable {
    case downloading
    case loading
}

nonisolated protocol TranscriptionBackend: Sendable {
    /// Returns the list of model names available for this backend.
    static func fetchAvailableModels() async throws -> [String]

    /// Downloads (if needed) and loads the named model.
    /// - Parameter onPhaseChange: Called when the load transitions between phases
    ///   (e.g. downloading → loading). May be called from any thread.
    func loadModel(name: String, onPhaseChange: (@Sendable (ModelLoadPhase) -> Void)?) async throws

    /// Transcribes a buffer of 16kHz mono Float PCM audio into text.
    /// - Parameters:
    ///   - audioBuffer: 16kHz mono Float PCM samples.
    ///   - language: Language code (e.g. "en", "auto"). Pass "auto" for automatic detection.
    func transcribe(audioBuffer: [Float], language: String) async throws -> String

    /// Unloads the current model to free memory.
    /// May block while waiting for active transcriptions to finish.
    func unloadModel()
}
