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
            activeGeneration: UUID(),
            activeConfigurationFingerprint: ProxyConfigurationFingerprint(data: activeData),
            activeProfileID: UUID()
        )
        try operation(journal, record, directoryURL)
    }
}
