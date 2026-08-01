import Foundation
import Synchronization
import Testing
@testable import DNSPilot

struct ProfileMutationCoordinatorTests {
    @Test(arguments: unlimitedMutationCases)
    func profileMutationsRemainAvailableAtHigherCounts(testCase: UnlimitedMutationCase) async throws {
        let fixture = try CoordinatorFixture(profileCount: testCase.profileCount)
        let coordinator = fixture.coordinator()
        let request = try fixture.request(for: testCase.kind)

        let result = await coordinator.mutate(request)

        #expect(result.isCommitted)
    }

    @Test func deleteRequiresExactRuleDefaultManualAndActiveMigrationPlan() async throws {
        let fixture = try CoordinatorFixture(profileCount: 2, activeProfileIndex: 0, withReferences: true)
        let coordinator = fixture.coordinator()
        let deleted = fixture.profiles[0]

        let missing = ProfileMutationRequest(
            operationID: UUID(),
            expectedConfigurationFingerprint: fixture.initial.fingerprint,
            intent: .delete(profileID: deleted.id, plan: ProfileDeletionPlan())
        )
        guard case .rejected(.invalidDeletionPlan) = await coordinator.mutate(missing) else {
            Issue.record("Expected an explicit deletion-plan rejection")
            return
        }

        let validPlan = ProfileDeletionPlan(
            ruleReplacements: [fixture.ruleID!: fixture.profiles[1].id],
            defaultReplacementProfileID: fixture.profiles[1].id,
            manualReplacementProfileID: fixture.profiles[1].id,
            activeReplacementProfileID: fixture.profiles[1].id
        )
        let valid = ProfileMutationRequest(
            operationID: UUID(),
            expectedConfigurationFingerprint: fixture.initial.fingerprint,
            intent: .delete(profileID: deleted.id, plan: validPlan)
        )
        let secondCoordinator = fixture.coordinator()

        #expect((await secondCoordinator.mutate(valid)).isCommitted)
        let current = await secondCoordinator.configuration().value
        #expect(current.profiles.map(\.id) == [fixture.profiles[1].id])
        #expect(current.rules.first?.profileID == fixture.profiles[1].id)
        #expect(current.defaultProfileID == fixture.profiles[1].id)
        #expect(current.operatingMode == .manual(profileID: fixture.profiles[1].id))
    }

    @Test func inactiveCASConflictIsTypedAndPreservesCurrent() async throws {
        let fixture = try CoordinatorFixture(profileCount: 1)
        fixture.store.nextCommitFailure = .compareAndSwapConflict
        let coordinator = fixture.coordinator()

        #expect(await coordinator.mutate(try fixture.editRequest(index: 0))
                == .rejected(.configurationConflict))
        #expect(fixture.store.persisted == fixture.initial)
    }

    @Test func deleteRemainsAvailableAtHigherProfileCounts() async throws {
        let fixture = try CoordinatorFixture(profileCount: 3)
        let coordinator = fixture.coordinator()
        let request = ProfileMutationRequest(
            operationID: UUID(),
            expectedConfigurationFingerprint: fixture.initial.fingerprint,
            intent: .delete(
                profileID: fixture.profiles[2].id,
                plan: ProfileDeletionPlan()
            )
        )

        #expect((await coordinator.mutate(request)).isCommitted)
        #expect(await coordinator.configuration().value.profiles.count == 2)
    }

    @Test func resetAtomicallyClearsProfilesRulesAndRouting() async throws {
        let fixture = try CoordinatorFixture(profileCount: 2, withReferences: true)
        let coordinator = fixture.coordinator()
        let request = ProfileMutationRequest(
            operationID: UUID(),
            expectedConfigurationFingerprint: fixture.initial.fingerprint,
            intent: .reset
        )

        #expect((await coordinator.mutate(request)).isCommitted)
        let configuration = await coordinator.configuration().value
        #expect(configuration.profiles.isEmpty)
        #expect(configuration.rules.isEmpty)
        #expect(configuration.defaultProfileID == nil)
        #expect(configuration.operatingMode == .automatic)
    }

    @Test func activeSuccessOrderingAndStableIDs() async throws {
        let fixture = try CoordinatorFixture(profileCount: 1, activeProfileIndex: 0)
        let controller = CoordinatorControllerFake(
            activeProfileID: fixture.profiles[0].id,
            oldRuntime: try fixture.runtime(for: fixture.profiles[0])
        )
        let coordinator = fixture.coordinator(controller: controller)
        let request = try fixture.editRequest(index: 0)

        #expect((await coordinator.mutate(request)).isCommitted)
        #expect(await controller.events == [.reserve, .persistDesired, .apply])
        #expect(await controller.lastMutationID == request.operationID)
        #expect(await controller.lastRuntimeOperationIDs.count == 1)
        #expect(fixture.store.events == [.encode, .commit])
        #expect(try fixture.journal.load() == .missing)
    }

    @Test func cacheUpdateCommitsInactiveAndReappliesActiveWithExactValue() async throws {
        let cache = try DNSCacheConfiguration(isEnabled: false, maximumEntries: 2_500)

        let inactiveFixture = try CoordinatorFixture(profileCount: 1)
        let inactiveController = CoordinatorControllerFake(
            activeProfileID: nil,
            oldRuntime: try inactiveFixture.runtime(for: inactiveFixture.profiles[0])
        )
        let inactive = inactiveFixture.coordinator(controller: inactiveController)
        let inactiveResult = await inactive.mutate(ProfileMutationRequest(
            operationID: UUID(),
            expectedConfigurationFingerprint: inactiveFixture.initial.fingerprint,
            intent: .updateDNSCache(cache)
        ))

        #expect(inactiveResult.isCommitted)
        #expect(await inactive.configuration().value.dnsCacheConfiguration == cache)
        #expect(await inactiveController.events.isEmpty)

        let activeFixture = try CoordinatorFixture(profileCount: 1, activeProfileIndex: 0)
        let activeController = CoordinatorControllerFake(
            activeProfileID: activeFixture.profiles[0].id,
            oldRuntime: try activeFixture.runtime(for: activeFixture.profiles[0])
        )
        let active = activeFixture.coordinator(controller: activeController)
        let activeResult = await active.mutate(ProfileMutationRequest(
            operationID: UUID(),
            expectedConfigurationFingerprint: activeFixture.initial.fingerprint,
            intent: .updateDNSCache(cache)
        ))

        #expect(activeResult.isCommitted)
        #expect(await active.configuration().value.dnsCacheConfiguration == cache)
        #expect(await activeController.lastTarget?.dnsCacheConfiguration == cache)
        #expect(await activeController.events == [.reserve, .persistDesired, .apply])
        #expect(try activeFixture.journal.load() == .missing)
    }

    @Test func unchangedCacheUpdateDoesNotCreateRuntimeMutation() async throws {
        let fixture = try CoordinatorFixture(profileCount: 1, activeProfileIndex: 0)
        let controller = CoordinatorControllerFake(
            activeProfileID: fixture.profiles[0].id,
            oldRuntime: try fixture.runtime(for: fixture.profiles[0])
        )
        let coordinator = fixture.coordinator(controller: controller)

        let result = await coordinator.mutate(ProfileMutationRequest(
            operationID: UUID(),
            expectedConfigurationFingerprint: fixture.initial.fingerprint,
            intent: .updateDNSCache(.standard)
        ))

        #expect(result.isCommitted)
        #expect(await controller.events.isEmpty)
        #expect(fixture.store.events == [.encode])
    }

    @Test func JSONCommitFailureCompensatesBeforeCleanup() async throws {
        let fixture = try CoordinatorFixture(profileCount: 1, activeProfileIndex: 0)
        fixture.store.nextCommitFailure = .injected
        let controller = CoordinatorControllerFake(
            activeProfileID: fixture.profiles[0].id,
            oldRuntime: try fixture.runtime(for: fixture.profiles[0])
        )
        let coordinator = fixture.coordinator(controller: controller)

        #expect(await coordinator.mutate(try fixture.editRequest(index: 0))
                == .rejected(.configurationCommitFailed))
        #expect(await controller.events == [.reserve, .persistDesired, .compensate])
        #expect(fixture.store.persisted == fixture.initial)
        #expect(try fixture.journal.load() == .missing)
    }

    @Test(arguments: [ActiveProfileMutationState.oldRuntimePreserved, .oldActive])
    func runtimeRejectionRestoresOldJSONAndDesired(
        state: ActiveProfileMutationState
    ) async throws {
        let fixture = try CoordinatorFixture(profileCount: 1, activeProfileIndex: 0)
        let controller = CoordinatorControllerFake(
            activeProfileID: fixture.profiles[0].id,
            oldRuntime: try fixture.runtime(for: fixture.profiles[0]),
            applyState: state
        )
        let coordinator = fixture.coordinator(controller: controller)

        #expect(await coordinator.mutate(try fixture.editRequest(index: 0))
                == .rejected(.runtimeRejected))
        #expect(await controller.events == [.reserve, .persistDesired, .apply, .compensate])
        #expect(fixture.store.persisted == fixture.initial)
        #expect(try fixture.journal.load() == .missing)
    }

    @Test func journalPhaseFailurePreservesExactEvidence() async throws {
        let fixture = try CoordinatorFixture(profileCount: 1, activeProfileIndex: 0)
        let journal = CoordinatorJournalFake(base: fixture.journal, failPhaseUpdate: true)
        let controller = CoordinatorControllerFake(
            activeProfileID: fixture.profiles[0].id,
            oldRuntime: try fixture.runtime(for: fixture.profiles[0])
        )
        let coordinator = fixture.coordinator(controller: controller, journal: journal)

        #expect(await coordinator.mutate(try fixture.editRequest(index: 0))
                == .recoveryRequired(.journalPhaseUpdateFailed))
        guard case let .loaded(entry, payload) = try fixture.journal.load() else {
            Issue.record("Expected preserved mutation evidence")
            return
        }
        #expect(entry.phase == .prepared)
        #expect(payload.oldAppConfigurationJSON == fixture.initial.data)
        #expect(await controller.events == [.reserve, .persistDesired])
    }

    @Test(arguments: [false, true])
    func recoveryUsesExactOfficialOldOrDraftJSON(finishDraft: Bool) async throws {
        let fixture = try CoordinatorFixture(profileCount: 1, activeProfileIndex: 0)
        let evidence = try fixture.installEvidence(officialDraft: finishDraft)
        let controller = CoordinatorControllerFake(
            activeProfileID: fixture.profiles[0].id,
            oldRuntime: evidence.oldRuntime
        )
        let coordinator = fixture.coordinator(
            current: finishDraft ? evidence.draftApp : fixture.initial,
            controller: controller
        )

        let result = await coordinator.recoverPendingMutation()

        if finishDraft {
            #expect(result == .finishedDraft(evidence.draftApp))
            #expect(await controller.recoveryGoals == [.finishDraft])
        } else {
            #expect(result == .restoredOld(fixture.initial))
            #expect(await controller.recoveryGoals == [.restoreOld])
        }
        #expect(try fixture.journal.load() == .missing)
    }

    @Test func recoveryUnknownOfficialJSONPreservesEvidence() async throws {
        let fixture = try CoordinatorFixture(profileCount: 1, activeProfileIndex: 0)
        _ = try fixture.installEvidence(officialDraft: false)
        let unknown = try PersistedAppConfiguration(value: AppConfiguration())
        fixture.store.forcePersisted(unknown)
        let coordinator = fixture.coordinator(current: unknown)

        #expect(await coordinator.recoverPendingMutation()
                == .recoveryRequired(.unknownOfficialConfiguration))
        guard case .loaded = try fixture.journal.load() else {
            Issue.record("Unknown official JSON must preserve evidence")
            return
        }
    }

    @Test func malformedAndMissingEvidenceRemainRecoveryRequired() async throws {
        let fixture = try CoordinatorFixture(profileCount: 1)
        try Data("bad".utf8).write(to: fixture.journal.journalURL)
        #expect(await fixture.coordinator().recoverPendingMutation()
                == .recoveryRequired(.journal(.missingCounterpart(.payload))))

        let fixture2 = try CoordinatorFixture(profileCount: 1)
        try Data("bad".utf8).write(to: fixture2.journal.journalURL)
        try Data("bad".utf8).write(to: fixture2.journal.payloadURL)
        #expect(await fixture2.coordinator().recoverPendingMutation()
                == .recoveryRequired(.journal(.corrupt(component: .journal, reason: .invalidJSON))))
    }

    @Test func disabledRecoveryIsTerminalOnlyWithControllerProof() async throws {
        let fixture = try CoordinatorFixture(profileCount: 1, activeProfileIndex: 0)
        let evidence = try fixture.installEvidence(officialDraft: true)
        let controller = CoordinatorControllerFake(
            activeProfileID: fixture.profiles[0].id,
            oldRuntime: evidence.oldRuntime,
            recoveryState: .disabled
        )
        let coordinator = fixture.coordinator(current: evidence.draftApp, controller: controller)

        #expect(await coordinator.recoverPendingMutation() == .disabled(evidence.draftApp))
        #expect(try fixture.journal.load() == .missing)
    }

    @Test func startupRecoveryCompletesBeforeOrdinaryControllerSynchronization() async throws {
        let fixture = try CoordinatorFixture(profileCount: 1, activeProfileIndex: 0)
        let evidence = try fixture.installEvidence(officialDraft: true)
        let controller = CoordinatorControllerFake(
            activeProfileID: fixture.profiles[0].id,
            oldRuntime: evidence.oldRuntime
        )
        let coordinator = fixture.coordinator(current: evidence.draftApp, controller: controller)

        #expect(await coordinator.recoverPendingMutationThenSynchronizeState()
                == .synchronized(
                    recovery: .finishedDraft(evidence.draftApp),
                    controllerState: .active(evidence.oldRuntime.value.generation)
                ))
        #expect(await controller.events == [.recover, .synchronize])
    }

    @Test func operationRetryIsIdempotentAndDivergentReuseConflicts() async throws {
        let fixture = try CoordinatorFixture(profileCount: 1)
        let coordinator = fixture.coordinator()
        let request = try fixture.editRequest(index: 0)

        let first = await coordinator.mutate(request)
        let retry = await coordinator.mutate(request)
        let profile = fixture.profiles[0]
        let conflicting = ProfileMutationRequest(
            operationID: request.operationID,
            expectedConfigurationFingerprint: request.expectedConfigurationFingerprint,
            intent: .edit(try DNSProfile(
                id: profile.id,
                name: "Different edit",
                upstream: profile.upstream
            ))
        )

        #expect(first == retry)
        #expect(first.isCommitted)
        #expect(await coordinator.mutate(conflicting) == .rejected(.operationConflict))
        #expect(fixture.store.commitCount == 1)
    }

    @Test func modeWriterAndProfileMutationShareCurrentConfiguration() async throws {
        let fixture = try CoordinatorFixture(profileCount: 1)
        let coordinator = fixture.coordinator()
        let initial = await coordinator.configurationWriterSnapshot()

        let modeResult = await coordinator.persistOperatingMode(
            .manual(profileID: fixture.profiles[0].id),
            expectedConfigurationFingerprint: initial.configuration.fingerprint,
            expectedConfigurationRevision: initial.revision
        )
        guard case let .persisted(modeSnapshot) = modeResult else {
            Issue.record("Expected mode persistence")
            return
        }
        let profile = fixture.profiles[0]
        let edit = ProfileMutationRequest(
            operationID: UUID(),
            expectedConfigurationFingerprint: modeSnapshot.configuration.fingerprint,
            intent: .edit(try DNSProfile(
                id: profile.id,
                name: "Edited after mode",
                upstream: profile.upstream
            ))
        )

        #expect((await coordinator.mutate(edit)).isCommitted)
        let final = await coordinator.configurationWriterSnapshot()
        #expect(final.revision == modeSnapshot.revision + 1)
        #expect(final.configuration.value.operatingMode == .manual(profileID: profile.id))
        #expect(final.configuration.value.profiles[0].name == "Edited after mode")
        #expect(fixture.store.persisted == final.configuration)
    }

    @Test func profileMutationWaitsForActiveSubmissionLease() async throws {
        let fixture = try CoordinatorFixture(profileCount: 1)
        let coordinator = fixture.coordinator()
        let initial = await coordinator.configurationWriterSnapshot()
        let lease = try #require(await coordinator.acquireOperatingModeSubmissionLease(
            expectedConfigurationFingerprint: initial.configuration.fingerprint,
            expectedConfigurationRevision: initial.revision
        ))
        let mutation = Task { await coordinator.mutate(try! fixture.editRequest(index: 0)) }

        try await waitUntilWriterFenceRejectsNewLease(
            coordinator,
            snapshot: initial
        )
        #expect(fixture.store.commitCount == 0)
        await coordinator.releaseOperatingModeSubmissionLease(lease)

        #expect((await mutation.value).isCommitted)
        #expect(fixture.store.commitCount == 1)
    }

    @Test func modePersistenceWaitsForActiveSubmissionLease() async throws {
        let fixture = try CoordinatorFixture(profileCount: 1)
        let coordinator = fixture.coordinator()
        let initial = await coordinator.configurationWriterSnapshot()
        let lease = try #require(await coordinator.acquireOperatingModeSubmissionLease(
            expectedConfigurationFingerprint: initial.configuration.fingerprint,
            expectedConfigurationRevision: initial.revision
        ))
        let persistence = Task {
            await coordinator.persistOperatingMode(
                .manual(profileID: fixture.profiles[0].id),
                expectedConfigurationFingerprint: initial.configuration.fingerprint,
                expectedConfigurationRevision: initial.revision
            )
        }

        try await waitUntilWriterFenceRejectsNewLease(
            coordinator,
            snapshot: initial
        )
        #expect(fixture.store.commitCount == 0)
        await coordinator.releaseOperatingModeSubmissionLease(lease)

        guard case .persisted = await persistence.value else {
            Issue.record("Expected mode persistence after lease release")
            return
        }
        #expect(fixture.store.commitCount == 1)
    }

    @Test func routingWriterPreservesProfilesAndOperatingMode() async throws {
        let fixture = try CoordinatorFixture(profileCount: 2)
        let coordinator = fixture.coordinator()
        let initial = await coordinator.configurationWriterSnapshot()
        _ = await coordinator.persistOperatingMode(
            .manual(profileID: fixture.profiles[1].id),
            expectedConfigurationFingerprint: initial.configuration.fingerprint,
            expectedConfigurationRevision: initial.revision
        )
        let modeSnapshot = await coordinator.configurationWriterSnapshot()
        let rule = try DNSRule(
            name: "Wi-Fi",
            conditions: RuleConditions(interfaceTypes: [.wifi]),
            profileID: fixture.profiles[0].id
        )

        let result = await coordinator.replaceRulesAndDefault(
            rules: [rule],
            defaultProfileID: fixture.profiles[1].id,
            expectedConfigurationFingerprint: modeSnapshot.configuration.fingerprint,
            expectedConfigurationRevision: modeSnapshot.revision
        )

        guard case let .committed(snapshot) = result else {
            Issue.record("Expected routing commit")
            return
        }
        #expect(snapshot.configuration.value.profiles == fixture.profiles)
        #expect(snapshot.configuration.value.operatingMode == .manual(profileID: fixture.profiles[1].id))
        #expect(snapshot.configuration.value.rules == [rule])
        #expect(snapshot.configuration.value.defaultProfileID == fixture.profiles[1].id)
    }

    @Test func routingWriterRejectsStaleRevisionAndInvalidReferences() async throws {
        let fixture = try CoordinatorFixture(profileCount: 1)
        let coordinator = fixture.coordinator()
        let initial = await coordinator.configurationWriterSnapshot()
        let missingProfileRule = try DNSRule(
            name: "Missing",
            conditions: RuleConditions(interfaceTypes: [.wifi]),
            profileID: UUID()
        )

        guard case .invalid = await coordinator.replaceRulesAndDefault(
            rules: [missingProfileRule],
            defaultProfileID: fixture.profiles[0].id,
            expectedConfigurationFingerprint: initial.configuration.fingerprint,
            expectedConfigurationRevision: initial.revision
        ) else {
            Issue.record("Expected invalid routing configuration to fail")
            return
        }
        #expect(fixture.store.commitCount == 0)

        guard case .conflict = await coordinator.replaceRulesAndDefault(
            rules: [],
            defaultProfileID: fixture.profiles[0].id,
            expectedConfigurationFingerprint: initial.configuration.fingerprint,
            expectedConfigurationRevision: initial.revision + 1
        ) else {
            Issue.record("Expected stale routing revision to conflict")
            return
        }
    }

    @Test func routingWriterWaitsForActiveSubmissionLease() async throws {
        let fixture = try CoordinatorFixture(profileCount: 1)
        let coordinator = fixture.coordinator()
        let initial = await coordinator.configurationWriterSnapshot()
        let lease = try #require(await coordinator.acquireOperatingModeSubmissionLease(
            expectedConfigurationFingerprint: initial.configuration.fingerprint,
            expectedConfigurationRevision: initial.revision
        ))
        let persistence = Task {
            await coordinator.replaceRulesAndDefault(
                rules: [],
                defaultProfileID: fixture.profiles[0].id,
                expectedConfigurationFingerprint: initial.configuration.fingerprint,
                expectedConfigurationRevision: initial.revision
            )
        }

        try await waitUntilWriterFenceRejectsNewLease(coordinator, snapshot: initial)
        #expect(fixture.store.commitCount == 0)
        await coordinator.releaseOperatingModeSubmissionLease(lease)

        guard case .committed = await persistence.value else {
            Issue.record("Expected routing persistence after lease release")
            return
        }
        #expect(fixture.store.commitCount == 1)
    }

    @Test(arguments: [false, true])
    func routingWriterRejectsPendingMutationEvidence(officialDraft: Bool) async throws {
        let fixture = try CoordinatorFixture(profileCount: 1, activeProfileIndex: 0)
        let evidence = try fixture.installEvidence(officialDraft: officialDraft)
        let current = officialDraft ? evidence.draftApp : fixture.initial
        let coordinator = fixture.coordinator(current: current)
        let snapshot = await coordinator.configurationWriterSnapshot()
        let rule = try DNSRule(
            name: "Blocked",
            conditions: RuleConditions(interfaceTypes: [.wifi]),
            profileID: fixture.profiles[0].id
        )

        guard case .recoveryRequired = await coordinator.replaceRulesAndDefault(
            rules: [rule],
            defaultProfileID: fixture.profiles[0].id,
            expectedConfigurationFingerprint: snapshot.configuration.fingerprint,
            expectedConfigurationRevision: snapshot.revision
        ) else {
            Issue.record("Expected pending journal evidence to fence routing writes")
            return
        }
        #expect(fixture.store.commitCount == 0)
    }

    @Test(arguments: [false, true])
    func modeWriterRejectsPendingMutationEvidence(officialDraft: Bool) async throws {
        let fixture = try CoordinatorFixture(profileCount: 1, activeProfileIndex: 0)
        let evidence = try fixture.installEvidence(officialDraft: officialDraft)
        let current = officialDraft ? evidence.draftApp : fixture.initial
        let coordinator = fixture.coordinator(current: current)
        let snapshot = await coordinator.configurationWriterSnapshot()

        guard case .recoveryRequired = await coordinator.persistOperatingMode(
            .manual(profileID: fixture.profiles[0].id),
            expectedConfigurationFingerprint: snapshot.configuration.fingerprint,
            expectedConfigurationRevision: snapshot.revision
        ) else {
            Issue.record("Expected pending journal evidence to fence mode writes")
            return
        }
        #expect(fixture.store.commitCount == 0)
    }
}

private func waitUntilWriterFenceRejectsNewLease(
    _ coordinator: ProfileMutationCoordinator,
    snapshot: AppConfigurationWriterSnapshot
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if let probe = await coordinator.acquireOperatingModeSubmissionLease(
            expectedConfigurationFingerprint: snapshot.configuration.fingerprint,
            expectedConfigurationRevision: snapshot.revision
        ) {
            await coordinator.releaseOperatingModeSubmissionLease(probe)
            await Task.yield()
        } else {
            return
        }
    }
    Issue.record("Configuration writer did not establish its submission fence")
}

private let unlimitedMutationCases: [UnlimitedMutationCase] = [
    .init(kind: .create, profileCount: 3),
    .init(kind: .duplicate, profileCount: 3),
    .init(kind: .edit, profileCount: 3),
]

struct UnlimitedMutationCase: Sendable, CustomTestStringConvertible {
    enum Kind: Sendable { case create, duplicate, edit }
    let kind: Kind
    let profileCount: Int
    var testDescription: String { "\(kind)-\(profileCount)" }
}

private extension ProfileMutationResult {
    var isCommitted: Bool {
        guard case .committed = self else { return false }
        return true
    }
}

private final class CoordinatorStoreFake: ConfigurationStoring, @unchecked Sendable {
    enum Failure: Error, Equatable { case compareAndSwapConflict, injected }
    private struct State {
        var persisted: PersistedAppConfiguration
        var nextFailure: Failure?
        var events: [Event] = []
        var commitCount = 0
    }
    enum Event: Equatable { case encode, commit }
    private let state: Mutex<State>

    init(_ persisted: PersistedAppConfiguration) { state = Mutex(State(persisted: persisted)) }
    var persisted: PersistedAppConfiguration { state.withLock { $0.persisted } }
    var events: [Event] { state.withLock { $0.events } }
    var commitCount: Int { state.withLock { $0.commitCount } }
    var nextCommitFailure: Failure? {
        get { state.withLock { $0.nextFailure } }
        set { state.withLock { $0.nextFailure = newValue } }
    }
    func forcePersisted(_ value: PersistedAppConfiguration) { state.withLock { $0.persisted = value } }
    func load() -> ConfigurationLoadResult { .loaded(persisted) }
    func encode(_ value: AppConfiguration) throws -> PersistedAppConfiguration {
        state.withLock { $0.events.append(.encode) }
        return try PersistedAppConfiguration(value: value)
    }
    func commit(
        _ configuration: PersistedAppConfiguration,
        replacing expected: AppConfigurationFingerprint?
    ) throws {
        try state.withLock { state in
            state.events.append(.commit)
            state.commitCount += 1
            if let failure = state.nextFailure {
                state.nextFailure = nil
                if failure == .compareAndSwapConflict {
                    throw ConfigurationStoreError.compareAndSwapConflict
                }
                throw failure
            }
            guard state.persisted.fingerprint == expected else {
                throw ConfigurationStoreError.compareAndSwapConflict
            }
            state.persisted = configuration
        }
    }
}

private struct CoordinatorJournalFake: ProfileMutationJournalStoring {
    let base: ProfileMutationJournal
    let failPhaseUpdate: Bool
    func payloadChecksum(for payload: ProfileMutationRecoveryPayload) throws -> ProfileMutationPayloadChecksum {
        try base.payloadChecksum(for: payload)
    }
    func write(entry: ProfileMutationJournalEntry, payload: ProfileMutationRecoveryPayload) throws {
        try base.write(entry: entry, payload: payload)
    }
    func load() throws -> ProfileMutationJournalLoadResult { try base.load() }
    func updatePhase(operationIdentity: ProfileMutationOperationIdentity, to phase: ProfileMutationPhase) throws {
        if failPhaseUpdate { throw CoordinatorTestError.injected }
        try base.updatePhase(operationIdentity: operationIdentity, to: phase)
    }
    func cleanup(operationIdentity: ProfileMutationOperationIdentity) throws {
        try base.cleanup(operationIdentity: operationIdentity)
    }
}

private actor CoordinatorControllerFake: ActiveProfileMutationControlling {
    enum Event: Equatable { case reserve, persistDesired, apply, compensate, recover, synchronize }
    let activeProfileID: UUID?
    let oldRuntime: PersistedProxyConfiguration
    let persistGate: AsyncGate?
    let applyState: ActiveProfileMutationState
    let recoveryState: ActiveProfileMutationState?
    private(set) var events: [Event] = []
    private(set) var persistCallCount = 0
    private(set) var lastMutationID: UUID?
    private(set) var lastRuntimeOperationIDs: [UUID] = []
    private(set) var lastTarget: DNSProxyTarget?
    private(set) var recoveryGoals: [ActiveProfileMutationRecoveryGoal] = []

    init(
        activeProfileID: UUID?,
        oldRuntime: PersistedProxyConfiguration,
        persistGate: AsyncGate? = nil,
        applyState: ActiveProfileMutationState = .draftActive,
        recoveryState: ActiveProfileMutationState? = nil
    ) {
        self.activeProfileID = activeProfileID
        self.oldRuntime = oldRuntime
        self.persistGate = persistGate
        self.applyState = applyState
        self.recoveryState = recoveryState
    }

    func synchronizeState() -> DNSProxyControllerState {
        events.append(.synchronize)
        return .active(oldRuntime.value.generation)
    }
    func activeProfileIDForMutation() -> UUID? { activeProfileID }
    func reserveActiveProfileMutation(
        to target: DNSProxyTarget,
        mutationID: UUID,
        runtimeOperationID: UUID
    ) throws -> ActiveProfileMutationReservation {
        events.append(.reserve)
        lastMutationID = mutationID
        lastRuntimeOperationIDs.append(runtimeOperationID)
        lastTarget = target
        let draft = try PersistedProxyConfiguration(value: ActiveProxyConfiguration(
            generation: UUID(),
            profileID: target.profileID,
            upstream: target.upstream,
            dnsCacheConfiguration: target.dnsCacheConfiguration
        ))
        return ActiveProfileMutationReservation(
            mutationID: mutationID,
            runtimeOperationID: runtimeOperationID,
            oldConfiguration: oldRuntime,
            draftConfiguration: draft
        )
    }
    func persistReservedDesired(_ reservation: ActiveProfileMutationReservation) async {
        events.append(.persistDesired)
        persistCallCount += 1
        if let persistGate { await persistGate.wait() }
    }
    func applyReservedMutation(_ reservation: ActiveProfileMutationReservation) -> ActiveProfileMutationResult {
        events.append(.apply)
        return result(reservation, state: applyState)
    }
    func compensateReservedMutation(_ reservation: ActiveProfileMutationReservation) -> ActiveProfileMutationResult {
        events.append(.compensate)
        return result(reservation, state: .oldActive)
    }
    func recoverActiveProfileMutation(
        oldConfigurationData: Data,
        draftConfigurationData: Data,
        mutationID: UUID,
        runtimeOperationID: UUID,
        goal: ActiveProfileMutationRecoveryGoal
    ) throws -> ActiveProfileMutationResult {
        events.append(.recover)
        recoveryGoals.append(goal)
        let old = try PersistedProxyConfiguration(data: oldConfigurationData)
        let draft = try PersistedProxyConfiguration(data: draftConfigurationData)
        return ActiveProfileMutationResult(
            mutationID: mutationID,
            runtimeOperationID: runtimeOperationID,
            oldConfiguration: old,
            draftConfiguration: draft,
            state: recoveryState ?? (goal == .restoreOld ? .oldActive : .draftActive)
        )
    }
    private func result(
        _ reservation: ActiveProfileMutationReservation,
        state: ActiveProfileMutationState
    ) -> ActiveProfileMutationResult {
        ActiveProfileMutationResult(
            mutationID: reservation.mutationID,
            runtimeOperationID: reservation.runtimeOperationID,
            oldConfiguration: reservation.oldConfiguration,
            draftConfiguration: reservation.draftConfiguration,
            state: state
        )
    }
}

private final class CoordinatorFixture {
    struct Evidence {
        let oldRuntime: PersistedProxyConfiguration
        let draftApp: PersistedAppConfiguration
    }
    let directoryURL: URL
    let profiles: [DNSProfile]
    let ruleID: UUID?
    let initial: PersistedAppConfiguration
    let store: CoordinatorStoreFake
    let journal: ProfileMutationJournal
    let activeProfileID: UUID?

    init(profileCount: Int, activeProfileIndex: Int? = nil, withReferences: Bool = false) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DNSPilot-Coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let createdProfiles = try (0..<profileCount).map {
            try DNSProfile(name: "Profile \($0)", upstream: .fixedCloudflare)
        }
        profiles = createdProfiles
        activeProfileID = activeProfileIndex.map { createdProfiles[$0].id }
        let rule = withReferences ? try DNSRule(
            name: "Rule",
            conditions: RuleConditions(interfaceTypes: [.wifi]),
            profileID: profiles[0].id
        ) : nil
        ruleID = rule?.id
        let value = try AppConfiguration(
            profiles: profiles,
            rules: rule.map { [$0] } ?? [],
            defaultProfileID: withReferences ? profiles[0].id : nil,
            operatingMode: withReferences ? .manual(profileID: profiles[0].id) : .automatic
        )
        initial = try PersistedAppConfiguration(value: value)
        store = CoordinatorStoreFake(initial)
        journal = ProfileMutationJournal(directoryURL: directoryURL)
    }

    deinit { try? FileManager.default.removeItem(at: directoryURL) }

    func coordinator(
        current: PersistedAppConfiguration? = nil,
        controller: CoordinatorControllerFake? = nil,
        journal journalOverride: (any ProfileMutationJournalStoring)? = nil
    ) -> ProfileMutationCoordinator {
        let fallbackRuntime = try! PersistedProxyConfiguration(value: ActiveProxyConfiguration(
            generation: UUID(),
            profileID: activeProfileID ?? profiles.first?.id ?? UUID(),
            upstream: .fixedCloudflare
        ))
        return ProfileMutationCoordinator(
            currentConfiguration: current ?? initial,
            configurationStore: store,
            journal: journalOverride ?? journal,
            controller: controller ?? CoordinatorControllerFake(
                activeProfileID: activeProfileID,
                oldRuntime: fallbackRuntime
            )
        )
    }

    func request(for kind: UnlimitedMutationCase.Kind) throws -> ProfileMutationRequest {
        let intent: ProfileMutationIntent
        switch kind {
        case .create:
            intent = .create(try DNSProfile(name: "Created", upstream: .fixedCloudflare))
        case .duplicate:
            let source = profiles[0]
            intent = .duplicate(
                sourceProfileID: source.id,
                duplicate: try DNSProfile(name: "Copy", upstream: source.upstream)
            )
        case .edit:
            let profile = profiles[0]
            intent = .edit(try DNSProfile(id: profile.id, name: "Edited", upstream: profile.upstream))
        }
        return ProfileMutationRequest(
            operationID: UUID(),
            expectedConfigurationFingerprint: initial.fingerprint,
            intent: intent
        )
    }

    func editRequest(index: Int) throws -> ProfileMutationRequest {
        let profile = profiles[index]
        return ProfileMutationRequest(
            operationID: UUID(),
            expectedConfigurationFingerprint: initial.fingerprint,
            intent: .edit(try DNSProfile(
                id: profile.id,
                name: "Edited \(profile.name)",
                upstream: .fixedForCurrentBuild
            ))
        )
    }

    func runtime(for profile: DNSProfile) throws -> PersistedProxyConfiguration {
        try PersistedProxyConfiguration(value: ActiveProxyConfiguration(
            generation: UUID(), profileID: profile.id, upstream: profile.upstream
        ))
    }

    func installEvidence(officialDraft: Bool) throws -> Evidence {
        let oldRuntime = try runtime(for: profiles[0])
        let edited = try DNSProfile(
            id: profiles[0].id,
            name: "Recovered Draft",
            upstream: .fixedForCurrentBuild
        )
        let draftValue = try AppConfiguration(profiles: [edited])
        let draftApp = try PersistedAppConfiguration(value: draftValue)
        let draftRuntime = try runtime(for: edited)
        let identity = ProfileMutationOperationIdentity(
            operationID: UUID(), runtimeTransactionID: UUID()
        )
        let payload = ProfileMutationRecoveryPayload(
            operationIdentity: identity,
            oldAppConfigurationJSON: initial.data,
            draftAppConfigurationJSON: draftApp.data,
            oldRuntimePropertyList: oldRuntime.data,
            draftRuntimePropertyList: draftRuntime.data
        )
        let entry = ProfileMutationJournalEntry(
            operationIdentity: identity,
            phase: officialDraft ? .configurationCommitted : .prepared,
            oldAppConfigurationFingerprint: initial.fingerprint,
            draftAppConfigurationFingerprint: draftApp.fingerprint,
            oldProfileID: oldRuntime.value.profileID,
            draftProfileID: draftRuntime.value.profileID,
            oldRuntimeIdentity: .init(
                profileID: oldRuntime.value.profileID,
                generation: oldRuntime.value.generation,
                configurationFingerprint: oldRuntime.fingerprint
            ),
            draftRuntimeIdentity: .init(
                profileID: draftRuntime.value.profileID,
                generation: draftRuntime.value.generation,
                configurationFingerprint: draftRuntime.fingerprint
            ),
            payloadChecksum: try journal.payloadChecksum(for: payload)
        )
        try journal.write(entry: entry, payload: payload)
        store.forcePersisted(officialDraft ? draftApp : initial)
        return Evidence(oldRuntime: oldRuntime, draftApp: draftApp)
    }
}

private enum CoordinatorTestError: Error { case injected }
