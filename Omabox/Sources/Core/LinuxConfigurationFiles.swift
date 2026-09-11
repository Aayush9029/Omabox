import Darwin
import Foundation

nonisolated enum LinuxConfigurationFiles {
    static var directoryURL: URL {
        if AppEnvironment.isUITesting {
            return URL.temporaryDirectory.appending(path: "Omabox-UITests/LinuxConfiguration", directoryHint: .isDirectory)
        }
        return URL.applicationSupportDirectory.appending(path: "Omabox/LinuxConfiguration", directoryHint: .isDirectory)
    }

    static func prepareDirectory(at directory: URL = directoryURL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw LinuxConfigurationError.invalidFolder
        }
        for file in LinuxConfigurationFile.allCases {
            let url = directory.appending(path: file.fileName)
            let header = switch file {
            case .environment: "# Add environment variables below as literal NAME=value lines.\n"
            case .desktop: "-- Add your Hyprland Lua settings below.\n"
            }
            let contents = Data(header.utf8)
            do {
                try contents.write(to: url, options: .withoutOverwriting)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch CocoaError.fileWriteFileExists {
                try seedEmptyFile(at: url, contents: contents, fileName: file.fileName)
            }
        }
        return directory
    }

    private static func seedEmptyFile(at url: URL, contents: Data, fileName: String) throws {
        guard try isEmptyRegularFile(at: url, fileName: fileName) else { return }
        var coordinationError: NSError?
        var writeError: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { coordinatedURL in
            do {
                guard try isEmptyRegularFile(at: coordinatedURL, fileName: fileName) else { return }
                try appendIfEmpty(at: coordinatedURL, contents: contents, fileName: fileName)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private static func isEmptyRegularFile(at url: URL, fileName: String) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LinuxConfigurationError.invalidFile(fileName)
        }
        return values.fileSize == 0
    }

    private static func appendIfEmpty(at url: URL, contents: Data, fileName: String) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw LinuxConfigurationError.invalidFile(fileName) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw LinuxConfigurationError.invalidFile(fileName)
        }
        guard metadata.st_size == 0 else { return }
        try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: contents)
    }
}

nonisolated enum LinuxConfigurationError: LocalizedError {
    case invalidFolder
    case invalidFile(String)
    case editorUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidFolder:
            "The Linux configuration folder must be a regular folder."
        case let .invalidFile(name):
            "\(name) must be a regular text file, rather than a link or folder."
        case .editorUnavailable:
            "TextEdit could not be found on this Mac."
        }
    }
}
