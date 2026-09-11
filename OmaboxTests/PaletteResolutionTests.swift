import AppKit
import CustomDump
import Testing
@testable import Omabox

@MainActor
struct PaletteResolutionTests {
    @Test func mainPaletteOffersOneResolutionCommandWithoutIndividualPresets() {
        let model = PaletteModel()
        for state: VMState in [.running, .paused] {
            model.open(commands: DesktopCommand.available(in: state, hasInstallation: true))
            expectNoDifference(model.page, .commands)
            expectNoDifference(model.results.filter { $0 == .resolution }, [.resolution])
            #expect(model.resolutionSelection == nil)
            #expect(Set(model.commands.map(\.rawValue)).isDisjoint(with: DesktopResolutionPreset.allCases.map(\.rawValue)))

            model.query = "resolution"
            expectNoDifference(model.results, [.resolution])
            model.query = "1280x800"
            #expect(!model.hasResults)
            #expect(model.selection == nil)
        }
    }

    @Test func returnOpensSubmenuAtCurrentResolutionWithoutExecutingACommand() throws {
        var resolutions: [DesktopResolutionPreset] = []
        var commands: [DesktopCommand] = []
        let model = PaletteModel(onResolutionSelected: { resolutions.append($0) })
        let current = CGSize(width: 1280, height: 800)
        model.open(commands: [.settings, .resolution], currentResolution: current)
        let initialPresentation = model.presentationID

        #expect(model.handleKeyboardEvent(try keyEvent(code: 125), isComposingText: false) { commands.append($0) })
        #expect(model.handleKeyboardEvent(try keyEvent(code: 36), isComposingText: false) { commands.append($0) })

        #expect(model.isPresented)
        expectNoDifference(model.page, .resolutions)
        expectNoDifference(model.currentResolution, current)
        expectNoDifference(model.resolutionSelection, .size1280x800)
        expectNoDifference(model.highlightedIdentifier, "resolution.1280x800")
        expectNoDifference(model.query, "")
        #expect(model.selection == nil)
        #expect(model.presentationID != initialPresentation)
        #expect(commands.isEmpty)
        #expect(resolutions.isEmpty)
    }

    @Test func arrowAndReturnApplyTheHighlightedPresetOnceAndClose() throws {
        var resolutions: [DesktopResolutionPreset] = []
        var commands: [DesktopCommand] = []
        let model = PaletteModel(onResolutionSelected: { resolutions.append($0) })
        model.open(commands: [.resolution], currentResolution: CGSize(width: 1280, height: 800))
        let enter = try keyEvent(code: 36)
        #expect(model.handleKeyboardEvent(enter, isComposingText: false) { commands.append($0) })
        #expect(model.handleKeyboardEvent(try keyEvent(code: 125), isComposingText: false, currentSearchText: "") { commands.append($0) })
        expectNoDifference(model.resolutionSelection, .size1440x900)

        #expect(model.handleKeyboardEvent(enter, isComposingText: false, currentSearchText: "") { commands.append($0) })
        #expect(!model.isPresented)
        #expect(!model.handleKeyboardEvent(enter, isComposingText: false) { commands.append($0) })
        model.activateSelection { commands.append($0) }
        model.selectResolution(.size1440x900)

        expectNoDifference(resolutions, [.size1440x900])
        #expect(commands.isEmpty)
    }

    @Test func escapeRestoresFilteredMainQueryAndHighlightBeforeClosing() throws {
        var resolutions: [DesktopResolutionPreset] = []
        var commands: [DesktopCommand] = []
        let model = PaletteModel(onResolutionSelected: { resolutions.append($0) })
        model.open(commands: [.resolution, .settings, .fullScreen])
        model.query = "screen"
        expectNoDifference(model.results, [.fullScreen, .resolution])
        #expect(model.handleKeyboardEvent(try keyEvent(code: 125), isComposingText: false) { commands.append($0) })
        #expect(model.handleKeyboardEvent(try keyEvent(code: 36), isComposingText: false) { commands.append($0) })
        model.query = "320p"
        let submenuPresentation = model.presentationID
        let escape = try keyEvent(code: 53)

        #expect(model.handleKeyboardEvent(escape, isComposingText: false) { commands.append($0) })
        #expect(model.isPresented)
        expectNoDifference(model.page, .commands)
        expectNoDifference(model.query, "screen")
        expectNoDifference(model.results, [.fullScreen, .resolution])
        expectNoDifference(model.highlightedIndex, 1)
        expectNoDifference(model.selection, .resolution)
        expectNoDifference(model.highlightedIdentifier, "command.resolution")
        #expect(model.presentationID != submenuPresentation)

        #expect(model.handleKeyboardEvent(escape, isComposingText: false) { commands.append($0) })
        #expect(!model.isPresented)
        #expect(commands.isEmpty)
        #expect(resolutions.isEmpty)
    }

    @Test func submenuSearchFindsPixelDimensionsAndAutomaticResolution() {
        let model = PaletteModel()
        model.open(commands: [.resolution])
        model.showResolutions()
        let searches: [(String, DesktopResolutionPreset)] = [
            ("320p", .size512x320),
            ("1280x800", .size1280x800),
            ("1280×800", .size1280x800),
            ("  AUTOMATIC  ", .fitToScreen)
        ]
        for (query, preset) in searches {
            model.query = query
            #expect(model.hasResults)
            expectNoDifference(model.resolutionResults, [preset])
            expectNoDifference(model.resolutionSelection, preset)
            expectNoDifference(model.highlightedIdentifier, "resolution.\(preset.rawValue)")
        }
    }

    @Test func noMatchingResolutionCannotApplyThePreviousSelection() throws {
        var resolutions: [DesktopResolutionPreset] = []
        var commands: [DesktopCommand] = []
        let model = PaletteModel(onResolutionSelected: { resolutions.append($0) })
        model.open(commands: [.resolution], currentResolution: CGSize(width: 1280, height: 800))
        model.showResolutions()
        expectNoDifference(model.resolutionSelection, .size1280x800)

        #expect(model.handleKeyboardEvent(try keyEvent(code: 36), isComposingText: false, currentSearchText: "unavailable size") { commands.append($0) })
        #expect(model.handleKeyboardEvent(try keyEvent(code: 125), isComposingText: false) { commands.append($0) })
        model.selectResolution(.size1280x800)

        #expect(model.isPresented)
        expectNoDifference(model.page, .resolutions)
        #expect(!model.hasResults)
        #expect(model.resolutionResults.isEmpty)
        #expect(model.resolutionSelection == nil)
        #expect(model.highlightedIdentifier == nil)
        #expect(commands.isEmpty)
        #expect(resolutions.isEmpty)
    }

    @Test func pointerSelectionRestoresTheClickedCommandInsteadOfThePreviousHighlight() {
        var resolutions: [DesktopResolutionPreset] = []
        var commands: [DesktopCommand] = []
        let model = PaletteModel(onResolutionSelected: { resolutions.append($0) })
        model.open(commands: [.resolution, .fullScreen, .settings])
        model.query = "screen"
        expectNoDifference(model.selection, .fullScreen)

        model.selectCommand(.resolution) { commands.append($0) }
        expectNoDifference(model.page, .resolutions)
        #expect(model.isPresented)
        model.query = "automatic"
        model.goBackOrClose()

        expectNoDifference(model.page, .commands)
        expectNoDifference(model.query, "screen")
        expectNoDifference(model.highlightedIndex, 1)
        expectNoDifference(model.selection, .resolution)
        #expect(model.isPresented)
        #expect(commands.isEmpty)
        #expect(resolutions.isEmpty)
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
