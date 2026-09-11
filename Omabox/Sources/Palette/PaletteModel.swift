import AppKit
import Observation

@MainActor
@Observable
final class PaletteModel {
    var isPresented = false
    private(set) var presentationID = UUID()
    private(set) var page: PalettePage = .commands
    private(set) var currentResolution: CGSize?
    @ObservationIgnored private let onPresentationChanged: () -> Void
    @ObservationIgnored private let onResolutionSelected: (DesktopResolutionPreset) -> Void
    @ObservationIgnored private var commandQuery = ""
    @ObservationIgnored private var commandSelection: DesktopCommand?
    var query = "" {
        didSet {
            if query != oldValue { highlightedIndex = 0 }
        }
    }
    var highlightedIndex = 0
    var commands: [DesktopCommand] = []

    init(
        onPresentationChanged: @escaping () -> Void = {},
        onResolutionSelected: @escaping (DesktopResolutionPreset) -> Void = { _ in }
    ) {
        self.onPresentationChanged = onPresentationChanged
        self.onResolutionSelected = onResolutionSelected
    }

    var resolutionResults: [DesktopResolutionPreset] {
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "×", with: "x")
            .split(whereSeparator: \.isWhitespace)
        return DesktopResolutionPreset.allCases.filter { preset in
            let text = "\(preset.title) \(preset.subtitle) \(preset.rawValue)"
                .lowercased().replacingOccurrences(of: "×", with: "x")
            return terms.allSatisfy { text.contains($0) }
        }
    }

    var resolutionSelection: DesktopResolutionPreset? {
        guard page == .resolutions, resolutionResults.indices.contains(highlightedIndex) else { return nil }
        return resolutionResults[highlightedIndex]
    }

    var highlightedIdentifier: String? {
        switch page {
        case .commands: selection.map { "command.\($0.rawValue)" }
        case .resolutions: resolutionSelection.map { "resolution.\($0.rawValue)" }
        }
    }

    var hasResults: Bool {
        switch page {
        case .commands: !results.isEmpty
        case .resolutions: !resolutionResults.isEmpty
        }
    }

    var results: [DesktopCommand] {
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return commands }

        var scored: [(command: DesktopCommand, score: Int, index: Int)] = []
        for (index, command) in commands.enumerated() {
            if let score = searchScore(for: command, terms: terms) {
                scored.append((command: command, score: score, index: index))
            }
        }
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
        }
        return scored.map(\.command)
    }

    private func searchScore(for command: DesktopCommand, terms: [Substring]) -> Int? {
        let fields = [(command.title, 3), (command.keywords, 2), (command.subtitle, 1)]
            .map { text, weight in
                (text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current), weight)
            }
        var score = 0
        for term in terms {
            guard let weight = fields.first(where: { $0.0.contains(term) })?.1 else { return nil }
            score += weight
        }
        return score
    }

    var selection: DesktopCommand? {
        guard page == .commands, results.indices.contains(highlightedIndex) else { return nil }
        return results[highlightedIndex]
    }

    func open(commands: [DesktopCommand], currentResolution: CGSize? = nil) {
        presentationID = UUID()
        page = .commands
        self.currentResolution = currentResolution
        self.commands = commands
        query = ""
        highlightedIndex = 0
        isPresented = true
        onPresentationChanged()
    }

    func moveSelection(by offset: Int) {
        let count = page == .commands ? results.count : resolutionResults.count
        guard count > 0 else { return }
        highlightedIndex = min(max(highlightedIndex + offset, 0), count - 1)
    }

    func handleKeyboardEvent(
        _ event: NSEvent,
        isComposingText: Bool,
        currentSearchText: String? = nil,
        onExecute: (DesktopCommand) -> Void
    ) -> Bool {
        guard isPresented, event.type == .keyDown, !isComposingText,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        if let currentSearchText { query = currentSearchText }
        switch event.keyCode {
        case 126: moveSelection(by: -1)
        case 125: moveSelection(by: 1)
        case 36, 76: activateSelection(onExecute: onExecute)
        case 53: goBackOrClose()
        default: return false
        }
        return true
    }

    func activateSelection(onExecute: (DesktopCommand) -> Void) {
        guard isPresented else { return }
        if page == .resolutions {
            if let preset = resolutionSelection { selectResolution(preset) }
            return
        }
        guard let command = selection else { return }
        selectCommand(command, onExecute: onExecute)
    }

    func selectCommand(_ command: DesktopCommand, onExecute: (DesktopCommand) -> Void) {
        guard isPresented, page == .commands, results.contains(command) else { return }
        highlightedIndex = results.firstIndex(of: command) ?? 0
        if command == .resolution {
            showResolutions()
            return
        }
        close()
        onExecute(command)
    }

    func showResolutions() {
        guard isPresented, page == .commands else { return }
        commandQuery = query
        commandSelection = selection
        page = .resolutions
        query = ""
        highlightedIndex = resolutionResults.firstIndex(where: { $0.matches(currentResolution) }) ?? 0
        presentationID = UUID()
        onPresentationChanged()
    }

    func selectResolution(_ preset: DesktopResolutionPreset) {
        guard isPresented, page == .resolutions, resolutionResults.contains(preset) else { return }
        close()
        onResolutionSelected(preset)
    }

    func goBackOrClose() {
        guard page == .resolutions else { close(); return }
        page = .commands
        query = commandQuery
        highlightedIndex = commandSelection.flatMap { results.firstIndex(of: $0) } ?? 0
        presentationID = UUID()
        onPresentationChanged()
    }

    func close() { isPresented = false }
}
