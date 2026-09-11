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
}
