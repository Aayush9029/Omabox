import CryptoKit
import CustomDump
import Darwin
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing
@testable import Omabox

@Suite(.dependencies { $0.uuid = .incrementing })
struct SSHFilesTests {
    @Test func discoversOnlyBoundedRegularPublicKeysAndLeavesPrivateFilesAlone() async throws {
        let fixture = try SSHFilesFixture()
        defer { fixture.remove() }
        let originalPrivateBytes = Data("private fixture must remain untouched".utf8)
        try fixture.write("id_ed25519", data: originalPrivateBytes)
        try fixture.write("id_ed25519.pub", data: Data((fixture.key.canonicalText + " fixture comment\n").utf8))
        try fixture.write("broken.pub", data: Data("not an SSH key".utf8))
        try fixture.write("oversized.pub", data: Data(repeating: 65, count: SSHKeyParser.maximumBytes + 1))
        try FileManager.default.createSymbolicLink(at: fixture.url("linked.pub"), withDestinationURL: fixture.url("id_ed25519.pub"))
        #expect(mkfifo(fixture.url("pipe.pub").path, mode_t(0o600)) == 0)
        let keys = try await fixture.provider.publicKeys(in: fixture.directory)
        expectNoDifference(Array(keys), [fixture.key])
        expectNoDifference(try Data(contentsOf: fixture.url("id_ed25519")), originalPrivateBytes)
    }

    @Test(arguments: ["", "Host other\n  User somebody", "Host *\r\n  ServerAliveInterval 30\r\n", "User guest\nHost other\n  HostName elsewhere\n"])
    func installsIdempotentlyAndRestoresOriginalConfigBytesAndPermissions(_ original: String) async throws {
        let fixture = try SSHFilesFixture()
        defer { fixture.remove() }
        try fixture.write("config", data: Data(original.utf8), mode: 0o640)
        let managed = try await fixture.install()
        let installedConfig = try Data(contentsOf: fixture.url("config"))
        expectNoDifference(installedConfig, Data(managed.configurationPrefix.utf8) + Data(original.utf8))
        expectNoDifference(try fixture.mode("config"), 0o640)
        expectNoDifference(try fixture.mode(managed.includeFileName), 0o600)
        expectNoDifference(try fixture.mode(managed.knownHostsFileName), 0o600)
        let repeated = try await fixture.install(previous: managed)
        expectNoDifference(repeated, managed)
        expectNoDifference(try Data(contentsOf: fixture.url("config")), installedConfig)
        try await fixture.provider.remove(in: fixture.directory, managed: repeated)
        expectNoDifference(try Data(contentsOf: fixture.url("config")), Data(original.utf8))
        expectNoDifference(try fixture.mode("config"), 0o640)
        #expect(!FileManager.default.fileExists(atPath: fixture.url(managed.includeFileName).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.url(managed.knownHostsFileName).path))
    }

    @Test func removalDeletesOnlyItsNewEmptyConfigAndPreservesLaterUserAdditions() async throws {
        let fixture = try SSHFilesFixture()
        defer { fixture.remove() }
        let managed = try await fixture.install()
        try await fixture.provider.remove(in: fixture.directory, managed: managed)
        #expect(!FileManager.default.fileExists(atPath: fixture.url("config").path))
        let next = try await fixture.install()
        let userAddition = Data("Host my-server\n  User my-user\n".utf8)
        try fixture.write("config", data: Data(next.configurationPrefix.utf8) + userAddition)
        try await fixture.provider.remove(in: fixture.directory, managed: next)
        expectNoDifference(try Data(contentsOf: fixture.url("config")), userAddition)
    }

    @Test(arguments: ["omabox.conf", "omabox_known_hosts", "config"])
    func userChangesPreventUpdatesAndRemovalWithoutTouchingAnyOtherFile(_ edited: String) async throws {
        let fixture = try SSHFilesFixture()
        defer { fixture.remove() }
        let managed = try await fixture.install()
        let modified = Data("user-owned replacement\n".utf8)
        try fixture.write(edited, data: modified)
        let before = try fixture.managedBytes()
        await #expect(throws: SSHFileError.self) { try await fixture.install(previous: managed) }
        expectNoDifference(try fixture.managedBytes(), before)
        await #expect(throws: SSHFileError.self) { try await fixture.provider.remove(in: fixture.directory, managed: managed) }
        expectNoDifference(try fixture.managedBytes(), before)
    }

    @Test(arguments: ["omabox.conf", "omabox_known_hosts"])
    func neverOverwritesUnownedDedicatedFiles(_ name: String) async throws {
        let fixture = try SSHFilesFixture()
        defer { fixture.remove() }
        let original = Data("belongs to the user\n".utf8)
        try fixture.write(name, data: original)
        await #expect(throws: SSHFileError.ownershipConflict(name)) { try await fixture.install() }
        expectNoDifference(try Data(contentsOf: fixture.url(name)), original)
        #expect(!FileManager.default.fileExists(atPath: fixture.url("config").path))
    }

    @Test(arguments: ["symlink", "hardlink", "fifo"])
    func unsafeConfigurationObjectsAreNeverFollowedOrChanged(_ kind: String) async throws {
        let fixture = try SSHFilesFixture()
        defer { fixture.remove() }
        let original = Data("unrelated file\n".utf8)
        try fixture.write("unrelated", data: original)
        switch kind {
        case "symlink":
            try FileManager.default.createSymbolicLink(at: fixture.url("config"), withDestinationURL: fixture.url("unrelated"))
        case "hardlink":
            #expect(link(fixture.url("unrelated").path, fixture.url("config").path) == 0)
        default:
            #expect(mkfifo(fixture.url("config").path, mode_t(0o600)) == 0)
        }
        await #expect(throws: SSHFileError.unsafeFile("config")) { try await fixture.install() }
        expectNoDifference(try Data(contentsOf: fixture.url("unrelated")), original)
        #expect(!FileManager.default.fileExists(atPath: fixture.url("omabox.conf").path))
    }

    @Test(arguments: ["Host omabox", "hOsT = OMABOX other", "Host oma*", "Host \"omabox\" # mine"])
    func rejectsExistingAliasAndMatchingNamedPatterns(_ hostLine: String) async throws {
        let fixture = try SSHFilesFixture()
        defer { fixture.remove() }
        let original = Data((hostLine + "\n  User other\n").utf8)
        try fixture.write("config", data: original)
        await #expect(throws: SSHFileError.self) { try await fixture.install() }
        expectNoDifference(try Data(contentsOf: fixture.url("config")), original)
        #expect(!FileManager.default.fileExists(atPath: fixture.url("omabox.conf").path))
    }

    @Test func preservesIncludesMatchRulesAndExcludedWildcardPatternsWithoutEvaluatingThem() async throws {
        let fixture = try SSHFilesFixture()
        defer { fixture.remove() }
        let original = Data("Include untouched/*.conf\nMatch exec \"a-command-that-must-never-run\"\n  User other\nHost oma* !omabox\n  User excluded\nHost *\n  ServerAliveInterval 30\n".utf8)
        try fixture.write("config", data: original)
        let managed = try await fixture.install()
        expectNoDifference(try Data(contentsOf: fixture.url("config")), Data(managed.configurationPrefix.utf8) + original)
        try await fixture.provider.remove(in: fixture.directory, managed: managed)
        expectNoDifference(try Data(contentsOf: fixture.url("config")), original)
    }

    @Test func updatesAddressAndPinnedHostKeyWhilePreservingConfigAndPublicKey() async throws {
        let fixture = try SSHFilesFixture()
        defer { fixture.remove() }
        let managed = try await fixture.install()
        let config = try Data(contentsOf: fixture.url("config"))
        var endpoint = fixture.endpoint
        endpoint.address = "192.168.64.12"
        endpoint.hostPublicKey = SSHFilesFixture.ed25519Text()
        let next = try await fixture.provider.install(in: fixture.directory, key: fixture.key, alias: "omabox", endpoint: endpoint, previous: managed)
        expectNoDifference(try Data(contentsOf: fixture.url("config")), config)
        expectNoDifference(try String(contentsOf: fixture.url(next.knownHostsFileName), encoding: .utf8), "omabox \(endpoint.hostPublicKey)\n")
        #expect(try String(contentsOf: fixture.url(next.includeFileName), encoding: .utf8).contains("HostName 192.168.64.12"))
        let publicKeys = try await fixture.provider.publicKeys(in: fixture.directory)
        expectNoDifference(publicKeys.first, fixture.key)
    }

    @Test func changedSelectedPublicKeyFailsBeforeWritingConfiguration() async throws {
        let fixture = try SSHFilesFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.key.fileName, data: Data(SSHFilesFixture.ed25519Text().utf8))
        await #expect(throws: SSHFileError.publicKeyChanged) { try await fixture.install() }
        #expect(!FileManager.default.fileExists(atPath: fixture.url("config").path))
    }

    @Test func directoryLockAndSnapshotChecksPreventClobberingConcurrentChanges() throws {
        let fixture = try SSHFilesFixture()
        defer { fixture.remove() }
        try fixture.write("config", data: Data("old\n".utf8))
        let directory = try SSHDirectory(url: fixture.directory)
        #expect(throws: SSHFileError.directoryBusy) { try SSHDirectory(url: fixture.directory) }
        let before = try #require(try directory.read("config", limit: 128))
        try fixture.write("config", data: Data("user edited\n".utf8))
        #expect(throws: SSHFileError.ownershipConflict("config")) {
            try directory.replace("config", with: Data("replacement\n".utf8), expected: before, temporaryName: ".omabox-test.tmp")
        }
        expectNoDifference(try Data(contentsOf: fixture.url("config")), Data("user edited\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.url(".omabox-test.tmp").path))
    }

    @Test func cancellationBeforeInstallationLeavesTheFolderUnchanged() async throws {
        let fixture = try SSHFilesFixture()
        defer { fixture.remove() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.install()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.url("config").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.url("omabox.conf").path))
    }

    @Test func restoringADeletedSnapshotPreservesItsOriginalPermissions() throws {
        let fixture = try SSHFilesFixture()
        defer { fixture.remove() }
        let original = Data("Host personal\n  User owner\n".utf8)
        try fixture.write("config", data: original, mode: 0o640)
        let directory = try SSHDirectory(url: fixture.directory)
        let before = try #require(try directory.read("config", limit: 1024))
        try directory.remove("config", expected: before)
        _ = try directory.replace(
            "config", with: before.data, expected: nil,
            temporaryName: ".omabox-restore.tmp", checkCancellation: false,
            restoringMode: before.mode
        )
        expectNoDifference(try Data(contentsOf: fixture.url("config")), original)
        expectNoDifference(try fixture.mode("config"), 0o640)
    }

    @Test(arguments: ["bad%path", "bad$path", "bad*path", "bad?path", "bad[path", "bad\"path", "bad\\path", "bad\npath"])
    func refusesPathsThatSSHWouldExpand(_ name: String) throws {
        #expect(throws: SSHFileError.unsupportedPath) { try SSHDirectory.validatePath("/selected/\(name)") }
    }

    @Test func quotedPathsSupportSpacesAndHashesAndNeverRequireReadingThePrivateKey() async throws {
        let fixture = try SSHFilesFixture(suffix: " space # folder")
        defer { fixture.remove() }
        let managed = try await fixture.install()
        let profile = try String(contentsOf: fixture.url(managed.includeFileName), encoding: .utf8)
        #expect(profile.contains("IdentityFile \"\(fixture.url("id_ed25519").path)\""))
        #expect(profile.contains("StrictHostKeyChecking yes"))
        #expect(profile.contains("HostKeyAlias omabox"))
        #expect(!FileManager.default.fileExists(atPath: fixture.url("id_ed25519").path))
        try await fixture.provider.remove(in: fixture.directory, managed: managed)
    }

    @Test func rejectsMalformedOrMismatchedWireKeysAndComputesStandardFingerprints() throws {
        let text = SSHFilesFixture.ed25519Text()
        let key = try SSHKeyParser.parse(Data((text + " hello\n").utf8), fileName: "key.pub")
        expectNoDifference(key.canonicalText, text)
        let blob = try #require(Data(base64Encoded: String(text.split(separator: " ")[1])))
        expectNoDifference(key.fingerprint, "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: ""))
        for invalid in [
            text.replacingOccurrences(of: "ssh-ed25519 ", with: "ssh-rsa "),
            text + "\n" + text,
            "ssh-ed25519 " + (blob + Data([0])).base64EncodedString(),
            "ssh-ed25519 " + SSHFilesFixture.wire([Data("ssh-ed25519".utf8), Data(repeating: 1, count: 31)]).base64EncodedString(),
            "ssh-ed25519 /////w=="
        ] {
            #expect(throws: SSHFileError.self) { try SSHKeyParser.parse(Data(invalid.utf8), fileName: "invalid.pub") }
        }
    }

    @Test func acceptsValidatedECDSAAndRSAWireFormats() throws {
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        let ecdsaBlob = SSHFilesFixture.wire([Data("ecdsa-sha2-nistp256".utf8), Data("nistp256".utf8), point])
        let ecdsa = "ecdsa-sha2-nistp256 " + ecdsaBlob.base64EncodedString()
        expectNoDifference(try SSHKeyParser.parse(Data(ecdsa.utf8), fileName: "ecdsa.pub").canonicalText, ecdsa)
        let modulus = Data([0, 0x80]) + Data(repeating: 0xA5, count: 254) + Data([1])
        let rsaBlob = SSHFilesFixture.wire([Data("ssh-rsa".utf8), Data([1, 0, 1]), modulus])
        let rsa = "ssh-rsa " + rsaBlob.base64EncodedString()
        expectNoDifference(try SSHKeyParser.parse(Data(rsa.utf8), fileName: "rsa.pub").canonicalText, rsa)
        #expect(throws: SSHFileError.self) { try SSHKeyParser.parse(Data(ecdsa.utf8), fileName: "host", hostKeyOnly: true) }
    }

    @Test(arguments: ["", "-omabox", "space name", "name\nHost other", "a/b", "\u{00E9}", String(repeating: "a", count: 64)])
    func rejectsInvalidHostAliases(_ alias: String) {
        #expect(!SSHFilesClient.isValidAlias(alias))
    }

    @Test(arguments: ["127.0.0.1", "0.0.0.0", "8.8.8.8", "192.168.64.255", "192.168.64.0", "192.168.064.1", "192.168.64.2\nProxyCommand evil"])
    func rejectsNonGuestAddressesAndInjectedEndpointValues(_ address: String) throws {
        let endpoint = SSHEndpoint(user: "omabox", address: address, hostPublicKey: SSHFilesFixture.ed25519Text())
        #expect(throws: SSHFileError.invalidEndpoint) { try SSHConfiguration.validate(endpoint) }
    }

    @Test func rejectsSSHPortsOutsideTheDedicatedGuestService() throws {
        let endpoint = SSHEndpoint(user: "omabox", address: "192.168.64.2", port: 22, hostPublicKey: SSHFilesFixture.ed25519Text())
        #expect(throws: SSHFileError.invalidEndpoint) { try SSHConfiguration.validate(endpoint) }
    }
}

private struct SSHFilesFixture: Sendable {
    let directory: URL
    let key: SSHPublicKey
    let endpoint: SSHEndpoint
    let provider = SSHFilesProvider()

    init(suffix: String = "") throws {
        directory = URL.temporaryDirectory.appending(path: "OmaboxSSHFiles-\(UUID().uuidString)\(suffix)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        key = try SSHKeyParser.parse(Data(Self.ed25519Text().utf8), fileName: "id_ed25519.pub")
        endpoint = SSHEndpoint(user: "omabox", address: "192.168.64.2", hostPublicKey: Self.ed25519Text())
        try write(key.fileName, data: Data(key.canonicalText.utf8))
    }

    func url(_ name: String) -> URL { directory.appending(path: name) }

    func write(_ name: String, data: Data, mode: Int = 0o600) throws {
        try data.write(to: url(name))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url(name).path)
    }

    func install(previous: SSHManagedFiles? = nil) async throws -> SSHManagedFiles {
        try await provider.install(in: directory, key: key, alias: "omabox", endpoint: endpoint, previous: previous)
    }

    func mode(_ name: String) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url(name).path)[.posixPermissions] as? Int)
    }

    func managedBytes() throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: ["config", "omabox.conf", "omabox_known_hosts"].map {
            ($0, try Data(contentsOf: url($0)))
        })
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    static func ed25519Text() -> String {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        return "ssh-ed25519 " + wire([Data("ssh-ed25519".utf8), key]).base64EncodedString()
    }

    static func wire(_ strings: [Data]) -> Data {
        strings.reduce(into: Data()) { result, string in
            var length = UInt32(string.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(string)
        }
    }
}
