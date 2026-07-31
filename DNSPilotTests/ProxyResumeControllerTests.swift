import Foundation
import Testing
@testable import DNSPilot

struct ProxyResumeControllerTests {
    @Test func safeQuitPersistsConfirmedRecordBeforeReturningDisabled() async throws {
        try await withFixture { directoryURL in
            let configuration = try PersistedProxyConfiguration(value: makeConfiguration())
            let manager = FakeDNSProxyManager(
                isEnabled: true,
                persistedConfiguration: configuration
            )
            let runtime = FakeRuntimeSession(activeConfiguration: configuration)
            let controller = makeController(
                manager: manager,
                statusProvider: runtime,
                runtimeController: runtime
            )
            let journal = ProxyResumeJournal(directoryURL: directoryURL)
            let appFingerprint = AppConfigurationFingerprint(data: Data("app".utf8))
            await controller.configureResumeJournal(
                journal,
                appConfigurationFingerprint: appFingerprint
            )
            #expect(await controller.synchronizeState() == .active(configuration.value.generation))

            let result = await controller.restoreSystemDNSForTerminationResult()

            #expect(result == .disabled)
            guard case let .loaded(record) = try journal.load() else {
                Issue.record("Expected safe-Quit resume record")
                return
            }
            #expect(record.phase == .disabledConfirmed)
            #expect(record.activeGeneration == configuration.value.generation)
            #expect(record.activeConfigurationFingerprint == configuration.fingerprint)
            #expect(await manager.currentSnapshot.isEnabled == false)
            #expect(await runtime.quiesceRequests.count == 1)
        }
    }

    @Test func journalPreparationFailureLeavesRuntimeAndManagerActive() async throws {
        let configuration = try PersistedProxyConfiguration(value: makeConfiguration())
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            persistedConfiguration: configuration
        )
        let runtime = FakeRuntimeSession(activeConfiguration: configuration)
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )
        await controller.configureResumeJournal(
            FailingProxyResumeJournal(),
            appConfigurationFingerprint: AppConfigurationFingerprint(data: Data("app".utf8))
        )
        _ = await controller.synchronizeState()

        let result = await controller.restoreSystemDNSForTerminationResult()

        guard case .resumePreparationFailed = result else {
            Issue.record("Expected resume preparation failure")
            return
        }
        #expect(await manager.currentSnapshot.isEnabled)
        #expect(await manager.disableSaveCount == 0)
        #expect(await runtime.quiesceRequests.isEmpty)
    }

    @Test func retryQuitReusesExactPreparedRecord() async throws {
        try await withFixture { directoryURL in
            let configuration = try PersistedProxyConfiguration(value: makeConfiguration())
            let manager = FakeDNSProxyManager(
                isEnabled: true,
                persistedConfiguration: configuration
            )
            let runtime = FakeRuntimeSession(activeConfiguration: configuration)
            let controller = makeController(
                manager: manager,
                statusProvider: runtime,
                runtimeController: runtime
            )
            let journal = ProxyResumeJournal(directoryURL: directoryURL)
            let appFingerprint = AppConfigurationFingerprint(data: Data("app".utf8))
            let record = makeRecord(
                managerSnapshot: await manager.currentSnapshot,
                appFingerprint: appFingerprint,
                configuration: configuration
            )
            try journal.prepare(record)
            await controller.configureResumeJournal(
                journal,
                appConfigurationFingerprint: appFingerprint
            )
            #expect(await controller.synchronizeState() == .active(configuration.value.generation))

            #expect(await controller.restoreSystemDNSForTerminationResult() == .disabled)

            guard case let .loaded(confirmed) = try journal.load() else {
                Issue.record("Expected confirmed resume record")
                return
            }
            #expect(confirmed.operationID == record.operationID)
            #expect(confirmed.phase == .disabledConfirmed)
        }
    }

    @Test func exactDisabledRecordIsClaimedAndFencedBeforeEnable() async throws {
        try await withFixture { directoryURL in
            let old = try PersistedProxyConfiguration(value: makeConfiguration())
            let manager = FakeDNSProxyManager(
                isEnabled: false,
                persistedConfiguration: old
            )
            let journal = ProxyResumeJournal(directoryURL: directoryURL)
            let appFingerprint = AppConfigurationFingerprint(data: Data("app".utf8))
            let record = makeRecord(
                managerSnapshot: await manager.currentSnapshot,
                appFingerprint: appFingerprint,
                configuration: old
            )
            try journal.prepare(record)
            try journal.confirmDisabled(operationID: record.operationID)
            let status = ManagerBackedStatusProvider(manager: manager)
            let controller = makeController(manager: manager, statusProvider: status)
            await controller.configureResumeJournal(
                journal,
                appConfigurationFingerprint: appFingerprint
            )
            #expect(await controller.synchronizeState() == .disabled)
            #expect(await controller.evaluateStartupResume() == .pending(
                record.updating(phase: .disabledConfirmed)
            ))
            let target = DNSProxyTarget(
                profileID: old.value.profileID,
                upstream: old.value.upstream
            )

            let snapshot = await controller.resumeAfterSafeQuit(
                target: target,
                record: record.updating(phase: .disabledConfirmed),
                appConfigurationFingerprint: appFingerprint
            )

            guard case .active = snapshot.state else {
                Issue.record("Expected resumed Active state")
                return
            }
            #expect(try journal.load() == .missing)
            #expect(await manager.enableSaveCount == 1)
            #expect(await manager.events.contains { event in
                if case .fencedEnable = event { true } else { false }
            })
        }
    }

    @Test func changedManagerBlocksStartupResumeWithoutEnableSave() async throws {
        try await withFixture { directoryURL in
            let old = try PersistedProxyConfiguration(value: makeConfiguration())
            let manager = FakeDNSProxyManager(
                isEnabled: false,
                persistedConfiguration: old
            )
            let journal = ProxyResumeJournal(directoryURL: directoryURL)
            let appFingerprint = AppConfigurationFingerprint(data: Data("app".utf8))
            let record = makeRecord(
                managerSnapshot: await manager.currentSnapshot,
                appFingerprint: appFingerprint,
                configuration: old
            )
            try journal.prepare(record)
            await manager.replaceOwnerIdentity(DNSProxyManagerOwnerIdentity(
                providerBundleIdentifier: "com.example.OtherProxy",
                providerConfigurationFingerprint: ProxyConfigurationFingerprint(
                    data: Data("other".utf8)
                ),
                localizedDescription: "Other"
            ))
            let controller = makeController(manager: manager)
            await controller.configureResumeJournal(
                journal,
                appConfigurationFingerprint: appFingerprint
            )

            #expect(await controller.evaluateStartupResume() == .failed(.managerChanged))
            #expect(await manager.enableSaveCount == 0)
        }
    }

    @Test func uncertainResumeSaveWithChangedManagerRequiresRecovery() async throws {
        try await withFixture { directoryURL in
            let old = try PersistedProxyConfiguration(value: makeConfiguration())
            let external = try ActiveProxyConfiguration(
                generation: UUID(),
                profileID: UUID(),
                upstream: old.value.upstream,
                loggingMode: old.value.loggingMode,
                schemaVersion: old.value.schemaVersion
            )
            let manager = FakeDNSProxyManager(
                isEnabled: false,
                activeConfiguration: old.value,
                enableFailures: [.configurationStaleReplacing(external)]
            )
            let journal = ProxyResumeJournal(directoryURL: directoryURL)
            let appFingerprint = AppConfigurationFingerprint(data: Data("app".utf8))
            let record = makeRecord(
                managerSnapshot: await manager.currentSnapshot,
                appFingerprint: appFingerprint,
                configuration: old
            )
            try journal.prepare(record)
            try journal.confirmDisabled(operationID: record.operationID)
            let confirmedRecord = record.updating(phase: .disabledConfirmed)
            let controller = makeController(manager: manager)
            await controller.configureResumeJournal(
                journal,
                appConfigurationFingerprint: appFingerprint
            )
            let target = DNSProxyTarget(
                profileID: old.value.profileID,
                upstream: old.value.upstream
            )

            let snapshot = await controller.resumeAfterSafeQuit(
                target: target,
                record: confirmedRecord,
                appConfigurationFingerprint: appFingerprint
            )

            guard case .recoveryRequired = snapshot.state else {
                Issue.record("Expected recovery after uncertain manager save, got \(snapshot.state)")
                return
            }
            #expect(await manager.currentSnapshot.activeConfiguration == external)
        }
    }

    @Test func cancelQuitDiscardsPreparedRecordAfterExactActiveIsRestored() async throws {
        try await withFixture { directoryURL in
            let active = try PersistedProxyConfiguration(value: makeConfiguration())
            let manager = FakeDNSProxyManager(
                isEnabled: true,
                persistedConfiguration: active
            )
            let journal = ProxyResumeJournal(directoryURL: directoryURL)
            let appFingerprint = AppConfigurationFingerprint(data: Data("app".utf8))
            let record = makeRecord(
                managerSnapshot: await manager.currentSnapshot,
                appFingerprint: appFingerprint,
                configuration: active
            )
            try journal.prepare(record)
            let controller = makeController(
                manager: manager,
                statusProvider: ManagerBackedStatusProvider(manager: manager)
            )
            await controller.configureResumeJournal(
                journal,
                appConfigurationFingerprint: appFingerprint
            )
            #expect(await controller.synchronizeState() == .active(active.value.generation))

            await controller.cancelTerminationRequest()

            #expect(try journal.load() == .missing)
            #expect(await manager.currentSnapshot.isEnabled)
        }
    }

    private func makeRecord(
        managerSnapshot: DNSProxyManagerSnapshot,
        appFingerprint: AppConfigurationFingerprint,
        configuration: PersistedProxyConfiguration
    ) -> ProxyResumeRecord {
        let owner = managerSnapshot.ownerIdentity!
        return ProxyResumeRecord(
            operationID: UUID(),
            phase: .preparedForQuit,
            appConfigurationFingerprint: appFingerprint,
            providerBundleIdentifier: owner.providerBundleIdentifier!,
            ownerConfigurationFingerprint: owner.providerConfigurationFingerprint,
            activeGeneration: configuration.value.generation,
            activeConfigurationFingerprint: configuration.fingerprint,
            activeProfileID: configuration.value.profileID
        )
    }

    private func withFixture(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DNSPilot-ProxyResumeControllerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try await operation(directoryURL)
    }
}

private struct FailingProxyResumeJournal: ProxyResumeJournalStoring {
    func load() throws -> ProxyResumeJournalLoadResult { .missing }
    func prepare(_ record: ProxyResumeRecord) throws { throw FakeTestError.saveFailed }
    func confirmDisabled(operationID: UUID) throws {}
    func claim(operationID: UUID, attemptID: UUID) throws -> ProxyResumeRecord {
        throw FakeTestError.saveFailed
    }
    func markFailed(
        operationID: UUID,
        attemptID: UUID,
        code: ProxyResumeFailureCode
    ) throws {}
    func prepareRetry(operationID: UUID) throws -> ProxyResumeRecord {
        throw FakeTestError.saveFailed
    }
    func discard(operationID: UUID?) throws {}
}

private actor ManagerBackedStatusProvider: ProxyRuntimeStatusProviding {
    private let manager: FakeDNSProxyManager
    private let providerInstanceID = UUID()

    init(manager: FakeDNSProxyManager) {
        self.manager = manager
    }

    func runtimeStatus() async -> ProxyRuntimeStatus {
        let snapshot = await manager.currentSnapshot
        guard snapshot.isEnabled, let configuration = snapshot.persistedConfiguration else {
            return ProxyRuntimeStatus(
                generation: nil,
                phase: .idle,
                errorCode: nil,
                updatedAt: Date(timeIntervalSince1970: 0),
                maximumConfigurationSchemaVersion: ActiveProxyConfiguration.currentSchemaVersion,
                runtimeControlProtocolVersion: DNSProxyXPCContract.currentRuntimeControlProtocolVersion,
                providerInstanceID: providerInstanceID
            )
        }
        return ProxyRuntimeStatus(
            generation: configuration.value.generation,
            phase: .ready,
            errorCode: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            maximumConfigurationSchemaVersion: ActiveProxyConfiguration.currentSchemaVersion,
            runtimeControlProtocolVersion: DNSProxyXPCContract.currentRuntimeControlProtocolVersion,
            providerInstanceID: providerInstanceID,
            configurationFingerprint: configuration.fingerprint
        )
    }

    func runtimeEvidence() -> ProxyRuntimeEvidence { .empty() }
}
