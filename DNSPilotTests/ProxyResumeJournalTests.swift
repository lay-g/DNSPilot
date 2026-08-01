import CryptoKit
import Foundation
import Testing
@testable import DNSPilot

struct ProxyResumeJournalTests {
    @Test func canonicalRoundTripAndOwnerOnlyPermissions() throws {
        try withFixture { journal, record, _ in
            try journal.prepare(record)

            #expect(try journal.load() == .loaded(record))
            let attributes = try FileManager.default.attributesOfItem(
                atPath: journal.recordURL.path
            )
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.uint16Value == 0o600)

            let data = try Data(contentsOf: journal.recordURL)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["checksum"] != nil)
            #expect(json["upstream"] == nil)
            #expect(json["providerConfiguration"] == nil)
        }
    }

    @Test func phaseTransitionsAreDurableAndIdempotent() throws {
        try withFixture { journal, record, _ in
            try journal.prepare(record)
            try journal.confirmDisabled(operationID: record.operationID)
            try journal.confirmDisabled(operationID: record.operationID)
            let attemptID = UUID()

            let claimed = try journal.claim(
                operationID: record.operationID,
                attemptID: attemptID
            )
            #expect(claimed.phase == .claimedForLaunch)
            #expect(claimed.attemptID == attemptID)
            #expect(
                try journal.claim(operationID: record.operationID, attemptID: attemptID)
                    == claimed
            )

            try journal.markFailed(
                operationID: record.operationID,
                attemptID: attemptID,
                code: .activationFailed
            )
            guard case let .loaded(failed) = try journal.load() else {
                Issue.record("Expected failed resume record")
                return
            }
            #expect(failed.phase == .failed)
            #expect(failed.failureCode == .activationFailed)

            let retry = try journal.prepareRetry(operationID: record.operationID)
            #expect(retry.phase == .disabledConfirmed)
            #expect(retry.attemptID == nil)
            #expect(retry.failureCode == nil)
        }
    }

    @Test func staleOperationsAndSecondClaimsAreRejected() throws {
        try withFixture { journal, record, _ in
            try journal.prepare(record)
            #expect(throws: ProxyResumeJournalError.operationConflict) {
                try journal.confirmDisabled(operationID: UUID())
            }
            let attemptID = UUID()
            _ = try journal.claim(operationID: record.operationID, attemptID: attemptID)
            #expect(throws: ProxyResumeJournalError.phaseConflict) {
                _ = try journal.claim(operationID: record.operationID, attemptID: UUID())
            }
        }
    }

    @Test func extensionUpgradeMustBeConfirmedBeforeResumeClaim() throws {
        try withFixture { journal, record, _ in
            try journal.prepare(record)
            try journal.confirmDisabled(operationID: record.operationID)
            let source = ProxyResumeExtensionBuildIdentity(
                shortVersion: "1.0",
                buildVersion: "36"
            )
            let target = ProxyResumeExtensionBuildIdentity(
                shortVersion: "1.1",
                buildVersion: "39"
            )
            let prepared = try journal.prepareExtensionUpgrade(
                operationID: record.operationID,
                source: source,
                target: target,
                localizedDescriptionFingerprint: record
                    .managerLocalizedDescriptionFingerprint!
            )
            let upgrade = try #require(prepared.extensionUpgrade)
            let attemptID = UUID()
            let submitted = try journal.markExtensionUpgradeSubmitted(
                operationID: record.operationID,
                upgradeOperationID: upgrade.operationID,
                attemptID: attemptID
            )
            #expect(submitted.extensionUpgrade?.phase == .replacementSubmitted)
            #expect(throws: ProxyResumeJournalError.phaseConflict) {
                _ = try journal.claim(operationID: record.operationID, attemptID: UUID())
            }

            let confirmed = try journal.confirmExtensionUpgrade(
                operationID: record.operationID,
                upgradeOperationID: upgrade.operationID,
                ownerConfigurationFingerprint: record.ownerConfigurationFingerprint,
                localizedDescriptionFingerprint: record
                    .managerLocalizedDescriptionFingerprint!
            )
            #expect(confirmed.schemaVersion == ProxyResumeRecord.currentSchemaVersion)
            #expect(confirmed.extensionUpgrade?.phase == .replacementConfirmed)
            #expect(
                try journal.claim(operationID: record.operationID, attemptID: UUID()).phase
                    == .claimedForLaunch
            )
        }
    }

    @Test func schemaOneRecordRemainsEligibleAndUpgradesOnExtensionPrepare() throws {
        try withFixture { journal, record, _ in
            let schemaOneRecord = ProxyResumeRecord(
                schemaVersion: 1,
                operationID: record.operationID,
                phase: record.phase,
                appConfigurationFingerprint: record.appConfigurationFingerprint,
                providerBundleIdentifier: record.providerBundleIdentifier,
                ownerConfigurationFingerprint: record.ownerConfigurationFingerprint,
                managerLocalizedDescriptionFingerprint: nil,
                activeGeneration: record.activeGeneration,
                activeConfigurationFingerprint: record.activeConfigurationFingerprint,
                activeProfileID: record.activeProfileID
            )
            try writeStoredRecord(schemaOneRecord, to: journal.recordURL)

            #expect(try journal.load() == .loaded(schemaOneRecord))
            let prepared = try journal.prepareExtensionUpgrade(
                operationID: schemaOneRecord.operationID,
                source: .init(shortVersion: "1.0", buildVersion: "36"),
                target: .init(shortVersion: "1.1", buildVersion: "39"),
                localizedDescriptionFingerprint: record
                    .managerLocalizedDescriptionFingerprint!
            )

            #expect(prepared.schemaVersion == ProxyResumeRecord.currentSchemaVersion)
            #expect(prepared.managerLocalizedDescriptionFingerprint != nil)
            #expect(prepared.extensionUpgrade?.phase == .prepared)
        }
    }

    @Test func corruptRecordIsPreservedAndCannotBePreparedOver() throws {
        try withFixture { journal, record, _ in
            try Data("not-json".utf8).write(to: journal.recordURL)

            guard case let .corrupt(reason, artifactURL) = try journal.load() else {
                Issue.record("Expected corrupt resume record")
                return
            }
            #expect(reason == .invalidJSON)
            #expect(try Data(contentsOf: artifactURL) == Data("not-json".utf8))
            #expect(throws: ProxyResumeJournalError.existingEvidenceRequiresRecovery) {
                try journal.prepare(record)
            }
        }
    }

    @Test func discardRequiresMatchingOperationButRecoveryDiscardRemovesCorruptSource() throws {
        try withFixture { journal, record, _ in
            try journal.prepare(record)
            #expect(throws: ProxyResumeJournalError.operationConflict) {
                try journal.discard(operationID: UUID())
            }
            try journal.discard(operationID: record.operationID)
            #expect(try journal.load() == .missing)

            try Data("bad".utf8).write(to: journal.recordURL)
            _ = try journal.load()
            try journal.discard(operationID: nil)
            #expect(try journal.load() == .missing)
        }
    }

    private func withFixture(
        _ operation: (ProxyResumeJournal, ProxyResumeRecord, URL) throws -> Void
    ) throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DNSPilot-ProxyResumeJournalTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let journal = ProxyResumeJournal(directoryURL: directoryURL)
        let activeData = Data("active-configuration".utf8)
        let record = ProxyResumeRecord(
            operationID: UUID(),
            phase: .preparedForQuit,
            appConfigurationFingerprint: AppConfigurationFingerprint(data: Data("app".utf8)),
            providerBundleIdentifier: "com.example.DNSPilot.Proxy",
            ownerConfigurationFingerprint: ProxyConfigurationFingerprint(data: Data("owner".utf8)),
            managerLocalizedDescriptionFingerprint: ProxyConfigurationFingerprint(
                data: Data("description".utf8)
            ),
            activeGeneration: UUID(),
            activeConfigurationFingerprint: ProxyConfigurationFingerprint(data: activeData),
            activeProfileID: UUID()
        )
        try operation(journal, record, directoryURL)
    }

    private func writeStoredRecord(_ record: ProxyResumeRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let recordData = try encoder.encode(record)
        let checksum = SHA256.hash(data: recordData)
            .map { String(format: "%02x", $0) }
            .joined()
        let stored = StoredRecordFixture(
            schemaVersion: 1,
            record: record,
            checksum: checksum
        )
        try encoder.encode(stored).write(to: url)
    }

    private struct StoredRecordFixture: Codable {
        let schemaVersion: Int
        let record: ProxyResumeRecord
        let checksum: String
    }
}
