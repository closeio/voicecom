import Foundation

protocol TranscriptionBackend: Sendable {
    /// Returns the list of model names available for this backend.
    static func fetchAvailableModels() async throws -> [String]

    /// Downloads (if needed) and loads the named model.
    func loadModel(name: String) async throws

    /// Transcribes a buffer of 16kHz mono Float PCM audio into text.
    func transcribe(audioBuffer: [Float]) async throws -> String

    /// Unloads the current model to free memory.
    func unloadModel()
}
