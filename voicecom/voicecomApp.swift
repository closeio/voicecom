import SwiftUI

@main
struct voicecomApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: appState.isRecording ? "mic.fill" : "mic")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
