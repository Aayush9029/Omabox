import CasePaths
import SwiftUI

@CasePathable
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case machine
    case sharing
    case shortcuts
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .machine: "Machine"
        case .sharing: "Sharing"
        case .shortcuts: "Shortcuts"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .machine: "desktopcomputer"
        case .sharing: "square.and.arrow.up"
        case .shortcuts: "keyboard"
        case .about: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .machine: .green
        case .sharing: .purple
        case .shortcuts: .orange
        case .about: .blue
        }
    }
}
