import Foundation

nonisolated struct VMResourcePolicy: Sendable {
    var cpuRange: ClosedRange<Int>
    var memoryRangeGiB: ClosedRange<Int>
    var diskRangeGiB: ClosedRange<Int> = 16...1_024

    func validate(_ preferences: VMPreferences) throws {
        guard cpuRange.contains(preferences.cpuCount) else {
            throw VMConfigurationError.invalidCPU(cpuRange)
        }
        guard memoryRangeGiB.contains(preferences.memoryGiB) else {
            throw VMConfigurationError.invalidMemory(memoryRangeGiB)
        }
        guard diskRangeGiB.contains(preferences.diskSizeGiB) else {
            throw VMConfigurationError.invalidDisk(diskRangeGiB)
        }
    }
}

nonisolated enum VMConfigurationError: LocalizedError, Equatable {
    case unsupportedHost
    case invalidCPU(ClosedRange<Int>)
    case invalidMemory(ClosedRange<Int>)
    case invalidDisk(ClosedRange<Int>)
    case missingFile(String)
    case unavailableSharedFolder
    case invalidMachineIdentifier
    case invalidMACAddress
    case noRunningMachine
    case alreadyRunning
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .unsupportedHost:
            "Omabox needs an Apple silicon Mac with virtualization available."
        case let .invalidCPU(range):
            "Choose between \(range.lowerBound) and \(range.upperBound) CPU cores."
        case let .invalidMemory(range):
            "Choose between \(range.lowerBound) and \(range.upperBound) GB of memory."
        case let .invalidDisk(range):
            "Choose a disk between \(range.lowerBound) and \(range.upperBound) GB."
        case let .missingFile(name):
            "The installation is missing or cannot read \(name). Prepare your Linux disk again."
        case .unavailableSharedFolder:
            "The shared folder is no longer available. Choose it again in Settings."
        case .invalidMachineIdentifier:
            "The saved virtual machine identity is invalid. Your disk has not been changed."
        case .invalidMACAddress:
            "The saved network address is invalid. Your disk has not been changed."
        case .noRunningMachine:
            "There is no active Linux session."
        case .alreadyRunning:
            "This Linux disk is already open in another Omabox session. Shut down that session before starting it here."
        case .microphoneDenied:
            "Allow microphone access for Omabox in System Settings → Privacy & Security → Microphone."
        }
    }
}
