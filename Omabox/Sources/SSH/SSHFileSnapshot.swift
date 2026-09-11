import Darwin
import Foundation

nonisolated struct SSHFileSnapshot: Equatable {
    var data: Data
    var mode: mode_t
    var device: dev_t
    var inode: ino_t
}
