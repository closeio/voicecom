import SwiftUI
import AppKit

/// A view that captures a keyboard shortcut when focused.
struct HotkeyRecorderView: NSViewRepresentable {
    /// When `false`, the recorder accepts a key press with no modifier keys.
    var requireModifiers: Bool = true
    var onKeyRecorded: (UInt16, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.requireModifiers = requireModifiers
        view.onKeyRecorded = onKeyRecorded
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.requireModifiers = requireModifiers
        // Only request first responder if not already active, to avoid
        // stealing focus on unrelated SwiftUI body re-evaluations.
        if let window = nsView.window, window.firstResponder !== nsView {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

class HotkeyRecorderNSView: NSView {
    var requireModifiers = true
    var onKeyRecorded: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    private var localMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            // Only register the monitor once to avoid accumulating duplicate monitors
            guard localMonitor == nil else { return }
            // Use a local event monitor to intercept key events before other monitors
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let relevantModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
                let modifiers = event.modifierFlags.intersection(relevantModifiers)
                if !modifiers.isEmpty || !self.requireModifiers {
                    self.onKeyRecorded?(event.keyCode, modifiers)
                    return nil // Consume the event so HotkeyManager doesn't see it
                }
                return event
            }
        } else {
            // View removed from window — clean up monitor
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
            }
            localMonitor = nil
        }
    }

    override func removeFromSuperview() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        super.removeFromSuperview()
    }

    // Note: No deinit — Swift 6 strict concurrency prevents accessing
    // non-Sendable `localMonitor` from nonisolated deinit. Monitor cleanup
    // is handled by removeFromSuperview() and viewDidMoveToWindow(nil).

    // keyDown is intentionally not overridden — the local event monitor handles
    // all key capture and consumes the event so it doesn't propagate to other monitors.
}
