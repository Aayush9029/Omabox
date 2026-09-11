import CustomDump
import Foundation
import Testing
@testable import Omabox

struct CustomizationTests {
    @Test func olderPreferencesKeepEveryExistingValueAndDefaultNewOptions() throws {
        let json = Data("""
        {
            "cpuCount": 3,
            "memoryGiB": 6,
            "diskSizeGiB": 72,
            "clipboardEnabled": false,
            "microphoneEnabled": true,
            "captureSystemKeys": true,
            "showsMenuBarIcon": false,
            "showsDockIcon": false,
            "startsOnLaunch": true,
            "sharedFolderBookmark": "AQID",
            "sharedFolderName": "Projects",
            "sharedFolderReadOnly": false,
            "machineIdentifier": "BAUG",
            "macAddress": "02:00:00:00:00:01"
        }
        """.utf8)
        var expected = VMPreferences()
        expected.cpuCount = 3
        expected.memoryGiB = 6
        expected.diskSizeGiB = 72
        expected.clipboardEnabled = false
        expected.microphoneEnabled = true
        expected.captureSystemKeys = true
        expected.showsMenuBarIcon = false
        expected.showsDockIcon = false
        expected.startsOnLaunch = true
        expected.sharedFolderBookmark = Data([1, 2, 3])
        expected.sharedFolderName = "Projects"
        expected.sharedFolderReadOnly = false
        expected.machineIdentifier = Data([4, 5, 6])
        expected.macAddress = "02:00:00:00:00:01"

        let decoded = try JSONDecoder().decode(VMPreferences.self, from: json)
        expectNoDifference(decoded, expected)
        expectNoDifference(decoded.displayScale, .automatic)
        expectNoDifference(decoded.renderThreadCount, 0)
    }

    @Test func displayOptionsRoundTripAndOnlyGenerateKnownBootArguments() throws {
        for (scale, argument) in [
            (DisplayScale.automatic, "omabox.display_scale=auto"),
            (.standard, "omabox.display_scale=1"),
            (.retina, "omabox.display_scale=2"),
        ] {
            var preferences = VMPreferences()
            preferences.cpuCount = 4
            preferences.displayScale = scale
            preferences.renderThreadCount = 2
            let encoded = try JSONEncoder().encode(preferences)
            expectNoDifference(try JSONDecoder().decode(VMPreferences.self, from: encoded), preferences)
            expectNoDifference(preferences.guestBootArguments, [argument, "omabox.render_threads=2"])
        }

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DisplayScale.self, from: Data("\"1 init=/bin/sh\"".utf8))
        }
    }

    @Test func renderingThreadsFollowAllocatedProcessorsAndBoundCustomValues() {
        var preferences = VMPreferences()
        preferences.cpuCount = 4
        expectNoDifference(preferences.effectiveRenderThreadCount, 4)

        preferences.renderThreadCount = 2
        expectNoDifference(preferences.effectiveRenderThreadCount, 2)

        preferences.renderThreadCount = Int.max
        expectNoDifference(preferences.effectiveRenderThreadCount, 4)

        preferences.cpuCount = 1
        expectNoDifference(preferences.effectiveRenderThreadCount, 1)

        preferences.renderThreadCount = -1
        preferences.cpuCount = 6
        expectNoDifference(preferences.effectiveRenderThreadCount, 6)

        preferences.cpuCount = 0
        expectNoDifference(preferences.effectiveRenderThreadCount, 1)
    }
}
