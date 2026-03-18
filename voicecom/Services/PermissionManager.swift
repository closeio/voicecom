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
                let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
            }
        }
    }

    /// Open System Settings directly to the Accessibility pane.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
