import Darwin
import Foundation
import Virtualization

@MainActor
final class SSHVM: NSObject, @preconcurrency VZVirtualMachineDelegate {
    private var machine: VZVirtualMachine?
    private let guestInput = Pipe()
    private let guestOutput = Pipe()
    private var input = Data()
    private var sshConnection: VZVirtioSocketConnection?
    private var sshRequestID: UUID?
    private var sshContinuation: CheckedContinuation<Data, any Error>?
    private var sshTimeout: Task<Void, Never>?
    private var sshExchange: Task<Void, Never>?

    func start(directory: URL, guestSource: URL, commandLine: String) throws {
        let configuration = VZVirtualMachineConfiguration()
        let loader = VZLinuxBootLoader(kernelURL: directory.appending(path: "kernel"))
        loader.initialRamdiskURL = directory.appending(path: "initramfs")
        loader.commandLine = commandLine
        configuration.bootLoader = loader
        configuration.platform = VZGenericPlatformConfiguration()
        configuration.cpuCount = 4
        configuration.memorySize = 4 * 1_073_741_824
        let storage = try VZDiskImageStorageDeviceAttachment(url: directory.appending(path: "rootfs.raw"), readOnly: false)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: storage)]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: guestInput.fileHandleForReading,
            fileHandleForWriting: guestOutput.fileHandleForWriting
        )
        configuration.serialPorts = [console]
        configuration.directorySharingDevices = [
            share(tag: "omabox-build", directory: guestSource, readOnly: true),
            share(tag: "omabox", directory: guestSource, readOnly: true),
            share(tag: "omabox-config", directory: directory.appending(path: "host-config"), readOnly: true),
            share(tag: "qa-readonly", directory: directory.appending(path: "readonly"), readOnly: true),
            share(tag: "qa-writable", directory: directory.appending(path: "exports"), readOnly: false),
        ]
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1440, heightInPixels: 900)]
        configuration.graphicsDevices = [graphics]
        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = nil
        sound.streams = [output]
        configuration.audioDevices = [sound]
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]
        try configuration.validate()
        let machine = VZVirtualMachine(configuration: configuration)
        self.machine = machine
        machine.delegate = self
        guestOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { FileHandle.standardOutput.write(data) }
        }
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in await self?.receive(data) }
        }
        let started = ProcessInfo.processInfo.systemUptime
        machine.start { [weak self] result in
            switch result {
            case .success:
                self?.emit(["event": "started", "milliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1_000])
            case let .failure(error):
                self?.emit(["event": "error", "message": error.localizedDescription])
                exit(1)
            }
        }
    }

    private func share(tag: String, directory: URL, readOnly: Bool) -> VZVirtioFileSystemDeviceConfiguration {
        let configuration = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        configuration.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: directory, readOnly: readOnly))
        return configuration
    }

    private func receive(_ data: Data) async {
        guard !data.isEmpty else { return }
        input.append(data)
        while let newline = input.firstIndex(of: 10) {
            let line = Data(input.prefix(upTo: newline))
            input.removeSubrange(...newline)
            if line.starts(with: Data("@omabox ".utf8)) {
                await control(Data(line.dropFirst(8)))
            } else {
                guestInput.fileHandleForWriting.write(line + Data([10]))
            }
        }
    }

    private func control(_ data: Data) async {
        guard let machine,
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = command["action"] as? String else { return }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            switch action {
            case "ssh":
                guard let request = command["request"] as? [String: Any] else {
                    throw SSHControlError.invalidRequest
                }
                let replyData = try await requestSSH(request)
                let reply = try JSONSerialization.jsonObject(with: replyData)
                emit(["event": action, "reply": reply, "milliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1_000])
                return
            case "pause":
                try await machine.pause()
            case "resume":
                try await machine.resume()
            case "resize":
                guard let width = command["width"] as? Int,
                      let height = command["height"] as? Int,
                      let display = machine.graphicsDevices.first?.displays.first else { return }
                try display.reconfigure(sizeInPixels: CGSize(width: width, height: height))
            default:
                return
            }
            emit(["event": action, "milliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1_000])
        } catch {
            emit(["event": "control-error", "action": action, "message": error.localizedDescription])
        }
    }

    private func requestSSH(_ request: [String: Any]) async throws -> Data {
        guard sshRequestID == nil,
              let device = machine?.socketDevices.first as? VZVirtioSocketDevice else {
            throw SSHControlError.unavailable
        }
        let encoded = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        guard encoded.count <= 16_384 else { throw SSHControlError.invalidRequest }
        let frame = encoded + Data([10])
        let requestID = UUID()
        sshRequestID = requestID
        return try await withCheckedThrowingContinuation { continuation in
            sshContinuation = continuation
            sshTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.finishSSH(requestID, result: .failure(SSHControlError.timeout))
            }
            device.connect(toPort: 4_041) { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self, self.sshRequestID == requestID else {
                        if case let .success(connection) = result { connection.close() }
                        return
                    }
                    switch result {
                    case let .success(connection):
                        self.sshConnection = connection
                        self.sshExchange = Task { [weak self] in
                            await self?.exchangeSSH(requestID, frame: frame)
                        }
                    case let .failure(error):
                        self.finishSSH(requestID, result: .failure(error))
                    }
                }
            }
        }
    }

    private func exchangeSSH(_ requestID: UUID, frame: Data) async {
        guard let connection = sshConnection else { return }
        let descriptor = connection.fileDescriptor
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else {
            finishSSH(requestID, result: .failure(SSHControlError.socket))
            return
        }
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var outgoing = frame
        var incoming = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while sshRequestID == requestID, !Task.isCancelled {
            if !outgoing.isEmpty {
                let count = outgoing.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, 0) }
                if count > 0 {
                    outgoing.removeFirst(count)
                } else if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                    finishSSH(requestID, result: .failure(SSHControlError.socket))
                    return
                }
            } else {
                let count = recv(descriptor, &buffer, buffer.count, 0)
                if count > 0 {
                    incoming.append(contentsOf: buffer.prefix(count))
                    if incoming.count > 16_384 {
                        finishSSH(requestID, result: .failure(SSHControlError.invalidReply))
                        return
                    }
                    if let newline = incoming.firstIndex(of: 10) {
                        guard newline == incoming.index(before: incoming.endIndex),
                              ((try? JSONSerialization.jsonObject(with: incoming.prefix(upTo: newline))) as? [String: Any]) != nil else {
                            finishSSH(requestID, result: .failure(SSHControlError.invalidReply))
                            return
                        }
                        finishSSH(requestID, result: .success(Data(incoming.prefix(upTo: newline))))
                        return
                    }
                } else if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                    finishSSH(requestID, result: .failure(SSHControlError.socket))
                    return
                }
            }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        }
    }

    private func finishSSH(_ requestID: UUID, result: Result<Data, any Error>) {
        guard sshRequestID == requestID else { return }
        let continuation = sshContinuation
        sshRequestID = nil
        sshContinuation = nil
        sshTimeout?.cancel()
        sshTimeout = nil
        sshExchange?.cancel()
        sshExchange = nil
        sshConnection?.close()
        sshConnection = nil
        continuation?.resume(with: result)
    }

    private func emit(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(Data("\n@QA ".utf8) + data + Data([10]))
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        emit(["event": "stopped"])
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        emit(["event": "error", "message": error.localizedDescription])
        exit(1)
    }
}

private enum SSHControlError: LocalizedError {
    case unavailable, invalidRequest, invalidReply, socket, timeout

    var errorDescription: String? {
        switch self {
        case .unavailable: "An SSH request is already running or the socket device is unavailable."
        case .invalidRequest: "The SSH request must be one JSON object no larger than 16 KiB."
        case .invalidReply: "The guest returned an invalid SSH reply."
        case .socket: "The SSH control connection closed or failed before a complete reply."
        case .timeout: "The SSH control request exceeded 15 seconds."
        }
    }
}

@main
struct Main {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { exit(2) }
        let instance = SSHVM()
        try instance.start(
            directory: URL(filePath: CommandLine.arguments[1]),
            guestSource: URL(filePath: CommandLine.arguments[2]),
            commandLine: CommandLine.arguments[3]
        )
        withExtendedLifetime(instance) { RunLoop.main.run() }
    }
}
