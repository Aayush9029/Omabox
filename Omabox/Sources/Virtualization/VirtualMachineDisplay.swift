import SwiftUI
import Virtualization

@MainActor
protocol GuestHostKeyboardCommandHandling: AnyObject {
    func handleHostKeyboardEvent(_ event: NSEvent) -> Bool
}

enum ReservedHostKeyboardCommand: Equatable {
    case palette
    case settings
    case releaseInput

    static let paletteKeyEquivalent = "k"
    static let paletteModifierFlags: NSEvent.ModifierFlags = [.control, .option, .command]

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let characters = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == Self.paletteModifierFlags, characters == Self.paletteKeyEquivalent {
            self = .palette
        } else if modifiers == .command, characters == "," {
            self = .settings
        } else if event.keyCode == 53, modifiers.contains([.control, .option]) {
            self = .releaseInput
        } else {
            return nil
        }
    }
}

struct VirtualMachineDisplay: NSViewRepresentable {
    var machine: VZVirtualMachine
    var capturesSystemKeys: Bool
    var acceptsGuestInput: Bool

    func makeNSView(context: Context) -> GuestDisplayView {
        let view = GuestDisplayView()
        view.virtualMachine = machine
        view.automaticallyReconfiguresDisplay = true
        view.acceptsGuestInput = acceptsGuestInput
        view.prefersSystemKeyCapture = capturesSystemKeys
        view.setAccessibilityIdentifier("guestDisplay")
        view.setAccessibilityLabel("Omarchy Linux desktop")
        return view
    }

    func updateNSView(_ view: GuestDisplayView, context: Context) {
        if view.virtualMachine !== machine { view.virtualMachine = machine }
        view.acceptsGuestInput = acceptsGuestInput
        view.prefersSystemKeyCapture = capturesSystemKeys
    }

    static func dismantleNSView(_ view: GuestDisplayView, coordinator: ()) {
        view.acceptsGuestInput = false
        view.virtualMachine = nil
    }
}

@MainActor
final class GuestDisplayView: VZVirtualMachineView {
    static weak var hostKeyboardCommandHandler: (any GuestHostKeyboardCommandHandling)?
    var reservedShortcutHandler: ((NSEvent) -> Bool)?

    var acceptsGuestInput = true {
        didSet {
            if !acceptsGuestInput, window?.firstResponder === self {
                window?.makeFirstResponder(nil)
            }
            updateSystemKeyCapture()
        }
    }

    var prefersSystemKeyCapture = false {
        didSet { updateSystemKeyCapture() }
    }

    override var acceptsFirstResponder: Bool {
        acceptsGuestInput && super.acceptsFirstResponder
    }

    override func becomeFirstResponder() -> Bool {
        guard acceptsGuestInput else { return false }
        let accepted = super.becomeFirstResponder()
        if accepted { capturesSystemKeys = prefersSystemKeyCapture }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { capturesSystemKeys = false }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSystemKeyCapture()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleReservedShortcut(event) { return true }
        guard acceptsGuestInput else { return false }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard !handleReservedShortcut(event) else { return }
        guard acceptsGuestInput else { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        guard acceptsGuestInput else { return }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard acceptsGuestInput else { return }
        super.flagsChanged(with: event)
    }

    private func handleReservedShortcut(_ event: NSEvent) -> Bool {
        if let reservedShortcutHandler { return reservedShortcutHandler(event) }
        return Self.hostKeyboardCommandHandler?.handleHostKeyboardEvent(event) ?? false
    }

    private func updateSystemKeyCapture() {
        capturesSystemKeys = acceptsGuestInput && prefersSystemKeyCapture && window?.firstResponder === self
    }
}
