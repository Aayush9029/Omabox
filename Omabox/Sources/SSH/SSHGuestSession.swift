import Foundation

nonisolated struct SSHGuestSession: Sendable {
    var id = UUID()
    var request: @MainActor @Sendable (SSHGuestRequest) async throws -> SSHGuestResponse
}
