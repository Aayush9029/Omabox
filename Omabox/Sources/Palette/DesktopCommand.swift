import CasePaths
import Foundation

@CasePathable
enum DesktopCommand: String, CaseIterable, Identifiable {
    case start, pause, resume, shutdown, settings, machine, sharing, shortcuts, folder, files, fullScreen

    var id: Self { self }

    var title: String {
        switch self {
        case .start: "Start Omarchy"
        case .pause: "Pause desktop"
        case .resume: "Resume desktop"
        case .shutdown: "Shut down Omarchy"
        case .settings: "Open Settings"
        case .machine: "Configure machine"
        case .sharing: "Sharing & permissions"
        case .shortcuts: "Keyboard shortcuts"
        case .folder: "Choose a shared folder"
        case .files: "Show desktop files in Finder"
        case .fullScreen: "Toggle full screen"
        }
    }

    var subtitle: String {
        switch self {
        case .start: "Open your Linux workspace"
        case .pause: "Keep your session in memory"
        case .resume: "Continue the paused session"
        case .shutdown: "Ask Linux to close your session safely"
        case .settings: "Omabox preferences"
        case .machine: "Processor, memory, and storage"
        case .sharing: "Clipboard, microphone, and shared folders"
        case .shortcuts: "Command keys and releasing input"
        case .folder: "Share a folder you choose with Linux"
        case .files: "Open the location of your virtual machine"
        case .fullScreen: "Enter or leave full screen"
        }
    }

    var symbol: String {
        switch self {
        case .start: "play.fill"
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .shutdown: "power"
        case .settings: "gearshape"
        case .machine: "cpu"
        case .sharing: "arrow.left.arrow.right"
        case .shortcuts: "keyboard"
        case .folder: "folder.badge.plus"
        case .files: "folder"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        }
    }

    var keywords: String {
        switch self {
        case .machine: "cpu ram cores memory disk storage hardware resources"
        case .sharing: "clipboard copy paste permissions microphone audio sound privacy"
        case .shortcuts: "command control option super keyboard keys hotkey escape release"
        default: ""
        }
    }
}
