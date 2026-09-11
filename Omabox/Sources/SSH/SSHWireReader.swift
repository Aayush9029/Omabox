import Foundation

nonisolated struct SSHWireReader {
    var data: Data
    var fileName: String
    private var offset = 0

    init(data: Data, fileName: String) {
        self.data = data
        self.fileName = fileName
    }

    var isAtEnd: Bool { offset == data.count }

    mutating func string() throws -> Data {
        guard data.count - offset >= 4 else { throw SSHFileError.invalidPublicKey(fileName) }
        let length = data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        guard length <= data.count - offset else { throw SSHFileError.invalidPublicKey(fileName) }
        let result = data.subdata(in: offset..<offset + Int(length))
        offset += Int(length)
        return result
    }
}
