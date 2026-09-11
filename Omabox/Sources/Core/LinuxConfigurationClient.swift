import AppKit
import Dependencies
import Foundation

nonisolated struct LinuxConfigurationClient: Sendable {
    var open: @MainActor @Sendable (LinuxConfigurationFile) async throws -> Void
}

extension LinuxConfigurationClient: DependencyKey {
    static let liveValue = Self(open: { file in
        let folder = try LinuxConfigurationFiles.prepareDirectory()
        guard let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            throw LinuxConfigurationError.editorUnavailable
        }
        _ = try await NSWorkspace.shared.open(
            [folder.appending(path: file.fileName)],
            withApplicationAt: editor,
            configuration: NSWorkspace.OpenConfiguration()
        )
    })

    static let testValue = Self(open: { _ in throw LinuxConfigurationError.editorUnavailable })
}

extension DependencyValues {
    var linuxConfigurationClient: LinuxConfigurationClient {
        get { self[LinuxConfigurationClient.self] }
        set { self[LinuxConfigurationClient.self] = newValue }
    }
}
