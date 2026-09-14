import SwiftUI

struct PaletteSearchField: NSViewRepresentable {
    let model: PaletteModel
    let onExecute: (DesktopCommand) -> Void

    func makeCoordinator() -> PaletteSearchFieldCoordinator {
        PaletteSearchFieldCoordinator(model: model, onExecute: onExecute)
    }

    func makeNSView(context: Context) -> PaletteTextField {
        let field = PaletteTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .title2)
        field.placeholderString = "Search commands and settings"
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("palette.search")
        field.setAccessibilityLabel("Search commands")
        return field
    }

    func updateNSView(_ field: PaletteTextField, context: Context) {
        context.coordinator.onExecute = onExecute
        field.placeholderString = model.page == .resolutions ? "Find a resolution" : "Search commands and settings"
        if field.stringValue != model.query, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = model.query
        }
        field.requestFocus(for: model.presentationID)
    }

    static func dismantleNSView(_ field: PaletteTextField, coordinator: PaletteSearchFieldCoordinator) {
        field.delegate = nil
        field.cancelFocusRequest()
    }
}
