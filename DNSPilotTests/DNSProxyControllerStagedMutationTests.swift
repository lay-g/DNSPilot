import Foundation
import Testing
@testable import DNSPilot

struct DNSProxyControllerStagedMutationTests {
    @Test func reservePreflightsWithoutMutatingManagerOrRuntime() async throws {
        let fixture = try await makeStagedFixture()
        let eventsBefore = await fixture.manager.events

        let reservation = try await fixture.controller.reserveActiveProfileMutation(
            to: fixture.target,
            mutationID: fixture.mutationID,
            runtimeOperationID: fixture.runtimeOperationID
        )

        #expect(reservation.mutationID == fixture.mutationID)
        #expect(reservation.runtimeOperationID == fixture.runtimeOperationID)
        #expect(reservation.oldConfiguration == fixture.oldPersisted)
        #expect(await fixture.manager.currentSnapshot.persistedConfiguration == fixture.oldPersisted)
        #expect(await fixture.manager.events == eventsBefore + [.load, .load])
        #expect(await fixture.runtime.requests.isEmpty)
    }

    @Test func failedReservePreflightLeavesExactOwnerUntouched() async throws {
        let old = try stagedConfiguration(profileID: UUID(), upstream: .fixedCloudflare)
        let persisted = try PersistedProxyConfiguration(value: old)
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            persistedConfiguration: persisted
        )
        let runtime = FakeRuntimeSession(activeConfiguration: persisted)
        let controller = makeController(
            manager: manager,
            validator: FakeUpstreamValidator { throw FakeTestError.unavailable },
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()

        await #expect(throws: FakeTestError.unavailable) {
            try await controller.reserveActiveProfileMutation(
                to: try stagedPlainTarget(),
                mutationID: UUID(),
                runtimeOperationID: UUID()
            )
        }

        #expect(await manager.currentSnapshot.persistedConfiguration == persisted)
        #expect(await runtime.requests.isEmpty)
    }

    @Test func cacheOnlyReservationSkipsPreflightAndRequiresSchemaFour() async throws {
        let old = try stagedConfiguration(profileID: UUID(), upstream: .fixedCloudflare)
        let persisted = try PersistedProxyConfiguration(value: old)
        let manager = FakeDNSProxyManager(isEnabled: true, persistedConfiguration: persisted)
        let validator = FakeUpstreamValidator { throw FakeTestError.unavailable }
        let runtime = FakeRuntimeSession(activeConfiguration: persisted)
        let controller = makeController(
            manager: manager,
            validator: validator,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()
        let cache = try DNSCacheConfiguration(isEnabled: false, maximumEntries: 2_500)
        let target = DNSProxyTarget(
            profileID: old.profileID,
            upstream: old.upstream,
            dnsCacheConfiguration: cache
        )

        let reservation = try await controller.reserveActiveProfileMutation(
            to: target,
            mutationID: UUID(),
            runtimeOperationID: UUID()
        )

        #expect(reservation.draftConfiguration.value.dnsCacheConfiguration == cache)
        #expect(await validator.validationCount == 0)
        #expect(await manager.currentSnapshot.persistedConfiguration == persisted)

        let legacyRuntime = FakeRuntimeSession(
            activeConfiguration: persisted,
            maximumConfigurationSchemaVersion: 3
        )
        let legacyController = makeController(
            manager: manager,
            validator: validator,
            statusProvider: legacyRuntime,
            runtimeController: legacyRuntime
        )
        _ = await legacyController.synchronizeState()

        do {
            _ = try await legacyController.reserveActiveProfileMutation(
                to: target,
                mutationID: UUID(),
                runtimeOperationID: UUID()
            )
            Issue.record("Expected schema 4 cache configuration to be rejected")
        } catch let error as DNSProxyControllerError {
            guard case let .unsupportedProviderConfigurationSchema(required, available) = error else {
                Issue.record("Expected a schema compatibility error, got \(error)")
                return
            }
            #expect(required == 4)
            #expect(available == 3)
        }
        #expect(await validator.validationCount == 0)
    }

    @Test func secondReservationIsRejected() async throws {
        let fixture = try await makeStagedFixture()
        _ = try await fixture.controller.reserveActiveProfileMutation(
            to: fixture.target,
            mutationID: fixture.mutationID,
            runtimeOperationID: fixture.runtimeOperationID
        )

        await #expect(throws: DNSProxyControllerError.self) {
            try await fixture.controller.reserveActiveProfileMutation(
                to: try stagedPlainTarget(),
                mutationID: UUID(),
                runtimeOperationID: UUID()
            )
        }
    }

    @Test func reserveAcceptsDistinctProviderBundleAndRuntimePayloadFingerprints() async throws {
        let fixture = try await makeStagedFixture()
        let ownerFingerprint = ProxyConfigurationFingerprint(
            data: Data("complete-provider-configuration".utf8)
        )
        #expect(ownerFingerprint != fixture.oldPersisted.fingerprint)
        await fixture.manager.replaceOwnerIdentity(
            DNSProxyManagerOwnerIdentity(
                providerBundleIdentifier: "com.example.DNSProxy",
                providerConfigurationFingerprint: ownerFingerprint,
                localizedDescription: "DNSPilot"
            )
        )

        let reservation = try await fixture.controller.reserveActiveProfileMutation(
            to: fixture.target,
            mutationID: fixture.mutationID,
            runtimeOperationID: fixture.runtimeOperationID
        )

        #expect(reservation.oldConfiguration == fixture.oldPersisted)
        #expect(await fixture.manager.currentSnapshot.persistedConfiguration
                == fixture.oldPersisted)
        #expect(await fixture.runtime.requests.isEmpty)
    }

    @Test func persistPrecedesRuntimeAndApplyUsesStableOperationID() async throws {
        let fixture = try await makeStagedFixture()
        let reservation = try await fixture.controller.reserveActiveProfileMutation(
            to: fixture.target,
            mutationID: fixture.mutationID,
            runtimeOperationID: fixture.runtimeOperationID
        )

        try await fixture.controller.persistReservedDesired(reservation)

        #expect(await fixture.manager.currentSnapshot.persistedConfiguration
                == reservation.draftConfiguration)
        #expect(await fixture.runtime.requests.isEmpty)

        let result = await fixture.controller.applyReservedMutation(reservation)
        let request = try #require(await fixture.runtime.requests.first)
        #expect(result.state == .draftActive)
        #expect(result.oldConfiguration == fixture.oldPersisted)
        #expect(result.draftConfiguration == reservation.draftConfiguration)
        #expect(request.operationID == fixture.runtimeOperationID)
        #expect(request.targetConfigurationData == reservation.draftConfiguration.data)
    }

    @Test func rejectedRuntimeCompensationRestoresExactOldBytes() async throws {
        let old = try stagedConfiguration(profileID: UUID(), upstream: .fixedCloudflare)
        let oldPersisted = try xmlPersistedConfiguration(old)
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            persistedConfiguration: oldPersisted
        )
        let runtime = FakeRuntimeSession(
            activeConfiguration: oldPersisted,
            outcomes: [.rejectedPreservingBase]
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()
        let reservation = try await controller.reserveActiveProfileMutation(
            to: try stagedPlainTarget(),
            mutationID: UUID(),
            runtimeOperationID: UUID()
        )
        try await controller.persistReservedDesired(reservation)

        #expect(await controller.applyReservedMutation(reservation).state
                == .oldRuntimePreserved)
        #expect(await manager.currentSnapshot.persistedConfiguration
                == reservation.draftConfiguration)

        let compensation = await controller.compensateReservedMutation(reservation)
        #expect(compensation.state == .oldActive)
        #expect(await manager.currentSnapshot.persistedConfiguration?.data == oldPersisted.data)
    }

    @Test func explicitRuntimeRejectionRequiresExactOldProofBeforeRollback() async throws {
        let old = try stagedConfiguration(profileID: UUID(), upstream: .fixedCloudflare)
        let oldPersisted = try PersistedProxyConfiguration(value: old)
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            persistedConfiguration: oldPersisted
        )
        let runtime = FakeRuntimeSession(
            activeConfiguration: oldPersisted,
            outcomes: [.rejected(.invalidTargetConfiguration)]
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()
        let reservation = try await controller.reserveActiveProfileMutation(
            to: try stagedPlainTarget(),
            mutationID: UUID(),
            runtimeOperationID: UUID()
        )
        try await controller.persistReservedDesired(reservation)

        #expect(await controller.applyReservedMutation(reservation).state
                == .oldRuntimePreserved)
        #expect(await controller.compensateReservedMutation(reservation).state == .oldActive)
        #expect(await manager.currentSnapshot.persistedConfiguration == oldPersisted)
    }

    @Test func externalManagerChangeBeforePersistEntersRecoveryWithoutRuntimeRequest() async throws {
        let fixture = try await makeStagedFixture()
        let reservation = try await fixture.controller.reserveActiveProfileMutation(
            to: fixture.target,
            mutationID: fixture.mutationID,
            runtimeOperationID: fixture.runtimeOperationID
        )
        let external = try stagedConfiguration(profileID: UUID(), upstream: .fixedCloudflare)
        await fixture.manager.replaceState(isEnabled: true, activeConfiguration: external)

        await #expect(throws: DNSProxyControllerError.self) {
            try await fixture.controller.persistReservedDesired(reservation)
        }

        expectRecoveryRequired(await fixture.controller.snapshot())
        #expect(await fixture.manager.currentSnapshot.activeConfiguration == external)
        #expect(await fixture.runtime.requests.isEmpty)
    }

    @Test(arguments: [
        RecoveryScenario(managerDraft: false, runtimeDraft: false),
        RecoveryScenario(managerDraft: true, runtimeDraft: false),
        RecoveryScenario(managerDraft: false, runtimeDraft: true),
        RecoveryScenario(managerDraft: true, runtimeDraft: true),
    ])
    func finishDraftRecoveryConvergesEveryExactOldDraftPair(
        scenario: RecoveryScenario
    ) async throws {
        let pair = try stagedPair()
        let managerConfiguration = scenario.managerDraft ? pair.draft : pair.old
        let runtimeConfiguration = scenario.runtimeDraft ? pair.draft : pair.old
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            persistedConfiguration: managerConfiguration
        )
        let runtime = FakeRuntimeSession(activeConfiguration: runtimeConfiguration)
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )
        let runtimeOperationID = UUID()

        let result = try await controller.recoverActiveProfileMutation(
            oldConfigurationData: pair.old.data,
            draftConfigurationData: pair.draft.data,
            mutationID: UUID(),
            runtimeOperationID: runtimeOperationID,
            goal: .finishDraft
        )

        #expect(result.state == .draftActive)
        #expect(await manager.currentSnapshot.persistedConfiguration == pair.draft)
        #expect(await runtime.runtimeStatus().generation == pair.draft.value.generation)
        for request in await runtime.requests {
            #expect(request.operationID == runtimeOperationID)
        }
    }

    @Test func restoreOldRecoveryReverseReappliesWithStableMutationIdentity() async throws {
        let pair = try stagedPair()
        let manager = FakeDNSProxyManager(isEnabled: true, persistedConfiguration: pair.draft)
        let runtime = FakeRuntimeSession(activeConfiguration: pair.draft)
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime,
            rollbackTimeout: .seconds(2)
        )
        let mutationID = UUID()

        let result = try await controller.recoverActiveProfileMutation(
            oldConfigurationData: pair.old.data,
            draftConfigurationData: pair.draft.data,
            mutationID: mutationID,
            runtimeOperationID: UUID(),
            goal: .restoreOld
        )

        #expect(result.state == .oldActive)
        #expect(await manager.currentSnapshot.persistedConfiguration == pair.old)
        #expect(await runtime.requests.first?.operationID == mutationID)
    }

    @Test func recoveryNeverOverwritesUnknownManagerState() async throws {
        let pair = try stagedPair()
        let foreign = try PersistedProxyConfiguration(
            value: stagedConfiguration(profileID: UUID(), upstream: .fixedCloudflare)
        )
        let manager = FakeDNSProxyManager(isEnabled: true, persistedConfiguration: foreign)
        let runtime = FakeRuntimeSession(activeConfiguration: pair.old)
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )

        let result = try await controller.recoverActiveProfileMutation(
            oldConfigurationData: pair.old.data,
            draftConfigurationData: pair.draft.data,
            mutationID: UUID(),
            runtimeOperationID: UUID(),
            goal: .finishDraft
        )

        guard case .recoveryRequired = result.state else {
            Issue.record("Expected recoveryRequired for foreign manager bytes")
            return
        }
        #expect(await manager.currentSnapshot.persistedConfiguration == foreign)
        #expect(await runtime.requests.isEmpty)
    }

    @Test func disabledRecoveryRequiresDisabledRuntimeAndNeverReenablesManager() async throws {
        let pair = try stagedPair()
        let disabledManager = FakeDNSProxyManager(
            isEnabled: false,
            persistedConfiguration: pair.old
        )
        let disabledController = makeController(
            manager: disabledManager,
            statusProvider: FakeRuntimeStatusProvider { .idle() }
        )

        let disabledResult = try await disabledController.recoverActiveProfileMutation(
            oldConfigurationData: pair.old.data,
            draftConfigurationData: pair.draft.data,
            mutationID: UUID(),
            runtimeOperationID: UUID(),
            goal: .finishDraft
        )
        #expect(disabledResult.state == .disabled)
        #expect(await disabledManager.currentSnapshot.isEnabled == false)

        let activeRuntimeManager = FakeDNSProxyManager(
            isEnabled: false,
            persistedConfiguration: pair.old
        )
        let activeRuntime = FakeRuntimeSession(activeConfiguration: pair.draft)
        let activeRuntimeController = makeController(
            manager: activeRuntimeManager,
            statusProvider: activeRuntime,
            runtimeController: activeRuntime
        )

        let inconsistentResult = try await activeRuntimeController
            .recoverActiveProfileMutation(
                oldConfigurationData: pair.old.data,
                draftConfigurationData: pair.draft.data,
                mutationID: UUID(),
                runtimeOperationID: UUID(),
                goal: .finishDraft
            )
        guard case .recoveryRequired = inconsistentResult.state else {
            Issue.record("Expected recoveryRequired for disabled manager with active runtime")
            return
        }
        #expect(await activeRuntimeManager.currentSnapshot.isEnabled == false)
        #expect(await activeRuntime.requests.isEmpty)
    }

    @Test func terminationCancelsUnpersistedReservationBeforeDisable() async throws {
        let fixture = try await makeStagedFixture()
        _ = try await fixture.controller.reserveActiveProfileMutation(
            to: fixture.target,
            mutationID: fixture.mutationID,
            runtimeOperationID: fixture.runtimeOperationID
        )

        #expect(await fixture.controller.restoreSystemDNSForTermination() == .disabled)
        #expect(await fixture.manager.currentSnapshot.isEnabled == false)
        #expect(await fixture.runtime.requests.isEmpty)
    }

    @Test func terminationCompensatesPersistedReservationBeforeDisable() async throws {
        let fixture = try await makeStagedFixture()
        let reservation = try await fixture.controller.reserveActiveProfileMutation(
            to: fixture.target,
            mutationID: fixture.mutationID,
            runtimeOperationID: fixture.runtimeOperationID
        )
        try await fixture.controller.persistReservedDesired(reservation)

        #expect(await fixture.controller.restoreSystemDNSForTermination() == .disabled)
        #expect(await fixture.manager.currentSnapshot.isEnabled == false)
        #expect(await fixture.manager.currentSnapshot.persistedConfiguration
                == fixture.oldPersisted)
        #expect(await fixture.runtime.requests.isEmpty)
    }

    @Test func terminationCompensationFencesConcurrentDraftApply() async throws {
        let old = try stagedConfiguration(profileID: UUID(), upstream: .fixedCloudflare)
        let oldPersisted = try PersistedProxyConfiguration(value: old)
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            persistedConfiguration: oldPersisted
        )
        let runtime = FakeRuntimeSession(activeConfiguration: oldPersisted)
        let compensationStatusBlocker = CompensationStatusBlocker()
        let statusProvider = FakeRuntimeStatusProvider {
            await compensationStatusBlocker.blockIfArmed()
            return await runtime.runtimeStatus()
        }
        let controller = makeController(
            manager: manager,
            statusProvider: statusProvider,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()
        let reservation = try await controller.reserveActiveProfileMutation(
            to: try stagedPlainTarget(),
            mutationID: UUID(),
            runtimeOperationID: UUID()
        )
        try await controller.persistReservedDesired(reservation)
        await compensationStatusBlocker.arm()

        let terminationTask = Task {
            await controller.restoreSystemDNSForTermination()
        }
        await compensationStatusBlocker.waitUntilBlocked()

        let concurrentApply = await controller.applyReservedMutation(reservation)
        guard case .recoveryRequired = concurrentApply.state else {
            Issue.record("Expected concurrent apply to be rejected by the execution fence")
            await compensationStatusBlocker.release()
            _ = await terminationTask.value
            return
        }
        #expect(await runtime.requests.isEmpty)

        await compensationStatusBlocker.release()
        #expect(await terminationTask.value == .disabled)
        #expect(await runtime.requests.isEmpty)
        #expect(await manager.currentSnapshot.isEnabled == false)
        #expect(await manager.currentSnapshot.persistedConfiguration == oldPersisted)
    }

    @Test func terminationDuringReservationPreflightCancelsBeforeAnyMutation() async throws {
        let old = try stagedConfiguration(profileID: UUID(), upstream: .fixedCloudflare)
        let oldPersisted = try PersistedProxyConfiguration(value: old)
        let manager = FakeDNSProxyManager(isEnabled: true, persistedConfiguration: oldPersisted)
        let runtime = FakeRuntimeSession(activeConfiguration: oldPersisted)
        let validator = FakeUpstreamValidator {
            try await Task.sleep(for: .seconds(30))
        }
        let controller = makeController(
            manager: manager,
            validator: validator,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()
        let reservationTask = Task {
            try await controller.reserveActiveProfileMutation(
                to: try stagedPlainTarget(),
                mutationID: UUID(),
                runtimeOperationID: UUID()
            )
        }
        while await validator.validationCount == 0 {
            await Task.yield()
        }

        #expect(await controller.restoreSystemDNSForTermination() == .disabled)
        await #expect(throws: (any Error).self) {
            try await reservationTask.value
        }
        #expect(await manager.currentSnapshot.isEnabled == false)
        #expect(await runtime.requests.isEmpty)
    }

    @Test func terminationDuringPersistedApplyCompensatesBeforeDisable() async throws {
        let old = try stagedConfiguration(profileID: UUID(), upstream: .fixedCloudflare)
        let oldPersisted = try PersistedProxyConfiguration(value: old)
        let manager = FakeDNSProxyManager(isEnabled: true, persistedConfiguration: oldPersisted)
        let runtime = FakeRuntimeSession(activeConfiguration: oldPersisted)
        let runtimeController = FakeRuntimeController { _ in
            try await Task.sleep(for: .seconds(30))
            throw FakeTestError.unavailable
        }
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtimeController
        )
        _ = await controller.synchronizeState()
        let reservation = try await controller.reserveActiveProfileMutation(
            to: try stagedPlainTarget(),
            mutationID: UUID(),
            runtimeOperationID: UUID()
        )
        try await controller.persistReservedDesired(reservation)
        let applyTask = Task { await controller.applyReservedMutation(reservation) }
        while await runtimeController.requests.isEmpty {
            await Task.yield()
        }

        #expect(await controller.restoreSystemDNSForTermination() == .disabled)
        #expect(await applyTask.value.state == .oldActive)
        #expect(await manager.currentSnapshot.isEnabled == false)
        #expect(await manager.currentSnapshot.persistedConfiguration == oldPersisted)
    }

    @Test func terminalReleaseDrainsOnlyLatestPendingTarget() async throws {
        let fixture = try await makeStagedFixture()
        let reservation = try await fixture.controller.reserveActiveProfileMutation(
            to: fixture.target,
            mutationID: fixture.mutationID,
            runtimeOperationID: fixture.runtimeOperationID
        )
        try await fixture.controller.persistReservedDesired(reservation)
        let pendingA = DNSProxyTarget(profileID: UUID(), upstream: .fixedCloudflare)
        let pendingB = try stagedPlainTarget()

        _ = await fixture.controller.activate(pendingA)
        _ = await fixture.controller.activate(pendingB)
        let result = await fixture.controller.applyReservedMutation(reservation)

        #expect(result.state == .draftActive)
        #expect(await fixture.controller.controllerSnapshot().activeProfileID == pendingB.profileID)
        #expect(await fixture.runtime.requests.count == 2)
        #expect(await fixture.manager.currentSnapshot.activeConfiguration?.profileID
                == pendingB.profileID)
    }
}

private struct StagedFixture {
    let controller: DNSProxyController
    let manager: FakeDNSProxyManager
    let runtime: FakeRuntimeSession
    let oldPersisted: PersistedProxyConfiguration
    let target: DNSProxyTarget
    let mutationID: UUID
    let runtimeOperationID: UUID
}

private actor CompensationStatusBlocker {
    private var isArmed = false
    private var isBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arm() {
        isArmed = true
    }

    func blockIfArmed() async {
        guard isArmed else { return }
        isArmed = false
        isBlocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

struct RecoveryScenario: Sendable, CustomTestStringConvertible {
    let managerDraft: Bool
    let runtimeDraft: Bool

    var testDescription: String {
        "manager=\(managerDraft ? "draft" : "old"),runtime=\(runtimeDraft ? "draft" : "old")"
    }
}

private func makeStagedFixture() async throws -> StagedFixture {
    let old = try stagedConfiguration(profileID: UUID(), upstream: .fixedCloudflare)
    let oldPersisted = try PersistedProxyConfiguration(value: old)
    let manager = FakeDNSProxyManager(isEnabled: true, persistedConfiguration: oldPersisted)
    let runtime = FakeRuntimeSession(activeConfiguration: oldPersisted)
    let controller = makeController(
        manager: manager,
        statusProvider: runtime,
        runtimeController: runtime
    )
    _ = await controller.synchronizeState()
    return StagedFixture(
        controller: controller,
        manager: manager,
        runtime: runtime,
        oldPersisted: oldPersisted,
        target: try stagedPlainTarget(),
        mutationID: UUID(),
        runtimeOperationID: UUID()
    )
}

private func stagedPair() throws -> (
    old: PersistedProxyConfiguration,
    draft: PersistedProxyConfiguration
) {
    let old = try PersistedProxyConfiguration(
        value: stagedConfiguration(profileID: UUID(), upstream: .fixedCloudflare)
    )
    let draft = try PersistedProxyConfiguration(
        value: stagedConfiguration(
            profileID: UUID(),
            upstream: .plain(try PlainDNSConfiguration(serverAddress: IPAddress("1.1.1.1")))
        )
    )
    return (old, draft)
}

private func stagedConfiguration(
    profileID: UUID,
    upstream: DNSUpstream
) throws -> ActiveProxyConfiguration {
    try ActiveProxyConfiguration(
        generation: UUID(),
        profileID: profileID,
        upstream: upstream
    )
}

private func stagedPlainTarget() throws -> DNSProxyTarget {
    DNSProxyTarget(
        profileID: UUID(),
        upstream: .plain(try PlainDNSConfiguration(serverAddress: IPAddress("1.1.1.1")))
    )
}

private func xmlPersistedConfiguration(
    _ configuration: ActiveProxyConfiguration
) throws -> PersistedProxyConfiguration {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    return try PersistedProxyConfiguration(data: encoder.encode(configuration))
}
