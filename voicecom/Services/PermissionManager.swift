import AVFoundation
import AppKit
import ApplicationServices

nonisolated final class PermissionManager: Sendable {
    var hasMicrophonePermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func requestMicrophonePermission() async {
        _ = await AVAudioApplication.requestRecordPermission()
    }

    /// Prompt the user to grant Accessibility permission.
    /// Dispatches to a background thread because `AXIsProcessTrustedWithOptions`
    /// can block the calling thread while it talks to the system service.
    func requestAccessibilityPermission() {
        if !AXIsProcessTrusted() {
            DispatchQueue.global(qos: .userInitiated).async {
                // Use the string value directly to avoid Swift 6 concurrency warnings
                // about the shared mutable kAXTrustedCheckOptionPrompt global.
                let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
            }
        }
    }

    /// Open System Settings directly to the Accessibility pane.
    func openAccessibilitySettings() {
        // Modern macOS (Ventura+) uses the Privacy & Security > Accessibility path
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
