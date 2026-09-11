import AppKit
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, GuestHostKeyboardCommandHandling {
    private var model: OmaboxModel?
    private lazy var palette = PaletteModel(
        onPresentationChanged: { [weak self] in self?.layoutCommandMenu() },
        onResolutionSelected: { [weak self] preset in self?.applyResolution(preset) }
    )
    private var desktopWindow: NSWindow?
    private var windowPresentation: DesktopWindowPresentation?
    private var pendingResolution: DesktopResolutionPreset?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var eventMonitor: Any?
    private var quitTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = OmaboxModel()
        self.model = model
        createDesktop(model: model)
        createMenu()
        observePreferences()
        observeDesktopPresentation()
        installKeyboardCommands()
    }

    private func createDesktop(model: OmaboxModel) {
        let content = NSHostingView(rootView: DesktopView(
            model: model,
            palette: palette,
            onSettings: { [weak self] in self?.showSettings(tab: .general) },
            onPalette: { [weak self] in self?.togglePalette() },
            onCommand: { [weak self] command in self?.execute(command) }
        ))
        content.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: DesktopWindowPresentation.homeSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Omabox"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.delegate = self
        windowPresentation = DesktopWindowPresentation(window: window)
        window.center()
        desktopWindow = window
        showDesktop()
    }

    func showSettings(tab: SettingsTab = .general) {
        guard let model else { return }
        let content = NSHostingView(rootView: SettingsView(model: model, initialTab: tab))
        content.sizingOptions = []
        if let settingsWindow {
            settingsWindow.contentView = content
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Omabox Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 660, height: 460)
        window.contentView = content
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func createMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        main.addItem(applicationItem)
        let application = NSMenu(title: "Omabox")
        applicationItem.submenu = application
        application.addItem(withTitle: "About Omabox", action: #selector(openAbout), keyEquivalent: "").target = self
        application.addItem(.separator())
        application.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        application.addItem(.separator())
        application.addItem(withTitle: "Hide Omabox", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        application.addItem(.separator())
        application.addItem(withTitle: "Quit Omabox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Show Omabox", action: #selector(showDesktop), keyEquivalent: "0").target = self
        let paletteItem = windowMenu.addItem(withTitle: "Command Palette", action: #selector(togglePalette), keyEquivalent: ReservedHostKeyboardCommand.paletteKeyEquivalent)
        paletteItem.target = self
        paletteItem.keyEquivalentModifierMask = ReservedHostKeyboardCommand.paletteModifierFlags
        let releaseItem = windowMenu.addItem(withTitle: "Release Keyboard", action: #selector(releaseKeyboard), keyEquivalent: "\u{1b}")
        releaseItem.target = self
        releaseItem.keyEquivalentModifierMask = [.control, .option]
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Pause Desktop", action: #selector(togglePause), keyEquivalent: "").target = self
        windowMenu.addItem(withTitle: "Shut Down Omarchy", action: #selector(shutDown), keyEquivalent: "").target = self
        windowMenu.addItem(.separator())
        let fullScreenItem = windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "Omabox")
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "Show Omabox", action: #selector(showDesktop), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "Release Keyboard", action: #selector(releaseKeyboard), keyEquivalent: "").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Pause Desktop", action: #selector(togglePause), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "Shut Down Omarchy", action: #selector(shutDown), keyEquivalent: "").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit Omabox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        status.menu = statusMenu
        statusItem = status
    }

    private func observePreferences() {
        guard let model else { return }
        withObservationTracking {
            statusItem?.isVisible = model.preferences.showsMenuBarIcon
            NSApp.setActivationPolicy(model.preferences.showsDockIcon ? .regular : .accessory)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePreferences() }
        }
    }

    private func installKeyboardCommands() {
        GuestDisplayView.hostKeyboardCommandHandler = self
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHostKeyboardEvent(event) == true ? nil : event
        }
    }

    private func observeDesktopPresentation() {
        guard let model else { return }
        withObservationTracking {
            windowPresentation?.update(showsDesktop: model.virtualMachine != nil && model.state.hasActiveSession)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeDesktopPresentation() }
        }
    }

    func handleHostKeyboardEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, NSApp.modalWindow == nil,
              event.window?.sheetParent == nil, event.window?.attachedSheet == nil else { return false }
        if event.window === desktopWindow, palette.isPresented {
            let editor = desktopWindow?.firstResponder as? NSTextView
            if palette.handleKeyboardEvent(
                event,
                isComposingText: editor?.hasMarkedText() == true,
                currentSearchText: editor?.string,
                onExecute: execute
            ) { return true }
        }
        switch ReservedHostKeyboardCommand(event: event) {
        case .palette where model?.state == .running || model?.state == .paused:
            togglePalette()
            return true
        case .settings:
            palette.close()
            showSettings()
            return true
        case .releaseInput:
            releaseKeyboard()
            return true
        default:
            return false
        }
    }

    @objc private func togglePalette() {
        guard let model, model.state == .running || model.state == .paused else { return }
        if palette.isPresented { palette.close(); return }
        showDesktop()
        if desktopWindow?.firstResponder is GuestDisplayView {
            desktopWindow?.makeFirstResponder(nil)
        }
        palette.open(
            commands: DesktopCommand.available(in: model.state, hasInstallation: model.installationURL != nil),
            currentResolution: model.virtualMachine?.graphicsDevices.first?.displays.first?.sizeInPixels
        )
    }

    private func layoutCommandMenu() {
        desktopWindow?.contentView?.needsLayout = true
        desktopWindow?.contentView?.layoutSubtreeIfNeeded()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePalette) || menuItem.action == #selector(releaseKeyboard) {
            return model?.state == .running || model?.state == .paused
        }
        if menuItem.action == #selector(togglePause) {
            menuItem.title = model?.state == .paused ? "Resume Desktop" : "Pause Desktop"
            return (model?.state == .running || model?.state == .paused) && model?.isChangingRunState == false
        }
        if menuItem.action == #selector(shutDown) {
            return (model?.state == .running || model?.state == .paused) && model?.isChangingRunState == false
        }
        return true
    }

    private func execute(_ command: DesktopCommand) {
        guard let model else { return }
        if command != .resolution { palette.close() }
        switch command {
        case .settings: showSettings()
        case .machine: showSettings(tab: .machine)
        case .sharing: showSettings(tab: .sharing)
        case .shortcuts: showSettings(tab: .shortcuts)
        case .folder: model.chooseSharedFolder()
        case .files:
            if let url = model.installationURL { NSWorkspace.shared.open(url) }
        case .fullScreen: desktopWindow?.toggleFullScreen(nil)
        case .resolution:
            palette.showResolutions()
        case .releaseKeyboard: releaseKeyboard()
        case .start: Task { await model.startButtonTapped() }
        case .pause: Task { await model.pauseButtonTapped() }
        case .resume: Task { await model.resumeButtonTapped() }
        case .shutdown: Task { await model.shutDownButtonTapped() }
        }
    }

    private func applyResolution(_ preset: DesktopResolutionPreset) {
        guard let window = desktopWindow, let display = model?.virtualMachine?.graphicsDevices.first?.displays.first,
              let guestView = guestDisplay(in: window.contentView) else { return }
        pendingResolution = preset
        if windowPresentation?.exitFullScreenIfNeeded() == true {
            return
        }
        pendingResolution = nil
        let wasAutomatic = guestView.automaticallyReconfiguresDisplay
        do {
            if let size = preset.sizeInPixels {
                guestView.automaticallyReconfiguresDisplay = false
                try display.reconfigure(sizeInPixels: size)
                window.aspectRatio = size
                windowPresentation?.resizeContent(to: size)
            } else {
                window.aspectRatio = .zero
                guestView.automaticallyReconfiguresDisplay = true
                windowPresentation?.fitToScreen()
            }
        } catch {
            guestView.automaticallyReconfiguresDisplay = wasAutomatic
            let alert = NSAlert(error: error)
            alert.messageText = "Unable to change the display resolution"
            alert.beginSheetModal(for: window)
        }
    }

    private func guestDisplay(in view: NSView?) -> GuestDisplayView? {
        if let display = view as? GuestDisplayView { return display }
        for child in view?.subviews ?? [] {
            if let display = guestDisplay(in: child) { return display }
        }
        return nil
    }

    @objc private func showDesktop() {
        desktopWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func openSettings() { showSettings() }
    @objc private func openAbout() { showSettings(tab: .about) }
    @objc private func releaseKeyboard() { desktopWindow?.makeFirstResponder(nil) }
    @objc private func togglePause() { execute(model?.state == .paused ? .resume : .pause) }
    @objc private func shutDown() { execute(.shutdown) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDesktop()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.state == .starting || model.state == .preparing {
            let alert = NSAlert()
            alert.messageText = model.state == .preparing ? "Your desktop is being prepared" : "Linux is starting"
            alert.informativeText = model.state == .preparing
                ? "Cancel setup in the Omabox window before quitting."
                : "Wait for Linux to finish starting, then quit to shut it down safely."
            alert.addButton(withTitle: "Show Omabox")
            alert.runModal()
            showDesktop()
            return .terminateCancel
        }
        guard model.state.hasActiveSession else { return .terminateNow }
        if quitTask != nil { return .terminateCancel }
        let alert = NSAlert()
        alert.messageText = "Shut down your desktop before quitting?"
        alert.informativeText = "Omabox will ask Linux to shut down safely. Save any work in your desktop first."
        alert.addButton(withTitle: "Shut Down & Quit")
        alert.addButton(withTitle: "Keep Running")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        quitTask = Task { [weak self] in
            let shutdownRequest = Task { await model.shutDownForQuit() }
            defer { shutdownRequest.cancel() }
            for _ in 0..<30 {
                if model.virtualMachine == nil { NSApp.reply(toApplicationShouldTerminate: true); return }
                try? await Task.sleep(for: .seconds(1))
            }
            self?.quitTask = nil
            NSApp.reply(toApplicationShouldTerminate: false)
            self?.showDesktop()
        }
        return .terminateLater
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === desktopWindow {
            windowPresentation?.recordDesktopFrame()
            palette.close()
            window.makeFirstResponder(nil)
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === desktopWindow else { return }
        windowPresentation?.didExitFullScreen()
        if let preset = pendingResolution {
            pendingResolution = nil
            applyResolution(preset)
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === desktopWindow else { return }
        windowPresentation?.didEnterFullScreen()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === desktopWindow else { return }
        windowPresentation?.willEnterFullScreen()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === desktopWindow else { return }
        windowPresentation?.willExitFullScreen()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        guard window === desktopWindow else { return }
        windowPresentation?.didFailToEnterFullScreen()
        if let preset = pendingResolution {
            pendingResolution = nil
            applyResolution(preset)
        }
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        guard window === desktopWindow else { return }
        let isWindowed = windowPresentation?.didFailToExitFullScreen() == true
        if let preset = pendingResolution {
            pendingResolution = nil
            if isWindowed {
                applyResolution(preset)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Leave full screen to resize the desktop"
            alert.informativeText = "macOS could not leave full screen. Try again from the command menu."
            alert.beginSheetModal(for: window)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === desktopWindow else { return }
        windowPresentation?.recordDesktopFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === desktopWindow else { return }
        windowPresentation?.recordDesktopFrame()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        GuestDisplayView.hostKeyboardCommandHandler = nil
    }
}
