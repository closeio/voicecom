import AppKit
import CoreGraphics

final class TextInsertionService {
    /// Tracks the pending clipboard restore so we can cancel it if a new paste arrives.
    private var restoreWorkItem: DispatchWorkItem?
    /// The original clipboard contents saved before the first paste in a burst.
    private var savedClipboardContents: String?

    /// Insert text into the frontmost application by copying to clipboard and simulating Cmd+V.
    /// Preserves and restores the previous clipboard contents.
    ///
    /// If called again before the previous restore completes, the pending restore is
    /// cancelled and the original clipboard contents are preserved across the entire burst.
    func insertText(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Cancel any pending clipboard restore from a previous paste
        restoreWorkItem?.cancel()
        restoreWorkItem = nil

        // Only save the original clipboard if we don't already have a saved copy
        // from a previous in-flight paste (avoids saving our own transcription text)
        if savedClipboardContents == nil {
            savedClipboardContents = pasteboard.string(forType: .string)
        }

        // Set transcribed text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let previousContents = savedClipboardContents

        // Simulate Cmd+V after a short delay to ensure pasteboard is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.simulatePaste()

            // Restore previous clipboard after giving the paste time to complete
            let workItem = DispatchWorkItem { [weak self] in
                pasteboard.clearContents()
                if let previous = previousContents {
                    pasteboard.setString(previous, forType: .string)
                }
                self?.savedClipboardContents = nil
            }
            self?.restoreWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
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
