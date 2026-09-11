import AppKit

@MainActor
final class PaletteTextField: NSTextField {
    private var requestedPresentationID: UUID?
    private var focusedPresentationID: UUID?

    func requestFocus(for presentationID: UUID) {
        requestedPresentationID = presentationID
        focusIfNeeded()
    }

    func cancelFocusRequest() {
        requestedPresentationID = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfNeeded()
    }

    private func focusIfNeeded() {
        guard let requestedPresentationID, requestedPresentationID != focusedPresentationID,
              let window, window.makeFirstResponder(self) else { return }
        focusedPresentationID = requestedPresentationID
    }
}
