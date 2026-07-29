import Foundation

protocol OperatingModeTargetSubmitting: Sendable {
    func controllerSnapshot() async -> ProxyControllerSnapshot
    func activeTargetForOperatingMode() async -> DNSProxyTarget?
    func switchTarget(to target: DNSProxyTarget) async -> ProxyControllerSnapshot
}

extension DNSProxyController: OperatingModeTargetSubmitting {}

enum OperatingModeSuppressionReason: Equatable, Sendable {
    case awaitingBootstrap
    case awaitingNetworkContext
    case noDefaultProfile
    case missingProfile(DNSProfile.ID)
    case proxyInactive
    case sessionInactive
    case equalTarget
    case staleDecision
    case staleSession
    case terminationFenced
}

enum OperatingModeDecisionResult: Equatable, Sendable {
    case persisted(AppConfigurationWriterSnapshot)
    case current(AppConfigurationWriterSnapshot)
    case submitted(target: DNSProxyTarget, snapshot: ProxyControllerSnapshot)
    case suppressed(OperatingModeSuppressionReason)
    case conflict(AppConfigurationWriterSnapshot)
    case recoveryRequired(AppConfigurationWriterSnapshot)
}

struct OperatingModeCoordinatorSnapshot: Equatable, Sendable {
    let configuration: AppConfigurationWriterSnapshot?
    let latestNetworkContext: NetworkContext?
    let sessionEpoch: UInt64
    let isSessionActive: Bool
    let isTerminationFenced: Bool
    let decisionRevision: UInt64
    let latestSubmittedTarget: DNSProxyTarget?
}

actor OperatingModeCoordinator {
    private let modePersister: any OperatingModePersisting
    private let targetSubmitter: any OperatingModeTargetSubmitting

    private var configurationSnapshot: AppConfigurationWriterSnapshot?
    private var latestNetworkContext: NetworkContext?
    private var sessionEpoch: UInt64
    private var isSessionActive: Bool
    private var isTerminationFenced = false
    private var decisionRevision: UInt64 = 0
    private var latestSubmittedTarget: DNSProxyTarget?
    private var automaticSubmissionInFlight = false
    private var pendingAutomaticDecision: DecisionIdentity?

    init(
        modePersister: any OperatingModePersisting,
        targetSubmitter: any OperatingModeTargetSubmitting,
        sessionEpoch: UInt64 = 0,
        isSessionActive: Bool = true
    ) {
        self.modePersister = modePersister
        self.targetSubmitter = targetSubmitter
        self.sessionEpoch = sessionEpoch
        self.isSessionActive = isSessionActive
    }

    func snapshot() -> OperatingModeCoordinatorSnapshot {
        OperatingModeCoordinatorSnapshot(
            configuration: configurationSnapshot,
            latestNetworkContext: latestNetworkContext,
            sessionEpoch: sessionEpoch,
            isSessionActive: isSessionActive,
            isTerminationFenced: isTerminationFenced,
            decisionRevision: decisionRevision,
            latestSubmittedTarget: latestSubmittedTarget
        )
    }

    func bootstrap(
        configuration: PersistedAppConfiguration,
        revision: UInt64
    ) async -> OperatingModeDecisionResult {
        guard !isTerminationFenced else { return .suppressed(.terminationFenced) }
        configurationSnapshot = AppConfigurationWriterSnapshot(
            configuration: configuration,
            revision: revision
        )
        let decision = beginDecision()
        switch configuration.value.operatingMode {
        case let .manual(profileID):
            return await submitProfileIfActive(profileID, decision: decision)
        case .automatic:
            return await evaluateAutomatic(decision: decision)
        }
    }

    func bootstrapFromWriter() async -> OperatingModeDecisionResult {
        let persisted = await modePersister.configurationWriterSnapshot()
        guard !isTerminationFenced else { return .suppressed(.terminationFenced) }
        configurationSnapshot = persisted
        let decision = beginDecision()
        switch persisted.configuration.value.operatingMode {
        case let .manual(profileID):
            return await submitProfileIfActive(profileID, decision: decision)
        case .automatic:
            return await evaluateAutomatic(decision: decision)
        }
    }

    func setMode(_ mode: OperatingMode) async -> OperatingModeDecisionResult {
        guard !isTerminationFenced else { return .suppressed(.terminationFenced) }
        guard configurationSnapshot != nil else {
            return .suppressed(.awaitingBootstrap)
        }
        let decision = beginDecision()
        if let result = await refreshConfiguration(for: decision) { return result }
        guard let expected = configurationSnapshot else {
            return .suppressed(.awaitingBootstrap)
        }
        if case let .manual(profileID) = mode,
           !expected.configuration.value.profiles.contains(where: { $0.id == profileID }) {
            return .suppressed(.missingProfile(profileID))
        }

        let persistence = await modePersister.persistOperatingMode(
            mode,
            expectedConfigurationFingerprint: expected.configuration.fingerprint,
            expectedConfigurationRevision: expected.revision
        )
        let persistedSnapshot = acceptPersistence(persistence)

        switch persistence {
        case .persisted, .current:
            guard !isTerminationFenced else { return .suppressed(.terminationFenced) }
            let persistedDecision = beginDecision()
            switch persistedSnapshot.configuration.value.operatingMode {
            case let .manual(profileID):
                return await submitProfileIfActive(profileID, decision: persistedDecision)
            case .automatic:
                return await evaluateAutomatic(decision: persistedDecision)
            }
        case .conflict:
            return .conflict(persistedSnapshot)
        case .recoveryRequired:
            return .recoveryRequired(persistedSnapshot)
        }
    }

    func updateNetworkContext(
        _ context: NetworkContext,
        sessionEpoch callbackEpoch: UInt64
    ) async -> OperatingModeDecisionResult {
        guard !isTerminationFenced else { return .suppressed(.terminationFenced) }
        guard callbackEpoch == sessionEpoch else { return .suppressed(.staleSession) }
        guard isSessionActive else { return .suppressed(.sessionInactive) }
        latestNetworkContext = context
        let decision = beginDecision()
        if let result = await refreshConfiguration(for: decision) { return result }
        guard configurationSnapshot?.configuration.value.operatingMode == .automatic else {
            return configurationSnapshot.currentConfigurationOr(.awaitingBootstrap)
        }
        return await evaluateAutomatic(decision: decision)
    }

    func updateNetworkContext(_ context: NetworkContext) async -> OperatingModeDecisionResult {
        await updateNetworkContext(context, sessionEpoch: sessionEpoch)
    }

    func updateGUISession(
        isActive active: Bool,
        epoch newEpoch: UInt64
    ) async -> OperatingModeDecisionResult {
        guard !isTerminationFenced else { return .suppressed(.terminationFenced) }
        guard newEpoch >= sessionEpoch else { return .suppressed(.staleSession) }
        let becameActive = active && (!isSessionActive || newEpoch != sessionEpoch)
        sessionEpoch = newEpoch
        isSessionActive = active
        let decision = beginDecision()
        guard active else {
            latestNetworkContext = nil
            return .suppressed(.sessionInactive)
        }
        if becameActive { latestNetworkContext = nil }
        if let result = await refreshConfiguration(for: decision) { return result }
        guard becameActive,
              configurationSnapshot?.configuration.value.operatingMode == .automatic else {
            return configurationSnapshot.currentConfigurationOr(.awaitingBootstrap)
        }
        return .suppressed(.awaitingNetworkContext)
    }

    func fenceForTermination() -> OperatingModeCoordinatorSnapshot {
        isTerminationFenced = true
        isSessionActive = false
        latestNetworkContext = nil
        _ = beginDecision()
        return snapshot()
    }

    func cancelTerminationFence(
        sessionEpoch resumedSessionEpoch: UInt64
    ) async -> OperatingModeDecisionResult {
        guard isTerminationFenced else {
            return configurationSnapshot.currentConfigurationOr(.awaitingBootstrap)
        }
        isTerminationFenced = false
        isSessionActive = true
        sessionEpoch = resumedSessionEpoch
        latestNetworkContext = nil
        let decision = beginDecision()
        if let result = await refreshConfiguration(for: decision) { return result }
        guard configurationSnapshot?.configuration.value.operatingMode == .automatic else {
            return configurationSnapshot.currentConfigurationOr(.awaitingBootstrap)
        }
        return .suppressed(.awaitingNetworkContext)
    }

    private func evaluateAutomatic(
        decision initialDecision: DecisionIdentity
    ) async -> OperatingModeDecisionResult {
        var decision = initialDecision
        while true {
            guard decisionIsCurrent(decision) else { return .suppressed(.staleDecision) }
            guard isSessionActive else { return .suppressed(.sessionInactive) }
            if automaticSubmissionInFlight {
                pendingAutomaticDecision = decision
                return .suppressed(.staleDecision)
            }
            guard let context = latestNetworkContext else {
                return .suppressed(.awaitingNetworkContext)
            }
            guard context.status == .satisfied else {
                return .suppressed(.awaitingNetworkContext)
            }
            guard let configuration = configurationSnapshot?.configuration.value else {
                return .suppressed(.awaitingBootstrap)
            }
            guard let defaultProfileID = configuration.defaultProfileID else {
                return .suppressed(.noDefaultProfile)
            }
            let match = RuleEngine.resolveProfile(
                context: context,
                rules: configuration.rules,
                defaultProfileID: defaultProfileID
            )
            automaticSubmissionInFlight = true
            let result = await submitProfileIfActive(match.profileID, decision: decision)
            automaticSubmissionInFlight = false

            guard let pendingDecision = pendingAutomaticDecision else { return result }
            pendingAutomaticDecision = nil
            guard decisionIsCurrent(pendingDecision),
                  configurationSnapshot?.configuration.value.operatingMode == .automatic else {
                return .suppressed(.staleDecision)
            }
            decision = pendingDecision
        }
    }

    private func submitProfileIfActive(
        _ profileID: DNSProfile.ID,
        decision: DecisionIdentity
    ) async -> OperatingModeDecisionResult {
        guard decisionIsCurrent(decision) else { return .suppressed(.staleDecision) }
        guard let profile = configurationSnapshot?.configuration.value.profiles.first(
            where: { $0.id == profileID }
        ) else {
            return .suppressed(.missingProfile(profileID))
        }
        let target = DNSProxyTarget(profileID: profile.id, upstream: profile.upstream)
        guard let configuration = configurationSnapshot,
              let lease = await modePersister.acquireOperatingModeSubmissionLease(
                  expectedConfigurationFingerprint: configuration.configuration.fingerprint,
                  expectedConfigurationRevision: configuration.revision
              ) else {
            return .suppressed(.staleDecision)
        }
        let result = await submit(
            target,
            decision: decision
        )
        await modePersister.releaseOperatingModeSubmissionLease(lease)
        return result
    }

    private func submit(
        _ target: DNSProxyTarget,
        decision: DecisionIdentity
    ) async -> OperatingModeDecisionResult {
        let activeTarget = await targetSubmitter.activeTargetForOperatingMode()
        guard decisionIsCurrent(decision) else { return .suppressed(.staleDecision) }
        if activeTarget == target {
            latestSubmittedTarget = target
            return .suppressed(.equalTarget)
        }

        let controller = await targetSubmitter.controllerSnapshot()
        guard decisionIsCurrent(decision) else { return .suppressed(.staleDecision) }
        switch controller.state {
        case .active, .preparing, .applying:
            break
        case .disabled, .repairing, .stopping, .failed, .degraded, .recoveryRequired:
            return .suppressed(.proxyInactive)
        }

        let submitted = await targetSubmitter.switchTarget(to: target)
        guard decisionIsCurrent(decision) else { return .suppressed(.staleDecision) }
        let submittedActiveTarget = await targetSubmitter.activeTargetForOperatingMode()
        guard decisionIsCurrent(decision) else { return .suppressed(.staleDecision) }
        if submittedActiveTarget == target {
            latestSubmittedTarget = target
        }
        return .submitted(target: target, snapshot: submitted)
    }

    private func refreshConfiguration(
        for decision: DecisionIdentity
    ) async -> OperatingModeDecisionResult? {
        let latest = await modePersister.configurationWriterSnapshot()
        guard decisionIsCurrent(decision) else { return .suppressed(.staleDecision) }
        guard let current = configurationSnapshot else {
            configurationSnapshot = latest
            return nil
        }
        if latest.revision > current.revision {
            configurationSnapshot = latest
        }
        return nil
    }

    private func acceptPersistence(
        _ result: OperatingModePersistenceResult
    ) -> AppConfigurationWriterSnapshot {
        let snapshot: AppConfigurationWriterSnapshot
        switch result {
        case let .persisted(value), let .current(value),
             let .conflict(value), let .recoveryRequired(value):
            snapshot = value
        }
        if snapshot.revision >= (configurationSnapshot?.revision ?? 0) {
            configurationSnapshot = snapshot
        }
        return snapshot
    }

    private func beginDecision() -> DecisionIdentity {
        decisionRevision &+= 1
        return DecisionIdentity(revision: decisionRevision, sessionEpoch: sessionEpoch)
    }

    private func decisionIsCurrent(_ decision: DecisionIdentity) -> Bool {
        !isTerminationFenced
            && decision.revision == decisionRevision
            && decision.sessionEpoch == sessionEpoch
    }

    private struct DecisionIdentity: Sendable {
        let revision: UInt64
        let sessionEpoch: UInt64
    }
}

private extension Optional where Wrapped == AppConfigurationWriterSnapshot {
    func currentConfigurationOr(
        _ reason: OperatingModeSuppressionReason
    ) -> OperatingModeDecisionResult {
        switch self {
        case let .some(snapshot):
            .current(snapshot)
        case .none:
            .suppressed(reason)
        }
    }
}
