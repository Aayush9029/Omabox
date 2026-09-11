import CustomDump
import Foundation
import Testing
@testable import Omabox

struct CoreRunLockTests {
    @Test func anotherSessionCannotAcquireTheSameDiskUntilItsOwnerReleasesIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var firstOwner: VMRunLock? = try VMRunLock(directory: directory)
        withExtendedLifetime(firstOwner) {
            #expect(throws: VMConfigurationError.alreadyRunning) {
                try VMRunLock(directory: directory)
            }
        }
        firstOwner = nil
        let nextOwner = try VMRunLock(directory: directory)
        withExtendedLifetime(nextOwner) {
            #expect(throws: VMConfigurationError.alreadyRunning) {
                try VMRunLock(directory: directory)
            }
        }
    }

    @Test func independentInstallationsDoNotBlockEachOther() throws {
        let firstDirectory = try temporaryDirectory()
        let secondDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let firstOwner = try VMRunLock(directory: firstDirectory)
        let secondOwner = try VMRunLock(directory: secondDirectory)
        withExtendedLifetime((firstOwner, secondOwner)) {
            #expect(FileManager.default.fileExists(atPath: firstDirectory.appending(path: "run.lock").path))
            #expect(FileManager.default.fileExists(atPath: secondDirectory.appending(path: "run.lock").path))
        }
    }

    @Test func refusesToFollowASymbolicLinkInsteadOfLockingTheWrongFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "unrelated-file")
        try Data("leave this file alone".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "run.lock"), withDestinationURL: target)
        #expect(throws: POSIXError.self) {
            try VMRunLock(directory: directory)
        }
        expectNoDifference(try String(contentsOf: target, encoding: .utf8), "leave this file alone")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "OmaboxRunLockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
