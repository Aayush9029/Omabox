import AppKit
import Dependencies
import Foundation
import IdentifiedCollections
import Observation
import Sharing
import Virtualization

@MainActor
@Observable
final class SSHAccessModel {
    @ObservationIgnored @Shared(.omaboxPreferences) var preferences
    @ObservationIgnored @Dependency(\.sshFilesClient) private var files
    @ObservationIgnored @Dependency(\.sshGuestClient) private var guest
    @ObservationIgnored @Dependency(\.sshFolderClient) private var folders
    @ObservationIgnored @Dependency(\.continuousClock) private var clock

    private(set) var phase: SSHAccessPhase = .disabled
    private(set) var publicKeys: IdentifiedArrayOf<SSHPublicKey> = []
    var draftAlias = "omabox"

    @ObservationIgnored private var machine: VZVirtualMachine?
    @ObservationIgnored private var session: SSHGuestSession?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reconciliation: Task<Void, Never>?
    @ObservationIgnored private var didLoad = false

    var isEnabled: Bool { preferences.sshEnabled }
    var folderPath: String? { preferences.sshFolderPath }
    var selectedKeyName: String? { preferences.sshPublicKeyName }
    var canChooseFolder: Bool { !isEnabled && phase != .configuring }
    var canChooseKey: Bool { !isEnabled && preferences.sshManagedFiles == nil && phase != .configuring }
    var canEnable: Bool { folderPath != nil && selectedKeyName != nil && SSHFilesClient.isValidAlias(draftAlias) }
    var connectionCommand: String? {
        guard case .ready = phase, let folderPath else { return nil }
        let defaultFolder = Self.userHome.appending(path: ".ssh").standardizedFileURL.path
        if URL(filePath: folderPath).standardizedFileURL.path == defaultFolder {
            return "ssh \(preferences.sshAlias)"
        }
        let configPath = URL(filePath: folderPath).appending(path: "config").path
        return "ssh -F \(Self.shellQuoted(configPath)) \(preferences.sshAlias)"
    }

    init(preferences: Shared<VMPreferences>? = nil) {
        if let preferences { _preferences = preferences }
        draftAlias = self.preferences.sshAlias
        phase = self.preferences.sshEnabled || self.preferences.sshNeedsDisable || self.preferences.sshManagedFiles != nil ? .waitingForDesktop : .disabled
    }

    func task() async {
        guard !didLoad else { return }
        didLoad = true
        if preferences.sshEnabled || preferences.sshNeedsDisable || preferences.sshManagedFiles != nil {
            restartReconciliation()
            return
        }
        guard preferences.sshFolderBookmark != nil else { return }
        do { publicKeys = try await readPublicKeys() }
        catch { phase = .failed(error.localizedDescription) }
    }

    func chooseFolderButtonTapped() async {
        guard canChooseFolder else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose your SSH folder"
        panel.message = "Omabox reads public keys ending in .pub. Private keys stay on your Mac."
        panel.prompt = "Use SSH Folder"
        panel.directoryURL = folderPath.map { URL(filePath: $0) } ?? Self.userHome.appending(path: ".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await folderSelected(url)
    }

    func folderSelected(_ url: URL) async {
        guard canChooseFolder else { return }
        do {
            let hasManagedFiles = preferences.sshManagedFiles != nil
            if hasManagedFiles {
                guard let folderPath,
                      url.standardizedFileURL.path == URL(filePath: folderPath).standardizedFileURL.path else {
                    throw SSHAccessError.differentManagedFolder
                }
            }
            let bookmark = try folders.makeBookmark(url)
            $preferences.withLock {
                $0.sshFolderBookmark = bookmark
                $0.sshFolderPath = url.path
                if !hasManagedFiles { $0.sshPublicKeyName = nil }
            }
            if hasManagedFiles || preferences.sshNeedsDisable {
                restartReconciliation()
                return
            }
            publicKeys = []
            publicKeys = try await readPublicKeys()
            if publicKeys.count == 1 {
                $preferences.sshPublicKeyName.withLock { $0 = publicKeys.first?.fileName }
            }
            phase = .disabled
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func publicKeySelected(_ name: String?) {
        guard canChooseKey else { return }
        $preferences.sshPublicKeyName.withLock { $0 = name }
    }

    func enabledChanged(_ enabled: Bool) {
        if enabled {
            guard canEnable else {
                phase = .failed(SSHAccessError.keyUnavailable.localizedDescription)
                return
            }
            $preferences.withLock {
                $0.sshEnabled = true
                $0.sshNeedsDisable = false
                $0.sshAlias = draftAlias
            }
        } else {
            $preferences.withLock {
                $0.sshNeedsDisable = $0.sshNeedsDisable || $0.sshEnabled
                $0.sshEnabled = false
            }
        }
        restartReconciliation()
    }

    func applyAliasButtonTapped() {
        guard SSHFilesClient.isValidAlias(draftAlias) else {
            phase = .failed("Use a host alias containing letters, numbers, periods, underscores, or hyphens.")
            return
        }
        $preferences.sshAlias.withLock { $0 = draftAlias }
        if isEnabled { restartReconciliation() }
    }

    func refreshButtonTapped() {
        restartReconciliation()
    }

    func copyCommandButtonTapped() {
        guard let connectionCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(connectionCommand, forType: .string)
    }

    func sessionChanged(machine: VZVirtualMachine?, isRunning: Bool) {
        guard self.machine !== machine || self.isRunning != isRunning else { return }
        self.machine = machine
        let session = machine.map { machine in
            SSHGuestSession(request: { [guest] request in try await guest.request(machine, request) })
        }
        sessionChanged(session: session, isRunning: isRunning)
    }

    func sessionChanged(session: SSHGuestSession?, isRunning: Bool) {
        guard self.session?.id != session?.id || self.isRunning != isRunning else { return }
        self.session = session
        self.isRunning = isRunning
        restartReconciliation()
    }

    private func restartReconciliation() {
        generation += 1
        let currentGeneration = generation
        let previous = reconciliation
        previous?.cancel()
        phase = preferences.sshEnabled || preferences.sshNeedsDisable || preferences.sshManagedFiles != nil ? .configuring : .disabled
        reconciliation = Task { [weak self] in
            await previous?.value
            guard let self, currentGeneration == generation, !Task.isCancelled else { return }
            await reconcile(generation: currentGeneration)
        }
    }

    private func reconcile(generation currentGeneration: Int) async {
        do {
            guard preferences.sshEnabled else {
                await disableAccess(generation: currentGeneration)
                return
            }
            let keys = try await readPublicKeys()
            guard currentGeneration == generation, !Task.isCancelled else { return }
            publicKeys = keys
            guard let key = keys.first(where: { $0.fileName == preferences.sshPublicKeyName }) else {
                throw SSHAccessError.keyUnavailable
            }
            guard let session, isRunning else {
                phase = .waitingForDesktop
                return
            }
            var configured = false
            var lastEndpoint: SSHEndpoint?
            while currentGeneration == generation, preferences.sshEnabled, isRunning {
                let request = configured ? SSHGuestRequest.status : .configure(publicKey: key.canonicalText)
                let response = try await requestWithRetry(session: session, request: request)
                guard currentGeneration == generation, !Task.isCancelled else { return }
                configured = response.enabled == true
                switch response.state {
                case "ready":
                    guard let user = response.user, let address = response.address,
                          let hostPublicKey = response.hostPublicKey else { throw SSHAccessError.invalidResponse }
                    let endpoint = SSHEndpoint(user: user, address: address, port: 2_222, hostPublicKey: hostPublicKey)
                    if endpoint != lastEndpoint || preferences.sshManagedFiles?.alias != preferences.sshAlias {
                        try await installHostEntry(key: key, endpoint: endpoint)
                    }
                    guard currentGeneration == generation, !Task.isCancelled else { return }
                    lastEndpoint = endpoint
                    phase = .ready(endpoint)
                case "pendingOwner":
                    phase = .pendingOwner
                case "pendingNetwork":
                    phase = .pendingNetwork
                case "disabled":
                    phase = .configuring
                default:
                    throw SSHAccessError.invalidResponse
                }
                try await clock.sleep(for: .seconds(lastEndpoint == nil ? 5 : 15))
            }
        } catch is CancellationError {
        } catch {
            if currentGeneration == generation { phase = .failed(error.localizedDescription) }
        }
    }

    private func disableAccess(generation currentGeneration: Int) async {
        var cleanupError: String?
        if let managed = preferences.sshManagedFiles {
            do {
                let folder = try scopedFolder()
                defer { folders.stopAccessing(folder) }
                try await files.removeConfiguration(folder, managed)
                $preferences.sshManagedFiles.withLock { $0 = nil }
                try await $preferences.save()
            } catch is CancellationError {
                return
            } catch {
                cleanupError = error.localizedDescription
            }
        }
        guard currentGeneration == generation, !Task.isCancelled else { return }
        if preferences.sshNeedsDisable {
            guard let session, isRunning else {
                phase = cleanupError.map(SSHAccessPhase.failed) ?? .waitingForDesktop
                return
            }
            do {
                let response = try await requestWithRetry(session: session, request: .disable)
                guard currentGeneration == generation, !Task.isCancelled else { return }
                guard response.enabled == false else { throw SSHAccessError.invalidResponse }
                $preferences.sshNeedsDisable.withLock { $0 = false }
            } catch is CancellationError {
                return
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
        }
        phase = cleanupError.map(SSHAccessPhase.failed) ?? .disabled
    }

    private func requestWithRetry(session: SSHGuestSession, request: SSHGuestRequest) async throws -> SSHGuestResponse {
        for attempt in 0..<6 {
            try Task.checkCancellation()
            do { return try await session.request(request).validated() }
            catch is CancellationError { throw CancellationError() }
            catch SSHAccessError.unavailable {
                if attempt == 5 { throw SSHAccessError.unavailable }
                try await clock.sleep(for: .seconds(2))
            }
        }
        throw SSHAccessError.unavailable
    }

    private func readPublicKeys() async throws -> IdentifiedArrayOf<SSHPublicKey> {
        let folder = try scopedFolder()
        defer { folders.stopAccessing(folder) }
        return try await files.publicKeys(folder)
    }

    private func installHostEntry(key: SSHPublicKey, endpoint: SSHEndpoint) async throws {
        let folder = try scopedFolder()
        defer { folders.stopAccessing(folder) }
        let record = try await files.installConfiguration(folder, key, preferences.sshAlias, endpoint, preferences.sshManagedFiles)
        $preferences.sshManagedFiles.withLock { $0 = record }
        try await $preferences.save()
    }

    private func scopedFolder() throws -> URL {
        guard let bookmark = preferences.sshFolderBookmark else { throw SSHAccessError.folderUnavailable }
        return try folders.resolve(bookmark)
    }

    private static var userHome: URL {
        URL(filePath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory(), directoryHint: .isDirectory)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
