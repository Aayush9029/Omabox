import Darwin
import Foundation
import Virtualization

@MainActor
final class SSHGuestRequestOperation {
    private let device: VZVirtioSocketDevice
    private let request: SSHGuestRequest
    private var continuation: CheckedContinuation<SSHGuestResponse, any Error>?
    private var readSource: (any DispatchSourceRead)?
    private var writeSource: (any DispatchSourceWrite)?
    private var lease: SSHSocketLease?
    private var timeout: Task<Void, Never>?
    private var output = Data()
    private var input = Data()
    private var completed = false

    init(device: VZVirtioSocketDevice, request: SSHGuestRequest) {
        self.device = device
        self.request = request
    }

    func value() async throws -> SSHGuestResponse {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                begin()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func begin() {
        do {
            output = try JSONEncoder().encode(request)
            output.append(10)
            guard output.count <= 16_384 else { throw SSHAccessError.invalidResponse }
        } catch {
            finish(.failure(error))
            return
        }
        setTimeout(.seconds(3), error: .unavailable)
        device.connect(toPort: 4_041) { [weak self] result in
            guard let self, !completed else {
                if case let .success(connection) = result { connection.close() }
                return
            }
            switch result {
            case let .success(connection): attach(connection)
            case .failure: finish(.failure(SSHAccessError.unavailable))
            }
        }
    }

    private func attach(_ connection: VZVirtioSocketConnection) {
        setTimeout(.seconds(20))
        let descriptor = connection.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            connection.close()
            finish(.failure(SSHAccessError.unavailable))
            return
        }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            connection.close()
            finish(.failure(SSHAccessError.unavailable))
            return
        }
        let lease = SSHSocketLease(connection: connection)
        self.lease = lease
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        reader.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailableData() } }
        reader.setCancelHandler { MainActor.assumeIsolated { lease.sourceDidCancel() } }
        let writer = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: .main)
        writer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.writeAvailableData() } }
        writer.setCancelHandler { MainActor.assumeIsolated { lease.sourceDidCancel() } }
        readSource = reader
        writeSource = writer
        reader.resume()
        writer.resume()
    }

    private func setTimeout(_ duration: Duration, error: SSHAccessError = .timedOut) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.finish(.failure(error))
        }
    }

    private func writeAvailableData() {
        guard !completed, let lease else { return }
        let count = output.withUnsafeBytes { send(lease.connection.fileDescriptor, $0.baseAddress, $0.count, 0) }
        if count > 0 {
            output.removeFirst(count)
            if output.isEmpty {
                writeSource?.cancel()
                writeSource = nil
            }
        } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
            finish(.failure(SSHAccessError.unavailable))
        }
    }

    private func readAvailableData() {
        guard !completed, let lease else { return }
        var buffer = [UInt8](repeating: 0, count: 8_192)
        let count = recv(lease.connection.fileDescriptor, &buffer, buffer.count, 0)
        if count == 0 {
            finish(.failure(SSHAccessError.unavailable))
        } else if count < 0 {
            if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                finish(.failure(SSHAccessError.unavailable))
            }
        } else {
            input.append(contentsOf: buffer.prefix(count))
            guard input.count <= 32_768 else {
                finish(.failure(SSHAccessError.invalidResponse))
                return
            }
            if let newline = input.firstIndex(of: 10) {
                do {
                    let response = try JSONDecoder().decode(SSHGuestResponse.self, from: input[..<newline]).validated()
                    finish(.success(response))
                } catch {
                    finish(.failure(error))
                }
            }
        }
    }

    private func finish(_ result: Result<SSHGuestResponse, any Error>) {
        guard !completed else { return }
        completed = true
        timeout?.cancel()
        timeout = nil
        readSource?.cancel()
        writeSource?.cancel()
        readSource = nil
        writeSource = nil
        lease = nil
        output.removeAll()
        input.removeAll()
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
