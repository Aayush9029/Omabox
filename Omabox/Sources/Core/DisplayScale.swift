import CasePaths

@CasePathable
nonisolated enum DisplayScale: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic = "auto"
    case standard = "1"
    case retina = "2"

    var id: Self { self }
}
