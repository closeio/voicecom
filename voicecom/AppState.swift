import SwiftUI
import AVFoundation
import ServiceManagement

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
        get { UserDefaults.standard.string(forKey: "selectedModel") ?? "ggml-small" }
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

    var pttEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "pttEnabled") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "pttEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "pttEnabled") }
    }

    var pttKeyCode: UInt16 {
        get { UInt16(UserDefaults.standard.integer(forKey: "pttKeyCode")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "pttKeyCode") }
    }

    var pttModifiers: UInt {
        get { UInt(UserDefaults.standard.integer(forKey: "pttModifiers")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "pttModifiers") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("[voicecom] Failed to \(newValue ? "enable" : "disable") launch at login: \(error)")
            }
        }
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
    private var loadModelTask: Task<Void, Never>?

    init() {
        // Set default hotkey if not configured: Option+Shift+R
        if UserDefaults.standard.object(forKey: "hotkeyKeyCode") == nil {
            hotkeyKeyCode = 15 // "R" key
            hotkeyModifiers = UInt(
                NSEvent.ModifierFlags.option.rawValue |
                NSEvent.ModifierFlags.shift.rawValue
            )
        }

        // Set default push-to-talk hotkey if not configured: Option+Shift+T
        if UserDefaults.standard.object(forKey: "pttKeyCode") == nil {
            pttKeyCode = 17 // "T" key
            pttModifiers = UInt(
                NSEvent.ModifierFlags.option.rawValue |
                NSEvent.ModifierFlags.shift.rawValue
            )
        }
    }

    // MARK: - Lifecycle

    func setup() async {
        guard !hasSetup else { return }
        hasSetup = true

         permissionManager.requestAccessibilityPermission()

        hotkeyManager.onToggle = { [weak self] in
            Task { @MainActor in
                await self?.toggleRecording()
            }
        }
        hotkeyManager.register(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)

        hotkeyManager.onPushToTalkDown = { [weak self] in
            Task { @MainActor in
                await self?.startRecordingIfNeeded()
            }
        }
        hotkeyManager.onPushToTalkUp = { [weak self] in
            Task { @MainActor in
                await self?.stopRecordingIfNeeded()
            }
        }
        if pttEnabled {
            hotkeyManager.registerPushToTalk(keyCode: pttKeyCode, modifiers: pttModifiers)
        }

        await loadAvailableModels()
        await loadModel()
    }

    func loadAvailableModels() async {
        do {
            let models = try await transcriptionService.fetchAvailableModels()
            self.availableModels = models

            // If the saved selection isn't supported on this device, pick a default
            if !models.contains(selectedModel), let first = models.last {
                selectedModel = first
            }
        } catch {
            self.errorMessage = "Failed to fetch models: \(error.localizedDescription)"
            self.availableModels = [
                "ggml-tiny.en",
                "ggml-base.en",
                "ggml-small.en",
                "ggml-medium.en",
                "ggml-large-v3-turbo",
            ]
        }
    }

    /// Load a model. Uses local cache if available, downloads if not.
    /// Cancels any in-flight load before starting a new one.
    func loadModel() async {
        loadModelTask?.cancel()

        isModelDownloading = true
        isModelLoaded = false
        statusMessage = "Loading model..."
        errorMessage = nil

        let model = selectedModel
        let task = Task {
            do {
                try await transcriptionService.loadModel(name: model)
                guard !Task.isCancelled else { return }
                isModelLoaded = true
                isModelDownloading = false
                statusMessage = "Ready"
            } catch {
                guard !Task.isCancelled else { return }
                isModelDownloading = false
                errorMessage = "Model failed: \(error.localizedDescription)"
                statusMessage = "Model not loaded"
            }
        }
        loadModelTask = task
        await task.value
    }

    private var isToggling = false

    func toggleRecording() async {
        guard !isToggling else { return }
        isToggling = true
        defer { isToggling = false }

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

    func updatePushToTalkHotkey(keyCode: UInt16, modifiers: UInt) {
        pttKeyCode = keyCode
        pttModifiers = modifiers
        if pttEnabled {
            hotkeyManager.registerPushToTalk(keyCode: keyCode, modifiers: modifiers)
        }
    }

    func setPushToTalkEnabled(_ enabled: Bool) {
        pttEnabled = enabled
        if enabled {
            hotkeyManager.registerPushToTalk(keyCode: pttKeyCode, modifiers: pttModifiers)
        } else {
            hotkeyManager.unregisterPushToTalk()
        }
    }

    /// Start recording (used by push-to-talk key down). No-op if already recording.
    func startRecordingIfNeeded() async {
        guard !isRecording, !isTranscribing else { return }
        await startRecording()
    }

    /// Stop recording and transcribe (used by push-to-talk key up). No-op if not recording.
    func stopRecordingIfNeeded() async {
        guard isRecording else { return }
        await stopRecordingAndTranscribe()
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
        errorMessage = nil

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
                // Delay resetting status so the user can see "Pasting..."
                // (insertText is asynchronous — the paste happens after ~0.1s)
                try? await Task.sleep(for: .milliseconds(300))
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
