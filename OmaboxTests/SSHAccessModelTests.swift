import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Synchronization
import Testing
@testable import Omabox

@Suite(.dependencies)
@MainActor
struct SSHAccessModelTests {
    @Test func waitsForTheOwnerBeforeInstallingAPinnedHostEntry() async {
        let clock = TestClock<Duration>()
        let installed = Mutex<[SSHEndpoint]>([])
        let receipt = managedFiles()
        let key = publicKey()
        let endpoint = endpoint()
        var requests: [SSHGuestRequest] = []
        let pending = response(state: "pendingOwner")
        let ready = response(state: "ready")
        let model = makeModel(clock: clock, files: SSHFilesClient(
            publicKeys: { _ in [key] },
            installConfiguration: { _, _, _, endpoint, _ in
                installed.withLock { $0.append(endpoint) }
                return receipt
            },
            removeConfiguration: { _, _ in }
        ))
        model.sessionChanged(session: SSHGuestSession {
            requests.append($0)
            return requests.count == 1 ? pending : ready
        }, isRunning: true)

        await settleUntil { model.phase == .pendingOwner }
        expectNoDifference(model.phase, .pendingOwner)
        expectNoDifference(installed.withLock { $0 }, [])
        #expect(model.connectionCommand == nil)

        await clock.advance(by: .seconds(5))
        await settleUntil { model.phase == .ready(endpoint) }
        expectNoDifference(model.phase, .ready(endpoint))
        expectNoDifference(requests, [.configure(publicKey: key.canonicalText), .status])
        expectNoDifference(installed.withLock { $0 }, [endpoint])
        expectNoDifference(model.preferences.sshManagedFiles, receipt)
        expectNoDifference(model.connectionCommand, "ssh -F '/selected/SSH folder/config' omabox")
        await finish(model)
    }

    @Test func reauthorizesAfterTheGuestServiceRestarts() async {
        let clock = TestClock<Duration>()
        let ready = response(state: "ready")
        let disabled = response(state: "disabled", enabled: false)
        let endpoint = endpoint()
        let key = publicKey()
        var requests: [SSHGuestRequest] = []
        let model = makeModel(clock: clock)
        model.sessionChanged(session: SSHGuestSession {
            requests.append($0)
            return requests.count == 2 ? disabled : ready
        }, isRunning: true)
        await settleUntil { model.phase == .ready(endpoint) }

        await clock.advance(by: .seconds(15))
        await settleUntil { requests.count == 2 && model.phase == .configuring }
        expectNoDifference(requests, [.configure(publicKey: key.canonicalText), .status])
        #expect(model.connectionCommand == nil)

        await clock.advance(by: .seconds(15))
        await settleUntil { requests.count == 3 && model.phase == .ready(endpoint) }
        expectNoDifference(requests, [.configure(publicKey: key.canonicalText), .status, .configure(publicKey: key.canonicalText)])
        expectNoDifference(model.phase, .ready(endpoint))
        await finish(model)
    }

    @Test func disablingWhilePausedRemovesTheHostEntryAndRevokesGuestAccessOnResume() async {
        let clock = TestClock<Duration>()
        let removed = Mutex<[SSHManagedFiles]>([])
        let receipt = managedFiles()
        let key = publicKey()
        let ready = response(state: "ready")
        let disabled = response(state: "disabled", enabled: false)
        var requests: [SSHGuestRequest] = []
        let model = makeModel(clock: clock, files: SSHFilesClient(
            publicKeys: { _ in [key] },
            installConfiguration: { _, _, _, _, _ in receipt },
            removeConfiguration: { _, record in removed.withLock { $0.append(record) } }
        ))
        let session = SSHGuestSession {
            requests.append($0)
            return $0.enabled == false ? disabled : ready
        }
        model.sessionChanged(session: session, isRunning: true)
        await settleUntil { model.phase.is(\.ready) }
        model.sessionChanged(session: session, isRunning: false)
        await settleUntil { model.phase == .waitingForDesktop }

        model.enabledChanged(false)
        await settleUntil { model.phase == .waitingForDesktop && model.preferences.sshManagedFiles == nil }
        expectNoDifference(removed.withLock { $0 }, [receipt])
        expectNoDifference(requests, [.configure(publicKey: key.canonicalText)])
        #expect(!model.isEnabled)
        #expect(model.preferences.sshNeedsDisable)
        #expect(model.connectionCommand == nil)

        model.sessionChanged(session: session, isRunning: true)
        await settleUntil { model.phase == .disabled }
        expectNoDifference(requests, [.configure(publicKey: key.canonicalText), .disable])
        expectNoDifference(model.phase, .disabled)
        #expect(!model.preferences.sshNeedsDisable)
        await finish(model)
    }

    @Test func disablingDuringAnInstallCleansTheCommittedFilesUsingTheirReceipt() async throws {
        let clock = TestClock<Duration>()
        let pendingInstall = Mutex<CheckedContinuation<SSHManagedFiles, any Error>?>(nil)
        let removed = Mutex<[SSHManagedFiles]>([])
        let receipt = managedFiles()
        let key = publicKey()
        let ready = response(state: "ready")
        let disabled = response(state: "disabled", enabled: false)
        var requests: [SSHGuestRequest] = []
        let model = makeModel(clock: clock, files: SSHFilesClient(
            publicKeys: { _ in [key] },
            installConfiguration: { _, _, _, _, _ in
                try await withCheckedThrowingContinuation { continuation in
                    pendingInstall.withLock { $0 = continuation }
                }
            },
            removeConfiguration: { _, record in removed.withLock { $0.append(record) } }
        ))
        model.sessionChanged(session: SSHGuestSession {
            requests.append($0)
            return $0.enabled == false ? disabled : ready
        }, isRunning: true)
        await settleUntil { pendingInstall.withLock { $0 != nil } }
        let completion = try #require(pendingInstall.withLock { $0 })

        model.enabledChanged(false)
        completion.resume(returning: receipt)
        await settleUntil { model.phase == .disabled }

        expectNoDifference(removed.withLock { $0 }, [receipt])
        expectNoDifference(requests, [.configure(publicKey: key.canonicalText), .disable])
        #expect(model.preferences.sshManagedFiles == nil)
        #expect(!model.preferences.sshNeedsDisable)
        expectNoDifference(model.phase, .disabled)
        await finish(model)
    }

    @Test func reenablingDuringRemovalDoesNotReuseTheRemovedFilesReceipt() async throws {
        let clock = TestClock<Duration>()
        let pendingRemoval = Mutex<CheckedContinuation<Void, any Error>?>(nil)
        let previousReceipts = Mutex<[SSHManagedFiles?]>([])
        let receipt = managedFiles()
        let key = publicKey()
        let ready = response(state: "ready")
        var initial = preferences()
        initial.sshEnabled = false
        initial.sshManagedFiles = receipt
        let model = makeModel(clock: clock, preferences: initial, files: SSHFilesClient(
            publicKeys: { _ in [key] },
            installConfiguration: { _, _, _, _, previous in
                previousReceipts.withLock { $0.append(previous) }
                return receipt
            },
            removeConfiguration: { _, _ in
                try await withCheckedThrowingContinuation { continuation in
                    pendingRemoval.withLock { $0 = continuation }
                }
            }
        ))
        model.sessionChanged(session: SSHGuestSession { _ in ready }, isRunning: true)
        await settleUntil { pendingRemoval.withLock { $0 != nil } }
        let completion = try #require(pendingRemoval.withLock { $0 })

        model.enabledChanged(true)
        completion.resume()
        await settleUntil { model.phase.is(\.ready) }

        expectNoDifference(previousReceipts.withLock { $0 }, [nil])
        expectNoDifference(model.preferences.sshManagedFiles, receipt)
        #expect(model.isEnabled)
        await finish(model)
    }

    @Test func olderGuestsFailAfterBoundedRetriesWithoutInstallingAHostEntry() async {
        let clock = TestClock<Duration>()
        var requests: [SSHGuestRequest] = []
        let model = makeModel(clock: clock)
        model.sessionChanged(session: SSHGuestSession {
            requests.append($0)
            throw SSHAccessError.unavailable
        }, isRunning: true)
        await settleUntil { requests.count == 1 }
        for expectedCount in 2...6 {
            await clock.advance(by: .seconds(2))
            await settleUntil { requests.count == expectedCount }
        }
        await settleUntil { model.phase.is(\.failed) }

        expectNoDifference(requests.count, 6)
        expectNoDifference(model.phase, .failed(SSHAccessError.unavailable.localizedDescription))
        #expect(model.preferences.sshManagedFiles == nil)
        #expect(model.connectionCommand == nil)
        await finish(model)
    }

    @Test func aResponseTimeoutDoesNotRepeatTheGuestConfigurationCommand() async {
        let clock = TestClock<Duration>()
        var requests: [SSHGuestRequest] = []
        let model = makeModel(clock: clock)
        model.sessionChanged(session: SSHGuestSession {
            requests.append($0)
            throw SSHAccessError.timedOut
        }, isRunning: true)
        await settleUntil { model.phase.is(\.failed) }

        expectNoDifference(requests, [.configure(publicKey: publicKey().canonicalText)])
        expectNoDifference(model.phase, .failed(SSHAccessError.timedOut.localizedDescription))
        #expect(model.preferences.sshManagedFiles == nil)
        await finish(model)
    }

    @Test(arguments: [false, true])
    func relaunchRetriesPendingFileCleanupBeforeLinuxStarts(_ cleanupFails: Bool) async {
        let clock = TestClock<Duration>()
        let removed = Mutex<[SSHManagedFiles]>([])
        let receipt = managedFiles()
        var initial = preferences()
        initial.sshEnabled = false
        initial.sshNeedsDisable = false
        initial.sshManagedFiles = receipt
        let model = makeModel(clock: clock, preferences: initial, files: SSHFilesClient(
            publicKeys: { _ in [] },
            installConfiguration: { _, _, _, _, _ in throw SSHAccessError.unavailable },
            removeConfiguration: { _, record in
                removed.withLock { $0.append(record) }
                if cleanupFails { throw SSHAccessError.folderUnavailable }
            }
        ))

        await model.task()
        model.sessionChanged(session: nil, isRunning: false)
        await settleUntil { model.phase != .configuring }

        expectNoDifference(removed.withLock { $0 }, [receipt])
        expectNoDifference(model.preferences.sshManagedFiles, cleanupFails ? receipt : nil)
        expectNoDifference(model.phase, cleanupFails ? .failed(SSHAccessError.folderUnavailable.localizedDescription) : .disabled)
        expectNoDifference(model.canChooseKey, !cleanupFails)
        #expect(!model.preferences.sshNeedsDisable)
        await finish(model)
    }

    @Test func quotesAnArbitrarySelectedFolderInTheCopyableCommand() async {
        let clock = TestClock<Duration>()
        let ready = response(state: "ready")
        var initial = preferences()
        initial.sshFolderPath = "/selected/O'Mac keys"
        initial.sshAlias = "my-linux"
        let model = makeModel(clock: clock, preferences: initial)
        model.sessionChanged(session: SSHGuestSession { _ in ready }, isRunning: true)
        await settleUntil { model.phase.is(\.ready) }

        expectNoDifference(model.connectionCommand, "ssh -F '/selected/O'\\''Mac keys/config' my-linux")
        await finish(model)
    }

    @Test func renewingFolderAccessKeepsTheReceiptUntilPendingCleanupCompletes() async throws {
        let clock = TestClock<Duration>()
        let pendingRemoval = Mutex<CheckedContinuation<Void, any Error>?>(nil)
        let stoppedAccess = Mutex<[URL]>([])
        let receipt = managedFiles()
        let folder = URL(filePath: "/selected/SSH folder")
        let renewedBookmark = Data([2])
        var initial = preferences()
        initial.sshEnabled = false
        initial.sshManagedFiles = receipt
        let model = makeModel(clock: clock, preferences: initial, files: SSHFilesClient(
            publicKeys: { _ in [] },
            installConfiguration: { _, _, _, _, _ in throw SSHAccessError.unavailable },
            removeConfiguration: { _, _ in
                try await withCheckedThrowingContinuation { continuation in
                    pendingRemoval.withLock { $0 = continuation }
                }
            }
        ), folders: SSHFolderClient(
            makeBookmark: { _ in renewedBookmark },
            resolve: { bookmark in
                guard bookmark == renewedBookmark else { throw SSHAccessError.folderUnavailable }
                return folder
            },
            stopAccessing: { folder in stoppedAccess.withLock { $0.append(folder) } }
        ))
        await model.task()
        await settleUntil { model.phase.is(\.failed) }
        expectNoDifference(model.phase, .failed(SSHAccessError.folderUnavailable.localizedDescription))
        #expect(model.canChooseFolder)
        #expect(!model.canChooseKey)

        await model.folderSelected(folder)
        await settleUntil { pendingRemoval.withLock { $0 != nil } }
        let completion = try #require(pendingRemoval.withLock { $0 })
        expectNoDifference(model.preferences.sshFolderBookmark, renewedBookmark)
        expectNoDifference(model.preferences.sshPublicKeyName, initial.sshPublicKeyName)
        expectNoDifference(model.preferences.sshManagedFiles, receipt)
        expectNoDifference(stoppedAccess.withLock { $0 }, [])

        completion.resume()
        await settleUntil { model.phase == .disabled }
        #expect(model.preferences.sshManagedFiles == nil)
        expectNoDifference(model.preferences.sshPublicKeyName, initial.sshPublicKeyName)
        expectNoDifference(stoppedAccess.withLock { $0 }, [folder])
        expectNoDifference(model.phase, .disabled)
        await finish(model)
    }

    @Test func recoveryCannotMoveTheOwnershipReceiptToADifferentFolder() async {
        let clock = TestClock<Duration>()
        let createdBookmarks = Mutex<[URL]>([])
        var initial = preferences()
        initial.sshEnabled = false
        initial.sshManagedFiles = managedFiles()
        let model = makeModel(clock: clock, preferences: initial, folders: SSHFolderClient(
            makeBookmark: { folder in
                createdBookmarks.withLock { $0.append(folder) }
                return Data([2])
            },
            resolve: { _ in throw SSHAccessError.folderUnavailable },
            stopAccessing: { _ in }
        ))
        await model.task()
        await settleUntil { model.phase.is(\.failed) }

        await model.folderSelected(URL(filePath: "/selected/another SSH folder"))

        expectNoDifference(model.preferences, initial)
        expectNoDifference(createdBookmarks.withLock { $0 }, [])
        expectNoDifference(model.phase, .failed(SSHAccessError.differentManagedFolder.localizedDescription))
        #expect(model.canChooseFolder)
        #expect(!model.canChooseKey)
        await finish(model)
    }

    @Test func noSSHWorkRunsUntilTheUserEnablesIt() async {
        let clock = TestClock<Duration>()
        let fileCalls = Mutex<[String]>([])
        var requests: [SSHGuestRequest] = []
        var initial = VMPreferences()
        initial.sshFolderBookmark = nil
        let model = makeModel(clock: clock, preferences: initial, files: SSHFilesClient(
            publicKeys: { _ in
                fileCalls.withLock { $0.append("read") }
                return []
            },
            installConfiguration: { _, _, _, _, _ in
                fileCalls.withLock { $0.append("install") }
                throw SSHAccessError.unavailable
            },
            removeConfiguration: { _, _ in fileCalls.withLock { $0.append("remove") } }
        ))
        model.sessionChanged(session: SSHGuestSession {
            requests.append($0)
            throw SSHAccessError.unavailable
        }, isRunning: true)
        await model.task()
        await finish(model)

        expectNoDifference(model.phase, .disabled)
        expectNoDifference(requests, [])
        expectNoDifference(fileCalls.withLock { $0 }, [])
    }

    private func makeModel(
        clock: TestClock<Duration>,
        preferences suppliedPreferences: VMPreferences? = nil,
        files suppliedFiles: SSHFilesClient? = nil,
        folders suppliedFolders: SSHFolderClient? = nil
    ) -> SSHAccessModel {
        let key = publicKey()
        let receipt = managedFiles()
        let preferences = suppliedPreferences ?? preferences()
        let folder = URL(filePath: preferences.sshFolderPath ?? "/selected/SSH folder")
        let files = suppliedFiles ?? SSHFilesClient(
            publicKeys: { _ in [key] },
            installConfiguration: { _, _, _, _, _ in receipt },
            removeConfiguration: { _, _ in }
        )
        return withDependencies {
            $0.continuousClock = clock
            $0.sshFilesClient = files
            $0.sshFolderClient = suppliedFolders ?? SSHFolderClient(resolve: { _ in folder }, stopAccessing: { _ in })
        } operation: {
            SSHAccessModel(preferences: Shared(value: preferences))
        }
    }

    private func preferences() -> VMPreferences {
        var preferences = VMPreferences()
        preferences.sshEnabled = true
        preferences.sshFolderBookmark = Data([1])
        preferences.sshFolderPath = "/selected/SSH folder"
        preferences.sshPublicKeyName = publicKey().fileName
        return preferences
    }

    private func publicKey() -> SSHPublicKey {
        SSHPublicKey(fileName: "test_ed25519.pub", canonicalText: "ssh-ed25519 disposable-public-fixture", fingerprint: "SHA256:fixture")
    }

    private func endpoint() -> SSHEndpoint {
        SSHEndpoint(user: "linuxuser", address: "192.168.64.2", port: 2_222, hostPublicKey: "ssh-ed25519 guest-host-fixture")
    }

    private func response(state: String, enabled: Bool = true) -> SSHGuestResponse {
        let endpoint = endpoint()
        return SSHGuestResponse(
            type: "sshConfigured", version: 1, enabled: enabled, state: state,
            user: state == "ready" ? endpoint.user : nil,
            address: state == "ready" ? endpoint.address : nil,
            port: 2_222, hostPublicKey: state == "ready" ? endpoint.hostPublicKey : nil
        )
    }

    private func managedFiles() -> SSHManagedFiles {
        SSHManagedFiles(
            alias: "omabox", includeFileName: "omabox.conf", includeSHA256: "include-digest",
            knownHostsFileName: "omabox_known_hosts", knownHostsSHA256: "host-digest",
            configurationPrefix: "Include /selected/omabox.conf\n", configurationPrefixSHA256: "prefix-digest",
            configurationWasCreated: false
        )
    }

    private func settleUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
    }

    private func finish(_ model: SSHAccessModel) async {
        model.sessionChanged(session: nil, isRunning: false)
        await settleUntil { model.phase != .configuring }
    }
}
