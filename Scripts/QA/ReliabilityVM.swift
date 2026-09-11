import Foundation
import Virtualization

@MainActor
final class ReliabilityVM: NSObject, @preconcurrency VZVirtualMachineDelegate {
    private var machine: VZVirtualMachine?
    private let guestInput = Pipe()
    private let guestOutput = Pipe()
    private var input = Data()

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

@main
struct Main {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { exit(2) }
        let instance = ReliabilityVM()
        try instance.start(
            directory: URL(filePath: CommandLine.arguments[1]),
            guestSource: URL(filePath: CommandLine.arguments[2]),
            commandLine: CommandLine.arguments[3]
        )
        withExtendedLifetime(instance) { RunLoop.main.run() }
    }
}
