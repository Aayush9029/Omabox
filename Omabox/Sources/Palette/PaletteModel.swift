import Foundation
import Observation

@MainActor
@Observable
final class PaletteModel {
    var isPresented = false
    private(set) var presentationID = UUID()
    var query = "" {
        didSet { highlightedIndex = 0 }
    }
    var highlightedIndex = 0
    var commands: [DesktopCommand] = []

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
        guard results.indices.contains(highlightedIndex) else { return nil }
        return results[highlightedIndex]
    }

    func open(commands: [DesktopCommand]) {
        presentationID = UUID()
        self.commands = commands
        query = ""
        highlightedIndex = 0
        isPresented = true
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        highlightedIndex = min(max(highlightedIndex + offset, 0), results.count - 1)
    }

    func close() { isPresented = false }
}
