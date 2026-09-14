import AppKit
import Dependencies
import Foundation
import Observation
import Sharing
import Virtualization

@MainActor
@Observable
final class OmaboxModel {
    @ObservationIgnored @Shared(.omaboxPreferences) var preferences
    @ObservationIgnored @Dependency(\.installerClient) private var installer
    @ObservationIgnored @Dependency(\.virtualMachineClient) private var virtualMachineClient
    @ObservationIgnored @Dependency(\.microphoneClient) private var microphone
    @ObservationIgnored @Dependency(\.continuousClock) private var clock
    @ObservationIgnored @Dependency(\.linuxConfigurationClient) private var linuxConfiguration

    private(set) var state: VMState = .absent {
        didSet { updateSSHSession() }
    }
    private(set) var progress: Double?
    var errorMessage: String?
    private(set) var virtualMachine: VZVirtualMachine? {
        didSet { updateSSHSession() }
    }
    private(set) var installationURL: URL?
    private(set) var supportsSaveRestore = false
    let ssh: SSHAccessModel

    @ObservationIgnored private var installation: GuestInstallation?
    @ObservationIgnored private var runtime: (any VirtualMachineRuntime)?
    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var installGeneration = 0
    @ObservationIgnored private var runtimeGeneration = 0
    private(set) var isChangingRunState = false {
        didSet { updateSSHSession() }
    }

    var sharedFolderName: String? { preferences.sharedFolderName }
    var isRunning: Bool { state.isRunning }
    var isBusy: Bool { state.isBusy || isChangingRunState }
    var resourcePolicy: VMResourcePolicy { virtualMachineClient.resourcePolicy() }

    func openLinuxConfigurationFile(_ file: LinuxConfigurationFile) async {
        do {
            try await linuxConfiguration.open(file)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    init(preferences: Shared<VMPreferences>? = nil) {
        ssh = SSHAccessModel(preferences: preferences)
        if let preferences { _preferences = preferences }
    }

    func task() async {
        guard !didLoad else { return }
        didLoad = true
        await ssh.task()
        do {
            if let existing = try await installer.existing() {
                installation = existing
                installationURL = existing.directory
                state = .ready
                if preferences.startsOnLaunch, !AppEnvironment.isUITesting {
                    await startButtonTapped()
                }
            }
        } catch {
            fail(error)
        }
    }

    /// The one button on the home screen: prepares the disk when there is none, then starts.
    func setUpOrStartButtonTapped() async {
        setupTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            if installationURL == nil {
                await prepareButtonTapped()
            }
            guard !Task.isCancelled, installationURL != nil else { return }
            await startButtonTapped()
        }
        setupTask = task
        await task.value
    }

    func cancelSetupButtonTapped() {
        setupTask?.cancel()
    }

    func prepareButtonTapped() async {
        guard !isBusy, !state.hasActiveSession else { return }
        errorMessage = nil
        do {
            try resourcePolicy.validate(preferences)
            state = .preparing
            progress = 0
            installGeneration += 1
            let generation = installGeneration
            let result = try await installer.prepare(preferences.diskSizeGiB) { [weak self] value in
                Task { @MainActor in
                    guard let self, self.installGeneration == generation, self.state == .preparing else { return }
                    self.progress = min(1, max(0, value))
                }
            }
            try Task.checkCancellation()
            installation = result
            installationURL = result.directory
            progress = nil
            state = .ready
        } catch is CancellationError {
            progress = nil
            state = installation == nil ? .absent : .ready
        } catch {
            progress = nil
            fail(error)
        }
    }

    func startButtonTapped() async {
        guard !isBusy, !state.hasActiveSession else { return }
        guard let installation else {
            errorMessage = "Prepare your Linux disk before starting Omarchy."
            return
        }
        errorMessage = nil
        runtimeGeneration += 1
        let generation = runtimeGeneration
        do {
            try resourcePolicy.validate(preferences)
            if preferences.microphoneEnabled, !microphone.isAuthorized() {
                throw VMConfigurationError.microphoneDenied
            }
            $preferences.withLock {
                if $0.machineIdentifier == nil {
                    $0.machineIdentifier = VZGenericMachineIdentifier().dataRepresentation
                }
                if $0.macAddress == nil {
                    $0.macAddress = VZMACAddress.randomLocallyAdministered().string
                }
            }
            state = .starting
            let nextRuntime = virtualMachineClient.makeRuntime()
            nextRuntime.onEvent = { [weak self] event in
                guard let self, runtimeGeneration == generation else { return }
                runtimeGeneration += 1
                virtualMachine = nil
                runtime = nil
                supportsSaveRestore = false
                switch event {
                case .stopped:
                    errorMessage = nil
                    state = .ready
                case let .failed(message):
                    errorMessage = message
                    state = .failed(message)
                }
            }
            runtime = nextRuntime
            try await nextRuntime.start(installation: installation, preferences: preferences)
            guard generation == runtimeGeneration, state == .starting else { return }
            virtualMachine = nextRuntime.virtualMachine
            supportsSaveRestore = nextRuntime.supportsSaveRestore
            state = .running
        } catch {
            guard generation == runtimeGeneration else { return }
            runtime = nil
            virtualMachine = nil
            fail(error)
        }
    }

    func pauseButtonTapped() async {
        guard state == .running, !isChangingRunState, let runtime else { return }
        let generation = runtimeGeneration
        isChangingRunState = true
        defer { isChangingRunState = false }
        do {
            try await runtime.pause()
            if generation == runtimeGeneration, state == .running { state = .paused }
        } catch {
            if generation == runtimeGeneration { errorMessage = error.localizedDescription }
        }
    }

    func resumeButtonTapped() async {
        guard state == .paused, !isChangingRunState, let runtime else { return }
        let generation = runtimeGeneration
        isChangingRunState = true
        defer { isChangingRunState = false }
        do {
            try await runtime.resume()
            if generation == runtimeGeneration, state == .paused { state = .running }
        } catch {
            if generation == runtimeGeneration { errorMessage = error.localizedDescription }
        }
    }

    func shutDownForQuit() async {
        do {
            while isChangingRunState {
                try await clock.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
        } catch {
            return
        }
        await shutDownButtonTapped()
    }

    func shutDownButtonTapped() async {
        guard state == .running || state == .paused, !isChangingRunState, let runtime else { return }
        let previousState = state
        let generation = runtimeGeneration
        var resumedPausedMachine = false
        isChangingRunState = true
        errorMessage = nil
        do {
            try Task.checkCancellation()
            if state == .paused {
                try await runtime.resume()
                resumedPausedMachine = true
            }
            guard generation == runtimeGeneration else {
                isChangingRunState = false
                return
            }
            try Task.checkCancellation()
            state = .stopping
            try runtime.requestStop()
            isChangingRunState = false
            for _ in 0..<80 {
                guard state == .stopping, generation == runtimeGeneration else { return }
                try await clock.sleep(for: .milliseconds(250))
            }
            if state == .stopping, generation == runtimeGeneration {
                errorMessage = "Linux is still shutting down. You can keep waiting or choose Force Stop. Force Stop may lose unsaved work."
            }
        } catch is CancellationError {
            isChangingRunState = false
            if generation == runtimeGeneration, resumedPausedMachine, state == .paused {
                state = .running
            }
        } catch {
            isChangingRunState = false
            guard generation == runtimeGeneration else { return }
            state = resumedPausedMachine ? .running : previousState
            errorMessage = error.localizedDescription
        }
    }

    func forceStopButtonTapped() async {
        guard state.hasActiveSession, !isChangingRunState, let runtime else { return }
        isChangingRunState = true
        defer { isChangingRunState = false }
        let previousState = state
        let generation = runtimeGeneration
        state = .stopping
        do {
            try await runtime.forceStop()
            guard generation == runtimeGeneration else { return }
            runtimeGeneration += 1
            self.runtime = nil
            virtualMachine = nil
            supportsSaveRestore = false
            errorMessage = nil
            state = .ready
        } catch {
            guard generation == runtimeGeneration else { return }
            state = previousState
            errorMessage = error.localizedDescription
        }
    }

    func microphoneButtonTapped() async {
        guard !state.hasActiveSession else {
            errorMessage = "Shut down Linux before changing microphone access."
            return
        }
        if preferences.microphoneEnabled {
            $preferences.microphoneEnabled.withLock { $0 = false }
            return
        }
        if await microphone.requestAccess() {
            guard !state.hasActiveSession else {
                errorMessage = "Microphone permission is granted. Shut down Linux before enabling its microphone."
                return
            }
            $preferences.microphoneEnabled.withLock { $0 = true }
            errorMessage = nil
        } else {
            errorMessage = VMConfigurationError.microphoneDenied.localizedDescription
        }
    }

    func clipboardPreferenceChanged() {
        runtime?.setClipboardEnabled(preferences.clipboardEnabled)
    }

    func chooseSharedFolder() {
        guard !state.hasActiveSession, !state.isBusy else {
            errorMessage = "Shut down Linux before changing its shared folder."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Share a folder with Omarchy"
        panel.message = "Only this folder will be available inside Linux."
        panel.prompt = "Share Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            $preferences.withLock {
                $0.sharedFolderBookmark = bookmark
                $0.sharedFolderName = url.lastPathComponent
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeSharedFolderButtonTapped() {
        guard !state.hasActiveSession else { return }
        $preferences.withLock {
            $0.sharedFolderBookmark = nil
            $0.sharedFolderName = nil
        }
    }

    private func fail(_ error: any Error) {
        errorMessage = error.localizedDescription
        state = .failed(error.localizedDescription)
    }

    private func updateSSHSession() {
        ssh.sessionChanged(machine: virtualMachine, isRunning: state == .running && !isChangingRunState)
    }
}
