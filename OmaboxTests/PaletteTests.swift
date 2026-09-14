import AppKit
import CustomDump
import Testing
@testable import Omabox

@MainActor
struct PaletteTests {
    @Test func filtersUsingResourceSynonymsAndWhitespace() {
        let model = PaletteModel()
        model.open(commands: DesktopCommand.allCases)
        model.query = "  CPU   ram  "
        expectNoDifference(model.results, [.machine])
        expectNoDifference(model.selection, .machine)
    }

    @Test func runningDesktopMemorySearchPrioritizesMachineConfiguration() {
        let model = PaletteModel()
        model.open(commands: [.pause, .shutdown, .settings, .machine, .sharing, .shortcuts])
        model.moveSelection(by: 4)
        model.query = "  MEMÓRY  "
        expectNoDifference(model.results, [.machine, .pause])
        expectNoDifference(model.selection, .machine)

        model.query = "memory pause"
        expectNoDifference(model.results, [.pause])
        expectNoDifference(model.selection, .pause)

        model.query = "memory pause cpu"
        #expect(model.results.isEmpty)
        #expect(model.selection == nil)
    }

    @Test func equalSearchRelevancePreservesCommandOrder() {
        let model = PaletteModel()
        model.open(commands: [.shutdown, .start])
        model.query = "Omarchy"
        expectNoDifference(model.results, [.shutdown, .start])
        model.open(commands: [.start, .shutdown])
        model.query = "Omarchy"
        expectNoDifference(model.results, [.start, .shutdown])
    }

    @Test func selectionStaysValidAsResultsChange() {
        let model = PaletteModel()
        model.open(commands: [.settings, .machine, .sharing])
        model.moveSelection(by: 100)
        expectNoDifference(model.selection, .sharing)
        model.query = "settings"
        expectNoDifference(model.highlightedIndex, 0)
        expectNoDifference(model.selection, .settings)
        model.query = "unfindable-command"
        model.moveSelection(by: 1)
        #expect(model.selection == nil)
    }

    @Test func openingResetsSearchAndUsesOnlyAvailableCommands() {
        let model = PaletteModel()
        model.open(commands: [.settings])
        model.query = "pause"
        #expect(model.results.isEmpty)
        model.close()
        model.open(commands: [.pause, .settings])
        expectNoDifference(model.query, "")
        expectNoDifference(model.results, [.pause, .settings])
        #expect(model.isPresented)
    }

    @Test func repeatedSearchWritesPreserveArrowSelectionAndReturnActivatesItOnce() throws {
        let model = PaletteModel()
        model.open(commands: [.pause, .shutdown, .settings, .sharing])
        var executed: [DesktopCommand] = []
        let down = try keyEvent(code: 125)
        let up = try keyEvent(code: 126)
        let enter = try keyEvent(code: 36)
        for event in [down, down, down, up] {
            #expect(model.handleKeyboardEvent(event, isComposingText: false, currentSearchText: "") { executed.append($0) })
        }
        expectNoDifference(model.selection, .settings)
        model.query = ""
        #expect(model.handleKeyboardEvent(enter, isComposingText: false, currentSearchText: "") { executed.append($0) })
        #expect(!model.handleKeyboardEvent(enter, isComposingText: false) { executed.append($0) })
        model.activateSelection { executed.append($0) }
        expectNoDifference(executed, [.settings])
        #expect(!model.isPresented)
    }

    @Test func latestEditorTextFiltersBeforeNavigationAndReturnUsesHighlightedResult() throws {
        let model = PaletteModel()
        model.open(commands: [.pause, .shutdown, .settings, .machine, .sharing])
        model.moveSelection(by: 4)
        var executed: [DesktopCommand] = []
        #expect(model.handleKeyboardEvent(try keyEvent(code: 125), isComposingText: false, currentSearchText: "memory") { executed.append($0) })
        expectNoDifference(model.results, [.machine, .pause])
        expectNoDifference(model.selection, .pause)
        #expect(model.handleKeyboardEvent(try keyEvent(code: 76), isComposingText: false, currentSearchText: "memory") { executed.append($0) })
        expectNoDifference(executed, [.pause])
    }

    @Test func inputCompositionAndCaretKeysStayWithTheSearchEditor() throws {
        let model = PaletteModel()
        model.open(commands: [.settings, .machine, .sharing])
        model.moveSelection(by: 1)
        var executed: [DesktopCommand] = []
        for code: UInt16 in [125, 126, 36, 53] {
            #expect(!model.handleKeyboardEvent(try keyEvent(code: code), isComposingText: true, currentSearchText: "marked text") { executed.append($0) })
        }
        for code: UInt16 in [123, 124] {
            #expect(!model.handleKeyboardEvent(try keyEvent(code: code), isComposingText: false) { executed.append($0) })
        }
        expectNoDifference(model.query, "")
        expectNoDifference(model.selection, .machine)
        #expect(model.isPresented)
        #expect(executed.isEmpty)
    }

    @Test func emptySearchAndEscapeCannotActivateAnOldSelection() throws {
        let model = PaletteModel()
        model.open(commands: [.settings, .machine])
        model.moveSelection(by: 1)
        var executed: [DesktopCommand] = []
        #expect(model.handleKeyboardEvent(try keyEvent(code: 36), isComposingText: false, currentSearchText: "no matching command") { executed.append($0) })
        #expect(model.isPresented)
        #expect(model.selection == nil)
        #expect(model.handleKeyboardEvent(try keyEvent(code: 53), isComposingText: false) { executed.append($0) })
        #expect(!model.isPresented)
        #expect(executed.isEmpty)
    }

    @Test func activeSessionCommandsIncludeHostControlsAndResumeReplacesPause() {
        let running = DesktopCommand.available(in: .running, hasInstallation: true)
        let paused = DesktopCommand.available(in: .paused, hasInstallation: true)
        #expect(running.contains(.pause))
        #expect(!running.contains(.resume))
        #expect(paused.contains(.resume))
        #expect(!paused.contains(.pause))
        for commands in [running, paused] {
            #expect(commands.contains(.settings))
            #expect(commands.contains(.releaseKeyboard))
            #expect(commands.contains(.shutdown))
            #expect(commands.contains(.files))
        }
        let home = DesktopCommand.available(in: .ready, hasInstallation: true)
        #expect(home.first == .start)
        #expect(home.contains(.settings) && home.contains(.files))
        #expect(!home.contains(.pause) && !home.contains(.shutdown) && !home.contains(.resolution))
        #expect(DesktopCommand.available(in: .absent, hasInstallation: false) == [.start, .folder, .machine, .sharing, .shortcuts, .settings])
        #expect(DesktopCommand.available(in: .preparing, hasInstallation: false).isEmpty)
        #expect(DesktopCommand.available(in: .starting, hasInstallation: true).isEmpty)
        #expect(!DesktopCommand.available(in: .running, hasInstallation: false).contains(.files))
    }

    @Test func commonPowerAndPreferenceTermsFindTheExpectedCommands() {
        let model = PaletteModel()
        model.open(commands: DesktopCommand.available(in: .running, hasInstallation: true))
        for query in ["shutdown", "power off", "turn off"] {
            model.query = query
            expectNoDifference(model.results, [.shutdown])
        }
        model.query = "suspend"
        expectNoDifference(model.results, [.pause])
        model.query = "preferences"
        expectNoDifference(model.results, [.settings])
        #expect(model.commands.contains(.folder))
        model.open(commands: DesktopCommand.available(in: .paused, hasInstallation: true))
        model.query = "unpause"
        expectNoDifference(model.results, [.resume])
    }

    private func keyEvent(code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: code
        ))
    }
}
