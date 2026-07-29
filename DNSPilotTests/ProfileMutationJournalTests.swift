import Foundation
import Testing
@testable import DNSPilot

struct ProfileMutationJournalTests {
    @Test func roundTripPreservesExactPayloadBytesAndCanonicalMetadata() throws {
        try withFixture { fixture in
            try fixture.store.write(entry: fixture.entry, payload: fixture.payload)

            #expect(try fixture.store.load() == .loaded(fixture.entry, fixture.payload))
            guard case let .loaded(_, payload) = try fixture.store.load() else {
                Issue.record("Expected loaded mutation evidence")
                return
            }
            #expect(payload.oldAppConfigurationJSON == fixture.payload.oldAppConfigurationJSON)
            #expect(payload.draftAppConfigurationJSON == fixture.payload.draftAppConfigurationJSON)
            #expect(payload.oldRuntimePropertyList == fixture.payload.oldRuntimePropertyList)
            #expect(payload.draftRuntimePropertyList == fixture.payload.draftRuntimePropertyList)

            let journalObject = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.journalURL))
                    as? [String: Any]
            )
            #expect(journalObject["oldAppConfigurationFingerprint"] as? String
                    == fixture.entry.oldAppConfigurationFingerprint.rawValue)
            #expect(journalObject["oldRuntimeIdentity"] != nil)
            #expect(journalObject["entitlementRevision"] == nil)
            #expect(journalObject["oldAppConfigurationJSON"] == nil)
            #expect(journalObject["oldRuntimePropertyList"] == nil)
        }
    }

    @Test func localFilesUseOwnerOnlyPermissions() throws {
        try withFixture { fixture in
            try fixture.store.write(entry: fixture.entry, payload: fixture.payload)

            for url in [fixture.store.journalURL, fixture.store.payloadURL] {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
                #expect(permissions.uint16Value == 0o600)
            }
        }
    }

    @Test func phaseUpdateIsDurableAndIdempotent() throws {
        try withFixture { fixture in
            try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
            let payloadBefore = try Data(contentsOf: fixture.store.payloadURL)

            try fixture.store.updatePhase(
                operationIdentity: fixture.entry.operationIdentity,
                to: .configurationCommitted
            )
            try fixture.store.updatePhase(
                operationIdentity: fixture.entry.operationIdentity,
                to: .configurationCommitted
            )

            #expect(
                try fixture.store.load()
                    == .loaded(fixture.entry.updatingPhase(.configurationCommitted), fixture.payload)
            )
            #expect(try Data(contentsOf: fixture.store.payloadURL) == payloadBefore)
        }
    }

    @Test func identicalOperationWriteIsIdempotentButDivergentReuseIsRejected() throws {
        try withFixture { fixture in
            try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
            try fixture.store.write(entry: fixture.entry, payload: fixture.payload)

            let conflicting = fixture.entry.updatingPhase(.configurationCommitted)
            #expect(throws: ProfileMutationJournalError.operationConflict) {
                try fixture.store.write(entry: conflicting, payload: fixture.payload)
            }
            #expect(try fixture.store.load() == .loaded(fixture.entry, fixture.payload))
        }
    }

    @Test func idempotentRetryCompletesAPreviouslyFailedDirectorySync() throws {
        try withFixture(fileSystemFailure: .journalDirectorySync) { fixture in
            #expect(throws: (any Error).self) {
                try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
            }
            let retry = ProfileMutationJournal(directoryURL: fixture.directoryURL)

            try retry.write(entry: fixture.entry, payload: fixture.payload)

            #expect(try retry.load() == .loaded(fixture.entry, fixture.payload))
        }
    }

    @Test func publishingStateFailuresRestartAsMissingWithoutPartialEvidence() throws {
        for failure in JournalFailurePoint.statePublicationFailures {
            try withFixture(fileSystemFailure: failure) { fixture in
                #expect(throws: (any Error).self) {
                    try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
                }
                #expect(!FileManager.default.fileExists(atPath: fixture.store.payloadURL.path))
                #expect(!FileManager.default.fileExists(atPath: fixture.store.journalURL.path))
                #expect(
                    FileManager.default.fileExists(atPath: fixture.store.stateURL.path)
                        == (failure == .stateDirectorySync)
                )
                let temporaryFileNames = try temporaryFiles(in: fixture.directoryURL)
                #expect(temporaryFileNames.isEmpty)

                let restarted = ProfileMutationJournal(directoryURL: fixture.directoryURL)
                let loadResult = try restarted.load()
                #expect(loadResult == .missing)
                #expect(!FileManager.default.fileExists(atPath: restarted.stateURL.path))
                #expect(!FileManager.default.fileExists(atPath: restarted.payloadURL.path))
                #expect(!FileManager.default.fileExists(atPath: restarted.journalURL.path))
            }
        }
    }

    @Test func retryAfterPublishingStateDirectorySyncFailureCompletesExactWrite() throws {
        try withFixture(fileSystemFailure: .stateDirectorySync) { fixture in
            #expect(throws: (any Error).self) {
                try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
            }
            #expect(FileManager.default.fileExists(atPath: fixture.store.stateURL.path))

            let retry = ProfileMutationJournal(directoryURL: fixture.directoryURL)
            try retry.write(entry: fixture.entry, payload: fixture.payload)

            #expect(try retry.load() == .loaded(fixture.entry, fixture.payload))
        }
    }

    @Test func publishingStateWithPartialPairFailsClosedWithoutDeletion() throws {
        try withFixture(fileSystemFailure: .stateDirectorySync) { fixture in
            #expect(throws: (any Error).self) {
                try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
            }
            try writeCanonical(fixture.entry, to: fixture.store.journalURL)

            let restarted = ProfileMutationJournal(directoryURL: fixture.directoryURL)
            #expect(try restarted.load() == .missingCounterpart(.payload))
            #expect(FileManager.default.fileExists(atPath: restarted.stateURL.path))
            #expect(FileManager.default.fileExists(atPath: restarted.journalURL.path))
            #expect(!FileManager.default.fileExists(atPath: restarted.payloadURL.path))
        }
    }

    @Test func missingAndMismatchedCounterpartsAreClassifiedWithoutDeletion() throws {
        try withFixture { fixture in
            try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
            try FileManager.default.removeItem(at: fixture.store.payloadURL)

            #expect(try fixture.store.load() == .missingCounterpart(.payload))
            #expect(FileManager.default.fileExists(atPath: fixture.store.journalURL.path))
        }

        try withFixture { fixture in
            let otherIdentity = ProfileMutationOperationIdentity(
                operationID: UUID(),
                runtimeTransactionID: UUID()
            )
            let mismatchedPayload = ProfileMutationRecoveryPayload(
                operationIdentity: otherIdentity,
                oldAppConfigurationJSON: fixture.payload.oldAppConfigurationJSON,
                draftAppConfigurationJSON: fixture.payload.draftAppConfigurationJSON,
                oldRuntimePropertyList: fixture.payload.oldRuntimePropertyList,
                draftRuntimePropertyList: fixture.payload.draftRuntimePropertyList
            )
            let mismatchedEntry = replacingChecksum(
                in: fixture.entry,
                with: try fixture.store.payloadChecksum(for: mismatchedPayload)
            )
            try writeCanonical(mismatchedEntry, to: fixture.store.journalURL)
            try writeCanonical(mismatchedPayload, to: fixture.store.payloadURL)

            #expect(
                try fixture.store.load()
                    == .corrupt(component: .pair, reason: .operationIdentityMismatch)
            )
        }
    }

    @Test func checksumAndEveryTypedFingerprintAreVerified() throws {
        try withFixture { fixture in
            try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
            let badChecksum = replacingChecksum(
                in: fixture.entry,
                with: ProfileMutationPayloadChecksum(data: Data("wrong".utf8))
            )
            try writeCanonical(badChecksum, to: fixture.store.journalURL)
            #expect(
                try fixture.store.load()
                    == .corrupt(component: .pair, reason: .payloadChecksumMismatch)
            )
        }

        for mutation in FingerprintMutation.allCases {
            try withFixture { fixture in
                let entry = mutation.apply(to: fixture.entry)
                try writeCanonical(entry, to: fixture.store.journalURL)
                try writeCanonical(fixture.payload, to: fixture.store.payloadURL)

                #expect(
                    try fixture.store.load()
                        == .corrupt(component: .pair, reason: mutation.expectedCorruption)
                )
            }
        }
    }

    @Test func runtimeAndProfileIdentitiesAreVerifiedAgainstExactPayloads() throws {
        try withFixture { fixture in
            let entry = replacingOldRuntimeIdentity(
                in: fixture.entry,
                with: ProfileMutationRuntimeIdentity(
                    profileID: fixture.entry.oldRuntimeIdentity.profileID,
                    generation: UUID(),
                    configurationFingerprint: fixture.entry.oldRuntimeIdentity.configurationFingerprint
                )
            )
            try writeCanonical(entry, to: fixture.store.journalURL)
            try writeCanonical(fixture.payload, to: fixture.store.payloadURL)
            #expect(
                try fixture.store.load()
                    == .corrupt(component: .pair, reason: .runtimeIdentityMismatch(.old))
            )
        }
    }

    @Test func unsupportedNewerCorruptAndNonCanonicalJSONAreClassified() throws {
        try withFixture { fixture in
            try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
            try replaceSchemaVersion(1, at: fixture.store.journalURL)
            #expect(
                try fixture.store.load()
                    == .unsupportedSchema(component: .journal, version: 1)
            )
        }
        try withFixture { fixture in
            try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
            try replaceSchemaVersion(2, at: fixture.store.payloadURL)
            #expect(
                try fixture.store.load()
                    == .newerSchema(component: .payload, version: 2)
            )
        }
        try withFixture { fixture in
            try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
            try Data("not-json".utf8).write(to: fixture.store.journalURL)
            #expect(
                try fixture.store.load()
                    == .corrupt(component: .journal, reason: .invalidJSON)
            )
        }
        try withFixture { fixture in
            try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
            let object = try JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.store.journalURL)
            )
            let pretty = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            )
            try pretty.write(to: fixture.store.journalURL)
            #expect(
                try fixture.store.load()
                    == .corrupt(component: .journal, reason: .nonCanonicalJSON)
            )
        }
    }

    @Test func journalPublicationFailuresPreserveAndRecoverExactEvidence() throws {
        for failure in JournalFailurePoint.journalPublicationFailures {
            try withFixture(fileSystemFailure: failure) { fixture in
                #expect(throws: (any Error).self) {
                    try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
                }
                #expect(FileManager.default.fileExists(atPath: fixture.store.payloadURL.path))
                if failure == .journalDirectorySync {
                    #expect(FileManager.default.fileExists(atPath: fixture.store.journalURL.path))
                } else {
                    #expect(!FileManager.default.fileExists(atPath: fixture.store.journalURL.path))
                }
                let temporaryFileNames = try temporaryFiles(in: fixture.directoryURL)
                #expect(temporaryFileNames.isEmpty)

                let restarted = ProfileMutationJournal(directoryURL: fixture.directoryURL)
                #expect(try restarted.load() == .loaded(fixture.entry, fixture.payload))
            }
        }
    }

    @Test func failedPhaseReplacementPreservesLoadablePriorEvidence() throws {
        for failure in JournalFailurePoint.journalPublicationFailures where failure != .journalDirectorySync {
            try withFixture { baseline in
                try baseline.store.write(entry: baseline.entry, payload: baseline.payload)
                let failingStore = ProfileMutationJournal(
                    directoryURL: baseline.directoryURL,
                    fileSystem: FailingJournalFileSystem(failure: failure)
                )

                #expect(throws: (any Error).self) {
                    try failingStore.updatePhase(
                        operationIdentity: baseline.entry.operationIdentity,
                        to: .configurationCommitted
                    )
                }
                #expect(try baseline.store.load() == .loaded(baseline.entry, baseline.payload))
                #expect(try temporaryFiles(in: baseline.directoryURL).isEmpty)
            }
        }
    }

    @Test func cleanupRemovesOnlyThePairAndSynchronizesDirectory() throws {
        try withFixture { fixture in
            let unrelatedURL = fixture.directoryURL.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: unrelatedURL)
            try fixture.store.write(entry: fixture.entry, payload: fixture.payload)

            try fixture.store.cleanup(operationIdentity: fixture.entry.operationIdentity)

            #expect(try fixture.store.load() == .missing)
            #expect(try Data(contentsOf: unrelatedURL) == Data("keep".utf8))
        }
    }

    @Test func payloadPublicationCrashIsCompletedAfterRestartOnlyForExactEvidence() throws {
        try withFixture(fileSystemFailure: .payloadDirectorySync) { fixture in
            #expect(throws: (any Error).self) {
                try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
            }
            #expect(FileManager.default.fileExists(atPath: fixture.store.payloadURL.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.store.journalURL.path))
            #expect(FileManager.default.fileExists(atPath: fixture.store.stateURL.path))
            let attributes = try FileManager.default.attributesOfItem(
                atPath: fixture.store.stateURL.path
            )
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.uint16Value == 0o600)

            let restarted = ProfileMutationJournal(directoryURL: fixture.directoryURL)
            #expect(try restarted.load() == .loaded(fixture.entry, fixture.payload))
            try restarted.write(entry: fixture.entry, payload: fixture.payload)
            #expect(try restarted.load() == .loaded(fixture.entry, fixture.payload))
        }

        try withFixture(fileSystemFailure: .payloadDirectorySync) { fixture in
            #expect(throws: (any Error).self) {
                try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
            }
            try Data("unknown".utf8).write(to: fixture.store.payloadURL)

            let restarted = ProfileMutationJournal(directoryURL: fixture.directoryURL)
            #expect(
                try restarted.load()
                    == .corrupt(component: .payload, reason: .invalidJSON)
            )
            #expect(FileManager.default.fileExists(atPath: restarted.payloadURL.path))
            #expect(FileManager.default.fileExists(atPath: restarted.stateURL.path))
            #expect(!FileManager.default.fileExists(atPath: restarted.journalURL.path))
        }
    }

    @Test func cleanupCrashBetweenPairUnlinksIsCompletedAfterRestart() throws {
        try withFixture { fixture in
            try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
            let failing = ProfileMutationJournal(
                directoryURL: fixture.directoryURL,
                fileSystem: FailingJournalFileSystem(failure: .payloadUnlink)
            )

            #expect(throws: (any Error).self) {
                try failing.cleanup(operationIdentity: fixture.entry.operationIdentity)
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.store.journalURL.path))
            #expect(FileManager.default.fileExists(atPath: fixture.store.payloadURL.path))
            #expect(FileManager.default.fileExists(atPath: fixture.store.stateURL.path))

            let restarted = ProfileMutationJournal(directoryURL: fixture.directoryURL)
            #expect(try restarted.load() == .missing)
            try restarted.cleanup(operationIdentity: fixture.entry.operationIdentity)
            #expect(try restarted.load() == .missing)
        }
    }

    @Test func cleanupDirectorySyncCrashIsCompletedAfterRestart() throws {
        try withFixture { fixture in
            try fixture.store.write(entry: fixture.entry, payload: fixture.payload)
            let failing = ProfileMutationJournal(
                directoryURL: fixture.directoryURL,
                fileSystem: FailingJournalFileSystem(failure: .cleanupDirectorySync)
            )

            #expect(throws: (any Error).self) {
                try failing.cleanup(operationIdentity: fixture.entry.operationIdentity)
            }
            #expect(FileManager.default.fileExists(atPath: fixture.store.stateURL.path))

            let restarted = ProfileMutationJournal(directoryURL: fixture.directoryURL)
            #expect(try restarted.load() == .missing)
            #expect(!FileManager.default.fileExists(atPath: restarted.stateURL.path))
        }
    }

    private func withFixture(
        fileSystemFailure: JournalFailurePoint? = nil,
        _ body: (JournalFixture) throws -> Void
    ) throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DNSPilot-ProfileMutationJournal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let fileSystem: any ConfigurationFileSystem = if let fileSystemFailure {
            FailingJournalFileSystem(failure: fileSystemFailure)
        } else {
            LocalConfigurationFileSystem()
        }
        let store = ProfileMutationJournal(directoryURL: directoryURL, fileSystem: fileSystem)
        let operationIdentity = ProfileMutationOperationIdentity(
            operationID: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!,
            runtimeTransactionID: UUID(uuidString: "60000000-0000-0000-0000-000000000002")!
        )
        let oldProfileID = UUID(uuidString: "60000000-0000-0000-0000-000000000003")!
        let draftProfileID = UUID(uuidString: "60000000-0000-0000-0000-000000000004")!
        let oldAppData = try PersistedAppConfiguration(
            value: AppConfiguration(
                profiles: [try DNSProfile(id: oldProfileID, name: "Old", upstream: .fixedCloudflare)],
                defaultProfileID: oldProfileID,
                operatingMode: .manual(profileID: oldProfileID)
            )
        ).data
        let draftAppData = try PersistedAppConfiguration(
            value: AppConfiguration(
                profiles: [try DNSProfile(id: draftProfileID, name: "Draft", upstream: .fixedForCurrentBuild)],
                defaultProfileID: draftProfileID,
                operatingMode: .manual(profileID: draftProfileID)
            )
        ).data
        let oldRuntime = try PersistedProxyConfiguration(
            value: ActiveProxyConfiguration(
                generation: UUID(uuidString: "60000000-0000-0000-0000-000000000005")!,
                profileID: oldProfileID,
                upstream: .fixedCloudflare
            )
        )
        let draftRuntime = try PersistedProxyConfiguration(
            value: ActiveProxyConfiguration(
                generation: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
                profileID: draftProfileID,
                upstream: .fixedForCurrentBuild
            )
        )
        let payload = ProfileMutationRecoveryPayload(
            operationIdentity: operationIdentity,
            oldAppConfigurationJSON: oldAppData,
            draftAppConfigurationJSON: draftAppData,
            oldRuntimePropertyList: oldRuntime.data,
            draftRuntimePropertyList: draftRuntime.data
        )
        let entry = ProfileMutationJournalEntry(
            operationIdentity: operationIdentity,
            phase: .prepared,
            oldAppConfigurationFingerprint: AppConfigurationFingerprint(data: oldAppData),
            draftAppConfigurationFingerprint: AppConfigurationFingerprint(data: draftAppData),
            oldProfileID: oldProfileID,
            draftProfileID: draftProfileID,
            oldRuntimeIdentity: ProfileMutationRuntimeIdentity(
                profileID: oldProfileID,
                generation: oldRuntime.value.generation,
                configurationFingerprint: oldRuntime.fingerprint
            ),
            draftRuntimeIdentity: ProfileMutationRuntimeIdentity(
                profileID: draftProfileID,
                generation: draftRuntime.value.generation,
                configurationFingerprint: draftRuntime.fingerprint
            ),
            payloadChecksum: try store.payloadChecksum(for: payload)
        )
        try body(
            JournalFixture(
                directoryURL: directoryURL,
                store: store,
                entry: entry,
                payload: payload
            )
        )
    }
}

private struct JournalFixture {
    let directoryURL: URL
    let store: ProfileMutationJournal
    let entry: ProfileMutationJournalEntry
    let payload: ProfileMutationRecoveryPayload
}

private enum FingerprintMutation: CaseIterable {
    case oldApp
    case draftApp
    case oldRuntime
    case draftRuntime

    var expectedCorruption: ProfileMutationJournalCorruption {
        switch self {
        case .oldApp: .appConfigurationFingerprintMismatch(.old)
        case .draftApp: .appConfigurationFingerprintMismatch(.draft)
        case .oldRuntime: .runtimeConfigurationFingerprintMismatch(.old)
        case .draftRuntime: .runtimeConfigurationFingerprintMismatch(.draft)
        }
    }

    func apply(to entry: ProfileMutationJournalEntry) -> ProfileMutationJournalEntry {
        let badApp = AppConfigurationFingerprint(data: Data("bad-app".utf8))
        let badRuntime = ProxyConfigurationFingerprint(data: Data("bad-runtime".utf8))
        return ProfileMutationJournalEntry(
            operationIdentity: entry.operationIdentity,
            phase: entry.phase,
            oldAppConfigurationFingerprint: self == .oldApp
                ? badApp : entry.oldAppConfigurationFingerprint,
            draftAppConfigurationFingerprint: self == .draftApp
                ? badApp : entry.draftAppConfigurationFingerprint,
            oldProfileID: entry.oldProfileID,
            draftProfileID: entry.draftProfileID,
            oldRuntimeIdentity: ProfileMutationRuntimeIdentity(
                profileID: entry.oldRuntimeIdentity.profileID,
                generation: entry.oldRuntimeIdentity.generation,
                configurationFingerprint: self == .oldRuntime
                    ? badRuntime : entry.oldRuntimeIdentity.configurationFingerprint
            ),
            draftRuntimeIdentity: ProfileMutationRuntimeIdentity(
                profileID: entry.draftRuntimeIdentity.profileID,
                generation: entry.draftRuntimeIdentity.generation,
                configurationFingerprint: self == .draftRuntime
                    ? badRuntime : entry.draftRuntimeIdentity.configurationFingerprint
            ),
            payloadChecksum: entry.payloadChecksum
        )
    }
}

private enum JournalFailurePoint: Sendable {
    case stateWrite
    case stateSync
    case stateRename
    case stateDirectorySync
    case journalWrite
    case journalSync
    case journalRename
    case journalDirectorySync
    case payloadDirectorySync
    case payloadUnlink
    case cleanupDirectorySync

    static let statePublicationFailures: [Self] = [
        .stateWrite,
        .stateSync,
        .stateRename,
        .stateDirectorySync,
    ]

    static let journalPublicationFailures: [Self] = [
        .journalWrite,
        .journalSync,
        .journalRename,
        .journalDirectorySync,
    ]
}

private struct FailingJournalFileSystem: ConfigurationFileSystem {
    let failure: JournalFailurePoint
    private let base = LocalConfigurationFileSystem()

    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func itemExists(at url: URL) -> Bool { base.itemExists(at: url) }
    func readFile(at url: URL) throws -> Data { try base.readFile(at: url) }

    func createFile(at url: URL, data: Data, permissions: UInt16) throws {
        if failure == .stateWrite, url.lastPathComponent.contains("mutation-state") {
            throw JournalTestError.injected
        }
        if failure == .journalWrite, url.lastPathComponent.contains("mutation-journal") {
            throw JournalTestError.injected
        }
        try base.createFile(at: url, data: data, permissions: permissions)
    }

    func synchronizeFile(at url: URL) throws {
        if failure == .stateSync, url.lastPathComponent.contains("mutation-state") {
            throw JournalTestError.injected
        }
        if failure == .journalSync, url.lastPathComponent.contains("mutation-journal") {
            throw JournalTestError.injected
        }
        try base.synchronizeFile(at: url)
    }

    func replaceAtomically(itemAt destinationURL: URL, withItemAt sourceURL: URL) throws {
        if failure == .stateRename,
           destinationURL.lastPathComponent == ProfileMutationJournal.stateFileName {
            throw JournalTestError.injected
        }
        if failure == .journalRename,
           destinationURL.lastPathComponent == ProfileMutationJournal.journalFileName {
            throw JournalTestError.injected
        }
        try base.replaceAtomically(itemAt: destinationURL, withItemAt: sourceURL)
    }

    func synchronizeDirectory(at url: URL) throws {
        if failure == .stateDirectorySync,
           base.itemExists(at: url.appendingPathComponent(ProfileMutationJournal.stateFileName)),
           !base.itemExists(at: url.appendingPathComponent(ProfileMutationJournal.payloadFileName)),
           !base.itemExists(at: url.appendingPathComponent(ProfileMutationJournal.journalFileName)) {
            throw JournalTestError.injected
        }
        if failure == .payloadDirectorySync,
           base.itemExists(at: url.appendingPathComponent(ProfileMutationJournal.payloadFileName)),
           !base.itemExists(at: url.appendingPathComponent(ProfileMutationJournal.journalFileName)) {
            throw JournalTestError.injected
        }
        if failure == .cleanupDirectorySync,
           base.itemExists(at: url.appendingPathComponent(ProfileMutationJournal.stateFileName)),
           !base.itemExists(at: url.appendingPathComponent(ProfileMutationJournal.journalFileName)),
           !base.itemExists(at: url.appendingPathComponent(ProfileMutationJournal.payloadFileName)) {
            throw JournalTestError.injected
        }
        if failure == .journalDirectorySync,
           base.itemExists(
               at: url.appendingPathComponent(ProfileMutationJournal.journalFileName)
           ) {
            throw JournalTestError.injected
        }
        try base.synchronizeDirectory(at: url)
    }

    func removeFileIfPresent(at url: URL) throws {
        if failure == .payloadUnlink,
           url.lastPathComponent == ProfileMutationJournal.payloadFileName {
            throw JournalTestError.injected
        }
        try base.removeFileIfPresent(at: url)
    }
}

private enum JournalTestError: Error {
    case injected
}

private func replacingChecksum(
    in entry: ProfileMutationJournalEntry,
    with checksum: ProfileMutationPayloadChecksum
) -> ProfileMutationJournalEntry {
    ProfileMutationJournalEntry(
        operationIdentity: entry.operationIdentity,
        phase: entry.phase,
        oldAppConfigurationFingerprint: entry.oldAppConfigurationFingerprint,
        draftAppConfigurationFingerprint: entry.draftAppConfigurationFingerprint,
        oldProfileID: entry.oldProfileID,
        draftProfileID: entry.draftProfileID,
        oldRuntimeIdentity: entry.oldRuntimeIdentity,
        draftRuntimeIdentity: entry.draftRuntimeIdentity,
        payloadChecksum: checksum
    )
}

private func replacingOldRuntimeIdentity(
    in entry: ProfileMutationJournalEntry,
    with identity: ProfileMutationRuntimeIdentity
) -> ProfileMutationJournalEntry {
    ProfileMutationJournalEntry(
        operationIdentity: entry.operationIdentity,
        phase: entry.phase,
        oldAppConfigurationFingerprint: entry.oldAppConfigurationFingerprint,
        draftAppConfigurationFingerprint: entry.draftAppConfigurationFingerprint,
        oldProfileID: entry.oldProfileID,
        draftProfileID: entry.draftProfileID,
        oldRuntimeIdentity: identity,
        draftRuntimeIdentity: entry.draftRuntimeIdentity,
        payloadChecksum: entry.payloadChecksum
    )
}

private func writeCanonical<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url)
}

private func replaceSchemaVersion(_ version: Int, at url: URL) throws {
    var object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    object["schemaVersion"] = version
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: url)
}

private func temporaryFiles(in directoryURL: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        .filter { $0.hasPrefix(".profile-mutation-") && $0.hasSuffix(".tmp") }
}
