import AppKit

@MainActor
final class WindowPresentationTestWindow: NSWindow {
    var fullScreenToggleCount = 0
    var reportsFullScreen = false

    override var styleMask: NSWindow.StyleMask {
        get { reportsFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue }
    }

    override func toggleFullScreen(_ sender: Any?) {
        fullScreenToggleCount += 1
    }
}
