import CryptoKit
import Darwin
import Foundation

enum ProxyResumePhase: String, Codable, Equatable, Sendable {
    case preparedForQuit
    case disabledConfirmed
    case claimedForLaunch
    case failed
}

enum ProxyResumeFailureCode: String, Codable, Equatable, Sendable {
    case configurationChanged
    case extensionUnavailable
    case managerChanged
    case networkUnavailable
    case profileUnavailable
    case activationFailed
    case outcomeUncertain
}

struct ProxyResumeRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let operationID: UUID
    let attemptID: UUID?
    let phase: ProxyResumePhase
    let appConfigurationFingerprint: AppConfigurationFingerprint
    let providerBundleIdentifier: String
    let ownerConfigurationFingerprint: ProxyConfigurationFingerprint
    let activeGeneration: UUID
    let activeConfigurationFingerprint: ProxyConfigurationFingerprint
    let activeProfileID: DNSProfile.ID
    let failureCode: ProxyResumeFailureCode?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        operationID: UUID,
        attemptID: UUID? = nil,
        phase: ProxyResumePhase,
        appConfigurationFingerprint: AppConfigurationFingerprint,
        providerBundleIdentifier: String,
        ownerConfigurationFingerprint: ProxyConfigurationFingerprint,
        activeGeneration: UUID,
        activeConfigurationFingerprint: ProxyConfigurationFingerprint,
        activeProfileID: DNSProfile.ID,
        failureCode: ProxyResumeFailureCode? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.attemptID = attemptID
        self.phase = phase
        self.appConfigurationFingerprint = appConfigurationFingerprint
        self.providerBundleIdentifier = providerBundleIdentifier
        self.ownerConfigurationFingerprint = ownerConfigurationFingerprint
        self.activeGeneration = activeGeneration
        self.activeConfigurationFingerprint = activeConfigurationFingerprint
        self.activeProfileID = activeProfileID
        self.failureCode = failureCode
    }

    func updating(
        phase: ProxyResumePhase,
        attemptID: UUID? = nil,
        failureCode: ProxyResumeFailureCode? = nil
    ) -> Self {
        Self(
            schemaVersion: schemaVersion,
            operationID: operationID,
            attemptID: attemptID,
            phase: phase,
            appConfigurationFingerprint: appConfigurationFingerprint,
            providerBundleIdentifier: providerBundleIdentifier,
            ownerConfigurationFingerprint: ownerConfigurationFingerprint,
            activeGeneration: activeGeneration,
            activeConfigurationFingerprint: activeConfigurationFingerprint,
            activeProfileID: activeProfileID,
            failureCode: failureCode
        )
    }
}

enum ProxyResumeJournalCorruption: Equatable, Sendable {
    case invalidJSON
    case nonCanonicalJSON
    case checksumMismatch
    case invalidRecord
}

enum ProxyResumeJournalLoadResult: Equatable, Sendable {
    case missing
    case loaded(ProxyResumeRecord)
    case newerSchema(version: Int)
    case unsupportedSchema(version: Int)
    case corrupt(reason: ProxyResumeJournalCorruption, recoveryArtifactURL: URL)
}

enum ProxyResumeJournalError: LocalizedError, Equatable, Sendable {
    case activeRecordExists
    case operationConflict
    case phaseConflict
    case existingEvidenceRequiresRecovery
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .activeRecordExists:
            "Another DNS Proxy resume record is already active."
        case .operationConflict:
            "The DNS Proxy resume operation does not match the persisted record."
        case .phaseConflict:
            "The DNS Proxy resume phase cannot make the requested transition."
        case .existingEvidenceRequiresRecovery:
            "Existing DNS Proxy resume evidence requires recovery."
        case let .unsupportedSchema(version):
            "Unsupported DNS Proxy resume schema version: \(version)."
        }
    }
}

protocol ProxyResumeJournalStoring: Sendable {
    func load() throws -> ProxyResumeJournalLoadResult
    func prepare(_ record: ProxyResumeRecord) throws
    func confirmDisabled(operationID: UUID) throws
    func claim(operationID: UUID, attemptID: UUID) throws -> ProxyResumeRecord
    func markFailed(
        operationID: UUID,
        attemptID: UUID,
        code: ProxyResumeFailureCode
    ) throws
    func prepareRetry(operationID: UUID) throws -> ProxyResumeRecord
    func discard(operationID: UUID?) throws
}

struct ProxyResumeJournal: ProxyResumeJournalStoring {
    static let fileName = "proxy-resume.json"
    private static let processLock = NSLock()

    let directoryURL: URL
    private let fileSystem: any ConfigurationFileSystem

    var recordURL: URL {
        directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    init(
        directoryURL: URL,
        fileSystem: any ConfigurationFileSystem = LocalConfigurationFileSystem()
    ) {
        self.directoryURL = directoryURL
        self.fileSystem = fileSystem
    }

    func load() throws -> ProxyResumeJournalLoadResult {
        try withExclusiveLock {
            try loadUnlocked()
        }
    }

    func prepare(_ record: ProxyResumeRecord) throws {
        try withExclusiveLock {
            try prepareDirectory()
            guard record.schemaVersion == ProxyResumeRecord.currentSchemaVersion else {
                throw ProxyResumeJournalError.unsupportedSchema(record.schemaVersion)
            }
            guard record.phase == .preparedForQuit,
                  record.attemptID == nil,
                  record.failureCode == nil,
                  !record.providerBundleIdentifier.isEmpty else {
                throw ProxyResumeJournalError.phaseConflict
            }
            switch try loadUnlocked() {
            case .missing:
                try publish(record)
            case let .loaded(existing) where existing == record:
                return
            case .loaded:
                throw ProxyResumeJournalError.activeRecordExists
            case .newerSchema, .unsupportedSchema, .corrupt:
                throw ProxyResumeJournalError.existingEvidenceRequiresRecovery
            }
        }
    }

    func confirmDisabled(operationID: UUID) throws {
        try transition(operationID: operationID) { record in
            switch record.phase {
            case .preparedForQuit:
                return record.updating(phase: .disabledConfirmed)
            case .disabledConfirmed:
                return record
            case .claimedForLaunch, .failed:
                throw ProxyResumeJournalError.phaseConflict
            }
        }
    }

    func claim(operationID: UUID, attemptID: UUID) throws -> ProxyResumeRecord {
        var claimed: ProxyResumeRecord?
        try transition(operationID: operationID) { record in
            switch record.phase {
            case .preparedForQuit, .disabledConfirmed:
                let updated = record.updating(
                    phase: .claimedForLaunch,
                    attemptID: attemptID
                )
                claimed = updated
                return updated
            case .claimedForLaunch where record.attemptID == attemptID:
                claimed = record
                return record
            case .claimedForLaunch, .failed:
                throw ProxyResumeJournalError.phaseConflict
            }
        }
        guard let claimed else { throw ProxyResumeJournalError.phaseConflict }
        return claimed
    }

    func markFailed(
        operationID: UUID,
        attemptID: UUID,
        code: ProxyResumeFailureCode
    ) throws {
        try transition(operationID: operationID) { record in
            switch record.phase {
            case .claimedForLaunch where record.attemptID == attemptID:
                return record.updating(
                    phase: .failed,
                    attemptID: attemptID,
                    failureCode: code
                )
            case .failed where record.attemptID == attemptID && record.failureCode == code:
                return record
            case .preparedForQuit, .disabledConfirmed, .claimedForLaunch, .failed:
                throw ProxyResumeJournalError.phaseConflict
            }
        }
    }

    func prepareRetry(operationID: UUID) throws -> ProxyResumeRecord {
        var retry: ProxyResumeRecord?
        try transition(operationID: operationID) { record in
            guard record.phase == .failed else {
                throw ProxyResumeJournalError.phaseConflict
            }
            let updated = record.updating(phase: .disabledConfirmed)
            retry = updated
            return updated
        }
        guard let retry else { throw ProxyResumeJournalError.phaseConflict }
        return retry
    }

    func discard(operationID: UUID?) throws {
        try withExclusiveLock {
            try prepareDirectory()
            switch try loadUnlocked() {
            case .missing:
                return
            case let .loaded(record):
                if let operationID, record.operationID != operationID {
                    throw ProxyResumeJournalError.operationConflict
                }
            case .newerSchema, .unsupportedSchema, .corrupt:
                guard operationID == nil else {
                    throw ProxyResumeJournalError.existingEvidenceRequiresRecovery
                }
            }
            try fileSystem.removeFileIfPresent(at: recordURL)
            try fileSystem.synchronizeDirectory(at: directoryURL)
        }
    }

    private func transition(
        operationID: UUID,
        update: (ProxyResumeRecord) throws -> ProxyResumeRecord
    ) throws {
        try withExclusiveLock {
            try prepareDirectory()
            guard case let .loaded(record) = try loadUnlocked() else {
                throw ProxyResumeJournalError.existingEvidenceRequiresRecovery
            }
            guard record.operationID == operationID else {
                throw ProxyResumeJournalError.operationConflict
            }
            let updated = try update(record)
            if updated != record { try publish(updated) }
        }
    }

    private func loadUnlocked() throws -> ProxyResumeJournalLoadResult {
        guard fileSystem.itemExists(at: recordURL) else { return .missing }
        let data = try fileSystem.readFile(at: recordURL)
        guard let schema = try? JSONDecoder().decode(SchemaEnvelope.self, from: data) else {
            return try corruptResult(data, reason: .invalidJSON)
        }
        if schema.schemaVersion > StoredRecord.currentSchemaVersion {
            return .newerSchema(version: schema.schemaVersion)
        }
        guard schema.schemaVersion == StoredRecord.currentSchemaVersion else {
            return .unsupportedSchema(version: schema.schemaVersion)
        }
        do {
            let stored = try Self.decodeCanonical(StoredRecord.self, from: data)
            let recordData = try Self.encodeCanonical(stored.record)
            guard stored.checksum == Checksum(data: recordData) else {
                return try corruptResult(data, reason: .checksumMismatch)
            }
            guard stored.record.schemaVersion == ProxyResumeRecord.currentSchemaVersion,
                  !stored.record.providerBundleIdentifier.isEmpty,
                  Self.recordShapeIsValid(stored.record) else {
                return try corruptResult(data, reason: .invalidRecord)
            }
            return .loaded(stored.record)
        } catch CanonicalJSONError.nonCanonical {
            return try corruptResult(data, reason: .nonCanonicalJSON)
        } catch {
            return try corruptResult(data, reason: .invalidJSON)
        }
    }

    private func publish(_ record: ProxyResumeRecord) throws {
        let recordData = try Self.encodeCanonical(record)
        let data = try Self.encodeCanonical(StoredRecord(
            record: record,
            checksum: Checksum(data: recordData)
        ))
        let temporaryURL = directoryURL.appendingPathComponent(
            ".proxy-resume.\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileSystem.removeFileIfPresent(at: temporaryURL) }
        try fileSystem.createFile(at: temporaryURL, data: data, permissions: 0o600)
        try fileSystem.synchronizeFile(at: temporaryURL)
        try fileSystem.replaceAtomically(itemAt: recordURL, withItemAt: temporaryURL)
        try fileSystem.synchronizeDirectory(at: directoryURL)
    }

    private func corruptResult(
        _ data: Data,
        reason: ProxyResumeJournalCorruption
    ) throws -> ProxyResumeJournalLoadResult {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let artifactURL = directoryURL.appendingPathComponent(
            "proxy-resume.corrupt.\(digest).json",
            isDirectory: false
        )
        if fileSystem.itemExists(at: artifactURL) {
            guard try fileSystem.readFile(at: artifactURL) == data else {
                throw ConfigurationStoreError.recoveryArtifactConflict
            }
        } else {
            try fileSystem.createFile(at: artifactURL, data: data, permissions: 0o600)
            try fileSystem.synchronizeFile(at: artifactURL)
            try fileSystem.synchronizeDirectory(at: directoryURL)
        }
        return .corrupt(reason: reason, recoveryArtifactURL: artifactURL)
    }

    private func prepareDirectory() throws {
        let existed = fileSystem.itemExists(at: directoryURL)
        try fileSystem.createDirectory(at: directoryURL)
        if !existed {
            try fileSystem.synchronizeDirectory(at: directoryURL.deletingLastPathComponent())
        }
    }

    private func withExclusiveLock<T>(_ operation: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        try prepareDirectory()
        let lockURL = directoryURL.appendingPathComponent(
            ".proxy-resume.lock",
            isDirectory: false
        )
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var lock = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        while Darwin.fcntl(descriptor, F_SETLKW, &lock) != 0 {
            guard errno == EINTR else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                _ = Darwin.close(descriptor)
                throw POSIXError(code)
            }
        }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
            _ = Darwin.close(descriptor)
        }
        return try operation()
    }

    private static func recordShapeIsValid(_ record: ProxyResumeRecord) -> Bool {
        switch record.phase {
        case .preparedForQuit, .disabledConfirmed:
            record.attemptID == nil && record.failureCode == nil
        case .claimedForLaunch:
            record.attemptID != nil && record.failureCode == nil
        case .failed:
            record.attemptID != nil && record.failureCode != nil
        }
    }

    private static func encodeCanonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decodeCanonical<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        let value = try JSONDecoder().decode(type, from: data)
        guard try encodeCanonical(value) == data else { throw CanonicalJSONError.nonCanonical }
        return value
    }

    private struct StoredRecord: Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let record: ProxyResumeRecord
        let checksum: Checksum

        init(
            schemaVersion: Int = Self.currentSchemaVersion,
            record: ProxyResumeRecord,
            checksum: Checksum
        ) {
            self.schemaVersion = schemaVersion
            self.record = record
            self.checksum = checksum
        }
    }

    private struct Checksum: RawRepresentable, Codable, Equatable {
        let rawValue: String

        init(data: Data) {
            rawValue = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        init?(rawValue: String) {
            guard rawValue.utf8.count == 64,
                  rawValue.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (97...102).contains(byte)
                  }) else { return nil }
            self.rawValue = rawValue
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let checksum = Self(rawValue: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a lowercase SHA-256 checksum."
                )
            }
            self = checksum
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }

    private enum CanonicalJSONError: Error {
        case nonCanonical
    }
}
