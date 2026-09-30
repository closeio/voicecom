import SwiftUI

/// Routes every termination path (the Quit button, SwiftUI's built-in Cmd+Q menu item,
/// logout/restart) through `AppState.shutdown()`. The loaded model must be freed before
/// `exit()` runs C++ static destructors — otherwise ggml's Metal device registry is torn
/// down while model buffers are still alive and trips a residency-set assertion.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    private var isShuttingDown = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        if !isShuttingDown {
            isShuttingDown = true
            Task { @MainActor in
                await appState.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

@main
struct voicecomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                    appDelegate.appState = appState
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

