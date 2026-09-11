import Darwin
import Foundation

nonisolated enum SSHConfiguration {
    static let includeFileName = "omabox.conf"
    static let knownHostsFileName = "omabox_known_hosts"
    static let maximumBytes = 1_048_576

    static func isValidAlias(_ alias: String) -> Bool {
        let bytes = Array(alias.utf8)
        guard (1...63).contains(bytes.count), let first = bytes.first,
              isASCIIAlphanumeric(first) else { return false }
        return bytes.allSatisfy { isASCIIAlphanumeric($0) || $0 == 46 || $0 == 95 || $0 == 45 }
    }

    static func prefix(in directory: URL) -> String {
        "Include \"\(directory.appending(path: includeFileName).path)\"\n"
    }

    static func validate(_ endpoint: SSHEndpoint) throws {
        let octets = endpoint.address.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { throw SSHFileError.invalidEndpoint }
        let numbers = octets.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0" else { return nil }
            return UInt8(part)
        }
        guard numbers.count == 4,
              numbers[0] == 10 || (numbers[0] == 172 && (16...31).contains(numbers[1]))
                || (numbers[0] == 192 && numbers[1] == 168),
              numbers[3] != 0, numbers[3] != 255,
              endpoint.port == 2222,
              isValidUser(endpoint.user) else { throw SSHFileError.invalidEndpoint }
        do {
            _ = try SSHKeyParser.parse(Data(endpoint.hostPublicKey.utf8), fileName: "Linux host key", hostKeyOnly: true)
        } catch {
            throw SSHFileError.invalidEndpoint
        }
    }

    static func profile(in directory: URL, key: SSHPublicKey, alias: String, endpoint: SSHEndpoint) -> Data {
        let identity = directory.appending(path: String(key.fileName.dropLast(4))).path
        let knownHosts = directory.appending(path: knownHostsFileName).path
        return Data("""
        Host \(alias)
            HostName \(endpoint.address)
            User \(endpoint.user)
            Port \(endpoint.port)
            IdentityFile "\(identity)"
            IdentitiesOnly yes
            PreferredAuthentications publickey
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            HostKeyAlias \(alias)
            HostKeyAlgorithms ssh-ed25519
            StrictHostKeyChecking yes
            UserKnownHostsFile "\(knownHosts)"
            GlobalKnownHostsFile /dev/null
            KnownHostsCommand none
            UpdateHostKeys no
            CheckHostIP no
            CanonicalizeHostname no
            ProxyCommand none
            ProxyJump none
            RemoteCommand none
            PermitLocalCommand no
            ControlMaster no
            ControlPath none
            ControlPersist no
            ForwardAgent no
            ForwardX11 no
        Host *

        """.utf8)
    }

    static func validateNoCollision(in data: Data, alias: String) throws {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw SSHFileError.configurationConflict("is not valid UTF-8 text")
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let keyword = trimmed.prefix(while: { $0 != " " && $0 != "\t" && $0 != "=" })
            guard keyword.lowercased() == "host" else { continue }
            let remainder = trimmed.dropFirst(keyword.count).drop(while: { $0 == " " || $0 == "\t" || $0 == "=" })
            let patterns = try hostPatterns(String(remainder))
            let excluded = patterns.contains { $0.hasPrefix("!") && matches(String($0.dropFirst()), alias) }
            if !excluded, patterns.contains(where: { !$0.hasPrefix("!") && $0 != "*" && matches($0, alias) }) {
                throw SSHFileError.configurationConflict("already contains a Host pattern matching \(alias)")
            }
        }
    }

    private static func hostPatterns(_ text: String) throws -> [String] {
        var patterns: [String] = []
        var token = ""
        var quoted = false
        var escaped = false
        for character in text {
            if escaped {
                token.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == "#", !quoted {
                break
            } else if (character == " " || character == "\t"), !quoted {
                if !token.isEmpty { patterns.append(token); token = "" }
            } else {
                token.append(character)
            }
        }
        guard !quoted, !escaped else {
            throw SSHFileError.configurationConflict("contains an incomplete Host pattern")
        }
        if !token.isEmpty { patterns.append(token) }
        guard !patterns.isEmpty else {
            throw SSHFileError.configurationConflict("contains an empty Host pattern")
        }
        return patterns
    }

    private static func matches(_ pattern: String, _ alias: String) -> Bool {
        fnmatch(pattern.lowercased(), alias.lowercased(), 0) == 0
    }

    private static func isASCIIAlphanumeric(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
    }

    private static func isValidUser(_ user: String) -> Bool {
        guard user != "root", !user.isEmpty, user.utf8.count <= 32 else { return false }
        let bytes = Array((user.hasSuffix("$") ? String(user.dropLast()) : user).utf8)
        guard let first = bytes.first, (97...122).contains(first) || first == 95 else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }
    }
}
