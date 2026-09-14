import XCTest

@MainActor
final class OmaboxUITests: XCTestCase {
    func testFirstLaunchShowsWelcomeWithoutStartingInstallation() {
        let app = launch()
        defer { finish(app) }

        XCTAssertEqual(element("welcome.title", in: app).label, "Omabox")
        let setup = element("welcome.setup", in: app)
        assertHittable(setup)
        XCTAssertTrue(setup.label.contains("Set Up Omarchy"))
        XCTAssertFalse(element("desktop.progress", in: app).exists)
        XCTAssertFalse(element("desktop.error", in: app).exists)
    }

    func testSettingsKeyboardShortcutOpensEveryPane() {
        let app = launch()
        defer { finish(app) }
        openSettings(in: app)

        for (tab, anchor) in [
            ("general", "settings.showInMenuBar"),
            ("sharing", "settings.clipboardSharing"),
        ] {
            selectTab(tab, in: app)
            assertHittable(element(anchor, in: app))
        }

        selectTab("machine", in: app)
        XCTAssertTrue(app.staticTexts["Rendering threads"].waitForExistence(timeout: 5))
        selectTab("shortcuts", in: app)
        XCTAssertTrue(app.staticTexts["Commands, always"].waitForExistence(timeout: 5))
        selectTab("about", in: app)
        XCTAssertTrue(app.staticTexts["Your Linux desktop, at home on your Mac."].waitForExistence(timeout: 5))
    }

    func testHomeSettingsOpensGeneralAfterVisitingAnotherPane() {
        let app = launch()
        defer { finish(app) }

        let settings = element("desktop.settings", in: app)
        assertHittable(settings)
        settings.click()
        assertHittable(element("settings.showInMenuBar", in: app))
        selectTab("machine", in: app)
        app.typeKey("w", modifierFlags: .command)
        assertHittable(settings)
        settings.click()
        assertHittable(element("settings.showInMenuBar", in: app))
    }

    func testSettingsPreserveMinimumSizeAndVisibleSidebar() {
        let app = launch()
        defer { finish(app) }
        openSettings(in: app)

        let window = settingsWindow(in: app)
        XCTAssertGreaterThanOrEqual(window.frame.width, 660)
        XCTAssertGreaterThanOrEqual(window.frame.height, 460)

        for tab in ["general", "machine", "sharing", "shortcuts", "about"] {
            let row = element("settings.tab.\(tab)", in: app)
            assertHittable(row)
            XCTAssertTrue(window.frame.contains(row.frame), "The \(tab) sidebar item is clipped.")
            XCTAssertFalse(row.label.isEmpty)
        }

        app.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(app.windows.containing(.any, identifier: "settings.tab.general").count, 1)
    }

    func testGeneralPreferencePersistsAfterQuitAndRelaunch() {
        let app = launch()
        defer { finish(app) }
        openSettings(in: app)
        selectTab("general", in: app)

        let menuBar = element("settings.showInMenuBar", in: app)
        assertHittable(menuBar)
        XCTAssertEqual(menuBar.value as? String, "On")
        menuBar.click()
        assertValue("Off", on: element("settings.showInMenuBar", in: app))

        selectTab("sharing", in: app)
        assertHittable(element("settings.clipboardSharing", in: app))
        selectTab("general", in: app)
        assertValue("Off", on: element("settings.showInMenuBar", in: app))

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        openSettings(in: app)
        selectTab("general", in: app)
        assertValue("Off", on: element("settings.showInMenuBar", in: app))
    }

    func testClipboardPreferenceCanBeChangedAndRestored() {
        let app = launch()
        defer { finish(app) }
        openSettings(in: app)
        selectTab("sharing", in: app)

        let clipboard = element("settings.clipboardSharing", in: app)
        assertHittable(clipboard)
        assertSwitchValue(true, on: clipboard)
        clipboard.click()
        assertSwitchValue(false, on: element("settings.clipboardSharing", in: app))

        selectTab("general", in: app)
        selectTab("sharing", in: app)
        assertSwitchValue(false, on: element("settings.clipboardSharing", in: app))
        element("settings.clipboardSharing", in: app).click()
        assertSwitchValue(true, on: element("settings.clipboardSharing", in: app))
    }

    func testKeyboardPreferenceChangesIndependentlyOfClipboard() {
        let app = launch()
        defer { finish(app) }
        openSettings(in: app)
        selectTab("shortcuts", in: app)

        let keyboard = element("settings.captureSystemKeys", in: app)
        assertHittable(keyboard)
        assertSwitchValue(false, on: keyboard)
        keyboard.click()
        assertSwitchValue(true, on: element("settings.captureSystemKeys", in: app))

        selectTab("sharing", in: app)
        assertSwitchValue(true, on: element("settings.clipboardSharing", in: app))
        selectTab("shortcuts", in: app)
        assertSwitchValue(true, on: element("settings.captureSystemKeys", in: app))
        element("settings.captureSystemKeys", in: app).click()
        assertSwitchValue(false, on: element("settings.captureSystemKeys", in: app))
    }

    func testCommandShortcutOpensPaletteOnHomeWithStartAndSettings() {
        let app = launch()
        defer { finish(app) }

        XCTAssertFalse(element("desktop.palette", in: app).exists)
        app.activate()
        app.typeKey("k", modifierFlags: .command)
        assertHittable(element("palette.search", in: app))
        assertHittable(element("palette.command.start", in: app))
        XCTAssertTrue(element("palette.command.machine", in: app).exists)
        XCTAssertFalse(element("palette.command.shutdown", in: app).exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(element("palette.search", in: app).waitForExistence(timeout: 1))
        assertHittable(element("welcome.setup", in: app))

        openSettings(in: app)
        app.activate()
        app.typeKey("k", modifierFlags: .command)
        XCTAssertFalse(element("palette.search", in: app).waitForExistence(timeout: 1))
        assertHittable(element("settings.tab.general", in: app))
    }

    func testHomePaletteSettingsCommandOpensMachinePane() {
        let app = launch()
        defer { finish(app) }

        let commands = element("welcome.palette", in: app)
        assertHittable(commands)
        commands.click()
        let machine = element("palette.command.machine", in: app)
        assertHittable(machine)
        machine.click()
        assertHittable(element("settings.cpu", in: app))
    }

    func testNativeSettingsAccessibilityStructure() throws {
        let app = launch()
        defer { finish(app) }
        openSettings(in: app)

        for tab in ["general", "machine", "sharing", "shortcuts", "about"] {
            selectTab(tab, in: app)
            try app.performAccessibilityAudit(for: [.action, .parentChild])
        }
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-reset"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(element("welcome.title", in: app).waitForExistence(timeout: 10))
        return app
    }

    private func finish(_ app: XCUIApplication) {
        if (testRun?.failureCount ?? 0) > 0 {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = name
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app.terminate()
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openSettings(in app: XCUIApplication) {
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        assertHittable(element("settings.tab.general", in: app))
    }

    private func settingsWindow(in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.containing(.any, identifier: "settings.tab.general").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        return window
    }

    private func selectTab(_ tab: String, in app: XCUIApplication) {
        let row = element("settings.tab.\(tab)", in: app)
        assertHittable(row)
        row.click()
    }

    private func assertHittable(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, file: file, line: line)
    }

    private func assertValue(_ value: String, on element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, file: file, line: line)
    }

    private func assertSwitchValue(_ value: Bool, on element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", NSNumber(value: value)),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, file: file, line: line)
    }
}
