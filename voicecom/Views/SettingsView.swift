import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .environment(appState)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            PermissionsSettingsTab()
                .environment(appState)
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }
        }
        .frame(width: 480, height: 540)
        .onAppear {
            // Target only the Settings window by its known identifier
            if let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
            }) {
                window.level = .floating
            }
        }
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var isRecordingHotkey = false
    @State private var isRecordingPTTHotkey = false

    var body: some View {
        Form {
            Section("Transcription Model") {
                if appState.availableModels.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading models…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Model", selection: Binding(
                        get: { appState.selectedModel },
                        set: { newValue in
                            if newValue != appState.selectedModel {
                                appState.selectedModel = newValue
                                Task { await appState.loadModel() }
                            }
                        }
                    )) {
                        ForEach(appState.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .disabled(appState.isRecording || appState.isTranscribing)
                }

                if appState.isModelLoading {
                    ProgressView("Downloading model…")
                        .progressViewStyle(.linear)
                }

                if appState.isModelLoaded {
                    Label("Model loaded", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                Picker("Language", selection: Binding(
                    get: { appState.transcriptionLanguage },
                    set: { appState.transcriptionLanguage = $0 }
                )) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("en")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Italian").tag("it")
                    Text("Portuguese").tag("pt")
                    Text("Dutch").tag("nl")
                    Text("Japanese").tag("ja")
                    Text("Chinese").tag("zh")
                    Text("Korean").tag("ko")
                    Text("Russian").tag("ru")
                }

                Text("Use \"Auto-detect\" with multilingual models (e.g. ggml-small, ggml-large). English-only models (.en) always transcribe in English.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Toggle Recording Shortcut") {
                hotkeyRow(
                    label: "Toggle Recording",
                    description: hotkeyDescription,
                    isRecording: $isRecordingHotkey,
                    defaultHint: "Default: ⌥⇧R (Option + Shift + R)",
                    onRecord: { keyCode, modifiers in
                        appState.updateHotkey(keyCode: keyCode, modifiers: modifiers.rawValue)
                    }
                )
            }

            Section("Push-to-Talk") {
                Toggle("Enable Push-to-Talk", isOn: Binding(
                    get: { appState.pttEnabled },
                    set: { appState.setPushToTalkEnabled($0) }
                ))

                if appState.pttEnabled {
                    hotkeyRow(
                        label: "Hold to Record",
                        description: pttHotkeyDescription,
                        isRecording: $isRecordingPTTHotkey,
                        defaultHint: "Default: ⌥⇧T (Option + Shift + T)",
                        onRecord: { keyCode, modifiers in
                            appState.updatePushToTalkHotkey(keyCode: keyCode, modifiers: modifiers.rawValue)
                        }
                    )
                }

                Text("Hold the shortcut to record, release to stop and transcribe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.launchAtLogin = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Hotkey Row

    @ViewBuilder
    private func hotkeyRow(
        label: String,
        description: String,
        isRecording: Binding<Bool>,
        defaultHint: String,
        onRecord: @escaping (UInt16, NSEvent.ModifierFlags) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label + ":")
                Spacer()

                if isRecording.wrappedValue {
                    HotkeyRecorderView { keyCode, modifiers in
                        onRecord(keyCode, modifiers)
                        isRecording.wrappedValue = false
                    }
                    .frame(width: 120, height: 28)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        Text("Press shortcut…")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    )
                } else {
                    KeyCapView(text: description)
                }

                Button(isRecording.wrappedValue ? "Cancel" : "Change") {
                    isRecording.wrappedValue.toggle()
                }
                .controlSize(.small)
            }

            Text(defaultHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var hotkeyDescription: String {
        Self.describeHotkey(keyCode: appState.hotkeyKeyCode, modifiers: appState.hotkeyModifiers)
    }

    private var pttHotkeyDescription: String {
        Self.describeHotkey(keyCode: appState.pttKeyCode, modifiers: appState.pttModifiers)
    }

    private static func describeHotkey(keyCode: UInt16, modifiers: UInt) -> String {
        var parts: [String] = []
        let mods = NSEvent.ModifierFlags(rawValue: modifiers)
        if mods.contains(.control) { parts.append("\u{2303}") }
        if mods.contains(.option) { parts.append("\u{2325}") }
        if mods.contains(.shift) { parts.append("\u{21E7}") }
        if mods.contains(.command) { parts.append("\u{2318}") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    static func keyCodeToString(_ keyCode: UInt16) -> String {
        let keyMap: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
            37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
            22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
            53: "Escape",
            122: "F1", 120: "F2", 99: "F3", 118: "F4",
            96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return keyMap[keyCode] ?? "Key(\(keyCode))"
    }
}

// MARK: - Key Cap View

struct KeyCapView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.background)
                    .shadow(color: .primary.opacity(0.15), radius: 0.5, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }
}

// MARK: - Permissions Tab

struct PermissionsSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var micPermission = false
    @State private var accessibilityPermission = false

    var body: some View {
        Form {
            Section("Required Permissions") {
                permissionRow(
                    title: "Microphone Access",
                    icon: "mic.fill",
                    granted: micPermission,
                    hint: "Will be requested on first recording",
                    action: nil
                )

                permissionRow(
                    title: "Accessibility (for text paste)",
                    icon: "keyboard",
                    granted: accessibilityPermission,
                    hint: nil,
                    action: {
                        appState.permissionManager.openAccessibilitySettings()
                    }
                )
            }

            Section {
                Text("Microphone access is requested automatically when you start your first recording. Accessibility access must be granted in System Settings to allow pasting text into other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .padding()
        .task {
            refreshPermissions()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                refreshPermissions()
            }
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        icon: String,
        granted: Bool,
        hint: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(granted ? .green : .secondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let action {
                Button("Open System Settings", action: action)
                    .controlSize(.small)
            } else if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refreshPermissions() {
        micPermission = appState.permissionManager.hasMicrophonePermission
        accessibilityPermission = appState.permissionManager.hasAccessibilityPermission
    }
}
