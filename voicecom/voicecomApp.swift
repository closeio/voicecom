import SwiftUI

@main
struct voicecomApp: App {
    @State private var appState = AppState()

    init() {
        // Trigger setup immediately so the model loads at launch,
        // rather than waiting for the user to open the menu bar popover.
        let state = _appState.wrappedValue
        Task { @MainActor in
            await state.setup()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: menuBarIconName)
                .symbolRenderingMode(.hierarchical)
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

