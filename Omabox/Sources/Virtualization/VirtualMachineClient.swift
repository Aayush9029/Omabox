import Dependencies
import Foundation
import Virtualization

nonisolated enum VMRuntimeEvent: Sendable {
    case stopped
    case failed(String)
}

@MainActor
protocol VirtualMachineRuntime: AnyObject {
    var virtualMachine: VZVirtualMachine? { get }
    var onEvent: (@MainActor (VMRuntimeEvent) -> Void)? { get set }
    var supportsSaveRestore: Bool { get }
    func start(installation: GuestInstallation, preferences: VMPreferences) async throws
    func pause() async throws
    func resume() async throws
    func requestStop() throws
    func forceStop() async throws
    func setClipboardEnabled(_ enabled: Bool)
}

nonisolated struct VirtualMachineClient: Sendable {
    var makeRuntime: @MainActor @Sendable () -> any VirtualMachineRuntime
    var resourcePolicy: @Sendable () -> VMResourcePolicy
}

extension VirtualMachineClient: DependencyKey {
    static var liveValue: Self {
        Self(
            makeRuntime: { AppleVirtualMachineRuntime() },
            resourcePolicy: {
                let maximumCPU = min(ProcessInfo.processInfo.activeProcessorCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
                let hostMemoryGiB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
                let maximumMemory = min(hostMemoryGiB - 2, Int(VZVirtualMachineConfiguration.maximumAllowedMemorySize / 1_073_741_824))
                return VMResourcePolicy(
                    cpuRange: max(1, VZVirtualMachineConfiguration.minimumAllowedCPUCount)...max(1, maximumCPU),
                    memoryRangeGiB: 2...max(2, maximumMemory)
                )
            }
        )
    }
}

extension DependencyValues {
    var virtualMachineClient: VirtualMachineClient {
        get { self[VirtualMachineClient.self] }
        set { self[VirtualMachineClient.self] = newValue }
    }
}
