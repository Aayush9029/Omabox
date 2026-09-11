import Darwin
import Foundation

nonisolated final class SSHDirectory {
    let url: URL
    private let descriptor: Int32

    init(url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw SSHFileError.invalidDirectory }
        try Self.validatePath(url.path)
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SSHFileError.invalidDirectory }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_uid == geteuid(), attributes.st_mode & 0o022 == 0 else {
            close(descriptor)
            throw SSHFileError.invalidDirectory
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw SSHFileError.directoryBusy
        }
        self.url = url
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func validatePath(_ path: String) throws {
        guard !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              path.rangeOfCharacter(from: CharacterSet(charactersIn: "\"\\*?[]%$~")) == nil else {
            throw SSHFileError.unsupportedPath
        }
    }

    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              name.utf8.count <= 255 else { throw SSHFileError.unsafeFile(name) }
        try validatePath(name)
    }

    func publicKeyNames() throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw posixError() }
        guard let stream = fdopendir(duplicate) else {
            close(duplicate)
            throw posixError()
        }
        defer { closedir(stream) }
        var names: [String] = []
        var count = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw posixError() }
                break
            }
            count += 1
            guard count <= 4096 else { throw SSHFileError.tooManyFiles }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name.hasSuffix(".pub"), name.count > 4 { names.append(name) }
        }
        return names.sorted()
    }

    func read(_ name: String, limit: Int, checkCancellation: Bool = true) throws -> SSHFileSnapshot? {
        try Self.validateName(name)
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw SSHFileError.unsafeFile(name)
        }
        defer { close(file) }
        var before = stat()
        guard fstat(file, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o022 == 0 else { throw SSHFileError.unsafeFile(name) }
        guard before.st_size >= 0, before.st_size <= limit else {
            throw SSHFileError.fileTooLarge(name)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(limit + 1, 16_384))
        while true {
            if checkCancellation { try Task.checkCancellation() }
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { break }
            guard data.count <= limit - count else { throw SSHFileError.fileTooLarge(name) }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(file, &after) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              data.count == before.st_size else { throw SSHFileError.ownershipConflict(name) }
        return SSHFileSnapshot(
            data: data, mode: before.st_mode & 0o777,
            device: before.st_dev, inode: before.st_ino
        )
    }

    func replace(
        _ name: String,
        with data: Data,
        expected: SSHFileSnapshot?,
        temporaryName: String,
        checkCancellation: Bool = true,
        restoringMode: mode_t? = nil
    ) throws -> SSHFileSnapshot {
        if checkCancellation { try Task.checkCancellation() }
        try Self.validateName(name)
        try Self.validateName(temporaryName)
        let file = openat(
            descriptor, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard file >= 0 else { throw posixError() }
        defer {
            close(file)
            unlinkat(descriptor, temporaryName, 0)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard fchmod(file, restoringMode ?? expected?.mode ?? mode_t(0o600)) == 0, fsync(file) == 0 else {
            throw posixError()
        }
        var stagedAttributes = stat()
        guard fstat(file, &stagedAttributes) == 0 else { throw posixError() }
        try verify(name, expected: expected, checkCancellation: checkCancellation)
        if checkCancellation { try Task.checkCancellation() }
        let result: Int32
        if expected == nil {
            result = renameatx_np(descriptor, temporaryName, descriptor, name, UInt32(RENAME_EXCL))
        } else {
            result = renameat(descriptor, temporaryName, descriptor, name)
        }
        guard result == 0 else {
            if errno == EEXIST { throw SSHFileError.ownershipConflict(name) }
            throw posixError()
        }
        return SSHFileSnapshot(
            data: data, mode: stagedAttributes.st_mode & 0o777,
            device: stagedAttributes.st_dev, inode: stagedAttributes.st_ino
        )
    }

    func remove(_ name: String, expected: SSHFileSnapshot, checkCancellation: Bool = true) throws {
        try verify(name, expected: expected, checkCancellation: checkCancellation)
        if checkCancellation { try Task.checkCancellation() }
        guard unlinkat(descriptor, name, 0) == 0 else { throw posixError() }
    }

    func verify(_ name: String, expected: SSHFileSnapshot?, checkCancellation: Bool = true) throws {
        guard try read(name, limit: 1_048_576, checkCancellation: checkCancellation) == expected else {
            throw SSHFileError.ownershipConflict(name)
        }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
