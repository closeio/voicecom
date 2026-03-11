import AppKit

final class HotkeyManager {
    // MARK: - Toggle mode callbacks
    var onToggle: (() -> Void)?

    // MARK: - Push-to-talk callbacks
    var onPushToTalkDown: (() -> Void)?
    var onPushToTalkUp: (() -> Void)?

    // MARK: - Toggle hotkey state
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var registeredKeyCode: UInt16 = 0
    private var registeredModifiers: NSEvent.ModifierFlags = []

    // MARK: - Push-to-talk hotkey state
    private var pttGlobalKeyDownMonitor: Any?
    private var pttGlobalKeyUpMonitor: Any?
    private var pttLocalKeyDownMonitor: Any?
    private var pttLocalKeyUpMonitor: Any?
    private var pttKeyCode: UInt16 = 0
    private var pttModifiers: NSEvent.ModifierFlags = []
    private var pttEnabled = false
    private var pttIsHeld = false

    // MARK: - Toggle hotkey

    func register(keyCode: UInt16, modifiers: UInt) {
        unregisterToggle()

        registeredKeyCode = keyCode
        registeredModifiers = NSEvent.ModifierFlags(rawValue: modifiers)

        // Monitor key events when app is NOT focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handleToggleKeyEvent(event)
        }

        // Monitor key events when app IS focused (e.g., settings window open)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if self?.isMatchingToggleHotkey(event) == true {
                self?.handleToggleKeyEvent(event)
                return nil // Consume the event so it doesn't trigger twice
            }
            return event
        }
    }

    private func unregisterToggle() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private func isMatchingToggleHotkey(_ event: NSEvent) -> Bool {
        let relevantModifiers: NSEvent.ModifierFlags = [
            .shift, .control, .option, .command
        ]
        let eventMods = event.modifierFlags.intersection(relevantModifiers)
        let targetMods = registeredModifiers.intersection(relevantModifiers)
        return event.keyCode == registeredKeyCode && eventMods == targetMods
    }

    private func handleToggleKeyEvent(_ event: NSEvent) {
        if isMatchingToggleHotkey(event) {
            onToggle?()
        }
    }

    // MARK: - Push-to-talk hotkey

    func registerPushToTalk(keyCode: UInt16, modifiers: UInt) {
        unregisterPushToTalk()

        pttKeyCode = keyCode
        pttModifiers = NSEvent.ModifierFlags(rawValue: modifiers)
        pttEnabled = true

        // Global monitors (app not focused)
        pttGlobalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handlePTTKeyDown(event)
        }
        pttGlobalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) {
            [weak self] event in
            self?.handlePTTKeyUp(event)
        }

        // Local monitors (app focused)
        pttLocalKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if self?.isMatchingPTTHotkey(event) == true {
                self?.handlePTTKeyDown(event)
                return nil
            }
            return event
        }
        pttLocalKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) {
            [weak self] event in
            if self?.isMatchingPTTHotkey(event) == true {
                self?.handlePTTKeyUp(event)
                return nil
            }
            return event
        }
    }

    func unregisterPushToTalk() {
        if let pttGlobalKeyDownMonitor {
            NSEvent.removeMonitor(pttGlobalKeyDownMonitor)
        }
        if let pttGlobalKeyUpMonitor {
            NSEvent.removeMonitor(pttGlobalKeyUpMonitor)
        }
        if let pttLocalKeyDownMonitor {
            NSEvent.removeMonitor(pttLocalKeyDownMonitor)
        }
        if let pttLocalKeyUpMonitor {
            NSEvent.removeMonitor(pttLocalKeyUpMonitor)
        }
        pttGlobalKeyDownMonitor = nil
        pttGlobalKeyUpMonitor = nil
        pttLocalKeyDownMonitor = nil
        pttLocalKeyUpMonitor = nil
        pttEnabled = false
        pttIsHeld = false
    }

    private func isMatchingPTTHotkey(_ event: NSEvent) -> Bool {
        let relevantModifiers: NSEvent.ModifierFlags = [
            .shift, .control, .option, .command
        ]
        let eventMods = event.modifierFlags.intersection(relevantModifiers)
        let targetMods = pttModifiers.intersection(relevantModifiers)
        return event.keyCode == pttKeyCode && eventMods == targetMods
    }

    private func handlePTTKeyDown(_ event: NSEvent) {
        guard pttEnabled, isMatchingPTTHotkey(event), !pttIsHeld else { return }
        pttIsHeld = true
        onPushToTalkDown?()
    }

    private func handlePTTKeyUp(_ event: NSEvent) {
        // For keyUp, only check keyCode — modifiers may already be released
        guard pttEnabled, event.keyCode == pttKeyCode, pttIsHeld else { return }
        pttIsHeld = false
        onPushToTalkUp?()
    }

    // MARK: - Cleanup

    func unregister() {
        unregisterToggle()
        unregisterPushToTalk()
    }

    deinit {
        unregister()
    }
}
