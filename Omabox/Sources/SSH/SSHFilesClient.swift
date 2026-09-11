import Dependencies
import Foundation
import IdentifiedCollections

nonisolated struct SSHFilesClient: Sendable {
    var publicKeys: @Sendable (URL) async throws -> IdentifiedArrayOf<SSHPublicKey>
    var installConfiguration: @Sendable (URL, SSHPublicKey, String, SSHEndpoint, SSHManagedFiles?) async throws -> SSHManagedFiles
    var removeConfiguration: @Sendable (URL, SSHManagedFiles) async throws -> Void

    static func isValidAlias(_ alias: String) -> Bool { SSHConfiguration.isValidAlias(alias) }
}

extension SSHFilesClient: DependencyKey {
    static var liveValue: Self {
        guard !AppEnvironment.isUITesting else { return testValue }
        let provider = SSHFilesProvider()
        return Self(
            publicKeys: { try await provider.publicKeys(in: $0) },
            installConfiguration: { try await provider.install(in: $0, key: $1, alias: $2, endpoint: $3, previous: $4) },
            removeConfiguration: { try await provider.remove(in: $0, managed: $1) }
        )
    }

    static var testValue: Self {
        Self(
            publicKeys: { _ in [] },
            installConfiguration: { _, _, _, _, _ in throw SSHFileError.invalidEndpoint },
            removeConfiguration: { _, _ in }
        )
    }
}

extension DependencyValues {
    var sshFilesClient: SSHFilesClient {
        get { self[SSHFilesClient.self] }
        set { self[SSHFilesClient.self] = newValue }
    }
}
