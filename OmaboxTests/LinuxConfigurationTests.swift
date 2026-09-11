import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing
@testable import Omabox

@Suite(.dependencies)
@MainActor
struct LinuxConfigurationTests {
    @Test func createsEmptyPrivateConfigurationFilesInAPrivateFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "LinuxConfiguration", directoryHint: .isDirectory)

        let prepared = try LinuxConfigurationFiles.prepareDirectory(at: folder)

        expectNoDifference(prepared, folder)
        expectNoDifference(try permissions(at: folder), 0o700)
        expectNoDifference(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["desktop.env", "hyprland.lua"])
        for name in ["desktop.env", "hyprland.lua"] {
            let file = folder.appending(path: name)
            expectNoDifference(try Data(contentsOf: file), Data())
            expectNoDifference(try permissions(at: file), 0o600)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            #expect(values.isRegularFile == true)
            #expect(values.isSymbolicLink != true)
        }
    }

    @Test func repeatedPreparationPreservesUserBytesPermissionsAndFileIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "LinuxConfiguration", directoryHint: .isDirectory)
        _ = try LinuxConfigurationFiles.prepareDirectory(at: folder)
        let environment = folder.appending(path: "desktop.env")
        let desktop = folder.appending(path: "hyprland.lua")
        let environmentBytes = Data("EDITOR=nvim\nLANG=fr_CA.UTF-8\nCUSTOM='café ☕'\n".utf8)
        let desktopBytes = Data("-- My desktop\nlocal gap = 12\n".utf8) + Data([0, 0xFF, 0x0A])
        try write(environmentBytes, to: environment, permissions: 0o640)
        try write(desktopBytes, to: desktop, permissions: 0o644)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: folder.path)
        let environmentIdentity = try fileIdentity(at: environment)
        let desktopIdentity = try fileIdentity(at: desktop)

        _ = try LinuxConfigurationFiles.prepareDirectory(at: folder)
        _ = try LinuxConfigurationFiles.prepareDirectory(at: folder)

        expectNoDifference(try Data(contentsOf: environment), environmentBytes)
        expectNoDifference(try Data(contentsOf: desktop), desktopBytes)
        expectNoDifference(try permissions(at: environment), 0o640)
        expectNoDifference(try permissions(at: desktop), 0o644)
        expectNoDifference(try permissions(at: folder), 0o750)
        expectNoDifference(try fileIdentity(at: environment), environmentIdentity)
        expectNoDifference(try fileIdentity(at: desktop), desktopIdentity)
    }

    @Test(arguments: LinuxConfigurationFile.allCases)
    func createsTheMissingSiblingWithoutOverwritingAPreexistingFile(_ existing: LinuxConfigurationFile) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existingURL = root.appending(path: existing.fileName)
        let bytes = Data("Custom configuration before Omabox first opened this folder.\n".utf8)
        try write(bytes, to: existingURL, permissions: 0o400)
        let identity = try fileIdentity(at: existingURL)

        _ = try LinuxConfigurationFiles.prepareDirectory(at: root)

        expectNoDifference(try Data(contentsOf: existingURL), bytes)
        expectNoDifference(try permissions(at: existingURL), 0o400)
        expectNoDifference(try fileIdentity(at: existingURL), identity)
        let missing: LinuxConfigurationFile = existing == .environment ? .desktop : .environment
        let createdURL = root.appending(path: missing.fileName)
        expectNoDifference(try Data(contentsOf: createdURL), Data())
        expectNoDifference(try permissions(at: createdURL), 0o600)
    }

    @Test(arguments: [false, true])
    func rejectsALinkedConfigurationFolderWithoutChangingItsTarget(_ targetExists: Bool) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "unrelated", directoryHint: .isDirectory)
        let marker = target.appending(path: "keep.txt")
        let bytes = Data("Keep this unrelated folder intact.\n".utf8)
        if targetExists {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o750])
            try write(bytes, to: marker, permissions: 0o640)
        }
        let link = root.appending(path: "LinuxConfiguration")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: (any Error).self) {
            _ = try LinuxConfigurationFiles.prepareDirectory(at: link)
        }

        expectNoDifference(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        if targetExists {
            expectNoDifference(try FileManager.default.contentsOfDirectory(atPath: target.path), ["keep.txt"])
            expectNoDifference(try Data(contentsOf: marker), bytes)
            expectNoDifference(try permissions(at: marker), 0o640)
            expectNoDifference(try permissions(at: target), 0o750)
        } else {
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test(arguments: LinuxConfigurationFile.allCases, [false, true])
    func rejectsLinkedFilesWithoutWritingThroughExistingOrDanglingLinks(_ file: LinuxConfigurationFile, _ targetExists: Bool) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "LinuxConfiguration", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let target = root.appending(path: "unrelated.txt")
        let bytes = Data("This file is not an Omabox configuration file.\n".utf8)
        if targetExists { try write(bytes, to: target, permissions: 0o640) }
        let link = folder.appending(path: file.fileName)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: LinuxConfigurationError.self) {
            _ = try LinuxConfigurationFiles.prepareDirectory(at: folder)
        }

        expectNoDifference(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        if targetExists {
            expectNoDifference(try Data(contentsOf: target), bytes)
            expectNoDifference(try permissions(at: target), 0o640)
        } else {
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test(arguments: LinuxConfigurationFile.allCases)
    func rejectsAFolderAtAConfigurationFilePathWithoutRemovingItsContents(_ file: LinuxConfigurationFile) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidFile = root.appending(path: file.fileName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: invalidFile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o750])
        let marker = invalidFile.appending(path: "keep.txt")
        let bytes = Data("Keep this folder and its contents.\n".utf8)
        try write(bytes, to: marker, permissions: 0o640)

        #expect(throws: LinuxConfigurationError.self) {
            _ = try LinuxConfigurationFiles.prepareDirectory(at: root)
        }

        expectNoDifference(try FileManager.default.contentsOfDirectory(atPath: invalidFile.path), ["keep.txt"])
        expectNoDifference(try permissions(at: invalidFile), 0o750)
        expectNoDifference(try Data(contentsOf: marker), bytes)
        expectNoDifference(try permissions(at: marker), 0o640)
    }

    @Test(arguments: LinuxConfigurationFile.allCases)
    func dispatchesOnlyTheSelectedFileWithoutStartingLinuxOrChangingPreferences(_ file: LinuxConfigurationFile) async {
        var opened: [LinuxConfigurationFile] = []
        let preferences = VMPreferences()
        let model = withDependencies {
            $0.linuxConfigurationClient = LinuxConfigurationClient(open: { opened.append($0) })
        } operation: {
            OmaboxModel(preferences: Shared(value: preferences))
        }

        await expectDifference(opened) {
            await model.openLinuxConfigurationFile(file)
        } changes: {
            $0 = [file]
        }

        #expect(model.errorMessage == nil)
        expectNoDifference(model.preferences, preferences)
        expectIdleModel(model)
    }

    @Test(arguments: [LinuxConfigurationError.invalidFolder, .invalidFile("hyprland.lua"), .editorUnavailable])
    func surfacesConfigurationClientFailuresWithoutChangingTheVMLifecycle(_ error: LinuxConfigurationError) async {
        var opened: [LinuxConfigurationFile] = []
        let preferences = VMPreferences()
        let model = withDependencies {
            $0.linuxConfigurationClient = LinuxConfigurationClient(open: {
                opened.append($0)
                throw error
            })
        } operation: {
            OmaboxModel(preferences: Shared(value: preferences))
        }

        await expectDifference(model.errorMessage) {
            await model.openLinuxConfigurationFile(.desktop)
        } changes: {
            $0 = error.localizedDescription
        }

        expectNoDifference(opened, [.desktop])
        expectNoDifference(model.preferences, preferences)
        expectIdleModel(model)
    }

    private func temporaryDirectory() throws -> URL {
        let root = URL.temporaryDirectory.appending(path: "OmaboxLinuxConfigurationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func write(_ bytes: Data, to url: URL, permissions: Int) throws {
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func permissions(at url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func fileIdentity(at url: URL) throws -> UInt64 {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber).uint64Value
    }

    private func expectIdleModel(_ model: OmaboxModel) {
        expectNoDifference(model.state, .absent)
        #expect(model.virtualMachine == nil)
        #expect(model.installationURL == nil)
        #expect(model.progress == nil)
        #expect(!model.supportsSaveRestore)
        #expect(!model.isChangingRunState)
        #expect(!model.isBusy)
        expectNoDifference(model.ssh.phase, .disabled)
    }
}
