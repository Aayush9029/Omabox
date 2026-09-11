import AppKit
import Testing
@testable import Omabox

@MainActor
struct AnimatedImageTests {
    @Test func attachedHiddenImageWaitsForAVisibleWindowAndStopsOnDetachment() {
        let window = makeWindow()
        defer { finish(window) }
        let imageView = makeImageView()
        #expect(!imageView.animates)

        window.contentView = imageView
        #expect(!imageView.animates)
        show(window)
        #expect(imageView.animates)

        window.contentView = NSView()
        #expect(imageView.window == nil)
        #expect(!imageView.animates)
        notify(NSWindow.didChangeOcclusionStateNotification, window)
        #expect(!imageView.animates)
    }

    @Test func occlusionAndMiniaturizationPausePlaybackUntilTheWindowIsVisibleAgain() {
        let window = makeWindow()
        defer { finish(window) }
        let imageView = makeImageView()
        window.contentView = imageView
        show(window)
        #expect(imageView.animates)

        window.reportsOccluded = true
        notify(NSWindow.didChangeOcclusionStateNotification, window)
        #expect(!imageView.animates)
        window.reportsOccluded = false
        notify(NSWindow.didChangeOcclusionStateNotification, window)
        #expect(imageView.animates)

        window.reportsMiniaturized = true
        notify(NSWindow.didMiniaturizeNotification, window)
        #expect(!imageView.animates)
        window.reportsMiniaturized = false
        notify(NSWindow.didDeminiaturizeNotification, window)
        #expect(imageView.animates)

        window.reportsVisible = false
        notify(NSWindow.didChangeOcclusionStateNotification, window)
        #expect(!imageView.animates)
    }

    @Test func closePausesBeforeVisibilityChangesAndARetainedWindowCanReopen() {
        let window = makeWindow()
        defer { finish(window) }
        let imageView = makeImageView()
        window.contentView = imageView
        show(window)
        #expect(imageView.animates)

        notify(NSWindow.willCloseNotification, window)

        #expect(window.isVisible)
        #expect(!imageView.animates)
        #expect(imageView.image != nil)
        window.reportsVisible = false
        window.reportsOccluded = true
        notify(NSWindow.didChangeOcclusionStateNotification, window)
        #expect(!imageView.animates)

        show(window)

        #expect(imageView.animates)
    }

    @Test func movingAnImageToAnotherWindowDisconnectsThePreviousWindowsEvents() {
        let firstWindow = makeWindow()
        let secondWindow = makeWindow()
        defer {
            finish(firstWindow)
            finish(secondWindow)
        }
        let imageView = makeImageView()
        firstWindow.contentView = imageView
        show(firstWindow)
        show(secondWindow)
        #expect(imageView.animates)

        firstWindow.contentView = NSView()
        #expect(!imageView.animates)
        secondWindow.contentView = imageView
        #expect(imageView.window === secondWindow)
        #expect(imageView.animates)

        firstWindow.reportsVisible = false
        notify(NSWindow.willCloseNotification, firstWindow)
        notify(NSWindow.didChangeOcclusionStateNotification, firstWindow)
        #expect(imageView.animates)
        notify(NSWindow.willCloseNotification, secondWindow)
        #expect(!imageView.animates)
    }

    @Test func reducedMotionAndHiddenAncestorsPauseUntilAllPlaybackConditionsAllow() {
        let window = makeWindow()
        defer { finish(window) }
        let container = NSView()
        let imageView = makeImageView()
        container.addSubview(imageView)
        window.contentView = container
        show(window)
        #expect(imageView.animates)

        imageView.allowsAnimation = false
        #expect(!imageView.animates)
        notify(NSWindow.didChangeOcclusionStateNotification, window)
        #expect(!imageView.animates)
        imageView.allowsAnimation = true
        #expect(imageView.animates)

        container.isHidden = true
        #expect(imageView.isHiddenOrHasHiddenAncestor)
        #expect(!imageView.animates)
        container.isHidden = false
        #expect(imageView.animates)
        imageView.isHidden = true
        #expect(!imageView.animates)
        imageView.allowsAnimation = false
        imageView.isHidden = false
        #expect(!imageView.animates)
        imageView.allowsAnimation = true
        #expect(imageView.animates)
    }

    @Test func dismantledImagesReleaseTheirImageAndIgnoreFurtherWindowEvents() {
        let window = makeWindow()
        defer { finish(window) }
        show(window)
        weak var retainedImageView: AnimatedImageView?

        autoreleasepool {
            let imageView = makeImageView()
            retainedImageView = imageView
            window.contentView = imageView
            #expect(imageView.animates)

            AnimatedImage.dismantleNSView(imageView, coordinator: ())

            #expect(!imageView.animates)
            #expect(imageView.image == nil)
            notify(NSWindow.didChangeOcclusionStateNotification, window)
            #expect(!imageView.animates)
            window.contentView = NSView()
        }

        #expect(retainedImageView == nil)
    }

    private func makeImageView() -> AnimatedImageView {
        let view = AnimatedImageView()
        view.image = NSImage(size: NSSize(width: 4, height: 4))
        view.allowsAnimation = true
        return view
    }

    private func makeWindow() -> AnimatedImageTestWindow {
        let window = AnimatedImageTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func show(_ window: AnimatedImageTestWindow) {
        window.reportsVisible = true
        window.reportsOccluded = false
        notify(NSWindow.didChangeOcclusionStateNotification, window)
    }

    private func notify(_ name: Notification.Name, _ window: AnimatedImageTestWindow) {
        NotificationCenter.default.post(name: name, object: window)
    }

    private func finish(_ window: AnimatedImageTestWindow) {
        window.reportsVisible = false
        window.contentView = nil
        window.close()
    }
}
