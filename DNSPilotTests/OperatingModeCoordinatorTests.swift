import Foundation
import Testing
@testable import DNSPilot

struct OperatingModeCoordinatorTests {
    @Test func manualPersistsBeforeSubmitAndIgnoresNetworkChanges() async throws {
        let fixture = try ModeFixture(mode: .automatic)
        _ = await fixture.coordinator.bootstrapFromWriter()

        let result = await fixture.coordinator.setMode(.manual(profileID: fixture.profiles[1].id))
        #expect(result.submittedProfileID == fixture.profiles[1].id)
        #expect(await fixture.events.values == [
            .persist(.manual(profileID: fixture.profiles[1].id)),
            .controllerSnapshot,
            .submit(fixture.profiles[1].id),
        ])

        _ = await fixture.coordinator.updateNetworkContext(
            ethernetContext,
            sessionEpoch: 0
        )
        #expect(await fixture.target.submittedProfileIDs == [fixture.profiles[1].id])
    }

    @Test func automaticImmediatelyRecomputesLatestContextUsingFirstOrderedRule() async throws {
        let fixture = try ModeFixture(mode: .manual(profileID: ModeFixture.profileIDs[0]))
        _ = await fixture.coordinator.bootstrapFromWriter()
        _ = await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
        await fixture.events.reset()

        let result = await fixture.coordinator.setMode(.automatic)

        #expect(result.submittedProfileID == fixture.profiles[1].id)
        #expect(await fixture.events.values == [
            .persist(.automatic),
            .controllerSnapshot,
            .submit(fixture.profiles[1].id),
        ])
    }

    @Test func automaticUsesDefaultWhenNoRuleMatches() async throws {
        let fixture = try ModeFixture(mode: .automatic)
        _ = await fixture.coordinator.bootstrapFromWriter()

        let result = await fixture.coordinator.updateNetworkContext(
            ethernetContext,
            sessionEpoch: 0
        )

        #expect(result.submittedProfileID == fixture.profiles[0].id)
    }

    @Test(arguments: [NetworkStatus.requiresConnection, .unsatisfied])
    func automaticWaitsForUsableNetworkBeforeReevaluating(status: NetworkStatus) async throws {
        let fixture = try ModeFixture(mode: .automatic)
        _ = await fixture.coordinator.bootstrapFromWriter()
        _ = await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
        let unavailableContext = NetworkContext(
            status: status,
            ssid: nil,
            ssidAvailability: .notOnWiFi,
            activeInterfaceTypes: [],
            addresses: []
        )

        let unavailable = await fixture.coordinator.updateNetworkContext(
            unavailableContext,
            sessionEpoch: 0
        )

        #expect(unavailable == .suppressed(.awaitingNetworkContext))
        #expect(await fixture.coordinator.snapshot().latestNetworkContext == unavailableContext)
        #expect(await fixture.target.submittedProfileIDs == [fixture.profiles[1].id])

        let reconnected = await fixture.coordinator.updateNetworkContext(
            ethernetContext,
            sessionEpoch: 0
        )
        #expect(reconnected.submittedProfileID == fixture.profiles[0].id)
        #expect(await fixture.target.submittedProfileIDs
                == [fixture.profiles[1].id, fixture.profiles[0].id])
    }

    @Test func equalAutomaticTargetIsNoOp() async throws {
        let fixture = try ModeFixture(mode: .automatic)
        _ = await fixture.coordinator.bootstrapFromWriter()
        _ = await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)

        #expect(await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
                == .suppressed(.equalTarget))
        #expect(await fixture.target.submittedProfileIDs == [fixture.profiles[1].id])
    }

    @Test func automaticContextBurstSubmitsLatestTargetWhileFirstIsPending() async throws {
        let fixture = try ModeFixture(mode: .automatic)
        _ = await fixture.coordinator.bootstrapFromWriter()
        let gate = AsyncGate()
        await fixture.target.setSwitchGate(gate)
        let coordinator = fixture.coordinator
        let target = fixture.target

        let first = Task {
            await coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
        }
        try await eventually { await target.submittedProfileIDs.count == 1 }
        let latest = Task {
            await coordinator.updateNetworkContext(ethernetContext, sessionEpoch: 0)
        }
        #expect(await latest.value == .suppressed(.staleDecision))
        #expect(await target.submittedProfileIDs == [fixture.profiles[1].id])
        await gate.open()

        #expect((await first.value).submittedProfileID == fixture.profiles[0].id)
        #expect(await target.submittedProfileIDs
                == [fixture.profiles[1].id, fixture.profiles[0].id])
    }

    @Test func unavailableNetworkReplacesPendingAutomaticContext() async throws {
        let fixture = try ModeFixture(mode: .automatic)
        _ = await fixture.coordinator.bootstrapFromWriter()
        let gate = AsyncGate()
        await fixture.target.setSwitchGate(gate)
        let coordinator = fixture.coordinator
        let target = fixture.target
        let unavailableContext = NetworkContext(
            status: .unsatisfied,
            ssid: nil,
            ssidAvailability: .notOnWiFi,
            activeInterfaceTypes: [],
            addresses: []
        )

        let switching = Task {
            await coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
        }
        try await eventually { await target.submittedProfileIDs.count == 1 }

        #expect(await coordinator.updateNetworkContext(unavailableContext, sessionEpoch: 0)
                == .suppressed(.staleDecision))
        await gate.open()

        #expect(await switching.value == .suppressed(.awaitingNetworkContext))
        #expect(await target.submittedProfileIDs == [fixture.profiles[1].id])
        #expect(await coordinator.snapshot().latestNetworkContext == unavailableContext)
    }

    @Test func automaticWithoutDefaultDoesNotSubmit() async throws {
        let fixture = try ModeFixture(mode: .automatic, includeDefault: false)
        _ = await fixture.coordinator.bootstrapFromWriter()

        #expect(await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
                == .suppressed(.noDefaultProfile))
        #expect(await fixture.target.submittedProfileIDs.isEmpty)
    }

    @Test func disabledProxyPersistsModeWithoutEnabling() async throws {
        let fixture = try ModeFixture(mode: .automatic, controllerState: .disabled)
        _ = await fixture.coordinator.bootstrapFromWriter()

        #expect(await fixture.coordinator.setMode(.manual(profileID: fixture.profiles[1].id))
                == .suppressed(.proxyInactive))
        #expect(await fixture.persister.snapshot.configuration.value.operatingMode
                == .manual(profileID: fixture.profiles[1].id))
        #expect(await fixture.target.submittedProfileIDs.isEmpty)
    }

    @Test func manualOverridesAutomaticWhileTargetSubmissionIsPending() async throws {
        let fixture = try ModeFixture(mode: .manual(profileID: ModeFixture.profileIDs[0]))
        _ = await fixture.coordinator.bootstrapFromWriter()
        _ = await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
        let pendingGate = AsyncGate()
        await fixture.target.setSwitchGate(pendingGate)
        let target = fixture.target
        let coordinator = fixture.coordinator
        let manualProfileID = fixture.profiles[0].id

        let automatic = Task { await coordinator.setMode(.automatic) }
        try await eventually { await target.submittedProfileIDs.count == 2 }
        let automaticRevision = await coordinator.snapshot().decisionRevision
        let manual = Task {
            await coordinator.setMode(.manual(profileID: manualProfileID))
        }
        try await eventually {
            await coordinator.snapshot().decisionRevision > automaticRevision
        }
        await pendingGate.open()
        try await eventually { await target.submittedProfileIDs.count == 3 }

        #expect(await automatic.value == .suppressed(.staleDecision))
        #expect((await manual.value).submittedProfileID == fixture.profiles[0].id)
        #expect(await fixture.target.submittedProfileIDs.suffix(2)
                 == [fixture.profiles[1].id, fixture.profiles[0].id])
    }

    @Test func networkCallbackCannotStrandPersistedManualModeWithoutItsTarget() async throws {
        let fixture = try ModeFixture(mode: .automatic)
        _ = await fixture.coordinator.bootstrapFromWriter()
        let gate = AsyncGate()
        await fixture.target.setSwitchGate(gate)
        let coordinator = fixture.coordinator
        let target = fixture.target

        let automatic = Task {
            await coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
        }
        try await eventually { await target.submittedProfileIDs.count == 1 }
        let revisionBeforeManual = await coordinator.snapshot().decisionRevision
        let manualProfileID = fixture.profiles[2].id
        let manual = Task {
            await coordinator.setMode(.manual(profileID: manualProfileID))
        }
        try await eventually {
            await coordinator.snapshot().decisionRevision > revisionBeforeManual
        }
        _ = await coordinator.updateNetworkContext(ethernetContext, sessionEpoch: 0)
        await gate.open()

        _ = await automatic.value
        #expect((await manual.value).submittedProfileID == manualProfileID)
        #expect(await fixture.persister.snapshot.configuration.value.operatingMode
                == .manual(profileID: manualProfileID))
        #expect(await fixture.target.submittedProfileIDs.last == manualProfileID)
    }

    @Test func staleSessionCallbackIsIgnored() async throws {
        let fixture = try ModeFixture(mode: .automatic)
        _ = await fixture.coordinator.bootstrapFromWriter()
        _ = await fixture.coordinator.updateGUISession(isActive: false, epoch: 1)

        #expect(await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
                == .suppressed(.staleSession))
        #expect(await fixture.coordinator.snapshot().latestNetworkContext == nil)
        #expect(await fixture.target.submittedProfileIDs.isEmpty)
    }

    @Test func sessionResumeWaitsForFreshResampledContext() async throws {
        let fixture = try ModeFixture(mode: .automatic)
        _ = await fixture.coordinator.bootstrapFromWriter()
        _ = await fixture.coordinator.updateNetworkContext(ethernetContext, sessionEpoch: 0)
        _ = await fixture.coordinator.updateGUISession(isActive: false, epoch: 1)
        _ = await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 1)

        let result = await fixture.coordinator.updateGUISession(isActive: true, epoch: 2)

        #expect(result == .suppressed(.awaitingNetworkContext))
        #expect(await fixture.coordinator.snapshot().latestNetworkContext == nil)
        #expect(await fixture.target.submittedProfileIDs == [fixture.profiles[0].id])

        #expect((await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 2))
                .submittedProfileID == fixture.profiles[1].id)
    }

    @Test func cancellingTerminationAcceptsOnlyTheResumedMonitorEpoch() async throws {
        let fixture = try ModeFixture(mode: .automatic)
        _ = await fixture.coordinator.bootstrapFromWriter()
        _ = await fixture.coordinator.fenceForTermination()

        #expect(await fixture.coordinator.cancelTerminationFence(sessionEpoch: 1)
                == .suppressed(.awaitingNetworkContext))
        #expect(await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
                == .suppressed(.staleSession))
        #expect((await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 1))
                .submittedProfileID == fixture.profiles[1].id)
    }

    @Test func failedControllerSwitchCanRetrySameTarget() async throws {
        let fixture = try ModeFixture(mode: .automatic)
        _ = await fixture.coordinator.bootstrapFromWriter()
        await fixture.target.setNextSwitchConfirmation(false)

        let first = await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
        let retry = await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)

        #expect(first.submittedProfileID == fixture.profiles[1].id)
        #expect(retry.submittedProfileID == fixture.profiles[1].id)
        #expect(await fixture.target.submittedProfileIDs
                == [fixture.profiles[1].id, fixture.profiles[1].id])
    }

    @Test func sameProfileNewUpstreamFailedSwitchRetriesExactTarget() async throws {
        let fixture = try MutationBackedModeFixture()
        _ = await fixture.modeCoordinator.bootstrapFromWriter()
        _ = await fixture.modeCoordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
        let edited = try DNSProfile(
            id: fixture.profiles[1].id,
            name: "Edited",
            upstream: .fixedCloudflare
        )
        let current = await fixture.mutationCoordinator.configurationWriterSnapshot()
        #expect((await fixture.mutationCoordinator.mutate(.init(
            operationID: UUID(),
            expectedConfigurationFingerprint: current.configuration.fingerprint,
            intent: .edit(edited)
        ))).isCommitted)
        await fixture.target.setNextSwitchConfirmation(false)

        _ = await fixture.modeCoordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
        _ = await fixture.modeCoordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)

        let oldTarget = DNSProxyTarget(
            profileID: fixture.profiles[1].id,
            upstream: fixture.profiles[1].upstream
        )
        let newTarget = DNSProxyTarget(
            profileID: fixture.profiles[1].id,
            upstream: .fixedCloudflare
        )
        let submittedTargets = await fixture.target.submittedTargets
        #expect(
            submittedTargets == [oldTarget, newTarget, newTarget],
            "Submitted targets: \(submittedTargets)"
        )
    }

    @Test func externalControllerTargetDriftRetriesDesiredExactTarget() async throws {
        let fixture = try ModeFixture(mode: .automatic)
        _ = await fixture.coordinator.bootstrapFromWriter()
        _ = await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
        await fixture.target.setActiveTarget(DNSProxyTarget(
            profileID: fixture.profiles[2].id,
            upstream: fixture.profiles[2].upstream
        ))

        let result = await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)

        #expect(result.submittedProfileID == fixture.profiles[1].id)
        #expect(await fixture.target.submittedProfileIDs
                == [fixture.profiles[1].id, fixture.profiles[1].id])
    }

    @Test func terminationFenceSuppressesAllNewDecisions() async throws {
        let fixture = try ModeFixture(mode: .automatic)
        _ = await fixture.coordinator.bootstrapFromWriter()
        let fenced = await fixture.coordinator.fenceForTermination()

        #expect(fenced.isTerminationFenced)
        #expect(await fixture.coordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
                == .suppressed(.terminationFenced))
        #expect(await fixture.coordinator.setMode(.manual(profileID: fixture.profiles[0].id))
                == .suppressed(.terminationFenced))
        #expect(await fixture.persister.persistCallCount == 0)
        #expect(await fixture.target.submittedProfileIDs.isEmpty)
    }

    @Test(arguments: [ModePersistenceFailure.conflict, .recovery])
    func persistenceFailureDoesNotSubmit(failure: ModePersistenceFailure) async throws {
        let fixture = try ModeFixture(mode: .automatic)
        await fixture.persister.setFailure(failure)
        _ = await fixture.coordinator.bootstrapFromWriter()

        let result = await fixture.coordinator.setMode(.manual(profileID: fixture.profiles[1].id))

        switch failure {
        case .conflict:
            guard case .conflict = result else { Issue.record("Expected conflict"); return }
        case .recovery:
            guard case .recoveryRequired = result else { Issue.record("Expected recovery"); return }
        }
        #expect(await fixture.target.submittedProfileIDs.isEmpty)
    }

    @Test func bootstrapRestoresPersistedManualWithoutRewritingMode() async throws {
        let fixture = try ModeFixture(mode: .manual(profileID: ModeFixture.profileIDs[1]))

        let result = await fixture.coordinator.bootstrapFromWriter()

        #expect(result.submittedProfileID == fixture.profiles[1].id)
        #expect(await fixture.persister.persistCallCount == 0)
    }

    @Test func automaticRefreshesProfileEditFromMutationWriter() async throws {
        let fixture = try MutationBackedModeFixture()
        _ = await fixture.modeCoordinator.bootstrapFromWriter()
        _ = await fixture.modeCoordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
        let edited = try DNSProfile(
            id: fixture.profiles[1].id,
            name: "Edited",
            upstream: .fixedCloudflare
        )
        let current = await fixture.mutationCoordinator.configurationWriterSnapshot()

        #expect((await fixture.mutationCoordinator.mutate(.init(
            operationID: UUID(),
            expectedConfigurationFingerprint: current.configuration.fingerprint,
            intent: .edit(edited)
        ))).isCommitted)
        _ = await fixture.modeCoordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)

        let submittedTargets = await fixture.target.submittedTargets
        #expect(submittedTargets.suffix(2) == [
            DNSProxyTarget(profileID: fixture.profiles[1].id, upstream: fixture.profiles[1].upstream),
            DNSProxyTarget(profileID: fixture.profiles[1].id, upstream: .fixedCloudflare),
        ], "Submitted targets: \(submittedTargets)")
    }

    @Test func automaticRefreshesProfileDeleteFromMutationWriter() async throws {
        let fixture = try MutationBackedModeFixture()
        _ = await fixture.modeCoordinator.bootstrapFromWriter()
        _ = await fixture.modeCoordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
        let current = await fixture.mutationCoordinator.configurationWriterSnapshot()

        #expect((await fixture.mutationCoordinator.mutate(.init(
            operationID: UUID(),
            expectedConfigurationFingerprint: current.configuration.fingerprint,
            intent: .delete(
                profileID: fixture.profiles[1].id,
                plan: ProfileDeletionPlan(ruleReplacements: [
                    fixture.wifiRuleID: fixture.profiles[2].id,
                ])
            )
        ))).isCommitted)
        _ = await fixture.modeCoordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)

        #expect(await fixture.target.submittedProfileIDs.suffix(2)
                == [fixture.profiles[1].id, fixture.profiles[2].id])
    }

    @Test func activeProfileMutationFencesOverlappingOldNetworkDecision() async throws {
        let gate = AsyncGate()
        let fixture = try MutationBackedModeFixture(activeMutationGate: gate)
        _ = await fixture.modeCoordinator.bootstrapFromWriter()
        let current = await fixture.mutationCoordinator.configurationWriterSnapshot()
        let edited = try DNSProfile(
            id: fixture.profiles[1].id,
            name: "Edited while active",
            upstream: .fixedCloudflare
        )
        let mutation = Task {
            await fixture.mutationCoordinator.mutate(.init(
                operationID: UUID(),
                expectedConfigurationFingerprint: current.configuration.fingerprint,
                intent: .edit(edited)
            ))
        }
        guard let mutationController = fixture.activeMutationController else {
            Issue.record("Expected active mutation controller")
            return
        }
        try await eventually { await mutationController.persistCallCount == 1 }

        let overlapping = await fixture.modeCoordinator.updateNetworkContext(
            wifiContext,
            sessionEpoch: 0
        )

        #expect(overlapping == .suppressed(.staleDecision))
        #expect(await fixture.target.submittedTargets.isEmpty)
        await gate.open()
        #expect((await mutation.value).isCommitted)

        _ = await fixture.modeCoordinator.updateNetworkContext(wifiContext, sessionEpoch: 0)
        #expect(await fixture.target.submittedTargets == [DNSProxyTarget(
            profileID: fixture.profiles[1].id,
            upstream: .fixedCloudflare
        )])
    }
}

private enum ModeEvent: Equatable, Sendable {
    case persist(OperatingMode)
    case controllerSnapshot
    case submit(DNSProfile.ID)
}

private actor ModeEventRecorder {
    private(set) var values: [ModeEvent] = []
    func append(_ event: ModeEvent) { values.append(event) }
    func reset() { values = [] }
}

enum ModePersistenceFailure: Sendable {
    case conflict
    case recovery
}

private actor ModePersisterFake: OperatingModePersisting {
    private(set) var snapshot: AppConfigurationWriterSnapshot
    private(set) var persistCallCount = 0
    private var failure: ModePersistenceFailure?
    private var writeFenced = false
    private var activeLeases: Set<OperatingModeSubmissionLease> = []
    private var leaseDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private let events: ModeEventRecorder

    init(configuration: PersistedAppConfiguration, events: ModeEventRecorder) {
        snapshot = AppConfigurationWriterSnapshot(configuration: configuration, revision: 0)
        self.events = events
    }

    func setFailure(_ failure: ModePersistenceFailure) { self.failure = failure }
    func configurationWriterSnapshot() -> AppConfigurationWriterSnapshot { snapshot }

    func acquireOperatingModeSubmissionLease(
        expectedConfigurationFingerprint: AppConfigurationFingerprint,
        expectedConfigurationRevision: UInt64
    ) -> OperatingModeSubmissionLease? {
        guard !writeFenced,
              expectedConfigurationFingerprint == snapshot.configuration.fingerprint,
              expectedConfigurationRevision == snapshot.revision else { return nil }
        let lease = OperatingModeSubmissionLease(
            id: UUID(),
            configurationRevision: snapshot.revision
        )
        activeLeases.insert(lease)
        return lease
    }

    func releaseOperatingModeSubmissionLease(_ lease: OperatingModeSubmissionLease) {
        guard activeLeases.remove(lease) != nil, activeLeases.isEmpty else { return }
        let waiters = leaseDrainWaiters
        leaseDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func persistOperatingMode(
        _ mode: OperatingMode,
        expectedConfigurationFingerprint: AppConfigurationFingerprint,
        expectedConfigurationRevision: UInt64
    ) async -> OperatingModePersistenceResult {
        guard !writeFenced else { return .conflict(snapshot) }
        writeFenced = true
        defer { writeFenced = false }
        while !activeLeases.isEmpty {
            await withCheckedContinuation { continuation in
                leaseDrainWaiters.append(continuation)
            }
        }
        persistCallCount += 1
        await events.append(.persist(mode))
        guard expectedConfigurationFingerprint == snapshot.configuration.fingerprint,
              expectedConfigurationRevision == snapshot.revision else {
            return .conflict(snapshot)
        }
        if failure == .conflict { return .conflict(snapshot) }
        if failure == .recovery { return .recoveryRequired(snapshot) }
        if snapshot.configuration.value.operatingMode == mode { return .current(snapshot) }

        do {
            let current = snapshot.configuration.value
            let changed = try AppConfiguration(
                profiles: current.profiles,
                rules: current.rules,
                defaultProfileID: current.defaultProfileID,
                operatingMode: mode
            )
            snapshot = AppConfigurationWriterSnapshot(
                configuration: try PersistedAppConfiguration(value: changed),
                revision: snapshot.revision + 1
            )
            return .persisted(snapshot)
        } catch {
            return .recoveryRequired(snapshot)
        }
    }
}

private actor ModeTargetFake: OperatingModeTargetSubmitting {
    private let state: DNSProxyControllerState
    private let events: ModeEventRecorder
    private var switchGate: AsyncGate?
    private var nextSwitchConfirmsTarget = true
    private var activeTarget: DNSProxyTarget?
    private(set) var submittedProfileIDs: [DNSProfile.ID] = []
    private(set) var submittedTargets: [DNSProxyTarget] = []

    init(
        state: DNSProxyControllerState,
        events: ModeEventRecorder,
        switchGate: AsyncGate?
    ) {
        self.state = state
        self.events = events
        self.switchGate = switchGate
    }

    func setSwitchGate(_ gate: AsyncGate?) { switchGate = gate }
    func setNextSwitchConfirmation(_ confirms: Bool) { nextSwitchConfirmsTarget = confirms }
    func setActiveTarget(_ target: DNSProxyTarget?) { activeTarget = target }

    func activeTargetForOperatingMode() -> DNSProxyTarget? {
        guard case .active = state else { return nil }
        return activeTarget
    }

    func controllerSnapshot() async -> ProxyControllerSnapshot {
        await events.append(.controllerSnapshot)
        return makeSnapshot()
    }

    func switchTarget(to target: DNSProxyTarget) async -> ProxyControllerSnapshot {
        submittedProfileIDs.append(target.profileID)
        submittedTargets.append(target)
        await events.append(.submit(target.profileID))
        if let switchGate { await switchGate.wait() }
        let confirms = nextSwitchConfirmsTarget
        nextSwitchConfirmsTarget = true
        if confirms { activeTarget = target }
        return makeSnapshot()
    }

    private func makeSnapshot() -> ProxyControllerSnapshot {
        ProxyControllerSnapshot(
            state: state,
            targetProfileID: nil,
            activeProfileID: activeTarget?.profileID,
            activeGeneration: nil,
            lastSwitchFailure: nil
        )
    }
}

private final class MutationBackedModeFixture {
    let directoryURL: URL
    let profiles: [DNSProfile]
    let wifiRuleID: DNSRule.ID
    let mutationCoordinator: ProfileMutationCoordinator
    let activeMutationController: ModeActiveMutationController?
    let target: ModeTargetFake
    let modeCoordinator: OperatingModeCoordinator

    init(activeMutationGate: AsyncGate? = nil) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DNSPilot-ModeMutation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let distinctUpstream = DNSUpstream.plain(try PlainDNSConfiguration(
            serverAddress: IPAddress("192.0.2.53")
        ))
        profiles = try [
            DNSProfile(name: "Default", upstream: .fixedCloudflare),
            DNSProfile(name: "Wi-Fi", upstream: distinctUpstream),
            DNSProfile(name: "Replacement", upstream: .fixedCloudflare),
        ]
        let wifiRule = try DNSRule(
            name: "Wi-Fi",
            conditions: RuleConditions(interfaceTypes: [.wifi]),
            profileID: profiles[1].id
        )
        wifiRuleID = wifiRule.id
        let persisted = try PersistedAppConfiguration(value: AppConfiguration(
            profiles: profiles,
            rules: [wifiRule],
            defaultProfileID: profiles[0].id,
            operatingMode: .automatic
        ))
        let store = ConfigurationStore(directoryURL: directoryURL)
        try store.commit(persisted, replacing: nil)
        let activeController: ModeActiveMutationController? = if let activeMutationGate {
            try ModeActiveMutationController(
                profile: profiles[1],
                persistGate: activeMutationGate
            )
        } else {
            nil
        }
        let mutationController: any ActiveProfileMutationControlling = if let activeController {
            activeController
        } else {
            InactiveMutationController()
        }
        let writer = ProfileMutationCoordinator(
            currentConfiguration: persisted,
            configurationStore: store,
            journal: ProfileMutationJournal(directoryURL: directoryURL),
            controller: mutationController
        )
        let recorder = ModeEventRecorder()
        let submitter = ModeTargetFake(
            state: .active(UUID()),
            events: recorder,
            switchGate: nil
        )
        mutationCoordinator = writer
        activeMutationController = activeController
        target = submitter
        modeCoordinator = OperatingModeCoordinator(
            modePersister: writer,
            targetSubmitter: submitter
        )
    }

    deinit { try? FileManager.default.removeItem(at: directoryURL) }
}

private actor ModeActiveMutationController: ActiveProfileMutationControlling {
    private let activeProfileID: DNSProfile.ID
    private let oldRuntime: PersistedProxyConfiguration
    private let persistGate: AsyncGate
    private(set) var persistCallCount = 0

    init(profile: DNSProfile, persistGate: AsyncGate) throws {
        activeProfileID = profile.id
        oldRuntime = try PersistedProxyConfiguration(value: ActiveProxyConfiguration(
            generation: UUID(),
            profileID: profile.id,
            upstream: profile.upstream
        ))
        self.persistGate = persistGate
    }

    func synchronizeState() -> DNSProxyControllerState { .active(oldRuntime.value.generation) }
    func activeProfileIDForMutation() -> UUID? { activeProfileID }
    func reserveActiveProfileMutation(
        to target: DNSProxyTarget,
        mutationID: UUID,
        runtimeOperationID: UUID
    ) throws -> ActiveProfileMutationReservation {
        let draft = try PersistedProxyConfiguration(value: ActiveProxyConfiguration(
            generation: UUID(),
            profileID: target.profileID,
            upstream: target.upstream
        ))
        return ActiveProfileMutationReservation(
            mutationID: mutationID,
            runtimeOperationID: runtimeOperationID,
            oldConfiguration: oldRuntime,
            draftConfiguration: draft
        )
    }
    func persistReservedDesired(_ reservation: ActiveProfileMutationReservation) async {
        persistCallCount += 1
        await persistGate.wait()
    }
    func applyReservedMutation(
        _ reservation: ActiveProfileMutationReservation
    ) -> ActiveProfileMutationResult {
        result(reservation, state: .draftActive)
    }
    func compensateReservedMutation(
        _ reservation: ActiveProfileMutationReservation
    ) -> ActiveProfileMutationResult {
        result(reservation, state: .oldActive)
    }
    func recoverActiveProfileMutation(
        oldConfigurationData: Data,
        draftConfigurationData: Data,
        mutationID: UUID,
        runtimeOperationID: UUID,
        goal: ActiveProfileMutationRecoveryGoal
    ) throws -> ActiveProfileMutationResult {
        throw MutationBackedModeTestError.unexpectedActiveMutation
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

private actor InactiveMutationController: ActiveProfileMutationControlling {
    func synchronizeState() -> DNSProxyControllerState { .disabled }
    func activeProfileIDForMutation() -> UUID? { nil }
    func reserveActiveProfileMutation(
        to target: DNSProxyTarget,
        mutationID: UUID,
        runtimeOperationID: UUID
    ) throws -> ActiveProfileMutationReservation {
        throw MutationBackedModeTestError.unexpectedActiveMutation
    }
    func persistReservedDesired(_ reservation: ActiveProfileMutationReservation) throws {}
    func applyReservedMutation(
        _ reservation: ActiveProfileMutationReservation
    ) -> ActiveProfileMutationResult {
        mutationResult(reservation)
    }
    func compensateReservedMutation(
        _ reservation: ActiveProfileMutationReservation
    ) -> ActiveProfileMutationResult {
        mutationResult(reservation)
    }
    func recoverActiveProfileMutation(
        oldConfigurationData: Data,
        draftConfigurationData: Data,
        mutationID: UUID,
        runtimeOperationID: UUID,
        goal: ActiveProfileMutationRecoveryGoal
    ) throws -> ActiveProfileMutationResult {
        throw MutationBackedModeTestError.unexpectedActiveMutation
    }

    private func mutationResult(
        _ reservation: ActiveProfileMutationReservation
    ) -> ActiveProfileMutationResult {
        ActiveProfileMutationResult(
            mutationID: reservation.mutationID,
            runtimeOperationID: reservation.runtimeOperationID,
            oldConfiguration: reservation.oldConfiguration,
            draftConfiguration: reservation.draftConfiguration,
            state: .disabled
        )
    }
}

private enum MutationBackedModeTestError: Error {
    case unexpectedActiveMutation
}

private final class ModeFixture {
    static let profileIDs = [UUID(), UUID(), UUID()]

    let profiles: [DNSProfile]
    let events: ModeEventRecorder
    let persister: ModePersisterFake
    let target: ModeTargetFake
    let coordinator: OperatingModeCoordinator

    init(
        mode: OperatingMode,
        includeDefault: Bool = true,
        controllerState: DNSProxyControllerState = .active(UUID()),
        switchGate: AsyncGate? = nil
    ) throws {
        let distinctUpstream = DNSUpstream.plain(try PlainDNSConfiguration(
            serverAddress: IPAddress("192.0.2.53")
        ))
        profiles = try [
            DNSProfile(id: Self.profileIDs[0], name: "Default", upstream: .fixedCloudflare),
            DNSProfile(id: Self.profileIDs[1], name: "First", upstream: distinctUpstream),
            DNSProfile(id: Self.profileIDs[2], name: "Second", upstream: .fixedCloudflare),
        ]
        let rules = try [
            DNSRule(
                name: "First Wi-Fi",
                conditions: RuleConditions(interfaceTypes: [.wifi]),
                profileID: profiles[1].id
            ),
            DNSRule(
                name: "Second Wi-Fi",
                conditions: RuleConditions(interfaceTypes: [.wifi]),
                profileID: profiles[2].id
            ),
        ]
        let configuration = try PersistedAppConfiguration(value: AppConfiguration(
            profiles: profiles,
            rules: rules,
            defaultProfileID: includeDefault ? profiles[0].id : nil,
            operatingMode: mode
        ))
        let recorder = ModeEventRecorder()
        let modePersister = ModePersisterFake(configuration: configuration, events: recorder)
        let targetSubmitter = ModeTargetFake(
            state: controllerState,
            events: recorder,
            switchGate: switchGate
        )
        events = recorder
        persister = modePersister
        target = targetSubmitter
        coordinator = OperatingModeCoordinator(
            modePersister: modePersister,
            targetSubmitter: targetSubmitter
        )
    }
}

private let wifiContext = NetworkContext(
    status: .satisfied,
    ssid: "Office",
    ssidAvailability: .available,
    activeInterfaceTypes: [.wifi],
    addresses: []
)

private let ethernetContext = NetworkContext(
    status: .satisfied,
    ssid: nil,
    ssidAvailability: .notOnWiFi,
    activeInterfaceTypes: [.wiredEthernet],
    addresses: []
)

private extension OperatingModeDecisionResult {
    var submittedProfileID: DNSProfile.ID? {
        guard case let .submitted(target, _) = self else { return nil }
        return target.profileID
    }
}

private extension ProfileMutationResult {
    var isCommitted: Bool {
        guard case .committed = self else { return false }
        return true
    }
}

private func eventually(
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !(await condition()) {
        guard clock.now < deadline else {
            Issue.record("Condition was not satisfied before timeout")
            return
        }
        await Task.yield()
    }
}
