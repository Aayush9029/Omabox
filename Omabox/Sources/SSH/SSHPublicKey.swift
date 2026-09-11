import Foundation
import Tagged

nonisolated struct SSHPublicKey: Identifiable, Equatable, Sendable {
    typealias ID = Tagged<Self, String>

    var fileName: String
    var canonicalText: String
    var fingerprint: String

    var id: ID { ID(rawValue: fileName) }
}
