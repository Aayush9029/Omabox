import CryptoKit
import Foundation

nonisolated enum SSHKeyParser {
    static let maximumBytes = 16_384

    static func parse(_ data: Data, fileName: String, hostKeyOnly: Bool = false) throws -> SSHPublicKey {
        guard data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8),
              !text.contains("\0") else { throw SSHFileError.invalidPublicKey(fileName) }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.contains(where: { $0.isNewline }) else {
            throw SSHFileError.invalidPublicKey(fileName)
        }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2,
              let blob = Data(base64Encoded: String(fields[1])),
              blob.base64EncodedString() == fields[1] else {
            throw SSHFileError.invalidPublicKey(fileName)
        }
        let algorithm = String(fields[0])
        guard !hostKeyOnly || algorithm == "ssh-ed25519" else {
            throw SSHFileError.invalidPublicKey(fileName)
        }
        var reader = SSHWireReader(data: blob, fileName: fileName)
        guard try reader.string() == Data(algorithm.utf8) else {
            throw SSHFileError.invalidPublicKey(fileName)
        }
        do {
            switch algorithm {
            case "ssh-ed25519":
                let key = try reader.string()
                guard key.count == 32 else { throw SSHFileError.invalidPublicKey(fileName) }
                _ = try Curve25519.Signing.PublicKey(rawRepresentation: key)
            case "ssh-rsa":
                let exponent = try positiveInteger(reader.string(), fileName: fileName)
                let modulus = try positiveInteger(reader.string(), fileName: fileName)
                guard exponent.count <= 8, exponent.last.map({ $0 & 1 == 1 }) == true,
                      exponent.count > 1 || exponent[0] >= 3,
                      modulus.last.map({ $0 & 1 == 1 }) == true else {
                    throw SSHFileError.invalidPublicKey(fileName)
                }
                let bitCount = modulus.count * 8 - modulus[0].leadingZeroBitCount
                guard (2048...16_384).contains(bitCount) else {
                    throw SSHFileError.invalidPublicKey(fileName)
                }
            case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
                let curve = String(algorithm.dropFirst("ecdsa-sha2-".count))
                guard try reader.string() == Data(curve.utf8) else {
                    throw SSHFileError.invalidPublicKey(fileName)
                }
                let point = try reader.string()
                switch curve {
                case "nistp256": _ = try P256.Signing.PublicKey(x963Representation: point)
                case "nistp384": _ = try P384.Signing.PublicKey(x963Representation: point)
                default: _ = try P521.Signing.PublicKey(x963Representation: point)
                }
            default:
                throw SSHFileError.invalidPublicKey(fileName)
            }
        } catch {
            throw SSHFileError.invalidPublicKey(fileName)
        }
        guard reader.isAtEnd else { throw SSHFileError.invalidPublicKey(fileName) }
        return SSHPublicKey(
            fileName: fileName,
            canonicalText: "\(algorithm) \(blob.base64EncodedString())",
            fingerprint: "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func positiveInteger(_ data: Data, fileName: String) throws -> [UInt8] {
        let bytes = [UInt8](data)
        guard let first = bytes.first, first < 128 else {
            throw SSHFileError.invalidPublicKey(fileName)
        }
        if first == 0 {
            guard bytes.count > 1, bytes[1] >= 128 else {
                throw SSHFileError.invalidPublicKey(fileName)
            }
            return Array(bytes.dropFirst())
        }
        return bytes
    }
}
