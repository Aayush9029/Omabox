import AVFoundation
import Foundation
import OSLog
import Virtualization

@MainActor
final class AppleVirtualMachineRuntime: NSObject, VirtualMachineRuntime, @preconcurrency VZVirtualMachineDelegate {
    private(set) var virtualMachine: VZVirtualMachine?
    var onEvent: (@MainActor (VMRuntimeEvent) -> Void)?
    private(set) var supportsSaveRestore = false

    private var sharedFolderURL: URL?
    private var serialOutput: FileHandle?
    private var clipboardBridge: GuestClipboardBridge?
    private var runLock: VMRunLock?
    private let logger = Logger(subsystem: "com.aayush.omabox", category: "VirtualMachine")

    func start(installation: GuestInstallation, preferences: VMPreferences) async throws {
        guard VZVirtualMachine.isSupported else { throw VMConfigurationError.unsupportedHost }
        guard virtualMachine == nil, runLock == nil else { throw VMConfigurationError.alreadyRunning }
        for url in [installation.kernel, installation.initialRamdisk, installation.disk].compactMap({ $0 }) {
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw VMConfigurationError.missingFile(url.lastPathComponent)
            }
        }
        if preferences.microphoneEnabled,
           AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            throw VMConfigurationError.microphoneDenied
        }

        do {
            runLock = try VMRunLock(directory: installation.directory)
            let configuration = try configuration(installation: installation, preferences: preferences)
            try configuration.validate()
            supportsSaveRestore = (try? configuration.validateSaveRestoreSupport()) != nil
            let machine = VZVirtualMachine(configuration: configuration)
            machine.delegate = self
            virtualMachine = machine
            try await machine.start()
            if let socketDevice = machine.socketDevices.first as? VZVirtioSocketDevice {
                let bridge = GuestClipboardBridge(socketDevice: socketDevice)
                clipboardBridge = bridge
                bridge.setEnabled(preferences.clipboardEnabled)
            }
            logger.info("Linux virtual machine started")
        } catch {
            releaseResources()
            throw error
        }
    }

    func pause() async throws {
        guard let virtualMachine else { throw VMConfigurationError.noRunningMachine }
        try await virtualMachine.pause()
        clipboardBridge?.setPaused(true)
    }

    func resume() async throws {
        guard let virtualMachine else { throw VMConfigurationError.noRunningMachine }
        try await virtualMachine.resume()
        clipboardBridge?.setPaused(false)
    }

    func requestStop() throws {
        guard let virtualMachine else { throw VMConfigurationError.noRunningMachine }
        try virtualMachine.requestStop()
    }

    func forceStop() async throws {
        guard let virtualMachine else { throw VMConfigurationError.noRunningMachine }
        try await virtualMachine.stop()
        releaseResources()
    }

    func setClipboardEnabled(_ enabled: Bool) {
        clipboardBridge?.setEnabled(enabled)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        logger.info("Linux guest shut down")
        releaseResources()
        onEvent?(.stopped)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        logger.error("Linux guest stopped: \(error.localizedDescription, privacy: .public)")
        releaseResources()
        onEvent?(.failed(error.localizedDescription))
    }

    private func configuration(installation: GuestInstallation, preferences: VMPreferences) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        let bootLoader = VZLinuxBootLoader(kernelURL: installation.kernel)
        bootLoader.initialRamdiskURL = installation.initialRamdisk
        bootLoader.commandLine = ([installation.commandLine] + preferences.guestBootArguments).joined(separator: " ")
        configuration.bootLoader = bootLoader
        configuration.cpuCount = preferences.cpuCount
        configuration.memorySize = UInt64(preferences.memoryGiB) * 1_073_741_824

        let platform = VZGenericPlatformConfiguration()
        if let identifier = preferences.machineIdentifier {
            guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: identifier) else {
                throw VMConfigurationError.invalidMachineIdentifier
            }
            platform.machineIdentifier = machineIdentifier
        }
        configuration.platform = platform

        let storage = try VZDiskImageStorageDeviceAttachment(
            url: installation.disk,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .full
        )
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: storage)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        if let address = preferences.macAddress {
            guard let macAddress = VZMACAddress(string: address) else {
                throw VMConfigurationError.invalidMACAddress
            }
            network.macAddress = macAddress
        }
        configuration.networkDevices = [network]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1_440, heightInPixels: 900)]
        configuration.graphicsDevices = [graphics]

        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        var streams: [VZVirtioSoundDeviceStreamConfiguration] = [output]
        if preferences.microphoneEnabled {
            let input = VZVirtioSoundDeviceInputStreamConfiguration()
            input.source = VZHostAudioInputStreamSource()
            streams.append(input)
        }
        sound.streams = streams
        configuration.audioDevices = [sound]

        let fileSystem = VZVirtioFileSystemDeviceConfiguration(tag: "omabox")
        if let bookmark = preferences.sharedFolderBookmark {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
            guard !stale, url.startAccessingSecurityScopedResource() else {
                throw VMConfigurationError.unavailableSharedFolder
            }
            sharedFolderURL = url
            fileSystem.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: url, readOnly: preferences.sharedFolderReadOnly))
        } else {
            fileSystem.share = VZMultipleDirectoryShare()
        }
        configuration.directorySharingDevices = [fileSystem]

        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        let logURL = installation.directory.appending(path: "console.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: logURL)
        serialOutput = outputHandle
        console.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: outputHandle)
        configuration.serialPorts = [console]
        return configuration
    }

    private func releaseResources() {
        clipboardBridge?.stop()
        clipboardBridge = nil
        virtualMachine = nil
        sharedFolderURL?.stopAccessingSecurityScopedResource()
        sharedFolderURL = nil
        try? serialOutput?.close()
        serialOutput = nil
        runLock = nil
    }
}
