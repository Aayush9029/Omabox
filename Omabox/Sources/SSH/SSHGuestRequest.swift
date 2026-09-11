import Foundation

nonisolated struct SSHGuestRequest: Codable, Equatable, Sendable {
    var type: String
    var version = 1
    var enabled: Bool?
    var publicKey: String?

    static func configure(publicKey: String) -> Self {
        Self(type: "configureSSH", enabled: true, publicKey: publicKey)
    }

    static let disable = Self(type: "configureSSH", enabled: false)
    static let status = Self(type: "sshStatus")
}
