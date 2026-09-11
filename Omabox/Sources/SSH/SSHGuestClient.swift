import Dependencies
import Foundation
import Virtualization

nonisolated struct SSHGuestClient: Sendable {
    var request: @MainActor @Sendable (VZVirtualMachine, SSHGuestRequest) async throws -> SSHGuestResponse
}

extension SSHGuestClient: DependencyKey {
    static var liveValue: Self {
        Self(request: { machine, request in
            guard machine.state == .running,
                  let device = machine.socketDevices.first as? VZVirtioSocketDevice else {
                throw SSHAccessError.unavailable
            }
            let operation = SSHGuestRequestOperation(device: device, request: request)
            return try await operation.value()
        })
    }

    static var testValue: Self {
        Self(request: { _, _ in throw SSHAccessError.unavailable })
    }
}

extension DependencyValues {
    var sshGuestClient: SSHGuestClient {
        get { self[SSHGuestClient.self] }
        set { self[SSHGuestClient.self] = newValue }
    }
}
