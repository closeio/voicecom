import SwiftUI
import AVFoundation

@Observable
@MainActor
final class AppState {
    // MARK: - UI State
    var isRecording = false
    var isTranscribing = false
    var isModelLoaded = false
    var isModelDownloading = false
    var modelDownloadProgress: Double = 0.0
    var statusMessage = "Ready"
    var lastTranscription = ""
    var errorMessage: String?

    // MARK: - Settings
    var selectedModel: String {
        get { UserDefaults.standard.string(forKey: "selectedModel") ?? "openai_whisper-small.en" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedModel") }
    }

    var hotkeyKeyCode: UInt16 {
        get { UInt16(UserDefaults.standard.integer(forKey: "hotkeyKeyCode")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "hotkeyKeyCode") }
    }

    var hotkeyModifiers: UInt {
        get { UInt(UserDefaults.standard.integer(forKey: "hotkeyModifiers")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "hotkeyModifiers") }
    }

    // MARK: - Services
    let audioRecorder = AudioRecorder()
    let transcriptionService = TranscriptionService()
    let textInsertionService = TextInsertionService()
    let hotkeyManager = HotkeyManager()
    let permissionManager = PermissionManager()

    // MARK: - Available Models
    var availableModels: [String] = []

    private var hasSetup = false

    init() {
        // Set default hotkey if not configured: Option+Shift+R
        if UserDefaults.standard.object(forKey: "hotkeyKeyCode") == nil {
            hotkeyKeyCode = 15 // "R" key
            hotkeyModifiers = UInt(
                NSEvent.ModifierFlags.option.rawValue |
                NSEvent.ModifierFlags.shift.rawValue
            )
        }
    }

    // MARK: - Lifecycle

    func setup() async {
        guard !hasSetup else { return }
        hasSetup = true

        // Prompt for accessibility permission if not yet granted
        permissionManager.requestAccessibilityPermission()

        hotkeyManager.onToggle = { [weak self] in
            Task { @MainActor in
                await self?.toggleRecording()
            }
        }
        hotkeyManager.register(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)

        await loadAvailableModels()
        await loadModel()
    }

    func loadAvailableModels() async {
        do {
            let models = try await TranscriptionService.fetchAvailableModels()
            self.availableModels = models

            // If the saved selection isn't supported on this device, pick a default
            if !models.contains(selectedModel), let first = models.last {
                selectedModel = first
            }
        } catch {
            self.errorMessage = "Failed to fetch models: \(error.localizedDescription)"
            // Provide a fallback list
            self.availableModels = [
                "openai_whisper-tiny",
                "openai_whisper-tiny.en",
                "openai_whisper-base",
                "openai_whisper-base.en",
                "openai_whisper-small",
                "openai_whisper-small.en",
                "openai_whisper-large-v3",
            ]
        }
    }

    /// Load a model. Uses local cache if available, downloads if not.
    func loadModel() async {
        isModelDownloading = true
        isModelLoaded = false
        statusMessage = "Loading model..."
        errorMessage = nil

        do {
            try await transcriptionService.loadModel(name: selectedModel)
            isModelLoaded = true
            isModelDownloading = false
            statusMessage = "Ready"
        } catch {
            isModelDownloading = false
            errorMessage = "Model failed: \(error.localizedDescription)"
            statusMessage = "Model not loaded"
        }
    }

    func toggleRecording() async {
        if isRecording {
            await stopRecordingAndTranscribe()
        } else {
            await startRecording()
        }
    }

    func updateHotkey(keyCode: UInt16, modifiers: UInt) {
        hotkeyKeyCode = keyCode
        hotkeyModifiers = modifiers
        hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
    }

    // MARK: - Private

    private func startRecording() async {
        guard isModelLoaded else {
            statusMessage = "Model not loaded yet"
            return
        }

        // Check and request mic permission
        if AVAudioApplication.shared.recordPermission != .granted {
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted {
                errorMessage = "Microphone permission denied"
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        do {
            try audioRecorder.startRecording()
            isRecording = true
            errorMessage = nil
            statusMessage = "Recording..."
        } catch {
            errorMessage = "Recording failed: \(error.localizedDescription)"
            print("[voicecom] Recording start error: \(error)")
        }
    }

    private func stopRecordingAndTranscribe() async {
        let audioBuffer = audioRecorder.stopRecording()
        isRecording = false
        isTranscribing = true
        statusMessage = "Transcribing..."

        guard !audioBuffer.isEmpty else {
            isTranscribing = false
            statusMessage = "Ready"
            errorMessage = "No audio recorded"
            return
        }

        do {
            let text = try await transcriptionService.transcribe(audioBuffer: audioBuffer)
            lastTranscription = text
            isTranscribing = false

            if !text.isEmpty {
                statusMessage = "Pasting..."
                print("[voicecom] Transcription result: \(text)")
                textInsertionService.insertText(text)
                statusMessage = "Ready"
            } else {
                statusMessage = "Ready"
                errorMessage = "No speech detected"
            }
        } catch {
            isTranscribing = false
            errorMessage = "Transcription failed: \(error.localizedDescription)"
            statusMessage = "Ready"
            print("[voicecom] Transcription error: \(error)")
        }
    }
}
