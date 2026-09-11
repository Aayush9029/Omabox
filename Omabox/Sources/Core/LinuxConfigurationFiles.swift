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
            do {
                try Data().write(to: url, options: .withoutOverwriting)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch CocoaError.fileWriteFileExists {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw LinuxConfigurationError.invalidFile(file.fileName)
                }
            }
        }
        return directory
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
