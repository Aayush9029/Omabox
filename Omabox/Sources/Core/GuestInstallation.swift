import Foundation

nonisolated struct GuestInstallation: Equatable, Sendable {
    var directory: URL
    var kernel: URL
    var initialRamdisk: URL?
    var disk: URL
    var commandLine: String
}
