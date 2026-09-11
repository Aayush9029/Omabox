import CasePaths

@CasePathable
nonisolated enum SSHAccessPhase: Equatable, Sendable {
    case disabled
    case waitingForDesktop
    case configuring
    case pendingOwner
    case pendingNetwork
    case ready(SSHEndpoint)
    case failed(String)
}
