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
    var isModelLoading = false
    var isModelDownloading = false
    var statusMessage = "Ready"
    var lastTranscription = ""
    var errorMessage: String?

    // MARK: - Settings
    var selectedModel: String {
        get { UserDefaults.standard.string(forKey: "selectedModel") ?? "ggml-small" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedModel") }
    }

    /// Default toggle hotkey: Option+Shift+R
    private static let defaultHotkeyKeyCode: UInt16 = 15 // "R" key
    private static let defaultHotkeyModifiers: UInt = UInt(
        NSEvent.ModifierFlags.option.rawValue | NSEvent.ModifierFlags.shift.rawValue
    )

    var hotkeyKeyCode: UInt16 {
        get {
            guard UserDefaults.standard.object(forKey: "hotkeyKeyCode") != nil else {
                return Self.defaultHotkeyKeyCode
            }
            return UInt16(clamping: UserDefaults.standard.integer(forKey: "hotkeyKeyCode"))
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: "hotkeyKeyCode") }
    }

    var hotkeyModifiers: UInt {
        get {
            guard UserDefaults.standard.object(forKey: "hotkeyModifiers") != nil else {
                return Self.defaultHotkeyModifiers
            }
            return UInt(clamping: UserDefaults.standard.integer(forKey: "hotkeyModifiers"))
        }
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

    /// Default push-to-talk hotkey: Option+Shift+T
    private static let defaultPttKeyCode: UInt16 = 17 // "T" key
    private static let defaultPttModifiers: UInt = UInt(
        NSEvent.ModifierFlags.option.rawValue | NSEvent.ModifierFlags.shift.rawValue
    )

    var pttKeyCode: UInt16 {
        get {
            guard UserDefaults.standard.object(forKey: "pttKeyCode") != nil else {
                return Self.defaultPttKeyCode
            }
            return UInt16(clamping: UserDefaults.standard.integer(forKey: "pttKeyCode"))
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: "pttKeyCode") }
    }

    var pttModifiers: UInt {
        get {
            guard UserDefaults.standard.object(forKey: "pttModifiers") != nil else {
                return Self.defaultPttModifiers
            }
            return UInt(clamping: UserDefaults.standard.integer(forKey: "pttModifiers"))
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: "pttModifiers") }
    }

    /// Language code for transcription (e.g. "en", "auto").
    /// Use "auto" to let Whisper detect the language automatically.
    var transcriptionLanguage: String {
        get { UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: "transcriptionLanguage") }
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
    /// Generation counter for model loads — used to detect stale onPhaseChange callbacks.
    private var loadModelGeneration: UInt64 = 0

    // Defaults for hotkey and PTT are handled in the computed property getters,
    // so no explicit init is needed to set them.

    // MARK: - Lifecycle

    func setup() async {
        guard !hasSetup else { return }
        hasSetup = true

        // Clean up stale temp recordings from previous sessions once at launch
        AudioRecorder.cleanupStaleTempFiles()

        permissionManager.requestAccessibilityPermission()

        // Auto-stop recording if max duration is reached
        audioRecorder.onMaxDurationReached = { [weak self] in
            Task { @MainActor in
                await self?.stopRecordingIfNeeded()
            }
        }

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
    /// Cancels any in-flight load and waits for it to finish before starting a new one.
    /// No-op if recording or transcribing to avoid pulling the model out mid-operation.
    func loadModel() async {
        guard !isRecording, !isTranscribing else { return }

        loadModelTask?.cancel()
        await loadModelTask?.value

        loadModelGeneration &+= 1
        isModelLoading = true
        isModelDownloading = false
        isModelLoaded = false
        statusMessage = "Loading model…"
        errorMessage = nil

        let model = selectedModel
        let task = Task {
            defer {
                // Always reset loading flags when the task ends, even on cancellation.
                // This prevents a perpetual "Loading model…" state if the task is
                // cancelled after the model was already loaded in the backend.
                if Task.isCancelled {
                    isModelLoading = false
                    isModelDownloading = false
                }
            }
            do {
                try await transcriptionService.loadModel(name: model) { [weak self, generation = self.loadModelGeneration] phase in
                    Task { @MainActor [weak self] in
                        // Check generation to discard stale callbacks from cancelled loads
                        guard let self, self.loadModelGeneration == generation else { return }
                        switch phase {
                        case .downloading:
                            self.isModelDownloading = true
                            self.statusMessage = "Downloading model…"
                        case .loading:
                            self.isModelDownloading = false
                            self.statusMessage = "Loading model…"
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                isModelLoaded = true
                isModelLoading = false
                isModelDownloading = false
                statusMessage = "Ready"
            } catch {
                guard !Task.isCancelled else { return }
                isModelLoading = false
                isModelDownloading = false
                errorMessage = "Model failed: \(error.localizedDescription)"
                statusMessage = "Model not loaded"
            }
        }
        loadModelTask = task
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

    /// Cleanly release the loaded model before the process exits.
    func shutdown() async {
        // Unregister hotkeys first to prevent callbacks during teardown
        hotkeyManager.unregister()

        loadModelTask?.cancel()
        await loadModelTask?.value
        await transcriptionService.unloadModel()
        isModelLoaded = false
    }

    // MARK: - Private

    private func startRecording() async {
        guard isModelLoaded, !isTranscribing else {
            if !isModelLoaded { statusMessage = "Model not loaded yet" }
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
            let text = try await transcriptionService.transcribe(audioBuffer: audioBuffer, language: transcriptionLanguage)
            lastTranscription = text
            isTranscribing = false

            if !text.isEmpty {
                statusMessage = "Pasting..."
                print("[voicecom] Transcription result: \(text)")
                let pasted = textInsertionService.insertText(text)
                if pasted {
                    // Delay resetting status so the user can see "Pasting..."
                    // (insertText is asynchronous — the paste happens after ~0.1s)
                    try? await Task.sleep(for: .milliseconds(300))
                    statusMessage = "Ready"
                } else {
                    statusMessage = "Ready"
                    errorMessage = "Accessibility denied — text copied to clipboard"
                }
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
