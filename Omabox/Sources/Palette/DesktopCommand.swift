import CasePaths
import Foundation

@CasePathable
enum DesktopCommand: String, CaseIterable, Identifiable {
    case start, pause, resume, shutdown, settings, machine, sharing, shortcuts, folder, files, fullScreen, releaseKeyboard, resolution

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
        case .releaseKeyboard: "Release keyboard"
        case .resolution: "Change resolution"
        }
    }

    var subtitle: String {
        switch self {
        case .start: "Boot Omarchy, or set it up first"
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
        case .releaseKeyboard: "Return keyboard and shortcuts to your Mac"
        case .resolution: "Choose a desktop size"
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
        case .releaseKeyboard: "keyboard.chevron.compact.down"
        case .resolution: "display"
        }
    }

    var keywords: String {
        switch self {
        case .shutdown: "shutdown power off stop turn off"
        case .resume: "unpause continue"
        case .pause: "suspend"
        case .settings: "preferences options configuration"
        case .folder: "directory folder share mount"
        case .machine: "cpu ram cores memory disk storage hardware resources"
        case .sharing: "clipboard copy paste permissions microphone audio sound privacy"
        case .shortcuts: "command control option super keyboard keys hotkey escape release"
        case .releaseKeyboard: "capture input escape control option host mac shortcuts"
        case .resolution: "resolution display size pixels screen monitor 320p"
        default: ""
        }
    }

    /// The block the row is filed under, shown at its trailing edge.
    var section: String {
        switch self {
        case .start, .pause, .resume, .shutdown: "Machine"
        case .fullScreen, .releaseKeyboard, .resolution: "Window"
        case .folder, .files: "Sharing"
        case .settings, .machine, .sharing, .shortcuts: "Settings"
        }
    }

    static func available(in state: VMState, hasInstallation: Bool) -> [Self] {
        var commands: [Self]
        switch state {
        case .running, .paused:
            commands = [state == .paused ? .resume : .pause, .shutdown, .releaseKeyboard, .resolution, .fullScreen]
        case .absent, .ready, .failed:
            commands = [.start]
        case .preparing, .starting, .stopping:
            return []
        }
        commands += [.folder, .machine, .sharing, .shortcuts, .settings]
        if hasInstallation { commands.append(.files) }
        return commands
    }
}
