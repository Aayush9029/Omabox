import Foundation

nonisolated enum SSHFileError: LocalizedError, Equatable {
    case invalidDirectory
    case unsupportedPath
    case unsafeFile(String)
    case fileTooLarge(String)
    case tooManyFiles
    case invalidPublicKey(String)
    case publicKeyChanged
    case invalidAlias
    case invalidEndpoint
    case configurationConflict(String)
    case ownershipConflict(String)
    case directoryBusy
    case incompleteRollback([String])

    var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            "Choose a folder owned by your Mac account. The folder must not be a symbolic link or writable by other accounts."
        case .unsupportedPath:
            "This folder or filename contains characters that SSH expands. Choose a path without quotes, backslashes, wildcards, percent signs, dollar signs, or control characters."
        case let .unsafeFile(name):
            "Omabox cannot safely use \(name). Choose a regular file owned by your account, without symbolic or hard links."
        case let .fileTooLarge(name):
            "The file \(name) exceeds the supported size."
        case .tooManyFiles:
            "This folder contains too many files. Choose your SSH folder or a separate folder for Omabox."
        case let .invalidPublicKey(name):
            "The file \(name) is not a supported OpenSSH Ed25519, RSA, or ECDSA public key."
        case .publicKeyChanged:
            "The selected public key changed. Select it again before enabling SSH."
        case .invalidAlias:
            "Use an SSH name beginning with a letter or number, followed by up to 62 letters, numbers, dots, underscores, or hyphens."
        case .invalidEndpoint:
            "The Linux SSH endpoint or host key is invalid. Restart Linux and try again."
        case let .configurationConflict(reason):
            "Your SSH configuration \(reason). Choose another name or a separate folder for Omabox."
        case let .ownershipConflict(name):
            "The file \(name) already exists or was changed outside Omabox. Omabox has left it untouched."
        case .directoryBusy:
            "Another operation is updating this SSH folder. Try again when it finishes."
        case let .incompleteRollback(names):
            "Omabox could not restore these files after an interrupted update: \(names.joined(separator: ", ")). Review those files in your selected SSH folder before trying again."
        }
    }
}
