import AppKit
import CoreGraphics

@MainActor
final class TextInsertionService {
    /// Tracks the pending paste+restore so we can cancel it if a new paste arrives.
    private var pasteWorkItem: DispatchWorkItem?
    /// The original clipboard items saved before the first paste in a burst.
    /// Stores all types (text, images, files, etc.) so the full clipboard is restored.
    private var savedPasteboardItems: [NSPasteboardItem]?
    /// Monotonically increasing generation counter to detect stale restore callbacks.
    private var pasteGeneration: UInt64 = 0
    /// The pasteboard changeCount after we last set transcription text.
    /// Used to detect if the user copied something between insertText calls.
    private var lastPasteChangeCount: Int = 0

    /// Maximum total byte size of clipboard data we'll save for restore.
    /// Prevents holding very large clipboard contents (e.g. images) in memory.
    private static let maxSavedClipboardBytes = 10 * 1024 * 1024 // 10 MB

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

        // Increment generation so any in-flight restore callbacks become stale
        pasteGeneration &+= 1
        let currentGeneration = pasteGeneration

        // Save the original clipboard if we don't already have a saved copy,
        // or refresh it if the user copied something since our last paste.
        if savedPasteboardItems == nil {
            savedPasteboardItems = Self.copyPasteboardItems(from: pasteboard)
        } else if pasteboard.changeCount != lastPasteChangeCount {
            // User copied something between insertText calls — save their new content
            savedPasteboardItems = Self.copyPasteboardItems(from: pasteboard)
        }

        // Set transcribed text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let changeCountAfterPaste = pasteboard.changeCount
        lastPasteChangeCount = changeCountAfterPaste
        let previousItems = savedPasteboardItems

        // Use a single cancellable work item for the entire paste+restore sequence.
        // This prevents double-paste when insertText is called rapidly — cancelling
        // the work item before it fires skips both the paste and the restore.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.pasteGeneration == currentGeneration else { return }
            self.simulatePaste()

            // Restore previous clipboard after giving the paste time to complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                // Check generation to ensure this callback isn't stale from a
                // previous insertText call that was superseded.
                guard self.pasteGeneration == currentGeneration else { return }
                // Only restore if the clipboard hasn't been changed by the user
                guard pasteboard.changeCount == changeCountAfterPaste else {
                    self.savedPasteboardItems = nil
                    return
                }
                pasteboard.clearContents()
                if let items = previousItems, !items.isEmpty {
                    pasteboard.writeObjects(items)
                }
                self.savedPasteboardItems = nil
            }
        }
        pasteWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        return true
    }

    /// Copies pasteboard items, skipping save entirely if total data exceeds the size limit.
    private static func copyPasteboardItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        var totalBytes = 0
        var copies: [NSPasteboardItem] = []
        for item in items {
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    totalBytes += data.count
                    if totalBytes > maxSavedClipboardBytes {
                        // Clipboard is too large to save — skip restore entirely
                        print("[voicecom] Clipboard data exceeds \(maxSavedClipboardBytes / 1024 / 1024) MB, skipping clipboard restore")
                        return nil
                    }
                    copy.setData(data, forType: type)
                }
            }
            copies.append(copy)
        }
        return copies
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
