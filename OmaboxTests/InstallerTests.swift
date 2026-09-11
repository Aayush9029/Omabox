import CryptoKit
import Foundation
import Testing
@testable import Omabox

struct InstallerTests {
    @Test func absentTemplateDoesNotCreateAnInstallation() async throws {
        let fixture = try GuestFixture()
        defer { fixture.remove() }
        let installer = fixture.installer
        #expect(try await installer.existing() == nil)
        await #expect(throws: GuestInstallationError.templateUnavailable) {
            try await installer.prepare(diskSizeGiB: 16, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.installationURL.path))
    }

    @Test func installsSparseDiskAndPreservesGuestChangesOnRepeatedPreparation() async throws {
        let fixture = try GuestFixture()
        defer { fixture.remove() }
        try fixture.writeTemplate()
        let installer = fixture.installer
        let installation = try await installer.prepare(diskSizeGiB: 16, progress: { _ in })
        #expect(try Data(contentsOf: installation.kernel) == fixture.kernel)
        #expect(try installation.disk.resourceValues(forKeys: [.fileSizeKey]).fileSize == 16 * 1_073_741_824)
        let disk = try FileHandle(forWritingTo: installation.disk)
        try disk.write(contentsOf: Data("guest-write".utf8))
        try disk.close()

        let repeated = try await installer.prepare(diskSizeGiB: 32, progress: { _ in })
        #expect(repeated == installation)
        #expect(try repeated.disk.resourceValues(forKeys: [.fileSizeKey]).fileSize == 16 * 1_073_741_824)
        let diskReader = try FileHandle(forReadingFrom: installation.disk)
        let guestData = try diskReader.read(upToCount: 11)
        try diskReader.close()
        #expect(guestData == Data("guest-write".utf8))
        #expect(try await installer.existing() == installation)
        #expect(try Data(contentsOf: fixture.templateURL.appending(path: "rootfs.raw")) == fixture.disk)
    }

    @Test func rejectsCorruptImageBeforePublishing() async throws {
        let fixture = try GuestFixture()
        defer { fixture.remove() }
        try fixture.writeTemplate()
        try Data("changed-kernel".utf8).write(to: fixture.templateURL.appending(path: "kernel"))
        await #expect(throws: GuestInstallationError.integrityFailure("kernel")) {
            try await fixture.installer.prepare(diskSizeGiB: 16, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.installationURL.path))
    }

    @Test(arguments: ["architecture", "kernelFile", "integrity"])
    func rejectsIncompatibleOrIncompleteMetadata(_ field: String) async throws {
        let fixture = try GuestFixture()
        defer { fixture.remove() }
        try fixture.writeTemplate()
        let metadataURL = fixture.templateURL.appending(path: "metadata.json")
        var metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        switch field {
        case "architecture": metadata[field] = "x86_64"
        case "kernelFile": metadata[field] = "../kernel"
        default: metadata.removeValue(forKey: field)
        }
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        await #expect(throws: GuestInstallationError.self) {
            try await fixture.installer.prepare(diskSizeGiB: 16, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.installationURL.path))
    }

    @Test func damagedInstalledDiskIsNeverReplacedWithTheTemplate() async throws {
        let fixture = try GuestFixture()
        defer { fixture.remove() }
        try fixture.writeTemplate()
        let installer = fixture.installer
        let installation = try await installer.prepare(diskSizeGiB: 16, progress: { _ in })
        let disk = try FileHandle(forWritingTo: installation.disk)
        try disk.truncate(atOffset: 4_096)
        try disk.close()
        await #expect(throws: GuestInstallationError.invalidFile("rootfs.raw")) {
            try await installer.prepare(diskSizeGiB: 16, progress: { _ in })
        }
        #expect(try installation.disk.resourceValues(forKeys: [.fileSizeKey]).fileSize == 4_096)
    }
}

private struct GuestFixture {
    let root: URL
    let kernel = Data("arm64-kernel-fixture".utf8)
    let initialRamdisk = Data("initial-ramdisk-fixture".utf8)
    let disk = Data(repeating: 0, count: 1_048_576)

    var templateURL: URL { root.appending(path: "template") }
    var installationURL: URL { root.appending(path: "managed/Guest") }
    var installer: GuestInstaller {
        GuestInstaller(templateURL: templateURL, installationURL: installationURL)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "OmaboxInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func writeTemplate() throws {
        try FileManager.default.createDirectory(at: templateURL, withIntermediateDirectories: true)
        var integrity: [String: [String: Any]] = [:]
        for (name, contents) in ["kernel": kernel, "initramfs": initialRamdisk, "rootfs.raw": disk] {
            try contents.write(to: templateURL.appending(path: name))
            integrity[name] = [
                "byteCount": contents.count,
                "sha256": SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined(),
            ]
        }
        let metadata: [String: Any] = [
            "schemaVersion": 1,
            "architecture": "aarch64",
            "kernelFile": "kernel",
            "initramfsFile": "initramfs",
            "diskFile": "rootfs.raw",
            "commandLine": "root=/dev/vda rw rootwait console=hvc0",
            "integrity": integrity,
        ]
        try JSONSerialization.data(withJSONObject: metadata).write(to: templateURL.appending(path: "metadata.json"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
