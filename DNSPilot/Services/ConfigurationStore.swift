import CryptoKit
import Darwin
import Foundation

struct AppConfigurationFingerprint: RawRepresentable, Codable, Hashable, Sendable {
    private static let encodedLength = 64

    let rawValue: String

    init?(rawValue: String) {
        guard
            rawValue.utf8.count == Self.encodedLength,
            rawValue.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            })
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    init(data: Data) {
        rawValue = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let fingerprint = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a 64-character lowercase SHA-256 fingerprint."
            )
        }
        self = fingerprint
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct PersistedAppConfiguration: Equatable, Sendable {
    let value: AppConfiguration
    let data: Data
    let fingerprint: AppConfigurationFingerprint

    init(data: Data) throws {
        let value = try JSONDecoder().decode(AppConfiguration.self, from: data)
        try self.init(value: value)
    }

    init(value: AppConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        self.value = value
        self.data = data
        fingerprint = AppConfigurationFingerprint(data: data)
    }
}

enum ConfigurationLoadResult: Equatable, Sendable {
    case missing(initial: PersistedAppConfiguration)
    case loaded(PersistedAppConfiguration)
    case newerSchema(version: Int)
    case unsupportedSchema(version: Int)
    case corrupt(recoveryArtifactURL: URL)
}

enum ConfigurationStoreError: LocalizedError, Equatable, Sendable {
    case compareAndSwapConflict
    case inconsistentPersistedConfiguration
    case recoveryArtifactConflict

    var errorDescription: String? {
        switch self {
        case .compareAndSwapConflict:
            "The app configuration changed before it could be saved."
        case .inconsistentPersistedConfiguration:
            "The persisted app configuration does not match its canonical value."
        case .recoveryArtifactConflict:
            "The app configuration recovery artifact does not match the corrupt source."
        }
    }
}

protocol ConfigurationStoring: Sendable {
    func load() throws -> ConfigurationLoadResult
    func encode(_ value: AppConfiguration) throws -> PersistedAppConfiguration
    func commit(
        _ configuration: PersistedAppConfiguration,
        replacing expected: AppConfigurationFingerprint?
    ) throws
}

protocol ConfigurationFileSystem: Sendable {
    func createDirectory(at url: URL) throws
    func itemExists(at url: URL) -> Bool
    func readFile(at url: URL) throws -> Data
    func createFile(at url: URL, data: Data, permissions: UInt16) throws
    func synchronizeFile(at url: URL) throws
    func replaceAtomically(itemAt destinationURL: URL, withItemAt sourceURL: URL) throws
    func synchronizeDirectory(at url: URL) throws
    func removeFileIfPresent(at url: URL) throws
}

struct LocalConfigurationFileSystem: ConfigurationFileSystem {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func readFile(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func createFile(at url: URL, data: Data, permissions: UInt16) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(permissions))
        }
        guard descriptor >= 0 else { throw posixError() }

        do {
            try data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        buffer.count - offset
                    )
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw posixError()
                    }
                    guard written > 0 else { throw posixError(EIO) }
                    offset += written
                }
            }
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }

        guard Darwin.close(descriptor) == 0 else { throw posixError() }
    }

    func synchronizeFile(at url: URL) throws {
        try synchronizeDescriptor(at: url, fullSync: true)
    }

    func replaceAtomically(itemAt destinationURL: URL, withItemAt sourceURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw posixError() }
    }

    func synchronizeDirectory(at url: URL) throws {
        try synchronizeDescriptor(at: url, fullSync: false)
    }

    func removeFileIfPresent(at url: URL) throws {
        let result = url.path.withCString { Darwin.unlink($0) }
        guard result == 0 || errno == ENOENT else { throw posixError() }
    }

    private func synchronizeDescriptor(at url: URL, fullSync: Bool) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw posixError() }
        let result = fullSync
            ? Darwin.fcntl(descriptor, F_FULLFSYNC)
            : Darwin.fsync(descriptor)
        guard result == 0 else {
            let error = posixError()
            _ = Darwin.close(descriptor)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else { throw posixError() }
    }
}

struct ConfigurationStore: ConfigurationStoring {
    static let configurationFileName = "configuration.json"
    private static let processLock = NSLock()

    let directoryURL: URL
    private let fileSystem: any ConfigurationFileSystem

    var configurationURL: URL {
        directoryURL.appendingPathComponent(Self.configurationFileName, isDirectory: false)
    }

    init(
        directoryURL: URL,
        fileSystem: any ConfigurationFileSystem = LocalConfigurationFileSystem()
    ) {
        self.directoryURL = directoryURL
        self.fileSystem = fileSystem
    }

    static func live() throws -> Self {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryName = Bundle.main.bundleIdentifier ?? "DNSPilot"
        return Self(
            directoryURL: applicationSupport.appendingPathComponent(
                directoryName,
                isDirectory: true
            )
        )
    }

    func load() throws -> ConfigurationLoadResult {
        try prepareDirectory()
        return try withExclusiveDirectoryLock {
            try loadUnlocked()
        }
    }

    private func loadUnlocked() throws -> ConfigurationLoadResult {
        guard fileSystem.itemExists(at: configurationURL) else {
            return .missing(initial: try encode(AppConfiguration()))
        }

        let sourceData = try fileSystem.readFile(at: configurationURL)
        let schemaVersion: Int
        do {
            schemaVersion = try JSONDecoder().decode(
                SchemaEnvelope.self,
                from: sourceData
            ).schemaVersion
        } catch {
            return .corrupt(
                recoveryArtifactURL: try preserveCorruptSource(sourceData)
            )
        }

        if schemaVersion > AppConfiguration.currentSchemaVersion {
            return .newerSchema(version: schemaVersion)
        }
        guard schemaVersion >= 1 else {
            return .unsupportedSchema(version: schemaVersion)
        }

        do {
            return .loaded(try PersistedAppConfiguration(data: sourceData))
        } catch {
            return .corrupt(
                recoveryArtifactURL: try preserveCorruptSource(sourceData)
            )
        }
    }

    func encode(_ value: AppConfiguration) throws -> PersistedAppConfiguration {
        try PersistedAppConfiguration(value: value)
    }

    func commit(
        _ configuration: PersistedAppConfiguration,
        replacing expected: AppConfigurationFingerprint?
    ) throws {
        try prepareDirectory()
        try withExclusiveDirectoryLock {
            try commitUnlocked(configuration, replacing: expected)
        }
    }

    private func commitUnlocked(
        _ configuration: PersistedAppConfiguration,
        replacing expected: AppConfigurationFingerprint?
    ) throws {
        guard try encode(configuration.value) == configuration else {
            throw ConfigurationStoreError.inconsistentPersistedConfiguration
        }

        if fileSystem.itemExists(at: configurationURL) {
            guard
                let expected,
                let current = try? PersistedAppConfiguration(
                    data: fileSystem.readFile(at: configurationURL)
                ),
                current.fingerprint == expected
            else {
                throw ConfigurationStoreError.compareAndSwapConflict
            }
        } else if expected != nil {
            throw ConfigurationStoreError.compareAndSwapConflict
        }

        try writeAtomically(configuration)
    }

    func replaceCorruptConfiguration(
        with value: AppConfiguration,
        matching recoveryArtifactURL: URL
    ) throws {
        try prepareDirectory()
        try withExclusiveDirectoryLock {
            let sourceData = try fileSystem.readFile(at: configurationURL)
            let artifactData = try fileSystem.readFile(at: recoveryArtifactURL)
            guard case let .corrupt(currentArtifactURL) = try loadUnlocked(),
                  currentArtifactURL.standardizedFileURL == recoveryArtifactURL.standardizedFileURL,
                  sourceData == artifactData else {
                throw ConfigurationStoreError.recoveryArtifactConflict
            }
            try writeAtomically(encode(value))
        }
    }

    private func writeAtomically(_ configuration: PersistedAppConfiguration) throws {
        let temporaryURL = directoryURL.appendingPathComponent(
            ".configuration.\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileSystem.removeFileIfPresent(at: temporaryURL) }

        try fileSystem.createFile(
            at: temporaryURL,
            data: configuration.data,
            permissions: 0o600
        )
        try fileSystem.synchronizeFile(at: temporaryURL)
        try fileSystem.replaceAtomically(
            itemAt: configurationURL,
            withItemAt: temporaryURL
        )
        try fileSystem.synchronizeDirectory(at: directoryURL)
    }

    private func preserveCorruptSource(_ data: Data) throws -> URL {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let artifactURL = directoryURL.appendingPathComponent(
            "configuration.corrupt.\(digest).json",
            isDirectory: false
        )
        if fileSystem.itemExists(at: artifactURL) {
            guard try fileSystem.readFile(at: artifactURL) == data else {
                throw ConfigurationStoreError.recoveryArtifactConflict
            }
            return artifactURL
        }
        do {
            try fileSystem.createFile(at: artifactURL, data: data, permissions: 0o600)
            try fileSystem.synchronizeFile(at: artifactURL)
            try fileSystem.synchronizeDirectory(at: directoryURL)
            return artifactURL
        } catch {
            try? fileSystem.removeFileIfPresent(at: artifactURL)
            throw error
        }
    }

    private func prepareDirectory() throws {
        let existed = fileSystem.itemExists(at: directoryURL)
        try fileSystem.createDirectory(at: directoryURL)
        if !existed {
            try fileSystem.synchronizeDirectory(
                at: directoryURL.deletingLastPathComponent()
            )
        }
    }

    private func withExclusiveDirectoryLock<T>(
        _ operation: () throws -> T
    ) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let lockURL = directoryURL.appendingPathComponent(
            ".configuration.lock",
            isDirectory: false
        )
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw posixError() }

        var lock = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        while Darwin.fcntl(descriptor, F_SETLKW, &lock) != 0 {
            guard errno == EINTR else {
                let error = posixError()
                _ = Darwin.close(descriptor)
                throw error
            }
        }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
            _ = Darwin.close(descriptor)
        }
        return try operation()
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }
}

private func posixError(_ code: Int32 = errno) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}
