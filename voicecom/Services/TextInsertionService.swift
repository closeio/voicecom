import AppKit
import CoreGraphics

@MainActor
final class TextInsertionService {
    /// Tracks the pending paste+restore so we can cancel it if a new paste arrives.
    private var pasteWorkItem: DispatchWorkItem?
    /// The original clipboard items saved before the first paste in a burst.
    /// Stores all types (text, images, files, etc.) so the full clipboard is restored.
    private var savedPasteboardItems: [NSPasteboardItem]?

    /// Insert text into the frontmost application by copying to clipboard and simulating Cmd+V.
    /// Preserves and restores the previous clipboard contents.
    ///
    /// If called again before the previous restore completes, the pending paste is
    /// cancelled and the original clipboard contents are preserved across the entire burst.
    ///
    /// Returns `false` if accessibility permission is not granted (paste cannot be simulated).
    /// In that case the transcription text remains on the clipboard for manual pasting.
    @discardableResult
    func insertText(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else {
            print("[voicecom] Accessibility permission not granted — text copied to clipboard for manual paste")
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return false
        }

        let pasteboard = NSPasteboard.general

        // Cancel any pending paste+restore from a previous call
        pasteWorkItem?.cancel()
        pasteWorkItem = nil

        // Only save the original clipboard if we don't already have a saved copy
        // from a previous in-flight paste (avoids saving our own transcription text)
        if savedPasteboardItems == nil {
            savedPasteboardItems = pasteboard.pasteboardItems?.map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        copy.setData(data, forType: type)
                    }
                }
                return copy
            }
        }

        // Set transcribed text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let changeCountAfterPaste = pasteboard.changeCount
        let previousItems = savedPasteboardItems

        // Use a single cancellable work item for the entire paste+restore sequence.
        // This prevents double-paste when insertText is called rapidly — cancelling
        // the work item before it fires skips both the paste and the restore.
        let workItem = DispatchWorkItem { [weak self] in
            self?.simulatePaste()

            // Restore previous clipboard after giving the paste time to complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                // Only restore if the clipboard hasn't been changed by the user
                guard pasteboard.changeCount == changeCountAfterPaste else {
                    self?.savedPasteboardItems = nil
                    return
                }
                pasteboard.clearContents()
                if let items = previousItems, !items.isEmpty {
                    pasteboard.writeObjects(items)
                }
                self?.savedPasteboardItems = nil
            }
        }
        pasteWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        return true
    }

    private func simulatePaste() {

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
