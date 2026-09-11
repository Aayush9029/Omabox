import AppKit

@MainActor
final class PaletteSearchFieldCoordinator: NSObject, NSTextFieldDelegate {
    let model: PaletteModel
    var onExecute: (DesktopCommand) -> Void

    init(model: PaletteModel, onExecute: @escaping (DesktopCommand) -> Void) {
        self.model = model
        self.onExecute = onExecute
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, model.isPresented else { return }
        model.query = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard model.isPresented, !textView.hasMarkedText() else { return false }
        model.query = textView.string
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): model.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): model.moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            model.activateSelection(onExecute: onExecute)
        case #selector(NSResponder.cancelOperation(_:)): model.goBackOrClose()
        default: return false
        }
        return true
    }
}
