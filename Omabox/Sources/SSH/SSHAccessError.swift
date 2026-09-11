import CasePaths
import Foundation

@CasePathable
nonisolated enum SSHAccessError: Equatable, LocalizedError {
    case unavailable
    case timedOut
    case invalidResponse
    case folderUnavailable
    case differentManagedFolder
    case keyUnavailable
    case guestRejected(String)

    var errorDescription: String? {
        switch self {
        case .unavailable, .timedOut:
            "The Linux SSH service is not responding. Older disks need the SSH integration update; newly prepared disks include it."
        case .invalidResponse:
            "Linux returned an invalid SSH configuration. No host entry was added."
        case .folderUnavailable:
            "Choose your SSH folder again to restore access."
        case .differentManagedFolder:
            "Choose the current SSH folder to restore access. Remove its managed configuration before choosing a different folder."
        case .keyUnavailable:
            "Choose a public key from the selected SSH folder. Private keys stay on your Mac."
        case let .guestRejected(message):
            message
        }
    }
}
