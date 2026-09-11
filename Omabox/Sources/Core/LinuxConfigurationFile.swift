import Foundation

nonisolated enum LinuxConfigurationFile: String, CaseIterable, Sendable {
    case environment
    case desktop

    var title: String {
        switch self {
        case .environment: "Environment"
        case .desktop: "Desktop"
        }
    }

    var fileName: String {
        switch self {
        case .environment: "desktop.env"
        case .desktop: "hyprland.lua"
        }
    }
}
