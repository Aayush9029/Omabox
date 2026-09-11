import Foundation

nonisolated struct SSHEndpoint: Codable, Equatable, Sendable {
    var user: String
    var address: String
    var port: Int = 2222
    var hostPublicKey: String
}
