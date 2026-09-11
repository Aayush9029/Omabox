import Darwin
import Foundation

nonisolated final class VMRunLock {
    private let descriptor: Int32

    init(directory: URL) throws {
        let url = directory.appending(path: "run.lock")
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var result: Int32
        repeat {
            result = flock(descriptor, LOCK_EX | LOCK_NB)
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK || failure == EAGAIN {
                throw VMConfigurationError.alreadyRunning
            }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
