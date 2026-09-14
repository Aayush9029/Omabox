import AppKit
import CustomDump
import Dependencies
import DependenciesTestSupport
import Sharing
import SwiftUI
import Testing
@testable import Omabox

@Suite(.dependencies)
@MainActor
struct WindowPresentationTests {
    @Test func hostedHomeKeepsTheNativeFrameAfterInitialAndUpdatedSwiftUILayout() async {
        let model = withDependencies {
            $0.installerClient = InstallerClient(
                existing: { nil },
                prepare: { _, _ in throw VMConfigurationError.unsupportedHost }
            )
            $0.virtualMachineClient = VirtualMachineClient(
                makeRuntime: {
                    Issue.record("Home layout must not create a virtual machine runtime.")
                    return AppleVirtualMachineRuntime()
                },
                resourcePolicy: { VMResourcePolicy(cpuRange: 1...8, memoryRangeGiB: 2...16) }
            )
        } operation: {
            OmaboxModel(preferences: Shared(value: VMPreferences()))
        }
        await model.task()
        let host = NSHostingView(rootView: DesktopView(
            model: model,
            palette: PaletteModel(),
            onSettings: {},
            onPalette: {},
            onCommand: { _ in }
        ))
        host.sizingOptions = []
        let window = makeWindow()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        let presentation = DesktopWindowPresentation(window: window, frameAutosaveName: nil)
        let delegate = WindowPresentationTestDelegate(presentation: presentation)
        window.delegate = delegate
        host.layoutSubtreeIfNeeded()
        window.update()
        expectNoDifference(window.frame.size, DesktopWindowPresentation.homeSize)
        expectNoDifference(host.bounds.size, DesktopWindowPresentation.homeSize)

        model.$preferences.cpuCount.withLock { $0 = 2 }
        model.errorMessage = "A setup failure can be shown without changing the window size."
        await Task.yield()
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        window.update()

        expectNoDifference(window.frame.size, DesktopWindowPresentation.homeSize)
        expectNoDifference(host.bounds.size, DesktopWindowPresentation.homeSize)
        expectNoDifference(window.minSize, DesktopWindowPresentation.homeSize)
        expectNoDifference(window.maxSize, DesktopWindowPresentation.homeSize)
        #expect(delegate.updateCount >= 2)
        #expect(model.virtualMachine == nil)
        #expect(!window.isVisible)
    }

    @Test func nativeWindowUpdatesRestoreClearedLimitsWithoutChangingTheFrameOrPreset() {
        let window = makeWindow()
        defer { window.close() }
        let presentation = DesktopWindowPresentation(window: window, frameAutosaveName: nil)
        let delegate = WindowPresentationTestDelegate(presentation: presentation)
        window.delegate = delegate
        let homeFrame = window.frame
        window.minSize = .zero
        window.maxSize = unlimitedSize

        window.update()

        #expect(delegate.updateCount > 0)
        expectNoDifference(window.minSize, DesktopWindowPresentation.homeSize)
        expectNoDifference(window.maxSize, DesktopWindowPresentation.homeSize)
        expectNoDifference(window.frame, homeFrame)
        #expect(!window.styleMask.contains(.resizable))

        presentation.update(showsDesktop: true)
        window.aspectRatio = NSSize(width: 512, height: 320)
        presentation.resizeContent(to: NSSize(width: 512, height: 320))
        let desktopFrame = window.frame
        window.minSize = .zero
        window.maxSize = NSSize(width: 4096, height: 4096)

        window.update()
        window.update()

        expectNoDifference(window.minSize, DesktopWindowPresentation.minimumDesktopSize)
        expectNoDifference(window.maxSize, unlimitedSize)
        expectNoDifference(window.frame, desktopFrame)
        expectNoDifference(window.aspectRatio, NSSize(width: 512, height: 320))
        #expect(window.styleMask.contains(.resizable))
        presentation.update(showsDesktop: false)
        presentation.update(showsDesktop: true)
        expectNoDifference(window.frame, desktopFrame)
        #expect(!window.isVisible)
    }

    @Test(arguments: [false, true])
    func nativeWindowUpdatesLeaveFullscreenLimitsAloneUntilWindowed(showsHomeOnExit: Bool) {
        let window = makeWindow()
        defer { window.close() }
        let presentation = DesktopWindowPresentation(window: window, frameAutosaveName: nil)
        let delegate = WindowPresentationTestDelegate(presentation: presentation)
        window.delegate = delegate
        presentation.update(showsDesktop: true)
        window.aspectRatio = NSSize(width: 512, height: 320)
        presentation.resizeContent(to: NSSize(width: 512, height: 320))
        let desktopFrame = window.frame
        presentation.willEnterFullScreen()
        let systemMinimum = NSSize(width: 13, height: 17)
        let systemMaximum = NSSize(width: 4096, height: 4096)
        window.minSize = systemMinimum
        window.maxSize = systemMaximum

        window.update()
        expectNoDifference(window.minSize, systemMinimum)
        expectNoDifference(window.maxSize, systemMaximum)
        window.reportsFullScreen = true
        presentation.didEnterFullScreen()
        window.update()
        expectNoDifference(window.minSize, systemMinimum)
        expectNoDifference(window.maxSize, systemMaximum)
        if showsHomeOnExit { presentation.update(showsDesktop: false) }
        presentation.willExitFullScreen()
        window.update()
        expectNoDifference(window.minSize, systemMinimum)
        expectNoDifference(window.maxSize, systemMaximum)

        window.reportsFullScreen = false
        presentation.didExitFullScreen()
        window.update()

        if showsHomeOnExit {
            expectNoDifference(window.minSize, DesktopWindowPresentation.homeSize)
            expectNoDifference(window.maxSize, DesktopWindowPresentation.homeSize)
            expectWindowSize(window, DesktopWindowPresentation.homeSize)
        } else {
            expectNoDifference(window.minSize, DesktopWindowPresentation.minimumDesktopSize)
            expectNoDifference(window.maxSize, unlimitedSize)
            expectNoDifference(window.frame, desktopFrame)
            expectNoDifference(window.aspectRatio, NSSize(width: 512, height: 320))
        }
        #expect(!window.isVisible)
    }

    @Test func homeStaysFixedAndDesktopAllowsSmallWindowsWithoutChangingNativeActions() {
        let window = makeWindow()
        defer { window.close() }
        let presentation = DesktopWindowPresentation(window: window, frameAutosaveName: nil)
        expectWindowSize(window, DesktopWindowPresentation.homeSize)
        #expect(!window.styleMask.contains(.resizable))
        expectNoDifference(window.minSize, DesktopWindowPresentation.homeSize)
        expectNoDifference(window.maxSize, DesktopWindowPresentation.homeSize)
        for type in buttons { #expect(window.standardWindowButton(type)?.isHidden == false) }

        presentation.update(showsDesktop: true)
        presentation.resizeContent(to: NSSize(width: 512, height: 320))
        expectWindowSize(window, NSSize(width: 512, height: 320))
        expectNoDifference(window.minSize, NSSize(width: 320, height: 240))
        #expect(window.maxSize.width > DesktopWindowPresentation.homeSize.width)
        #expect(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
        for type in buttons { #expect(window.standardWindowButton(type)?.isHidden == true) }
    }

    @Test func stoppingRestoresHomeAndRestartingRestoresGeometryWithFreeResizing() {
        let window = makeWindow()
        defer { window.close() }
        let presentation = DesktopWindowPresentation(window: window, frameAutosaveName: nil)
        presentation.update(showsDesktop: true)
        window.aspectRatio = NSSize(width: 512, height: 320)
        presentation.resizeContent(to: NSSize(width: 512, height: 320))
        let desktopFrame = window.frame

        presentation.update(showsDesktop: true)
        expectNoDifference(window.aspectRatio, NSSize(width: 512, height: 320))
        expectNoDifference(window.frame, desktopFrame)
        presentation.update(showsDesktop: false)
        expectWindowSize(window, DesktopWindowPresentation.homeSize)
        for type in buttons { #expect(window.standardWindowButton(type)?.isHidden == false) }
        presentation.update(showsDesktop: true)
        expectNoDifference(window.frame, desktopFrame)
        expectNoDifference(window.aspectRatio, .zero)
        expectNoDifference(window.resizeIncrements, NSSize(width: 1, height: 1))
    }

    @Test func runtimeGeometryPersistsAcrossControllersWithoutSavingTheHomeFrame() {
        let name = "OmaboxWindowPresentationTests-\(UUID().uuidString)"
        defer { NSWindow.removeFrame(usingName: name) }
        let firstWindow = makeWindow()
        defer { firstWindow.close() }
        let first = DesktopWindowPresentation(window: firstWindow, frameAutosaveName: name)
        first.update(showsDesktop: true)
        first.resizeContent(to: NSSize(width: 640, height: 480))
        let desktopFrame = firstWindow.frame
        first.recordDesktopFrame()
        first.update(showsDesktop: false)
        first.recordDesktopFrame()

        let secondWindow = makeWindow()
        defer { secondWindow.close() }
        let second = DesktopWindowPresentation(window: secondWindow, frameAutosaveName: name)
        expectWindowSize(secondWindow, DesktopWindowPresentation.homeSize)
        second.update(showsDesktop: true)
        expectNoDifference(secondWindow.frame, desktopFrame)
    }

    @Test func failedFullscreenEntryAppliesPendingHomeWithoutSavingTheTransitionFrame() {
        let window = makeWindow()
        defer { window.close() }
        let presentation = DesktopWindowPresentation(window: window, frameAutosaveName: nil)
        presentation.update(showsDesktop: true)
        presentation.resizeContent(to: NSSize(width: 512, height: 320))
        let desktopFrame = window.frame
        presentation.willEnterFullScreen()
        window.setContentSize(NSSize(width: 900, height: 680))
        presentation.recordDesktopFrame()
        presentation.update(showsDesktop: false)
        #expect(window.fullScreenToggleCount == 0)
        #expect(window.styleMask.contains(.resizable))

        presentation.didFailToEnterFullScreen()
        expectWindowSize(window, DesktopWindowPresentation.homeSize)
        presentation.update(showsDesktop: true)
        expectNoDifference(window.frame, desktopFrame)
    }

    @Test func shutdownDuringFullscreenEntryWaitsForExitAndCanRecoverFromExitFailure() {
        let window = makeWindow()
        defer { window.close() }
        let presentation = DesktopWindowPresentation(window: window, frameAutosaveName: nil)
        presentation.update(showsDesktop: true)
        presentation.resizeContent(to: NSSize(width: 512, height: 320))
        let desktopFrame = window.frame
        presentation.willEnterFullScreen()
        window.setContentSize(NSSize(width: 900, height: 680))
        presentation.update(showsDesktop: false)
        window.reportsFullScreen = true
        presentation.didEnterFullScreen()
        #expect(window.fullScreenToggleCount == 1)
        presentation.update(showsDesktop: false)
        #expect(window.fullScreenToggleCount == 1)

        #expect(!presentation.didFailToExitFullScreen())
        presentation.recordDesktopFrame()
        for type in buttons { #expect(window.standardWindowButton(type)?.isHidden == true) }
        presentation.update(showsDesktop: false)
        #expect(window.fullScreenToggleCount == 2)
        presentation.willExitFullScreen()
        window.reportsFullScreen = false
        presentation.didExitFullScreen()
        expectWindowSize(window, DesktopWindowPresentation.homeSize)
        presentation.update(showsDesktop: true)
        expectNoDifference(window.frame, desktopFrame)
    }

    @Test func presetRequestsWaitThroughFullscreenEntryAndPreserveTheWindowedFrame() {
        let window = makeWindow()
        defer { window.close() }
        let presentation = DesktopWindowPresentation(window: window, frameAutosaveName: nil)
        presentation.update(showsDesktop: true)
        presentation.resizeContent(to: NSSize(width: 640, height: 480))
        let desktopFrame = window.frame
        presentation.willEnterFullScreen()
        #expect(presentation.exitFullScreenIfNeeded())
        presentation.resizeContent(to: NSSize(width: 512, height: 320))
        expectNoDifference(window.frame, desktopFrame)
        #expect(window.fullScreenToggleCount == 0)
        window.reportsFullScreen = true
        presentation.didEnterFullScreen()
        #expect(window.fullScreenToggleCount == 1)
        window.reportsFullScreen = false
        presentation.didExitFullScreen()
        expectNoDifference(window.frame, desktopFrame)
        #expect(!presentation.exitFullScreenIfNeeded())
        presentation.resizeContent(to: NSSize(width: 512, height: 320))
        expectWindowSize(window, NSSize(width: 512, height: 320))
    }

    @Test func fitScreenUnlocksAspectAndInvalidOrHomeResizeRequestsDoNotChangeGeometry() throws {
        let window = makeWindow()
        defer { window.close() }
        let presentation = DesktopWindowPresentation(window: window, frameAutosaveName: nil)
        let homeFrame = window.frame
        presentation.resizeContent(to: NSSize(width: 512, height: 320))
        presentation.fitToScreen()
        expectNoDifference(window.frame, homeFrame)
        presentation.update(showsDesktop: true)
        let desktopFrame = window.frame
        for size in [NSSize(width: 0, height: 320), NSSize(width: CGFloat.nan, height: 320), NSSize(width: 512, height: CGFloat.infinity)] {
            presentation.resizeContent(to: size)
            expectNoDifference(window.frame, desktopFrame)
        }
        window.aspectRatio = NSSize(width: 512, height: 320)
        let screen = try #require(window.screen ?? NSScreen.main)
        presentation.fitToScreen()
        expectNoDifference(window.aspectRatio, .zero)
        expectNoDifference(window.frame, screen.visibleFrame)
        expectWindowSize(window, screen.visibleFrame.size)
    }

    @Test func failedExitWithClearedNativeFullscreenRestoresTheSavedDesktopAndAllowsResolutionChanges() {
        let window = makeWindow()
        defer { window.close() }
        let presentation = DesktopWindowPresentation(window: window, frameAutosaveName: nil)
        presentation.update(showsDesktop: true)
        presentation.resizeContent(to: NSSize(width: 640, height: 480))
        let desktopFrame = window.frame
        presentation.willEnterFullScreen()
        window.reportsFullScreen = true
        presentation.didEnterFullScreen()
        window.setContentSize(NSSize(width: 900, height: 680))
        #expect(presentation.exitFullScreenIfNeeded())
        window.reportsFullScreen = false

        #expect(presentation.didFailToExitFullScreen())

        expectNoDifference(window.frame, desktopFrame)
        #expect(!presentation.exitFullScreenIfNeeded())
        expectNoDifference(window.fullScreenToggleCount, 1)
        presentation.resizeContent(to: NSSize(width: 512, height: 320))
        expectWindowSize(window, NSSize(width: 512, height: 320))
    }

    @Test func failedExitWithClearedNativeFullscreenCanFinishPendingHomePresentation() {
        let window = makeWindow()
        defer { window.close() }
        let presentation = DesktopWindowPresentation(window: window, frameAutosaveName: nil)
        presentation.update(showsDesktop: true)
        presentation.willEnterFullScreen()
        window.reportsFullScreen = true
        presentation.didEnterFullScreen()
        presentation.update(showsDesktop: false)
        window.reportsFullScreen = false

        #expect(presentation.didFailToExitFullScreen())

        expectWindowSize(window, DesktopWindowPresentation.homeSize)
        #expect(!window.styleMask.contains(.resizable))
        for type in buttons { #expect(window.standardWindowButton(type)?.isHidden == false) }
    }

    @Test func oversizedPresetKeepsTheFullSizeViewAspectWhenFittedToTheDisplay() throws {
        let window = makeWindow()
        defer { window.close() }
        let presentation = DesktopWindowPresentation(window: window, frameAutosaveName: nil)
        presentation.update(showsDesktop: true)
        let screen = try #require(window.screen ?? NSScreen.main)
        let width = max(screen.visibleFrame.width, screen.visibleFrame.height * 1.6) * 2
        window.aspectRatio = NSSize(width: 16, height: 10)

        presentation.resizeContent(to: NSSize(width: width, height: width / 1.6))

        #expect(window.frame.width <= screen.visibleFrame.width)
        #expect(window.frame.height <= screen.visibleFrame.height)
        #expect(abs(window.frame.width / window.frame.height - 1.6) < 0.01)
        expectWindowSize(window, window.frame.size)
    }

    private var buttons: [NSWindow.ButtonType] { [.closeButton, .miniaturizeButton, .zoomButton] }

    private var unlimitedSize: NSSize {
        NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    private func expectWindowSize(_ window: NSWindow, _ expected: NSSize) {
        window.contentView?.layoutSubtreeIfNeeded()
        expectNoDifference(window.frame.size, expected)
        expectNoDifference(window.contentView?.bounds.size, expected)
    }

    private func makeWindow() -> WindowPresentationTestWindow {
        let window = WindowPresentationTestWindow(
            contentRect: NSRect(x: 80, y: 80, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        return window
    }
}
