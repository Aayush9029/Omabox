import AppKit

@MainActor
final class AnimatedImageView: NSImageView {
    var allowsAnimation = false {
        didSet { updateAnimation() }
    }

    private var isWindowClosing = false
    private var windowObservers: [NSObjectProtocol] = []

    isolated deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        removeWindowObservers()
        animates = false
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isWindowClosing = false
        if let window {
            for name in [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.willCloseNotification,
            ] {
                let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                    let isClosing = notification.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated {
                        self?.isWindowClosing = isClosing
                        self?.updateAnimation()
                    }
                }
                windowObservers.append(observer)
            }
        }
        updateAnimation()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateAnimation()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAnimation()
    }

    func invalidate() {
        allowsAnimation = false
        image = nil
        removeWindowObservers()
    }

    private func removeWindowObservers() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
    }

    private func updateAnimation() {
        let shouldAnimate = allowsAnimation && !isWindowClosing && !isHiddenOrHasHiddenAncestor
            && window?.isVisible == true && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true
        if animates != shouldAnimate { animates = shouldAnimate }
    }
}
