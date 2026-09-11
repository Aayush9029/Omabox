import AppKit
@testable import Omabox

@MainActor
final class WindowPresentationTestDelegate: NSObject, NSWindowDelegate {
    let presentation: DesktopWindowPresentation
    private(set) var updateCount = 0

    init(presentation: DesktopWindowPresentation) {
        self.presentation = presentation
    }

    func windowDidUpdate(_ notification: Notification) {
        updateCount += 1
        presentation.reassertWindowedSizeLimits()
    }
}
