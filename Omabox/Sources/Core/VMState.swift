import CasePaths

@CasePathable
nonisolated enum VMState: Equatable, Sendable {
    case absent
    case preparing
    case ready
    case starting
    case running
    case paused
    case stopping
    case failed(String)

    var title: String {
        switch self {
        case .absent: "Not installed"
        case .preparing: "Preparing"
        case .ready: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .paused: "Paused"
        case .stopping: "Shutting down"
        case .failed: "Unable to start"
        }
    }

    var detail: String {
        switch self {
        case .absent: "Set up Omarchy on this Mac."
        case .preparing: "Setting up your private Linux disk. This can take a few minutes."
        case .ready: "Start your Linux desktop."
        case .starting: "Starting Linux."
        case .running: "Omarchy is running in this window."
        case .paused: "Your session stays in memory until you resume or quit."
        case .stopping: "Waiting for Linux to finish and save its files."
        case let .failed(message): message
        }
    }

    var isRunning: Bool { self == .running }

    var isBusy: Bool {
        switch self {
        case .preparing, .starting, .stopping: true
        case .absent, .ready, .running, .paused, .failed: false
        }
    }

    var hasActiveSession: Bool {
        switch self {
        case .starting, .running, .paused, .stopping: true
        case .absent, .preparing, .ready, .failed: false
        }
    }
}
