import Foundation

nonisolated struct SSHFileMutation {
    var name: String
    var before: SSHFileSnapshot?
    var after: SSHFileSnapshot?
}
