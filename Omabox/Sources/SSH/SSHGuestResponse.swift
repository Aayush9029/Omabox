import Foundation

nonisolated struct SSHGuestResponse: Codable, Equatable, Sendable {
    var type: String
    var version: Int
    var enabled: Bool?
    var state: String?
    var user: String?
    var address: String?
    var port: Int?
    var hostPublicKey: String?
    var message: String?

    func validated() throws -> Self {
        guard version == 1 else { throw SSHAccessError.invalidResponse }
        if type == "sshError" {
            throw SSHAccessError.guestRejected(String((message ?? "Linux could not configure SSH.").prefix(300)))
        }
        guard type == "sshConfigured", enabled != nil,
              let state, ["ready", "pendingOwner", "pendingNetwork", "disabled"].contains(state) else {
            throw SSHAccessError.invalidResponse
        }
        guard (state == "disabled") == (enabled == false) else { throw SSHAccessError.invalidResponse }
        if state == "ready" {
            guard enabled == true, user != nil, address != nil, port == 2_222,
                  hostPublicKey != nil else { throw SSHAccessError.invalidResponse }
        }
        return self
    }
}
