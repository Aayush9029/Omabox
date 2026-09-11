import Foundation

nonisolated struct SSHManagedFiles: Codable, Equatable, Sendable {
    var alias: String
    var includeFileName: String
    var includeSHA256: String
    var knownHostsFileName: String
    var knownHostsSHA256: String
    var configurationPrefix: String
    var configurationPrefixSHA256: String
    var configurationWasCreated: Bool
}
