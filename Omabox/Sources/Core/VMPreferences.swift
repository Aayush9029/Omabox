import Foundation
import Sharing

nonisolated struct VMPreferences: Codable, Equatable, Sendable {
    static var storageURL: URL {
        if AppEnvironment.isUITesting {
            return URL.temporaryDirectory.appending(path: "Omabox-UITests/preferences.json")
        }
        return URL.applicationSupportDirectory.appending(path: "Omabox/preferences.json")
    }

    var cpuCount = min(4, ProcessInfo.processInfo.activeProcessorCount)
    var memoryGiB = min(8, max(2, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) / 2))
    var diskSizeGiB = 40
    var clipboardEnabled = true
    var microphoneEnabled = false
    var captureSystemKeys = false
    var showsMenuBarIcon = true
    var showsDockIcon = true
    var startsOnLaunch = false
    var displayScale = DisplayScale.automatic
    var renderThreadCount = 0
    var sharedFolderBookmark: Data?
    var sharedFolderName: String?
    var sharedFolderReadOnly = true
    var machineIdentifier: Data?
    var macAddress: String?

    var effectiveRenderThreadCount: Int {
        let maximum = max(1, cpuCount)
        return renderThreadCount > 0 ? min(renderThreadCount, maximum) : maximum
    }

    var guestBootArguments: [String] {
        [
            "omabox.display_scale=\(displayScale.rawValue)",
            "omabox.render_threads=\(effectiveRenderThreadCount)",
        ]
    }
}

extension VMPreferences {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VMPreferences()
        cpuCount = try container.decodeIfPresent(Int.self, forKey: .cpuCount) ?? defaults.cpuCount
        memoryGiB = try container.decodeIfPresent(Int.self, forKey: .memoryGiB) ?? defaults.memoryGiB
        diskSizeGiB = try container.decodeIfPresent(Int.self, forKey: .diskSizeGiB) ?? defaults.diskSizeGiB
        clipboardEnabled = try container.decodeIfPresent(Bool.self, forKey: .clipboardEnabled) ?? defaults.clipboardEnabled
        microphoneEnabled = try container.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? defaults.microphoneEnabled
        captureSystemKeys = try container.decodeIfPresent(Bool.self, forKey: .captureSystemKeys) ?? defaults.captureSystemKeys
        showsMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showsMenuBarIcon) ?? defaults.showsMenuBarIcon
        showsDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showsDockIcon) ?? defaults.showsDockIcon
        startsOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .startsOnLaunch) ?? defaults.startsOnLaunch
        displayScale = try container.decodeIfPresent(DisplayScale.self, forKey: .displayScale) ?? defaults.displayScale
        renderThreadCount = try container.decodeIfPresent(Int.self, forKey: .renderThreadCount) ?? defaults.renderThreadCount
        sharedFolderBookmark = try container.decodeIfPresent(Data.self, forKey: .sharedFolderBookmark)
        sharedFolderName = try container.decodeIfPresent(String.self, forKey: .sharedFolderName)
        sharedFolderReadOnly = try container.decodeIfPresent(Bool.self, forKey: .sharedFolderReadOnly) ?? defaults.sharedFolderReadOnly
        machineIdentifier = try container.decodeIfPresent(Data.self, forKey: .machineIdentifier)
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
    }
}

extension SharedKey where Self == FileStorageKey<VMPreferences>.Default {
    static var omaboxPreferences: Self {
        Self[
            .fileStorage(VMPreferences.storageURL),
            default: VMPreferences()
        ]
    }
}
