import SwiftUI
import AppKit

/// A view that captures a keyboard shortcut when focused.
struct HotkeyRecorderView: NSViewRepresentable {
    var onKeyRecorded: (UInt16, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onKeyRecorded = onKeyRecorded
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        // Ensure the view becomes first responder once it's in the window
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

class HotkeyRecorderNSView: NSView {
    var onKeyRecorded: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    private var localMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            // Use a local event monitor to intercept key events before other monitors
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let relevantModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
                let modifiers = event.modifierFlags.intersection(relevantModifiers)
                if !modifiers.isEmpty {
                    self.onKeyRecorded?(event.keyCode, modifiers)
                    return nil // Consume the event so HotkeyManager doesn't see it
                }
                return event
            }
        }
    }

    override func removeFromSuperview() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        super.removeFromSuperview()
    }

    override func keyDown(with event: NSEvent) {
        let relevantModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let modifiers = event.modifierFlags.intersection(relevantModifiers)

        // Require at least one modifier key
        if !modifiers.isEmpty {
            onKeyRecorded?(event.keyCode, modifiers)
        }
    }
}
