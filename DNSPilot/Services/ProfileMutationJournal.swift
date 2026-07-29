import CryptoKit
import Foundation

enum ProfileMutationPhase: String, Codable, Equatable, Sendable {
    case prepared
    case configurationCommitted
}

enum ProfileMutationStateSide: String, Codable, Equatable, Sendable {
    case old
    case draft
}

struct ProfileMutationOperationIdentity: Codable, Equatable, Sendable {
    let operationID: UUID
    let runtimeTransactionID: UUID
}

struct ProfileMutationRuntimeIdentity: Codable, Equatable, Sendable {
    let profileID: UUID
    let generation: UUID
    let configurationFingerprint: ProxyConfigurationFingerprint
}

struct ProfileMutationPayloadChecksum: RawRepresentable, Codable, Hashable, Sendable {
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
        guard let checksum = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a 64-character lowercase SHA-256 checksum."
            )
        }
        self = checksum
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ProfileMutationRecoveryPayload: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let operationIdentity: ProfileMutationOperationIdentity
    let oldAppConfigurationJSON: Data
    let draftAppConfigurationJSON: Data
    let oldRuntimePropertyList: Data
    let draftRuntimePropertyList: Data

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        operationIdentity: ProfileMutationOperationIdentity,
        oldAppConfigurationJSON: Data,
        draftAppConfigurationJSON: Data,
        oldRuntimePropertyList: Data,
        draftRuntimePropertyList: Data
    ) {
        self.schemaVersion = schemaVersion
        self.operationIdentity = operationIdentity
        self.oldAppConfigurationJSON = oldAppConfigurationJSON
        self.draftAppConfigurationJSON = draftAppConfigurationJSON
        self.oldRuntimePropertyList = oldRuntimePropertyList
        self.draftRuntimePropertyList = draftRuntimePropertyList
    }
}

struct ProfileMutationJournalEntry: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let operationIdentity: ProfileMutationOperationIdentity
    let phase: ProfileMutationPhase
    let oldAppConfigurationFingerprint: AppConfigurationFingerprint
    let draftAppConfigurationFingerprint: AppConfigurationFingerprint
    let oldProfileID: UUID
    let draftProfileID: UUID
    let oldRuntimeIdentity: ProfileMutationRuntimeIdentity
    let draftRuntimeIdentity: ProfileMutationRuntimeIdentity
    let payloadChecksum: ProfileMutationPayloadChecksum

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        operationIdentity: ProfileMutationOperationIdentity,
        phase: ProfileMutationPhase,
        oldAppConfigurationFingerprint: AppConfigurationFingerprint,
        draftAppConfigurationFingerprint: AppConfigurationFingerprint,
        oldProfileID: UUID,
        draftProfileID: UUID,
        oldRuntimeIdentity: ProfileMutationRuntimeIdentity,
        draftRuntimeIdentity: ProfileMutationRuntimeIdentity,
        payloadChecksum: ProfileMutationPayloadChecksum
    ) {
        self.schemaVersion = schemaVersion
        self.operationIdentity = operationIdentity
        self.phase = phase
        self.oldAppConfigurationFingerprint = oldAppConfigurationFingerprint
        self.draftAppConfigurationFingerprint = draftAppConfigurationFingerprint
        self.oldProfileID = oldProfileID
        self.draftProfileID = draftProfileID
        self.oldRuntimeIdentity = oldRuntimeIdentity
        self.draftRuntimeIdentity = draftRuntimeIdentity
        self.payloadChecksum = payloadChecksum
    }

    func updatingPhase(_ phase: ProfileMutationPhase) -> Self {
        Self(
            schemaVersion: schemaVersion,
            operationIdentity: operationIdentity,
            phase: phase,
            oldAppConfigurationFingerprint: oldAppConfigurationFingerprint,
            draftAppConfigurationFingerprint: draftAppConfigurationFingerprint,
            oldProfileID: oldProfileID,
            draftProfileID: draftProfileID,
            oldRuntimeIdentity: oldRuntimeIdentity,
            draftRuntimeIdentity: draftRuntimeIdentity,
            payloadChecksum: payloadChecksum
        )
    }
}

enum ProfileMutationJournalComponent: Equatable, Sendable {
    case journal
    case payload
    case state
    case pair
}

enum ProfileMutationJournalCorruption: Equatable, Sendable {
    case invalidJSON
    case nonCanonicalJSON
    case operationIdentityMismatch
    case payloadChecksumMismatch
    case appConfigurationFingerprintMismatch(ProfileMutationStateSide)
    case runtimeConfigurationFingerprintMismatch(ProfileMutationStateSide)
    case profileIdentityMismatch(ProfileMutationStateSide)
    case runtimeIdentityMismatch(ProfileMutationStateSide)
}

enum ProfileMutationJournalLoadResult: Equatable, Sendable {
    case missing
    case loaded(ProfileMutationJournalEntry, ProfileMutationRecoveryPayload)
    case missingCounterpart(ProfileMutationJournalComponent)
    case newerSchema(component: ProfileMutationJournalComponent, version: Int)
    case unsupportedSchema(component: ProfileMutationJournalComponent, version: Int)
    case corrupt(component: ProfileMutationJournalComponent, reason: ProfileMutationJournalCorruption)
}

enum ProfileMutationJournalError: LocalizedError, Equatable, Sendable {
    case invalidEvidence(ProfileMutationJournalCorruption)
    case unsupportedSchema(component: ProfileMutationJournalComponent, version: Int)
    case activeMutationExists
    case operationConflict
    case existingEvidenceRequiresRecovery

    var errorDescription: String? {
        switch self {
        case .invalidEvidence:
            "Mutation recovery evidence failed validation."
        case let .unsupportedSchema(component, version):
            "Unsupported profile mutation \(component) schema version: \(version)."
        case .activeMutationExists:
            "Another profile mutation journal is already active."
        case .operationConflict:
            "The profile mutation operation UUID was reused with different evidence."
        case .existingEvidenceRequiresRecovery:
            "Existing profile mutation evidence requires recovery before it can be changed."
        }
    }
}

protocol ProfileMutationJournalStoring: Sendable {
    func payloadChecksum(
        for payload: ProfileMutationRecoveryPayload
    ) throws -> ProfileMutationPayloadChecksum
    func write(
        entry: ProfileMutationJournalEntry,
        payload: ProfileMutationRecoveryPayload
    ) throws
    func load() throws -> ProfileMutationJournalLoadResult
    func updatePhase(
        operationIdentity: ProfileMutationOperationIdentity,
        to phase: ProfileMutationPhase
    ) throws
    func cleanup(operationIdentity: ProfileMutationOperationIdentity) throws
}

struct ProfileMutationJournal: ProfileMutationJournalStoring {
    static let journalFileName = "profile-mutation-journal.json"
    static let payloadFileName = "profile-mutation-recovery.json"
    static let stateFileName = "profile-mutation-state.json"
    private static let processLock = NSLock()

    let directoryURL: URL
    private let fileSystem: any ConfigurationFileSystem

    var journalURL: URL {
        directoryURL.appendingPathComponent(Self.journalFileName, isDirectory: false)
    }

    var payloadURL: URL {
        directoryURL.appendingPathComponent(Self.payloadFileName, isDirectory: false)
    }

    var stateURL: URL {
        directoryURL.appendingPathComponent(Self.stateFileName, isDirectory: false)
    }

    init(
        directoryURL: URL,
        fileSystem: any ConfigurationFileSystem = LocalConfigurationFileSystem()
    ) {
        self.directoryURL = directoryURL
        self.fileSystem = fileSystem
    }

    func payloadChecksum(
        for payload: ProfileMutationRecoveryPayload
    ) throws -> ProfileMutationPayloadChecksum {
        ProfileMutationPayloadChecksum(data: try Self.encodeCanonical(payload))
    }

    func write(
        entry: ProfileMutationJournalEntry,
        payload: ProfileMutationRecoveryPayload
    ) throws {
        try withProcessLock {
            try prepareDirectory()
            guard entry.schemaVersion == ProfileMutationJournalEntry.currentSchemaVersion else {
                throw ProfileMutationJournalError.unsupportedSchema(
                    component: .journal,
                    version: entry.schemaVersion
                )
            }
            guard payload.schemaVersion == ProfileMutationRecoveryPayload.currentSchemaVersion else {
                throw ProfileMutationJournalError.unsupportedSchema(
                    component: .payload,
                    version: payload.schemaVersion
                )
            }
            if case let .invalid(reason) = try validate(entry: entry, payload: payload) {
                throw ProfileMutationJournalError.invalidEvidence(reason)
            }

            let entryData = try Self.encodeCanonical(entry)
            let payloadData = try Self.encodeCanonical(payload)
            let journalExists = fileSystem.itemExists(at: journalURL)
            let payloadExists = fileSystem.itemExists(at: payloadURL)

            if fileSystem.itemExists(at: stateURL) {
                let state = try requireExistingState(for: entry.operationIdentity)
                guard state.phase == .publishing else {
                    throw ProfileMutationJournalError.existingEvidenceRequiresRecovery
                }
                guard state.entry == entry else {
                    throw ProfileMutationJournalError.operationConflict
                }
            }

            if journalExists {
                let existingEntryData = try fileSystem.readFile(at: journalURL)
                guard let existingEntry = try? Self.decodeCanonical(
                    ProfileMutationJournalEntry.self,
                    from: existingEntryData
                ) else {
                    throw ProfileMutationJournalError.existingEvidenceRequiresRecovery
                }
                guard existingEntry.operationIdentity.operationID == entry.operationIdentity.operationID else {
                    throw ProfileMutationJournalError.activeMutationExists
                }
                guard existingEntryData == entryData else {
                    throw ProfileMutationJournalError.operationConflict
                }
            }

            if payloadExists {
                let existingPayloadData = try fileSystem.readFile(at: payloadURL)
                guard let existingPayload = try? Self.decodeCanonical(
                    ProfileMutationRecoveryPayload.self,
                    from: existingPayloadData
                ) else {
                    throw ProfileMutationJournalError.existingEvidenceRequiresRecovery
                }
                guard existingPayload.operationIdentity.operationID == payload.operationIdentity.operationID else {
                    throw ProfileMutationJournalError.activeMutationExists
                }
                guard existingPayloadData == payloadData else {
                    throw ProfileMutationJournalError.operationConflict
                }
            }

            if journalExists && payloadExists {
                try fileSystem.synchronizeDirectory(at: directoryURL)
                try finishPublicationIfPresent()
                return
            }

            if !fileSystem.itemExists(at: stateURL) {
                try publish(
                    Self.encodeCanonical(ProfileMutationJournalState(phase: .publishing, entry: entry)),
                    at: stateURL,
                    temporaryLabel: "state"
                )
            }
            if !payloadExists {
                try publish(payloadData, at: payloadURL, temporaryLabel: "payload")
            }
            if !journalExists {
                try publish(entryData, at: journalURL, temporaryLabel: "journal")
            }
            try finishPublicationIfPresent()
        }
    }

    func load() throws -> ProfileMutationJournalLoadResult {
        try withProcessLock {
            try prepareDirectory()
            return try loadUnlocked()
        }
    }

    func updatePhase(
        operationIdentity: ProfileMutationOperationIdentity,
        to phase: ProfileMutationPhase
    ) throws {
        try withProcessLock {
            try prepareDirectory()
            guard case let .loaded(entry, _) = try loadUnlocked() else {
                throw ProfileMutationJournalError.existingEvidenceRequiresRecovery
            }
            guard entry.operationIdentity == operationIdentity else {
                if entry.operationIdentity.operationID == operationIdentity.operationID {
                    throw ProfileMutationJournalError.operationConflict
                }
                throw ProfileMutationJournalError.activeMutationExists
            }
            guard entry.phase != phase else { return }
            try publish(
                Self.encodeCanonical(entry.updatingPhase(phase)),
                at: journalURL,
                temporaryLabel: "journal"
            )
        }
    }

    func cleanup(operationIdentity: ProfileMutationOperationIdentity) throws {
        try withProcessLock {
            try prepareDirectory()
            if fileSystem.itemExists(at: stateURL) {
                let state = try requireExistingState(for: operationIdentity)
                if state.phase == .terminal {
                    try completeTerminalCleanup(state)
                    return
                }
            }
            guard case let .loaded(entry, _) = try loadUnlocked() else {
                if !fileSystem.itemExists(at: journalURL),
                   !fileSystem.itemExists(at: payloadURL),
                   !fileSystem.itemExists(at: stateURL) {
                    return
                }
                throw ProfileMutationJournalError.existingEvidenceRequiresRecovery
            }
            guard entry.operationIdentity == operationIdentity else {
                if entry.operationIdentity.operationID == operationIdentity.operationID {
                    throw ProfileMutationJournalError.operationConflict
                }
                throw ProfileMutationJournalError.activeMutationExists
            }
            let state = ProfileMutationJournalState(phase: .terminal, entry: entry)
            try publish(
                Self.encodeCanonical(state),
                at: stateURL,
                temporaryLabel: "state"
            )
            try completeTerminalCleanup(state)
        }
    }

    private func loadUnlocked() throws -> ProfileMutationJournalLoadResult {
        if fileSystem.itemExists(at: stateURL) {
            let stateResult = loadState()
            switch stateResult {
            case let .success(state):
                switch state.phase {
                case .publishing:
                    return try completePublication(state)
                case .terminal:
                    try completeTerminalCleanup(state)
                    return .missing
                }
            case let .failure(result):
                return result
            }
        }
        return try loadPairUnlocked()
    }

    private func loadPairUnlocked() throws -> ProfileMutationJournalLoadResult {
        let journalExists = fileSystem.itemExists(at: journalURL)
        let payloadExists = fileSystem.itemExists(at: payloadURL)
        switch (journalExists, payloadExists) {
        case (false, false):
            return .missing
        case (false, true):
            return .missingCounterpart(.journal)
        case (true, false):
            return .missingCounterpart(.payload)
        case (true, true):
            break
        }

        let entryData = try fileSystem.readFile(at: journalURL)
        let payloadData = try fileSystem.readFile(at: payloadURL)

        switch Self.schemaClassification(
            data: entryData,
            currentVersion: ProfileMutationJournalEntry.currentSchemaVersion,
            component: .journal
        ) {
        case let .some(result): return result
        case nil: break
        }
        switch Self.schemaClassification(
            data: payloadData,
            currentVersion: ProfileMutationRecoveryPayload.currentSchemaVersion,
            component: .payload
        ) {
        case let .some(result): return result
        case nil: break
        }

        let entry: ProfileMutationJournalEntry
        let payload: ProfileMutationRecoveryPayload
        do {
            entry = try Self.decodeCanonical(ProfileMutationJournalEntry.self, from: entryData)
        } catch CanonicalJSONError.nonCanonical {
            return .corrupt(component: .journal, reason: .nonCanonicalJSON)
        } catch {
            return .corrupt(component: .journal, reason: .invalidJSON)
        }
        do {
            payload = try Self.decodeCanonical(ProfileMutationRecoveryPayload.self, from: payloadData)
        } catch CanonicalJSONError.nonCanonical {
            return .corrupt(component: .payload, reason: .nonCanonicalJSON)
        } catch {
            return .corrupt(component: .payload, reason: .invalidJSON)
        }

        switch try validate(entry: entry, payload: payload) {
        case .valid:
            return .loaded(entry, payload)
        case let .invalid(reason):
            return .corrupt(component: .pair, reason: reason)
        }
    }

    private func completePublication(
        _ state: ProfileMutationJournalState
    ) throws -> ProfileMutationJournalLoadResult {
        let journalExists = fileSystem.itemExists(at: journalURL)
        let payloadExists = fileSystem.itemExists(at: payloadURL)
        guard payloadExists else {
            if !journalExists {
                try fileSystem.removeFileIfPresent(at: stateURL)
                try fileSystem.synchronizeDirectory(at: directoryURL)
                return .missing
            }
            return .missingCounterpart(.payload)
        }

        let payloadData = try fileSystem.readFile(at: payloadURL)
        if let result = Self.schemaClassification(
            data: payloadData,
            currentVersion: ProfileMutationRecoveryPayload.currentSchemaVersion,
            component: .payload
        ) {
            return result
        }
        let payload: ProfileMutationRecoveryPayload
        do {
            payload = try Self.decodeCanonical(ProfileMutationRecoveryPayload.self, from: payloadData)
        } catch CanonicalJSONError.nonCanonical {
            return .corrupt(component: .payload, reason: .nonCanonicalJSON)
        } catch {
            return .corrupt(component: .payload, reason: .invalidJSON)
        }
        switch try validate(entry: state.entry, payload: payload) {
        case let .invalid(reason):
            return .corrupt(component: .pair, reason: reason)
        case .valid:
            break
        }

        if journalExists {
            let journalData = try fileSystem.readFile(at: journalURL)
            guard journalData == (try Self.encodeCanonical(state.entry)) else {
                return try loadPairUnlocked()
            }
        } else {
            try publish(
                Self.encodeCanonical(state.entry),
                at: journalURL,
                temporaryLabel: "journal"
            )
        }
        try finishPublicationIfPresent()
        return .loaded(state.entry, payload)
    }

    private func completeTerminalCleanup(_ state: ProfileMutationJournalState) throws {
        if fileSystem.itemExists(at: journalURL) {
            let data = try fileSystem.readFile(at: journalURL)
            guard (try? Self.decodeCanonical(ProfileMutationJournalEntry.self, from: data)) == state.entry else {
                throw ProfileMutationJournalError.existingEvidenceRequiresRecovery
            }
        }
        if fileSystem.itemExists(at: payloadURL) {
            let data = try fileSystem.readFile(at: payloadURL)
            guard let payload = try? Self.decodeCanonical(ProfileMutationRecoveryPayload.self, from: data) else {
                throw ProfileMutationJournalError.existingEvidenceRequiresRecovery
            }
            guard case .valid = try validate(entry: state.entry, payload: payload) else {
                throw ProfileMutationJournalError.existingEvidenceRequiresRecovery
            }
        }

        try fileSystem.removeFileIfPresent(at: journalURL)
        try fileSystem.removeFileIfPresent(at: payloadURL)
        try fileSystem.synchronizeDirectory(at: directoryURL)
        try fileSystem.removeFileIfPresent(at: stateURL)
        try fileSystem.synchronizeDirectory(at: directoryURL)
    }

    private func finishPublicationIfPresent() throws {
        guard fileSystem.itemExists(at: stateURL) else { return }
        try fileSystem.removeFileIfPresent(at: stateURL)
        try fileSystem.synchronizeDirectory(at: directoryURL)
    }

    private func requireExistingState(
        for operationIdentity: ProfileMutationOperationIdentity
    ) throws -> ProfileMutationJournalState {
        switch loadState() {
        case let .success(state):
            guard state.entry.operationIdentity == operationIdentity else {
                if state.entry.operationIdentity.operationID == operationIdentity.operationID {
                    throw ProfileMutationJournalError.operationConflict
                }
                throw ProfileMutationJournalError.activeMutationExists
            }
            return state
        case .failure:
            throw ProfileMutationJournalError.existingEvidenceRequiresRecovery
        }
    }

    private func loadState() -> StateLoadResult {
        let data: Data
        do {
            data = try fileSystem.readFile(at: stateURL)
        } catch {
            return .failure(.corrupt(component: .state, reason: .invalidJSON))
        }
        if let result = Self.schemaClassification(
            data: data,
            currentVersion: ProfileMutationJournalState.currentSchemaVersion,
            component: .state
        ) {
            return .failure(result)
        }
        do {
            let state = try Self.decodeCanonical(ProfileMutationJournalState.self, from: data)
            if state.entry.schemaVersion > ProfileMutationJournalEntry.currentSchemaVersion {
                return .failure(.newerSchema(component: .journal, version: state.entry.schemaVersion))
            }
            if state.entry.schemaVersion != ProfileMutationJournalEntry.currentSchemaVersion {
                return .failure(.unsupportedSchema(component: .journal, version: state.entry.schemaVersion))
            }
            return .success(state)
        } catch CanonicalJSONError.nonCanonical {
            return .failure(.corrupt(component: .state, reason: .nonCanonicalJSON))
        } catch {
            return .failure(.corrupt(component: .state, reason: .invalidJSON))
        }
    }

    private func validate(
        entry: ProfileMutationJournalEntry,
        payload: ProfileMutationRecoveryPayload
    ) throws -> PairValidation {
        guard entry.operationIdentity == payload.operationIdentity else {
            return .invalid(.operationIdentityMismatch)
        }
        let payloadData = try Self.encodeCanonical(payload)
        guard entry.payloadChecksum == ProfileMutationPayloadChecksum(data: payloadData) else {
            return .invalid(.payloadChecksumMismatch)
        }

        let appStates = [
            (ProfileMutationStateSide.old, payload.oldAppConfigurationJSON,
             entry.oldAppConfigurationFingerprint, entry.oldProfileID),
            (.draft, payload.draftAppConfigurationJSON,
             entry.draftAppConfigurationFingerprint, entry.draftProfileID),
        ]
        for (side, data, fingerprint, profileID) in appStates {
            guard AppConfigurationFingerprint(data: data) == fingerprint else {
                return .invalid(.appConfigurationFingerprintMismatch(side))
            }
            guard
                let persisted = try? PersistedAppConfiguration(data: data),
                persisted.data == data
            else {
                return .invalid(.appConfigurationFingerprintMismatch(side))
            }
            guard persisted.value.profiles.contains(where: { $0.id == profileID }) else {
                return .invalid(.profileIdentityMismatch(side))
            }
        }

        let runtimeStates = [
            (ProfileMutationStateSide.old, payload.oldRuntimePropertyList,
             entry.oldRuntimeIdentity),
            (.draft, payload.draftRuntimePropertyList,
             entry.draftRuntimeIdentity),
        ]
        for (side, data, identity) in runtimeStates {
            guard ProxyConfigurationFingerprint(data: data) == identity.configurationFingerprint else {
                return .invalid(.runtimeConfigurationFingerprintMismatch(side))
            }
            guard let persisted = try? PersistedProxyConfiguration(data: data) else {
                return .invalid(.runtimeConfigurationFingerprintMismatch(side))
            }
            guard
                persisted.value.profileID == identity.profileID,
                persisted.value.generation == identity.generation
            else {
                return .invalid(.runtimeIdentityMismatch(side))
            }
            let expectedProfileID = side == .old ? entry.oldProfileID : entry.draftProfileID
            guard identity.profileID == expectedProfileID else {
                return .invalid(.profileIdentityMismatch(side))
            }
        }
        return .valid
    }

    private func publish(_ data: Data, at destinationURL: URL, temporaryLabel: String) throws {
        let temporaryURL = directoryURL.appendingPathComponent(
            ".profile-mutation-\(temporaryLabel).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileSystem.removeFileIfPresent(at: temporaryURL) }
        try fileSystem.createFile(at: temporaryURL, data: data, permissions: 0o600)
        try fileSystem.synchronizeFile(at: temporaryURL)
        try fileSystem.replaceAtomically(itemAt: destinationURL, withItemAt: temporaryURL)
        try fileSystem.synchronizeDirectory(at: directoryURL)
    }

    private func prepareDirectory() throws {
        let existed = fileSystem.itemExists(at: directoryURL)
        try fileSystem.createDirectory(at: directoryURL)
        if !existed {
            try fileSystem.synchronizeDirectory(at: directoryURL.deletingLastPathComponent())
        }
    }

    private func withProcessLock<T>(_ operation: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        return try operation()
    }

    private static func encodeCanonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decodeCanonical<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        let value = try JSONDecoder().decode(type, from: data)
        guard try encodeCanonical(value) == data else {
            throw CanonicalJSONError.nonCanonical
        }
        return value
    }

    private static func schemaClassification(
        data: Data,
        currentVersion: Int,
        component: ProfileMutationJournalComponent
    ) -> ProfileMutationJournalLoadResult? {
        guard let envelope = try? JSONDecoder().decode(SchemaEnvelope.self, from: data) else {
            return .corrupt(component: component, reason: .invalidJSON)
        }
        if envelope.schemaVersion > currentVersion {
            return .newerSchema(component: component, version: envelope.schemaVersion)
        }
        if envelope.schemaVersion != currentVersion {
            return .unsupportedSchema(component: component, version: envelope.schemaVersion)
        }
        return nil
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }

    private struct ProfileMutationJournalState: Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let phase: Phase
        let entry: ProfileMutationJournalEntry

        init(schemaVersion: Int = Self.currentSchemaVersion, phase: Phase, entry: ProfileMutationJournalEntry) {
            self.schemaVersion = schemaVersion
            self.phase = phase
            self.entry = entry
        }

        enum Phase: String, Codable {
            case publishing
            case terminal
        }
    }

    private enum StateLoadResult {
        case success(ProfileMutationJournalState)
        case failure(ProfileMutationJournalLoadResult)
    }

    private enum CanonicalJSONError: Error {
        case nonCanonical
    }

    private enum PairValidation {
        case valid
        case invalid(ProfileMutationJournalCorruption)
    }
}
