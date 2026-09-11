import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing
import Virtualization
@testable import Omabox

@Suite(.dependencies)
@MainActor
struct CoreRuntimeTests {
    private var installation: GuestInstallation {
        GuestInstallation(
            directory: URL(filePath: "/test/Omabox"),
            kernel: URL(filePath: "/test/Omabox/kernel"),
            initialRamdisk: nil,
            disk: URL(filePath: "/test/Omabox/rootfs.raw"),
            commandLine: "console=hvc0 root=/dev/vda rw"
        )
    }

    @Test func openingAnEmptyLibraryDoesNotPretendToBeInstalled() async {
        let model = makeModel(existing: nil)
        await model.task()
        expectNoDifference(model.state, .absent)
        #expect(model.installationURL == nil)
        await model.startButtonTapped()
        expectNoDifference(model.state, .absent)
        #expect(model.errorMessage != nil)
    }

    @Test func preparationBecomesReadyOnlyWhenInstallerReturns() async {
        let model = makeModel(existing: nil)
        await expectDifference(model.state) {
            await model.prepareButtonTapped()
        } changes: {
            $0 = .ready
        }
        expectNoDifference(model.installationURL, installation.directory)
        #expect(model.progress == nil)
    }

    @Test func installerFailureSurfacesAnActionableError() async {
        let model = withDependencies {
            $0.installerClient = InstallerClient(
                existing: { nil },
                prepare: { _, _ in throw TestFailure.diskFull }
            )
            $0.virtualMachineClient = client(runtime: TestRuntime())
        } operation: {
            OmaboxModel(preferences: Shared(value: preferences()))
        }
        await model.prepareButtonTapped()
        expectNoDifference(model.state, .failed(TestFailure.diskFull.localizedDescription))
        #expect(model.installationURL == nil)
        #expect(model.progress == nil)
    }

    @Test func startsPausesResumesAndHandlesGuestShutdown() async {
        let runtime = TestRuntime()
        let model = makeModel(runtime: runtime, existing: installation)
        await model.task()
        expectNoDifference(model.state, .ready)
        await model.startButtonTapped()
        expectNoDifference(model.state, .running)
        await model.pauseButtonTapped()
        expectNoDifference(model.state, .paused)
        await model.resumeButtonTapped()
        expectNoDifference(model.state, .running)
        runtime.onEvent?(.stopped)
        expectNoDifference(model.state, .ready)
        expectNoDifference(runtime.calls, ["start", "pause", "resume"])
    }

    @Test func startFailurePreservesTheInstallationForRetry() async {
        let runtime = TestRuntime()
        runtime.startError = TestFailure.startFailed
        let model = makeModel(runtime: runtime, existing: installation)
        await model.task()
        await model.startButtonTapped()
        expectNoDifference(model.state, .failed(TestFailure.startFailed.localizedDescription))
        expectNoDifference(model.installationURL, installation.directory)
        runtime.startError = nil
        await model.startButtonTapped()
        expectNoDifference(model.state, .running)
        #expect(model.errorMessage == nil)
    }

    @Test func supersededStartFailurePreservesTheNewRuntime() async throws {
        let firstRuntime = TestRuntime()
        let secondRuntime = TestRuntime()
        let started = AsyncStream<Void>.makeStream()
        var firstCompletion: CheckedContinuation<Void, any Error>?
        firstRuntime.startOperation = {
            try await withCheckedThrowingContinuation { continuation in
                firstCompletion = continuation
                started.continuation.yield(())
            }
        }
        let installation = installation
        let model = withDependencies {
            $0.installerClient = InstallerClient(existing: { installation }, prepare: { _, _ in installation })
            $0.virtualMachineClient = VirtualMachineClient(
                makeRuntime: { firstRuntime.calls.isEmpty ? firstRuntime : secondRuntime },
                resourcePolicy: { VMResourcePolicy(cpuRange: 1...8, memoryRangeGiB: 2...16) }
            )
        } operation: {
            OmaboxModel(preferences: Shared(value: preferences()))
        }
        await model.task()
        let firstAttempt = Task { await model.startButtonTapped() }
        var signals = started.stream.makeAsyncIterator()
        await signals.next()
        firstRuntime.onEvent?(.failed("The first attempt stopped early."))

        await model.startButtonTapped()
        expectNoDifference(model.state, .running)
        let completion = try #require(firstCompletion)
        completion.resume(throwing: TestFailure.startFailed)
        await firstAttempt.value
        started.continuation.finish()

        expectNoDifference(model.state, .running)
        #expect(model.errorMessage == nil)
        model.$preferences.clipboardEnabled.withLock { $0 = false }
        model.clipboardPreferenceChanged()
        #expect(firstRuntime.clipboardEnabled)
        #expect(!secondRuntime.clipboardEnabled)
        expectNoDifference(firstRuntime.calls, ["start"])
        expectNoDifference(secondRuntime.calls, ["start"])
    }

    @Test func deniedMicrophoneDoesNotEnableThePreference() async {
        let model = makeModel(existing: nil)
        await model.microphoneButtonTapped()
        #expect(!model.preferences.microphoneEnabled)
        expectNoDifference(model.errorMessage, VMConfigurationError.microphoneDenied.localizedDescription)
    }

    @Test func invalidResourcesAreRejectedBeforeCallingTheVM() async {
        let runtime = TestRuntime()
        var invalidPreferences = preferences()
        invalidPreferences.cpuCount = 100
        let model = makeModel(runtime: runtime, existing: installation, preferences: invalidPreferences)
        await model.task()
        await model.startButtonTapped()
        #expect(model.state.is(\.failed))
        expectNoDifference(runtime.calls, [])
    }

    @Test func clipboardPermissionCanBeRevokedDuringARunningSession() async {
        let runtime = TestRuntime()
        let model = makeModel(runtime: runtime, existing: installation)
        await model.task()
        await model.startButtonTapped()
        model.$preferences.clipboardEnabled.withLock { $0 = false }
        model.clipboardPreferenceChanged()
        expectNoDifference(runtime.clipboardEnabled, false)
        expectNoDifference(model.state, .running)
    }

    @Test func forceStopFailureDoesNotPretendTheMachineStopped() async {
        let runtime = TestRuntime()
        runtime.stopError = TestFailure.stopFailed
        let model = makeModel(runtime: runtime, existing: installation)
        await model.task()
        await model.startButtonTapped()
        await model.forceStopButtonTapped()
        expectNoDifference(model.state, .running)
        #expect(model.errorMessage != nil)
    }

    @Test func shutdownWaitsForGuestConfirmation() async {
        let runtime = TestRuntime()
        let model = withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            makeModel(runtime: runtime, existing: installation)
        }
        await model.task()
        await model.startButtonTapped()
        await model.shutDownButtonTapped()
        expectNoDifference(model.state, .stopping)
        #expect(model.errorMessage?.contains("Force Stop") == true)
        runtime.onEvent?(.stopped)
        expectNoDifference(model.state, .ready)
        #expect(model.errorMessage == nil)
    }

    @Test func failedResumeDuringShutdownPreservesPausedState() async {
        let runtime = TestRuntime()
        let model = makeModel(runtime: runtime, existing: installation)
        await model.task()
        await model.startButtonTapped()
        await model.pauseButtonTapped()
        runtime.resumeError = TestFailure.startFailed
        await model.shutDownButtonTapped()
        expectNoDifference(model.state, .paused)
        #expect(!model.isChangingRunState)
        #expect(model.errorMessage != nil)
    }

    @Test func quittingDuringPauseWaitsThenRequestsGracefulShutdown() async throws {
        let runtime = TestRuntime()
        let clock = TestClock<Duration>()
        let pausing = AsyncStream<Void>.makeStream()
        var pauseCompletion: CheckedContinuation<Void, any Error>?
        runtime.pauseOperation = {
            try await withCheckedThrowingContinuation { continuation in
                pauseCompletion = continuation
                pausing.continuation.yield(())
            }
        }
        let model = withDependencies {
            $0.continuousClock = clock
        } operation: {
            makeModel(runtime: runtime, existing: installation)
        }
        await model.task()
        await model.startButtonTapped()
        let pause = Task { await model.pauseButtonTapped() }
        var signals = pausing.stream.makeAsyncIterator()
        await signals.next()
        let quit = Task { await model.shutDownForQuit() }
        await clock.advance(by: .milliseconds(100))
        expectNoDifference(runtime.calls, ["start", "pause"])

        let completion = try #require(pauseCompletion)
        completion.resume()
        await pause.value
        await clock.advance(by: .milliseconds(100))
        expectNoDifference(runtime.calls, ["start", "pause", "resume", "requestStop"])
        expectNoDifference(model.state, .stopping)

        runtime.onEvent?(.stopped)
        await clock.advance(by: .milliseconds(250))
        await quit.value
        pausing.continuation.finish()
        expectNoDifference(model.state, .ready)
        #expect(model.errorMessage == nil)
    }

    @Test func canceledQuitWaitDoesNotRequestShutdownAfterPauseFinishes() async throws {
        let runtime = TestRuntime()
        let clock = TestClock<Duration>()
        let pausing = AsyncStream<Void>.makeStream()
        var pauseCompletion: CheckedContinuation<Void, any Error>?
        runtime.pauseOperation = {
            try await withCheckedThrowingContinuation { continuation in
                pauseCompletion = continuation
                pausing.continuation.yield(())
            }
        }
        let model = withDependencies {
            $0.continuousClock = clock
        } operation: {
            makeModel(runtime: runtime, existing: installation)
        }
        await model.task()
        await model.startButtonTapped()
        let pause = Task { await model.pauseButtonTapped() }
        var signals = pausing.stream.makeAsyncIterator()
        await signals.next()
        let quit = Task { await model.shutDownForQuit() }
        await clock.advance(by: .milliseconds(100))
        quit.cancel()
        await quit.value

        let completion = try #require(pauseCompletion)
        completion.resume()
        await pause.value
        pausing.continuation.finish()
        expectNoDifference(runtime.calls, ["start", "pause"])
        expectNoDifference(model.state, .paused)
        #expect(!model.isChangingRunState)
    }

    @Test func canceledQuitDuringResumeDoesNotRequestShutdown() async throws {
        let runtime = TestRuntime()
        let resuming = AsyncStream<Void>.makeStream()
        var resumeCompletion: CheckedContinuation<Void, any Error>?
        runtime.resumeOperation = {
            try await withCheckedThrowingContinuation { continuation in
                resumeCompletion = continuation
                resuming.continuation.yield(())
            }
        }
        let model = makeModel(runtime: runtime, existing: installation)
        await model.task()
        await model.startButtonTapped()
        await model.pauseButtonTapped()
        let quit = Task { await model.shutDownForQuit() }
        var signals = resuming.stream.makeAsyncIterator()
        await signals.next()

        quit.cancel()
        let completion = try #require(resumeCompletion)
        completion.resume()
        await quit.value
        resuming.continuation.finish()

        expectNoDifference(runtime.calls, ["start", "pause", "resume"])
        expectNoDifference(model.state, .running)
        #expect(!model.isChangingRunState)
        #expect(model.errorMessage == nil)
    }

    private func preferences() -> VMPreferences {
        var value = VMPreferences()
        value.cpuCount = 4
        value.memoryGiB = 8
        value.diskSizeGiB = 40
        return value
    }

    private func makeModel(
        runtime: TestRuntime = TestRuntime(),
        existing: GuestInstallation?,
        preferences: VMPreferences? = nil
    ) -> OmaboxModel {
        let installation = installation
        return withDependencies {
            $0.installerClient = InstallerClient(
                existing: { existing },
                prepare: { _, progress in
                    progress(0.5)
                    return installation
                }
            )
            $0.virtualMachineClient = client(runtime: runtime)
            $0.microphoneClient = .testValue
        } operation: {
            OmaboxModel(preferences: Shared(value: preferences ?? self.preferences()))
        }
    }

    private func client(runtime: TestRuntime) -> VirtualMachineClient {
        VirtualMachineClient(
            makeRuntime: { runtime },
            resourcePolicy: { VMResourcePolicy(cpuRange: 1...8, memoryRangeGiB: 2...16) }
        )
    }
}

@MainActor
private final class TestRuntime: VirtualMachineRuntime {
    var virtualMachine: VZVirtualMachine?
    var onEvent: (@MainActor (VMRuntimeEvent) -> Void)?
    var supportsSaveRestore = false
    var calls: [String] = []
    var clipboardEnabled = true
    var startError: (any Error)?
    var startOperation: (@MainActor () async throws -> Void)?
    var pauseOperation: (@MainActor () async throws -> Void)?
    var resumeOperation: (@MainActor () async throws -> Void)?
    var resumeError: (any Error)?
    var stopError: (any Error)?

    func start(installation: GuestInstallation, preferences: VMPreferences) async throws {
        calls.append("start")
        if let startError { throw startError }
        try await startOperation?()
    }

    func pause() async throws {
        calls.append("pause")
        try await pauseOperation?()
    }
    func resume() async throws {
        calls.append("resume")
        if let resumeError { throw resumeError }
        try await resumeOperation?()
    }
    func requestStop() throws { calls.append("requestStop") }
    func forceStop() async throws {
        calls.append("forceStop")
        if let stopError { throw stopError }
    }
    func setClipboardEnabled(_ enabled: Bool) { clipboardEnabled = enabled }
}

private enum TestFailure: Error {
    case diskFull
    case startFailed
    case stopFailed
}
