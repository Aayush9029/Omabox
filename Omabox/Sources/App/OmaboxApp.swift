import AppKit
import Dependencies
import SwiftUI

@main
@MainActor
struct OmaboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if AppEnvironment.isUITesting, ProcessInfo.processInfo.arguments.contains("--ui-testing-reset") {
            let preferences = URL.temporaryDirectory.appending(path: "Omabox-UITests/preferences.json")
            try? FileManager.default.removeItem(at: preferences)
        }
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}
