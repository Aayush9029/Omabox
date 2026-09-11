import Dependencies
import Foundation
import IdentifiedCollections

actor SSHFilesProvider {
    @Dependency(\.uuid) private var uuid

    func publicKeys(in url: URL) throws -> IdentifiedArrayOf<SSHPublicKey> {
        try Task.checkCancellation()
        let directory = try SSHDirectory(url: url)
        var keys: IdentifiedArrayOf<SSHPublicKey> = []
        for name in try directory.publicKeyNames() {
            try Task.checkCancellation()
            do {
                guard let snapshot = try directory.read(name, limit: SSHKeyParser.maximumBytes) else { continue }
                keys.append(try SSHKeyParser.parse(snapshot.data, fileName: name))
            } catch is SSHFileError {
                continue
            }
        }
        return keys
    }

    func install(
        in url: URL, key: SSHPublicKey, alias: String, endpoint: SSHEndpoint, previous: SSHManagedFiles?
    ) throws -> SSHManagedFiles {
        try Task.checkCancellation()
        guard SSHConfiguration.isValidAlias(alias) else { throw SSHFileError.invalidAlias }
        guard key.fileName.hasSuffix(".pub"), key.fileName.count > 4 else {
            throw SSHFileError.invalidPublicKey(key.fileName)
        }
        try SSHConfiguration.validate(endpoint)
        let directory = try SSHDirectory(url: url)
        guard let publicKey = try directory.read(key.fileName, limit: SSHKeyParser.maximumBytes),
              try SSHKeyParser.parse(publicKey.data, fileName: key.fileName) == key else {
            throw SSHFileError.publicKeyChanged
        }
        let hostKey = try SSHKeyParser.parse(
            Data(endpoint.hostPublicKey.utf8), fileName: "Linux host key", hostKeyOnly: true
        )
        let configuration = try directory.read("config", limit: SSHConfiguration.maximumBytes)
        let include = try directory.read(SSHConfiguration.includeFileName, limit: SSHConfiguration.maximumBytes)
        let knownHosts = try directory.read(SSHConfiguration.knownHostsFileName, limit: SSHConfiguration.maximumBytes)
        let base: Data
        if let previous {
            base = try validateOwnership(
                in: directory, managed: previous, configuration: configuration, include: include, knownHosts: knownHosts
            )
        } else {
            guard include == nil else { throw SSHFileError.ownershipConflict(SSHConfiguration.includeFileName) }
            guard knownHosts == nil else { throw SSHFileError.ownershipConflict(SSHConfiguration.knownHostsFileName) }
            base = configuration?.data ?? Data()
            guard base.range(of: Data(SSHConfiguration.prefix(in: url).utf8)) == nil else {
                throw SSHFileError.ownershipConflict("config")
            }
        }
        try SSHConfiguration.validateNoCollision(in: base, alias: alias)
        let prefix = SSHConfiguration.prefix(in: url)
        let profile = SSHConfiguration.profile(in: url, key: key, alias: alias, endpoint: endpoint)
        let pinnedKey = Data("\(alias) \(hostKey.canonicalText)\n".utf8)
        let desiredConfiguration = Data(prefix.utf8) + base
        guard desiredConfiguration.count <= SSHConfiguration.maximumBytes else {
            throw SSHFileError.fileTooLarge("config")
        }
        var mutations: [SSHFileMutation] = []
        do {
            try update(SSHConfiguration.knownHostsFileName, data: pinnedKey, previous: knownHosts, in: directory, mutations: &mutations)
            try update(SSHConfiguration.includeFileName, data: profile, previous: include, in: directory, mutations: &mutations)
            try update("config", data: desiredConfiguration, previous: configuration, in: directory, mutations: &mutations)
        } catch {
            let failures = rollback(mutations, in: directory)
            if !failures.isEmpty { throw SSHFileError.incompleteRollback(failures) }
            throw error
        }
        return SSHManagedFiles(
            alias: alias,
            includeFileName: SSHConfiguration.includeFileName,
            includeSHA256: SSHKeyParser.sha256(profile),
            knownHostsFileName: SSHConfiguration.knownHostsFileName,
            knownHostsSHA256: SSHKeyParser.sha256(pinnedKey),
            configurationPrefix: prefix,
            configurationPrefixSHA256: SSHKeyParser.sha256(Data(prefix.utf8)),
            configurationWasCreated: previous?.configurationWasCreated ?? (configuration == nil)
        )
    }

    func remove(in url: URL, managed: SSHManagedFiles) throws {
        try Task.checkCancellation()
        let directory = try SSHDirectory(url: url)
        let configuration = try directory.read("config", limit: SSHConfiguration.maximumBytes)
        let include = try directory.read(SSHConfiguration.includeFileName, limit: SSHConfiguration.maximumBytes)
        let knownHosts = try directory.read(SSHConfiguration.knownHostsFileName, limit: SSHConfiguration.maximumBytes)
        let base = try validateOwnership(
            in: directory, managed: managed, configuration: configuration, include: include, knownHosts: knownHosts
        )
        var mutations: [SSHFileMutation] = []
        do {
            if managed.configurationWasCreated && base.isEmpty, let configuration {
                try directory.remove("config", expected: configuration)
                mutations.append(SSHFileMutation(name: "config", before: configuration, after: nil))
            } else {
                try update("config", data: base, previous: configuration, in: directory, mutations: &mutations)
            }
            if let include {
                try directory.remove(SSHConfiguration.includeFileName, expected: include)
                mutations.append(SSHFileMutation(name: SSHConfiguration.includeFileName, before: include, after: nil))
            }
            if let knownHosts {
                try directory.remove(SSHConfiguration.knownHostsFileName, expected: knownHosts)
                mutations.append(SSHFileMutation(name: SSHConfiguration.knownHostsFileName, before: knownHosts, after: nil))
            }
        } catch {
            let failures = rollback(mutations, in: directory)
            if !failures.isEmpty { throw SSHFileError.incompleteRollback(failures) }
            throw error
        }
    }

    private func validateOwnership(
        in directory: SSHDirectory,
        managed: SSHManagedFiles,
        configuration: SSHFileSnapshot?,
        include: SSHFileSnapshot?,
        knownHosts: SSHFileSnapshot?
    ) throws -> Data {
        guard managed.includeFileName == SSHConfiguration.includeFileName,
              managed.knownHostsFileName == SSHConfiguration.knownHostsFileName,
              SSHConfiguration.isValidAlias(managed.alias),
              managed.configurationPrefix == SSHConfiguration.prefix(in: directory.url),
              SSHKeyParser.sha256(Data(managed.configurationPrefix.utf8)) == managed.configurationPrefixSHA256 else {
            throw SSHFileError.ownershipConflict("Omabox ownership record")
        }
        guard let include, SSHKeyParser.sha256(include.data) == managed.includeSHA256 else {
            throw SSHFileError.ownershipConflict(SSHConfiguration.includeFileName)
        }
        guard let knownHosts, SSHKeyParser.sha256(knownHosts.data) == managed.knownHostsSHA256 else {
            throw SSHFileError.ownershipConflict(SSHConfiguration.knownHostsFileName)
        }
        let prefix = Data(managed.configurationPrefix.utf8)
        guard let configuration, configuration.data.starts(with: prefix) else {
            throw SSHFileError.ownershipConflict("config")
        }
        return Data(configuration.data.dropFirst(prefix.count))
    }

    private func update(
        _ name: String, data: Data, previous: SSHFileSnapshot?,
        in directory: SSHDirectory, mutations: inout [SSHFileMutation]
    ) throws {
        try Task.checkCancellation()
        guard previous?.data != data else {
            try directory.verify(name, expected: previous)
            return
        }
        let next = try directory.replace(name, with: data, expected: previous, temporaryName: temporaryName())
        mutations.append(SSHFileMutation(name: name, before: previous, after: next))
    }

    private func rollback(_ mutations: [SSHFileMutation], in directory: SSHDirectory) -> [String] {
        var failures: [String] = []
        for mutation in mutations.reversed() {
            do {
                if let before = mutation.before {
                    _ = try directory.replace(
                        mutation.name, with: before.data, expected: mutation.after,
                        temporaryName: temporaryName(), checkCancellation: false,
                        restoringMode: before.mode
                    )
                } else if let after = mutation.after {
                    try directory.remove(mutation.name, expected: after, checkCancellation: false)
                }
            } catch {
                failures.append(mutation.name)
            }
        }
        return failures.sorted()
    }

    private func temporaryName() -> String { ".omabox-\(uuid().uuidString).tmp" }
}
