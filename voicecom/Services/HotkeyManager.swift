import AppKit

final class HotkeyManager {
    var onToggle: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var registeredKeyCode: UInt16 = 0
    private var registeredModifiers: NSEvent.ModifierFlags = []

    func register(keyCode: UInt16, modifiers: UInt) {
        unregister()

        registeredKeyCode = keyCode
        registeredModifiers = NSEvent.ModifierFlags(rawValue: modifiers)

        // Monitor key events when app is NOT focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handleKeyEvent(event)
        }

        // Monitor key events when app IS focused (e.g., settings window open)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if self?.isMatchingHotkey(event) == true {
                self?.handleKeyEvent(event)
                return nil // Consume the event so it doesn't trigger twice
            }
            return event
        }
    }

    func unregister() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private func isMatchingHotkey(_ event: NSEvent) -> Bool {
        let relevantModifiers: NSEvent.ModifierFlags = [
            .shift, .control, .option, .command
        ]
        let eventMods = event.modifierFlags.intersection(relevantModifiers)
        let targetMods = registeredModifiers.intersection(relevantModifiers)
        return event.keyCode == registeredKeyCode && eventMods == targetMods
    }

    private func handleKeyEvent(_ event: NSEvent) {
        if isMatchingHotkey(event) {
            onToggle?()
        }
    }

    deinit {
        unregister()
    }
}
