import AppKit
import OSLog

@MainActor
final class DesktopWindowPresentation {
    static let homeSize = NSSize(width: 880, height: 560)
    static let minimumDesktopSize = NSSize(width: 320, height: 240)

    private weak var window: NSWindow?
    private let frameAutosaveName: String?
    private var showsDesktop = false
    private var requestedDesktop = false
    private var desktopFrame: NSRect?
    private var fullScreenState = DesktopWindowFullScreenState.windowed
    private var requestsWindowedPresentation = false
    private var isApplyingFrame = false
    private let logger = Logger(subsystem: "ca.optimalapps.omabox", category: "WindowPresentation")

    init(window: NSWindow, frameAutosaveName: String? = "OmaboxRuntimeWindow") {
        self.window = window
        self.frameAutosaveName = AppEnvironment.isUITesting ? nil : frameAutosaveName
        applyHome()
    }

    func update(showsDesktop: Bool) {
        requestedDesktop = showsDesktop
        guard self.showsDesktop != showsDesktop else {
            updateWindowButtons()
            return
        }
        guard isWindowed else {
            if !showsDesktop { exitFullScreenIfNeeded() }
            return
        }
        applyRequestedPresentation(captureCurrentFrame: true)
    }

    func recordDesktopFrame() {
        guard let window, showsDesktop, isWindowed, !isApplyingFrame, valid(window.frame) else { return }
        desktopFrame = window.frame
        if let frameAutosaveName { window.saveFrame(usingName: frameAutosaveName) }
    }

    @discardableResult
    func exitFullScreenIfNeeded() -> Bool {
        guard let window, !isWindowed else { return false }
        requestsWindowedPresentation = true
        if fullScreenState == .fullScreen || fullScreenState == .windowed {
            fullScreenState = .exiting
            window.toggleFullScreen(nil)
        }
        return true
    }

    func willEnterFullScreen() {
        recordDesktopFrame()
        fullScreenState = .entering
    }

    func didEnterFullScreen() {
        fullScreenState = .fullScreen
        updateWindowButtons()
        if requestsWindowedPresentation || !requestedDesktop { exitFullScreenIfNeeded() }
    }

    func willExitFullScreen() {
        fullScreenState = .exiting
    }

    func didExitFullScreen() {
        finishWindowedTransition()
    }

    func didFailToEnterFullScreen() {
        finishWindowedTransition()
    }

    @discardableResult
    func didFailToExitFullScreen() -> Bool {
        guard let window else { return false }
        let remainsFullScreen = window.styleMask.contains(.fullScreen)
        logger.error("Full-screen exit failed; nativeFullscreen=\(remainsFullScreen, privacy: .public), aspect=\(window.aspectRatio.width, privacy: .public)×\(window.aspectRatio.height, privacy: .public)")
        guard remainsFullScreen else {
            finishWindowedTransition()
            return true
        }
        fullScreenState = .fullScreen
        requestsWindowedPresentation = false
        updateWindowButtons()
        return false
    }

    func updateWindowButtons() {
        guard let window else { return }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = showsDesktop
        }
    }

    func resizeContent(to size: NSSize) {
        guard showsDesktop, isWindowed, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        setSize(size, fitsScreen: true)
        recordDesktopFrame()
    }

    func fitToScreen() {
        guard let window, showsDesktop, isWindowed, let screen = window.screen ?? NSScreen.main else { return }
        window.aspectRatio = .zero
        setFrame(clamped(screen.visibleFrame, fitsScreen: true))
        recordDesktopFrame()
    }

    private var isWindowed: Bool {
        fullScreenState == .windowed && window?.styleMask.contains(.fullScreen) == false
    }

    private func finishWindowedTransition() {
        fullScreenState = .windowed
        requestsWindowedPresentation = false
        if showsDesktop, requestedDesktop { restoreDesktopFrame() }
        applyRequestedPresentation(captureCurrentFrame: false)
        updateWindowButtons()
    }

    private func applyRequestedPresentation(captureCurrentFrame: Bool) {
        guard let window, isWindowed, showsDesktop != requestedDesktop else { return }
        if requestedDesktop {
            window.styleMask.insert(.resizable)
            window.collectionBehavior.remove(.fullScreenNone)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.minSize = Self.minimumDesktopSize
            window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            window.aspectRatio = .zero
            window.resizeIncrements = NSSize(width: 1, height: 1)
            showsDesktop = true
            restoreDesktopFrame()
            recordDesktopFrame()
        } else {
            if captureCurrentFrame { recordDesktopFrame() }
            showsDesktop = false
            applyHome()
        }
        updateWindowButtons()
    }

    private func restoreDesktopFrame() {
        guard let window else { return }
        if let desktopFrame, valid(desktopFrame) {
            setFrame(clamped(desktopFrame, fitsScreen: true))
        } else if let frameAutosaveName, window.setFrameUsingName(frameAutosaveName), valid(window.frame) {
            setFrame(clamped(window.frame, fitsScreen: true))
        } else {
            setSize(NSSize(width: 960, height: 600), fitsScreen: true)
        }
    }

    private func setSize(_ size: NSSize, fitsScreen: Bool) {
        guard let window else { return }
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let frame = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        setFrame(clamped(frame, fitsScreen: fitsScreen))
    }

    private func setFrame(_ frame: NSRect) {
        isApplyingFrame = true
        defer { isApplyingFrame = false }
        window?.setFrame(frame, display: true)
    }

    private func applyHome() {
        guard let window else { return }
        window.aspectRatio = .zero
        window.resizeIncrements = NSSize(width: 1, height: 1)
        window.minSize = Self.homeSize
        window.maxSize = Self.homeSize
        window.styleMask.remove(.resizable)
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)
        setSize(Self.homeSize, fitsScreen: false)
        updateWindowButtons()
    }

    private func clamped(_ frame: NSRect, fitsScreen: Bool) -> NSRect {
        guard let window, let screen = window.screen ?? NSScreen.main else { return frame }
        let visible = screen.visibleFrame
        var size = frame.size
        if fitsScreen {
            let minimum = Self.minimumDesktopSize
            if window.aspectRatio == .zero {
                size.width = max(minimum.width, min(size.width, visible.width))
                size.height = max(minimum.height, min(size.height, visible.height))
            } else {
                let scale = max(
                    min(1, visible.width / size.width, visible.height / size.height),
                    minimum.width / size.width,
                    minimum.height / size.height
                )
                size = NSSize(width: size.width * scale, height: size.height * scale)
            }
        }
        return NSRect(
            x: min(max(frame.midX - size.width / 2, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(frame.midY - size.height / 2, visible.minY), max(visible.minY, visible.maxY - size.height)),
            width: size.width,
            height: size.height
        )
    }

    private func valid(_ frame: NSRect) -> Bool {
        frame.width.isFinite && frame.height.isFinite && frame.midX.isFinite && frame.midY.isFinite
            && frame.width > 0 && frame.height > 0
    }
}
