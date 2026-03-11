import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if appState.isRecording {
                Button("Stop Recording") {
                    Task { await appState.toggleRecording() }
                }
            } else if appState.isTranscribing {
                Text("Transcribing...")
            } else {
                Button("Start Recording") {
                    Task { await appState.toggleRecording() }
                }
                .disabled(!appState.isModelLoaded)
            }

            Divider()

            Text(appState.statusMessage)

            if !appState.lastTranscription.isEmpty {
                Text("Last: \(appState.lastTranscription)")
                    .lineLimit(2)
            }

            if let error = appState.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }

            Divider()

            if appState.isModelDownloading {
                Text("Downloading model...")
            } else if appState.isModelLoaded {
                Text("Model: \(appState.selectedModel)")
            } else {
                Text("Model not loaded")
            }

            Divider()

            Button("Settings...") {
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Quit voicecom") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .task {
            await appState.setup()
        }
    }
}
