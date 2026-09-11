import Dependencies
import Foundation

nonisolated struct SSHFolderClient: Sendable {
    var makeBookmark: @Sendable (URL) throws -> Data = { url in
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    var resolve: @Sendable (Data) throws -> URL
    var stopAccessing: @Sendable (URL) -> Void
}

extension SSHFolderClient: DependencyKey {
    static let liveValue = Self(
        resolve: { bookmark in
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
            guard !stale, url.startAccessingSecurityScopedResource() else { throw SSHAccessError.folderUnavailable }
            return url
        },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() }
    )

    static let testValue = Self(
        makeBookmark: { _ in throw SSHAccessError.folderUnavailable },
        resolve: { _ in throw SSHAccessError.folderUnavailable },
        stopAccessing: { _ in }
    )
}

extension DependencyValues {
    var sshFolderClient: SSHFolderClient {
        get { self[SSHFolderClient.self] }
        set { self[SSHFolderClient.self] = newValue }
    }
}
