import CryptoKit
import Darwin
import Dependencies
import Foundation

nonisolated struct InstallerClient: Sendable {
    var existing: @Sendable () async throws -> GuestInstallation?
    var prepare: @Sendable (Int, @escaping @Sendable (Double) -> Void) async throws -> GuestInstallation
}

extension InstallerClient: DependencyKey {
    static var liveValue: Self {
        if AppEnvironment.isUITesting {
            return testValue
        }
        let store = GuestInstaller(
            templateURL: Bundle.main.resourceURL?.appending(path: "Guest", directoryHint: .isDirectory),
            installationURL: URL.applicationSupportDirectory
                .appending(path: "Omabox/Guest", directoryHint: .isDirectory)
        )
        return Self(
            existing: { try await store.existing() },
            prepare: { size, progress in try await store.prepare(diskSizeGiB: size, progress: progress) }
        )
    }

    static var testValue: Self {
        Self(existing: { nil }, prepare: { _, _ in throw GuestInstallationError.templateUnavailable })
    }
}

extension DependencyValues {
    var installerClient: InstallerClient {
        get { self[InstallerClient.self] }
        set { self[InstallerClient.self] = newValue }
    }
}

actor GuestInstaller {
    private let templateURL: URL?
    private let installationURL: URL
    private let fileManager = FileManager.default

    init(templateURL: URL?, installationURL: URL) {
        self.templateURL = templateURL
        self.installationURL = installationURL
    }

    func existing() throws -> GuestInstallation? {
        guard fileManager.fileExists(atPath: installationURL.path) else { return nil }
        let metadata = try readMetadata(in: installationURL)
        guard let diskMinimumBytes = metadata.installedDiskMinimumBytes, diskMinimumBytes > 0 else {
            throw GuestInstallationError.invalidMetadata
        }
        try validateFiles(in: installationURL, metadata: metadata, isTemplate: false)
        return metadata.installation(in: installationURL)
    }

    func prepare(diskSizeGiB: Int, progress: @Sendable (Double) -> Void) throws -> GuestInstallation {
        try Task.checkCancellation()
        if let existing = try existing() {
            progress(1)
            return existing
        }
        guard (16...1_024).contains(diskSizeGiB) else {
            throw GuestInstallationError.invalidDiskSize
        }
        guard let templateURL,
              fileManager.fileExists(atPath: templateURL.appending(path: "metadata.json").path) else {
            throw GuestInstallationError.templateUnavailable
        }
        progress(0)
        var metadata = try readMetadata(in: templateURL)
        try validateFiles(in: templateURL, metadata: metadata, isTemplate: true)
        progress(0.1)

        let parentURL = installationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let stagingURL = parentURL.appending(path: ".guest-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stagingURL) }

        let files = metadata.fileNames
        let totalBytes = try files.reduce(Int64(0)) { total, name in
            total + (try fileSize(templateURL.appending(path: name)))
        }
        var completedBytes: Int64 = 0
        for name in files {
            try Task.checkCancellation()
            let source = templateURL.appending(path: name)
            let destination = stagingURL.appending(path: name)
            let size = try fileSize(source)
            let previousBytes = completedBytes
            try copySparseFile(from: source, to: destination) { copied in
                progress(0.1 + 0.8 * Double(previousBytes + copied) / Double(totalBytes))
            }
            guard try fileSize(destination) == size else {
                throw GuestInstallationError.invalidFile(name)
            }
            completedBytes += size
        }

        let diskURL = stagingURL.appending(path: metadata.diskFile)
        let requestedBytes = Int64(diskSizeGiB) * 1_073_741_824
        let diskBytes = max(requestedBytes, try fileSize(diskURL))
        let diskHandle = try FileHandle(forWritingTo: diskURL)
        do {
            try diskHandle.truncate(atOffset: UInt64(diskBytes))
            try diskHandle.synchronize()
            try diskHandle.close()
        } catch {
            try? diskHandle.close()
            throw error
        }
        metadata.installedDiskMinimumBytes = diskBytes
        let metadataData = try JSONEncoder().encode(metadata)
        try metadataData.write(to: stagingURL.appending(path: "metadata.json"), options: .atomic)
        try validateFiles(in: stagingURL, metadata: metadata, isTemplate: false)
        try Task.checkCancellation()
        try fileManager.moveItem(at: stagingURL, to: installationURL)
        progress(1)
        return metadata.installation(in: installationURL)
    }

    private func readMetadata(in directory: URL) throws -> GuestMetadata {
        let metadataURL = directory.appending(path: "metadata.json")
        guard try fileSize(metadataURL) <= 1_048_576 else {
            throw GuestInstallationError.invalidMetadata
        }
        let metadata: GuestMetadata
        do {
            metadata = try JSONDecoder().decode(GuestMetadata.self, from: Data(contentsOf: metadataURL))
        } catch {
            throw GuestInstallationError.invalidMetadata
        }
        guard metadata.schemaVersion == 1,
              metadata.architecture == "aarch64",
              metadata.kernelFile == "kernel",
              metadata.initramfsFile == "initramfs",
              metadata.diskFile == "rootfs.raw",
              !metadata.commandLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !metadata.commandLine.contains("\0") else {
            throw GuestInstallationError.invalidMetadata
        }
        return metadata
    }

    private func validateFiles(in directory: URL, metadata: GuestMetadata, isTemplate: Bool) throws {
        for name in metadata.fileNames {
            try Task.checkCancellation()
            let url = directory.appending(path: name)
            let size = try fileSize(url)
            let isInstalledDisk = !isTemplate && name == metadata.diskFile
            if isInstalledDisk {
                if let minimumBytes = metadata.installedDiskMinimumBytes,
                   minimumBytes <= 0 || size < minimumBytes {
                    throw GuestInstallationError.invalidFile(name)
                }
                continue
            }
            if isTemplate && metadata.integrity?[name] == nil {
                throw GuestInstallationError.integrityFailure(name)
            }
            if let integrity = metadata.integrity?[name] {
                guard integrity.byteCount > 0,
                      integrity.byteCount == size,
                      integrity.sha256.count == 64,
                      integrity.sha256.allSatisfy({ $0.isHexDigit }),
                      try sha256(of: url) == integrity.sha256.lowercased() else {
                    throw GuestInstallationError.integrityFailure(name)
                }
            }
        }
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0 else {
            throw GuestInstallationError.invalidFile(url.lastPathComponent)
        }
        return Int64(size)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func copySparseFile(from source: URL, to destination: URL, progress: (Int64) -> Void) throws {
        let size = try fileSize(source)
        let cloneResult = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                clonefile(sourcePath, destinationPath, 0)
            }
        }
        if cloneResult == 0 {
            progress(size)
            return
        }
        let sourceValues = try source.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        let volumeValues = try destination.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = volumeValues.volumeAvailableCapacityForImportantUsage {
            let requiredBytes = Int64(sourceValues.totalFileAllocatedSize ?? Int(size)) + 67_108_864
            guard available >= requiredBytes else {
                throw GuestInstallationError.insufficientStorage
            }
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw GuestInstallationError.copyFailed
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied: Int64 = 0
        while let data = try input.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            copied += Int64(data.count)
            if data.allSatisfy({ $0 == 0 }) {
                try output.seek(toOffset: UInt64(copied))
            } else {
                try output.write(contentsOf: data)
            }
            progress(copied)
        }
        try output.truncate(atOffset: UInt64(copied))
        try output.synchronize()
    }
}

nonisolated private struct GuestMetadata: Codable {
    var schemaVersion: Int
    var architecture: String
    var kernelFile: String
    var initramfsFile: String
    var diskFile: String
    var commandLine: String
    var integrity: [String: GuestFileIntegrity]?
    var installedDiskMinimumBytes: Int64?

    var fileNames: [String] { [kernelFile, initramfsFile, diskFile] }

    func installation(in directory: URL) -> GuestInstallation {
        GuestInstallation(
            directory: directory,
            kernel: directory.appending(path: kernelFile),
            initialRamdisk: directory.appending(path: initramfsFile),
            disk: directory.appending(path: diskFile),
            commandLine: commandLine
        )
    }
}

nonisolated private struct GuestFileIntegrity: Codable {
    var byteCount: Int64
    var sha256: String
}

nonisolated enum GuestInstallationError: LocalizedError, Equatable {
    case templateUnavailable
    case invalidMetadata
    case invalidFile(String)
    case integrityFailure(String)
    case invalidDiskSize
    case copyFailed
    case insufficientStorage

    var errorDescription: String? {
        switch self {
        case .templateUnavailable:
            "This build does not include a Linux guest image. Run Scripts/prepare-guest.sh to prepare the ARM64 guest assets, then rebuild Omabox."
        case .invalidMetadata:
            "The Linux guest metadata is invalid or uses an unsupported format. Prepare matching ARM64 assets with Scripts/prepare-guest.sh. Your existing disk has not been replaced."
        case let .invalidFile(name):
            "The Linux guest file \(name) is missing, empty, or damaged. Your existing disk has not been replaced."
        case let .integrityFailure(name):
            "The Linux guest file \(name) failed its size or SHA-256 verification. Prepare the guest assets again with Scripts/prepare-guest.sh."
        case .invalidDiskSize:
            "Choose a disk between 16 and 1,024 GB."
        case .copyFailed:
            "Omabox could not create the Linux disk. Check available storage and try again."
        case .insufficientStorage:
            "There is not enough free storage to copy the Linux image. Free up space on your Mac and try again."
        }
    }
}
