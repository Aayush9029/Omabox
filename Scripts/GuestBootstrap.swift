import Foundation
import Virtualization
import Darwin

@MainActor
final class Bootstrap: NSObject, @preconcurrency VZVirtualMachineDelegate {
    var machine: VZVirtualMachine?
    var qaConnection: VZVirtioSocketConnection?
    var qaHandle: FileHandle?
    var qaBuffer = Data()

    func start(directory: URL, share: URL, commandLine: String) throws {
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
        console.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: .standardInput, fileHandleForWriting: .standardOutput)
        configuration.serialPorts = [console]
        let fileSystem = VZVirtioFileSystemDeviceConfiguration(tag: "omabox-build")
        fileSystem.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: share, readOnly: true))
        let testShare = VZVirtioFileSystemDeviceConfiguration(tag: "omabox")
        testShare.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: share, readOnly: true))
        configuration.directorySharingDevices = [fileSystem, testShare]
        if ProcessInfo.processInfo.environment["OMABOX_QA_CLIPBOARD"] == "1" {
            let exports = directory.appending(path: "exports")
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            let outputShare = VZVirtioFileSystemDeviceConfiguration(tag: "omabox-qa")
            outputShare.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: exports, readOnly: false))
            configuration.directorySharingDevices.append(outputShare)
        }
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
        machine.start { result in
            if case let .failure(error) = result {
                FileHandle.standardError.write(Data("Bootstrap failed: \(error)\n".utf8))
                exit(1)
            }
        }
        if ProcessInfo.processInfo.environment["OMABOX_QA_CLIPBOARD"] == "1" {
            Task { [self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard qaConnection == nil else { continue }
                    guard machine.state == .running, let device = machine.socketDevices.first as? VZVirtioSocketDevice else { continue }
                    device.connect(toPort: 4040) { [weak self] result in
                        guard let self, case let .success(connection) = result else { return }
                        let descriptor = dup(connection.fileDescriptor)
                        guard descriptor >= 0 else { return }
                        qaConnection = connection
                        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                        qaHandle = handle
                        handle.readabilityHandler = { [weak self] input in
                            var bytes = [UInt8](repeating: 0, count: 16_384)
                            let count = Darwin.read(input.fileDescriptor, &bytes, bytes.count)
                            if count < 0 && errno == EINTR { return }
                            let data = count > 0 ? Data(bytes.prefix(count)) : Data()
                            Task { @MainActor [weak self] in self?.readQA(data, from: input) }
                        }
                    }
                }
            }
        }
    }

    func readQA(_ data: Data, from handle: FileHandle) {
        guard qaHandle === handle else { return }
        guard !data.isEmpty else {
            qaHandle?.readabilityHandler = nil
            qaHandle = nil
            qaConnection = nil
            qaBuffer.removeAll()
            return
        }
        qaBuffer.append(data)
        while let newline = qaBuffer.firstIndex(of: 10) {
            let line = qaBuffer.prefix(upTo: newline)
            qaBuffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            FileHandle.standardOutput.write(Data("OMABOX_QA_VSOCK: \(String(decoding: line, as: UTF8.self))\n".utf8))
            if message["type"] as? String == "ready" {
                try? qaHandle?.write(contentsOf: Data("{\"type\":\"clipboard\",\"text\":\"omabox-host-clipboard-qa-20260911\"}\n".utf8))
            }
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) { exit(0) }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        FileHandle.standardError.write(Data("Guest stopped: \(error)\n".utf8))
        exit(1)
    }
}

@main
struct GuestBootstrap {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            FileHandle.standardError.write(Data("Usage: GuestBootstrap GUEST_DIRECTORY SHARE_DIRECTORY COMMAND_LINE\n".utf8))
            exit(2)
        }
        let bootstrap = Bootstrap()
        try bootstrap.start(
            directory: URL(filePath: CommandLine.arguments[1]),
            share: URL(filePath: CommandLine.arguments[2]),
            commandLine: CommandLine.arguments[3]
        )
        withExtendedLifetime(bootstrap) { RunLoop.main.run() }
    }
}
