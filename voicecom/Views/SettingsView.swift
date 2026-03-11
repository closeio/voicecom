import SwiftUI

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
        .frame(width: 450, height: 420)
        .onAppear {
            // Keep settings window above other windows since this is a menu bar app
            if let window = NSApp.windows.first(where: { $0.isVisible }) {
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
                    Text("Loading models...")
                        .foregroundStyle(.secondary)
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
                }

                if appState.isModelDownloading {
                    ProgressView("Downloading model...")
                        .progressViewStyle(.linear)
                }

                if appState.isModelLoaded {
                    Label("Model loaded", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section("Global Keyboard Shortcut") {
                HStack {
                    Text("Toggle Recording:")
                    Spacer()

                    if isRecordingHotkey {
                        HotkeyRecorderView { keyCode, modifiers in
                            appState.updateHotkey(
                                keyCode: keyCode,
                                modifiers: modifiers.rawValue
                            )
                            isRecordingHotkey = false
                        }
                        .frame(width: 120, height: 24)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            Text("Press shortcut...")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        )
                    } else {
                        Text(hotkeyDescription)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    Button(isRecordingHotkey ? "Cancel" : "Change") {
                        isRecordingHotkey.toggle()
                    }
                }

                Text("Default: \u{2325}\u{21E7}R (Option + Shift + R)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Push-to-Talk Shortcut") {
                Toggle("Enable Push-to-Talk", isOn: Binding(
                    get: { appState.pttEnabled },
                    set: { appState.setPushToTalkEnabled($0) }
                ))

                if appState.pttEnabled {
                    HStack {
                        Text("Hold to Record:")
                        Spacer()

                        if isRecordingPTTHotkey {
                            HotkeyRecorderView { keyCode, modifiers in
                                appState.updatePushToTalkHotkey(
                                    keyCode: keyCode,
                                    modifiers: modifiers.rawValue
                                )
                                isRecordingPTTHotkey = false
                            }
                            .frame(width: 120, height: 24)
                            .background(Color.orange.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                Text("Press shortcut...")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            )
                        } else {
                            Text(pttHotkeyDescription)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }

                        Button(isRecordingPTTHotkey ? "Cancel" : "Change") {
                            isRecordingPTTHotkey.toggle()
                        }
                    }

                    Text("Default: \u{2325}\u{21E7}T (Option + Shift + T)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Hold the shortcut to record, release to stop and transcribe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
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

// MARK: - Permissions Tab

struct PermissionsSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var micPermission = false
    @State private var accessibilityPermission = false
    @State private var refreshTimer: Timer?

    var body: some View {
        Form {
            Section("Required Permissions") {
                HStack {
                    Label {
                        Text("Microphone Access")
                    } icon: {
                        Image(systemName: micPermission
                              ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(micPermission ? .green : .red)
                    }
                    Spacer()
                    if !micPermission {
                        Text("Will be requested on first recording")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Label {
                        Text("Accessibility (for text paste)")
                    } icon: {
                        Image(systemName: accessibilityPermission
                              ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(accessibilityPermission ? .green : .red)
                    }
                    Spacer()
                    if !accessibilityPermission {
                        Button("Open System Settings") {
                            appState.permissionManager.requestAccessibilityPermission()
                        }
                    }
                }
            }

            Section {
                Text("Microphone access is requested automatically when you start your first recording. Accessibility access must be granted in System Settings to allow pasting text into other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Note: During development (running from Xcode), permissions reset on each build because the app signature changes.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            refreshPermissions()
            // Poll every 2 seconds so status updates after user grants in System Settings
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                Task { @MainActor in
                    refreshPermissions()
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func refreshPermissions() {
        micPermission = appState.permissionManager.hasMicrophonePermission
        accessibilityPermission = appState.permissionManager.hasAccessibilityPermission
    }
}
