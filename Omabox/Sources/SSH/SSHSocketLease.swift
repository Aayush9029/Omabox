import Virtualization

@MainActor
final class SSHSocketLease {
    let connection: VZVirtioSocketConnection
    private var pendingSources = 2

    init(connection: VZVirtioSocketConnection) {
        self.connection = connection
    }

    func sourceDidCancel() {
        pendingSources -= 1
        if pendingSources == 0 { connection.close() }
    }
}
