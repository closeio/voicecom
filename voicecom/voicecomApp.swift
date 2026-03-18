import SwiftUI

@main
struct voicecomApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: menuBarIconName)
                .symbolRenderingMode(.hierarchical)
                .task {
                    // Trigger setup from the label view — it is rendered
                    // immediately at launch, unlike the .window-style content
                    // view which is only created when the popover opens.
                    await appState.setup()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }

    private var menuBarIconName: String {
        if appState.isRecording {
            return "waveform.circle.fill"
        } else if appState.isModelDownloading {
            return "arrow.down.circle"
        } else if appState.isModelLoading {
            return "circle.dashed"
        } else if appState.isModelLoaded {
            return "mic.fill"
        } else {
            return "mic.slash"
        }
    }
}

