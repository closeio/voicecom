import AppKit
import CoreGraphics

final class TextInsertionService {
    /// Insert text into the frontmost application by copying to clipboard and simulating Cmd+V.
    /// Preserves and restores the previous clipboard contents.
    func insertText(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard
        let previousContents = pasteboard.string(forType: .string)

        // Set transcribed text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V after a short delay to ensure pasteboard is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.simulatePaste()

            // Restore previous clipboard after giving the paste time to complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                pasteboard.clearContents()
                if let previous = previousContents {
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }
    }

    private func simulatePaste() {
        // Check accessibility permission first
        guard AXIsProcessTrusted() else {
            print("[voicecom] Accessibility permission not granted — cannot simulate paste")
            return
        }

        let vKeyCode: CGKeyCode = 9 // "V" key

        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: vKeyCode,
            keyDown: true
        ) else {
            print("[voicecom] Failed to create keyDown event")
            return
        }
        keyDown.flags = .maskCommand

        guard let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: vKeyCode,
            keyDown: false
        ) else {
            print("[voicecom] Failed to create keyUp event")
            return
        }
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}

