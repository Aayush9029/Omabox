import AppKit
import Darwin
import Foundation
import OSLog
import Virtualization

nonisolated struct ClipboardMessage: Codable, Equatable, Sendable {
    var type: String
    var text: String?
    var version: Int?
}

nonisolated struct ClipboardFrameDecoder: Sendable {
    static let maximumTextBytes = 65_536
    static let maximumFrameBytes = 524_288
    private var bufferedData = Data()

    mutating func append(_ data: Data) throws -> [ClipboardMessage] {
        bufferedData.append(data)
        var messages: [ClipboardMessage] = []
        while let newline = bufferedData.firstIndex(of: 10) {
            guard newline - bufferedData.startIndex <= Self.maximumFrameBytes else {
                throw ClipboardProtocolError.oversizedFrame
            }
            let frame = bufferedData[..<newline]
            bufferedData.removeSubrange(...newline)
            let message = try JSONDecoder().decode(ClipboardMessage.self, from: frame)
            switch message.type {
            case "ready":
                guard message.version == 1 else { throw ClipboardProtocolError.unsupportedVersion }
            case "clipboard":
                guard let text = message.text, text.utf8.count <= Self.maximumTextBytes else {
                    throw ClipboardProtocolError.oversizedText
                }
            default:
                throw ClipboardProtocolError.unrecognizedMessage
            }
            messages.append(message)
        }
        guard bufferedData.count <= Self.maximumFrameBytes else {
            throw ClipboardProtocolError.oversizedFrame
        }
        return messages
    }
}

nonisolated enum ClipboardProtocolError: Error {
    case oversizedFrame
    case oversizedText
    case unsupportedVersion
    case unrecognizedMessage
}

@MainActor
final class GuestClipboardBridge {
    private let socketDevice: VZVirtioSocketDevice
    private var connection: VZVirtioSocketConnection?
    private var readSource: (any DispatchSourceRead)?
    private var connectionTask: Task<Void, Never>?
    private var decoder = ClipboardFrameDecoder()
    private var enabled = false
    private var paused = false
    private var isReady = false
    private var generation = 0
    private var lastChangeCount = 0
    private var lastText: String?
    private var pendingWrite = Data()
    private let logger = Logger(subsystem: "com.aayush.omabox", category: "Clipboard")

    init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        restartIfNeeded()
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        restartIfNeeded()
    }

    func stop() {
        enabled = false
        generation += 1
        connectionTask?.cancel()
        connectionTask = nil
        disconnect()
    }

    private func restartIfNeeded() {
        generation += 1
        connectionTask?.cancel()
        connectionTask = nil
        disconnect()
        guard enabled, !paused else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let currentGeneration = generation
        connectionTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, currentGeneration == generation {
                if connection == nil {
                    do {
                        let nextConnection = try await socketDevice.connect(toPort: 4_040)
                        guard !Task.isCancelled, currentGeneration == generation else {
                            nextConnection.close()
                            return
                        }
                        attach(nextConnection)
                    } catch {
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        continue
                    }
                }
                synchronizeHostClipboard()
                flushPendingWrite()
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            }
        }
    }

    private func attach(_ connection: VZVirtioSocketConnection) {
        self.connection = connection
        let descriptor = connection.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.receiveAvailableData()
            }
        }
        let closeConnection = { @MainActor in connection.close() }
        source.setCancelHandler {
            MainActor.assumeIsolated {
                closeConnection()
            }
        }
        readSource = source
        source.resume()
    }

    private func receiveAvailableData() {
        guard let connection else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var budget = ClipboardFrameDecoder.maximumFrameBytes + 16_384
        while budget > 0 {
            let count = recv(connection.fileDescriptor, &buffer, buffer.count, 0)
            if count == 0 {
                disconnect()
                return
            }
            if count < 0 {
                if errno != EAGAIN, errno != EWOULDBLOCK { disconnect() }
                return
            }
            budget -= count
            do {
                for message in try decoder.append(Data(buffer.prefix(count))) {
                    receive(message)
                }
            } catch {
                logger.error("Guest clipboard protocol rejected an invalid message")
                disconnect()
                return
            }
        }
    }

    private func receive(_ message: ClipboardMessage) {
        if message.type == "ready" {
            isReady = true
            return
        }
        guard isReady, enabled, !paused, NSApp.isActive,
              let text = message.text, text != lastText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastText = text
        lastChangeCount = pasteboard.changeCount
    }

    private func synchronizeHostClipboard() {
        guard isReady, enabled, !paused, NSApp.isActive else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string),
              text.utf8.count <= ClipboardFrameDecoder.maximumTextBytes,
              text != lastText else { return }
        guard pendingWrite.isEmpty else {
            lastChangeCount = -1
            return
        }
        do {
            pendingWrite = try JSONEncoder().encode(ClipboardMessage(type: "clipboard", text: text))
            pendingWrite.append(10)
            lastText = text
        } catch {
            logger.error("Unable to encode clipboard text")
        }
    }

    private func flushPendingWrite() {
        guard enabled, !paused, isReady, NSApp.isActive,
              let connection, !pendingWrite.isEmpty else { return }
        let count = pendingWrite.withUnsafeBytes { bytes in
            send(connection.fileDescriptor, bytes.baseAddress, bytes.count, 0)
        }
        if count > 0 {
            pendingWrite.removeFirst(count)
        } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK {
            disconnect()
        }
    }

    private func disconnect() {
        if let readSource {
            readSource.cancel()
        } else {
            connection?.close()
        }
        readSource = nil
        connection = nil
        decoder = ClipboardFrameDecoder()
        pendingWrite.removeAll(keepingCapacity: false)
        isReady = false
        lastText = nil
    }
}
