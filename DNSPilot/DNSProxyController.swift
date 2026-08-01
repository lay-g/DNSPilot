import Foundation
import OSLog

enum DNSProxyControllerState: Equatable, Sendable {
    case disabled
    case preparing(UUID)
    case applying(UUID)
    case repairing(UUID)
    case active(UUID)
    case stopping
    case failed(String)
    case degraded(String)
    case recoveryRequired(String)

    var description: String {
        switch self {
        case .disabled:
            "Disabled"
        case .preparing:
            "Preparing DNS proxy..."
        case .applying:
            "Applying DNS proxy configuration..."
        case .repairing:
            "Repairing DNS proxy configuration..."
        case let .active(generation):
            "Ready (generation \(generation.uuidString))"
        case .stopping:
            "Restoring system DNS..."
        case let .failed(message):
            "Failed: \(message)"
        case let .degraded(message):
            "Degraded: \(message)"
        case let .recoveryRequired(message):
            "System DNS recovery required: \(message)"
        }
    }

    var userDescription: String {
        switch self {
        case .disabled:
            "Off"
        case .preparing:
            "Preparing"
        case .applying:
            "Applying"
        case .repairing:
            "Repairing"
        case .active:
            "On"
        case .stopping:
            "Restoring System DNS"
        case .failed:
            "Error"
        case .degraded:
            "Limited"
        case .recoveryRequired:
            "Recovery required"
        }
    }
}

enum DNSProxyTerminationRestoreResult: Equatable, Sendable {
    case disabled
    case resumePreparationFailed(state: DNSProxyControllerState, message: String)
    case restoreFailed(DNSProxyControllerState)

    var state: DNSProxyControllerState {
        switch self {
        case .disabled:
            .disabled
        case let .resumePreparationFailed(state, _):
            state
        case let .restoreFailed(state):
            state
        }
    }
}

enum ProxyResumeStartupEvaluation: Equatable, Sendable {
    case none
    case pending(ProxyResumeRecord)
    case failed(ProxyResumeFailureCode)
    case recoveryRequired(ProxyResumeFailureCode)
}

enum ProxyResumeManagerMismatchField: String, Hashable, Sendable {
    case persistedConfigurationUnavailable
    case ownerIdentityUnavailable
    case providerBundleIdentifier
    case ownerConfigurationFingerprint
    case localizedDescriptionFingerprint
    case activeGeneration
    case activeProfileID
    case activeConfigurationFingerprint
}

enum ProxyResumeExtensionUpgradeDecision: Equatable, Sendable {
    case notNeeded
    case submitted(ProxyResumeRecord)
    case confirmed(ProxyResumeRecord)
    case blocked(ProxyResumeFailureCode)
    case recoveryRequired(ProxyResumeFailureCode)
}

struct DNSProxyTarget: Hashable, Sendable {
    let profileID: UUID
    let upstream: DNSUpstream
    let dnsCacheConfiguration: DNSCacheConfiguration

    init(
        profileID: UUID,
        upstream: DNSUpstream,
        dnsCacheConfiguration: DNSCacheConfiguration = .standard
    ) {
        self.profileID = profileID
        self.upstream = upstream
        self.dnsCacheConfiguration = dnsCacheConfiguration
    }
}

enum ProxySwitchFailureCode: String, Equatable, Sendable {
    case targetPreflightFailed
    case providerCompatibilityUnavailable
    case oldGenerationChanged
    case managerStateUnavailable
    case targetWriteFailed
    case targetReadinessTimedOut
    case targetProviderFailed
}

struct ProxySwitchFailure: Equatable, Sendable {
    let code: ProxySwitchFailureCode
    let targetProfileID: UUID
    let activeProfileID: UUID?
    let providerErrorCode: ProxyRuntimeErrorCode?
    let message: String

    var diagnosticSummary: String {
        [
            code.rawValue,
            "provider=\(providerErrorCode?.rawValue ?? "none")",
            message,
        ].joined(separator: " | ")
    }
}

struct ProxyControllerSnapshot: Equatable, Sendable {
    let state: DNSProxyControllerState
    let targetProfileID: UUID?
    let activeProfileID: UUID?
    let activeGeneration: UUID?
    let lastSwitchFailure: ProxySwitchFailure?
}

enum DNSProxyControllerError: LocalizedError, Sendable {
    case missingExtensionIdentifier
    case managerConfigurationChangedDuringRollback
    case managerStateUnavailable(String)
    case readinessTimeout
    case providerFailed(ProxyRuntimeErrorCode?)
    case unsupportedProviderConfigurationSchema(required: Int, available: Int?)
    case runtimeControlOutcomeUncertain
    case rollbackDeadlineExceeded
    case terminationRequested
    case activeProfileMutationAlreadyReserved
    case activeProfileMutationReservationMismatch
    case activeProfileMutationNotPersisted

    var errorDescription: String? {
        switch self {
        case .missingExtensionIdentifier:
            "DNSProxyExtensionIdentifier is missing from the Host Info.plist."
        case .managerConfigurationChangedDuringRollback:
            "The DNS Proxy configuration changed before rollback. The newer configuration was not disabled."
        case let .managerStateUnavailable(message):
            "The DNS Proxy manager state could not be confirmed: \(message)"
        case .readinessTimeout:
            "The DNS Proxy did not report ready within five seconds."
        case let .providerFailed(code):
            "The DNS Proxy provider failed to start (\(code?.rawValue ?? "unknown"))."
        case let .unsupportedProviderConfigurationSchema(required, available):
            "The active DNS Proxy extension supports configuration schema "
                + "\(available.map(String.init) ?? "1 or earlier"), but this target requires schema \(required)."
        case .runtimeControlOutcomeUncertain:
            "The DNS Proxy runtime operation did not reach a confirmed terminal state."
        case .rollbackDeadlineExceeded:
            "The DNS Proxy recovery deadline expired before manager state could be confirmed."
        case .terminationRequested:
            "System DNS restoration was requested while the DNS Proxy was preparing."
        case .activeProfileMutationAlreadyReserved:
            "Another active Profile mutation is already reserved."
        case .activeProfileMutationReservationMismatch:
            "The active Profile mutation reservation no longer matches the controller."
        case .activeProfileMutationNotPersisted:
            "The reserved active Profile mutation has not persisted its desired configuration."
        }
    }
}

struct ActiveProfileMutationReservation: Equatable, Sendable {
    let mutationID: UUID
    let runtimeOperationID: UUID
    let oldConfiguration: PersistedProxyConfiguration
    let draftConfiguration: PersistedProxyConfiguration
    fileprivate let controllerIdentity: UUID

    init(
        mutationID: UUID,
        runtimeOperationID: UUID,
        oldConfiguration: PersistedProxyConfiguration,
        draftConfiguration: PersistedProxyConfiguration,
        controllerIdentity: UUID = UUID()
    ) {
        self.mutationID = mutationID
        self.runtimeOperationID = runtimeOperationID
        self.oldConfiguration = oldConfiguration
        self.draftConfiguration = draftConfiguration
        self.controllerIdentity = controllerIdentity
    }
}

enum ActiveProfileMutationRecoveryGoal: Equatable, Sendable {
    case restoreOld
    case finishDraft
}

enum ActiveProfileMutationState: Equatable, Sendable {
    case draftActive
    case oldRuntimePreserved
    case oldActive
    case disabled
    case recoveryRequired(String)
}

struct ActiveProfileMutationResult: Equatable, Sendable {
    let mutationID: UUID
    let runtimeOperationID: UUID
    let oldConfiguration: PersistedProxyConfiguration
    let draftConfiguration: PersistedProxyConfiguration
    let state: ActiveProfileMutationState
}

struct ProfileDeletionLease: Hashable, Sendable {
    let id: UUID
}

actor DNSProxyController {
    private struct RuntimeReapplyResolution: Sendable {
        let response: ProxyReapplyResponse
        let verificationDeadline: ContinuousClock.Instant
    }

    private struct DisabledRuntimeQuarantine: Sendable {
        let expectedManagerSnapshot: DNSProxyManagerSnapshot
        let lifecycleRequest: ProxyLifecycleRequest?
    }

    private struct ReservedActiveProfileMutation: Sendable {
        let reservation: ActiveProfileMutationReservation
        let baseManagerSnapshot: DNSProxyManagerSnapshot
        let providerInstanceID: UUID
        var draftManagerSnapshot: DNSProxyManagerSnapshot?
    }

    private enum RecoveryObservedState: Equatable, Sendable {
        case old
        case draft
        case disabled
        case unknown
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "DNSPilot",
        category: "DNSProxyController"
    )
    private let manager: any DNSProxyManagerManaging
    private let validator: any UpstreamValidating
    private let statusProvider: any ProxyRuntimeStatusProviding
    private let runtimeController: any ProxyRuntimeControlling
    private let configuredProviderBundleIdentifier: String?
    private var configuredLoggingMode: ProxyLoggingMode
    private let configuredUpstream: DNSUpstream
    private let readinessTimeout: Duration
    private let rollbackTimeout: Duration
    private let pollInterval: Duration
    private var state: DNSProxyControllerState = .disabled {
        didSet { presentationDidChange() }
    }
    private var activeTarget: DNSProxyTarget? {
        didSet { presentationDidChange() }
    }
    private var activeGeneration: UUID? {
        didSet { presentationDidChange() }
    }
    private var activeLoggingMode: ProxyLoggingMode?
    private var targetProfileID: UUID? {
        didSet { presentationDidChange() }
    }
    private var lastSwitchFailure: ProxySwitchFailure? {
        didSet { presentationDidChange() }
    }
    private var failedTarget: DNSProxyTarget?
    private var operationInProgress = false
    private var inFlightTarget: DNSProxyTarget?
    private var pendingTarget: DNSProxyTarget?
    private var terminationRequested = false
    private var terminationCancellationRequested = false
    private var terminationRestoreOwnsOperation = false
    private var managerMutationOutcomeUncertain = false
    private var disabledRuntimeQuarantine: DisabledRuntimeQuarantine?
    private var pendingDeadlineManagerCalls: Set<UUID> = []
    private var preflightTask: Task<Void, any Error>?
    private var readinessTask: Task<Void, any Error>?
    private var runtimeControlTask: Task<ProxyReapplyResponse, any Error>?
    private var reservedActiveProfileMutation: ReservedActiveProfileMutation?
    private var stagedMutationPreparationInProgress = false
    private var stagedMutationExecutionInProgress = false
    private var profileDeletionLeaseID: UUID?
    private var resumeJournal: (any ProxyResumeJournalStoring)?
    private var resumeAppConfigurationFingerprint: AppConfigurationFingerprint?
    private var terminationResumePreparationError: String?
    private var presentationRevision: UInt64 = 0
    private var presentationPublishScheduled = false
    private var presentationChangeHandler: (@MainActor @Sendable (
        UInt64,
        ProxyControllerSnapshot
    ) -> Void)?

    init(loggingMode: ProxyLoggingMode? = nil) {
        let runtimeRouter = MachXPCServiceRouter()
        manager = NetworkExtensionDNSProxyManager()
        validator = UpstreamValidator()
        statusProvider = runtimeRouter
        runtimeController = runtimeRouter
        configuredProviderBundleIdentifier = Bundle.main.object(
            forInfoDictionaryKey: "DNSProxyExtensionIdentifier"
        ) as? String
        configuredLoggingMode = loggingMode ?? ProxyLoggingMode(
            rawValue: Bundle.main.object(
                forInfoDictionaryKey: "DNSPilotProxyLoggingMode"
            ) as? String ?? ""
        ) ?? .default
        configuredUpstream = .fixedForCurrentBuild
        readinessTimeout = .seconds(5)
        rollbackTimeout = .seconds(8)
        pollInterval = .milliseconds(200)
    }

    init(
        manager: any DNSProxyManagerManaging,
        validator: any UpstreamValidating,
        statusProvider: any ProxyRuntimeStatusProviding,
        runtimeController: any ProxyRuntimeControlling,
        providerBundleIdentifier: String?,
        loggingMode: ProxyLoggingMode = .default,
        upstream: DNSUpstream = .fixedCloudflare,
        readinessTimeout: Duration = .seconds(5),
        rollbackTimeout: Duration = .seconds(8),
        pollInterval: Duration = .milliseconds(200)
    ) {
        self.manager = manager
        self.validator = validator
        self.statusProvider = statusProvider
        self.runtimeController = runtimeController
        configuredProviderBundleIdentifier = providerBundleIdentifier
        configuredLoggingMode = loggingMode
        configuredUpstream = upstream
        self.readinessTimeout = readinessTimeout
        self.rollbackTimeout = rollbackTimeout
        self.pollInterval = pollInterval
    }

    func snapshot() -> DNSProxyControllerState {
        state
    }

    func configureResumeJournal(
        _ journal: any ProxyResumeJournalStoring,
        appConfigurationFingerprint: AppConfigurationFingerprint
    ) {
        resumeJournal = journal
        resumeAppConfigurationFingerprint = appConfigurationFingerprint
    }

    func evaluateStartupResume() async -> ProxyResumeStartupEvaluation {
        guard let resumeJournal, let appFingerprint = resumeAppConfigurationFingerprint else {
            return .none
        }
        let record: ProxyResumeRecord
        do {
            switch try resumeJournal.load() {
            case .missing:
                return .none
            case let .loaded(value):
                record = value
            case .newerSchema, .unsupportedSchema, .corrupt:
                return .recoveryRequired(.outcomeUncertain)
            }
        } catch {
            return .recoveryRequired(.outcomeUncertain)
        }

        guard record.appConfigurationFingerprint == appFingerprint else {
            return .failed(.configurationChanged)
        }
        guard record.phase == .preparedForQuit || record.phase == .disabledConfirmed else {
            return .failed(record.failureCode ?? .activationFailed)
        }

        do {
            let snapshot = try await manager.loadSnapshot()
            let mismatches = managerSnapshotMismatches(snapshot, record: record)
            let upgradeCanReconcile = record.extensionUpgrade.map { upgrade in
                upgrade.phase != .replacementConfirmed
                    && !snapshot.isEnabled
                    && mismatches.isSubset(of: Self.extensionReplacementAllowedMismatches)
            } ?? false
            guard mismatches.isEmpty || upgradeCanReconcile else {
                logger.error(
                    "Startup DNS Proxy resume manager mismatch: \(Self.mismatchDescription(mismatches), privacy: .public)"
                )
                return .failed(.managerChanged)
            }
            if snapshot.isEnabled {
                guard case .active = state,
                      activeGeneration == record.activeGeneration,
                      activeTarget?.profileID == record.activeProfileID else {
                    return .recoveryRequired(.outcomeUncertain)
                }
                try resumeJournal.discard(operationID: record.operationID)
                return .none
            }
            return .pending(record)
        } catch {
            return .recoveryRequired(.outcomeUncertain)
        }
    }

    func resumeAfterSafeQuit(
        target: DNSProxyTarget,
        record: ProxyResumeRecord,
        appConfigurationFingerprint: AppConfigurationFingerprint
    ) async -> ProxyControllerSnapshot {
        guard !operationInProgress, !terminationRequested,
              let resumeJournal,
              resumeAppConfigurationFingerprint == appConfigurationFingerprint,
              record.appConfigurationFingerprint == appConfigurationFingerprint else {
            return makeSnapshot()
        }

        operationInProgress = true
        let attemptID = UUID()
        let generation = UUID()
        var didEnableManager = false
        var attemptedManagerEnable = false
        var expectedDisabledSnapshot: DNSProxyManagerSnapshot?
        defer { operationInProgress = false }
        targetProfileID = target.profileID
        state = .preparing(generation)

        do {
            let expected = try await manager.loadSnapshot()
            expectedDisabledSnapshot = expected
            guard !expected.isEnabled,
                  managerSnapshotMismatches(expected, record: record).isEmpty,
                  record.extensionUpgrade?.phase != .prepared,
                  record.extensionUpgrade?.phase != .replacementSubmitted else {
                throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
            }
            _ = try resumeJournal.claim(
                operationID: record.operationID,
                attemptID: attemptID
            )
            let schemaVersion = try await compatibleSchemaVersion(for: target)
            try await validate(upstream: target.upstream)
            let configuration = try ActiveProxyConfiguration(
                generation: generation,
                profileID: target.profileID,
                upstream: target.upstream,
                loggingMode: configuredLoggingMode,
                dnsCacheConfiguration: target.dnsCacheConfiguration,
                schemaVersion: schemaVersion
            )
            let persisted = try PersistedProxyConfiguration(value: configuration)
            state = .applying(generation)
            attemptedManagerEnable = true
            switch try await manager.saveEnabledConfiguration(
                persisted,
                providerBundleIdentifier: try providerBundleIdentifier(),
                ifDisabledSnapshotMatches: expected
            ) {
            case let .enabled(enabledSnapshot):
                didEnableManager = true
                try await waitUntilReadyCancellable(
                    configuration: persisted,
                    timeout: readinessTimeout
                )
                let confirmed = try await manager.loadSnapshot()
                guard confirmed == enabledSnapshot else {
                    throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
                }
                setActive(configuration)
                try resumeJournal.discard(operationID: record.operationID)
            case .configurationChanged:
                throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
            }
        } catch {
            if didEnableManager {
                do {
                    try await disableManager(ifGenerationMatches: generation)
                    clearPresentationForDisabledState()
                } catch {
                    requireSwitchRecovery(
                        "Startup DNS Proxy resume could not be reconciled after activation failed."
                    )
                }
            } else if attemptedManagerEnable {
                let observed = try? await manager.loadSnapshot()
                if let expectedDisabledSnapshot,
                   observed == expectedDisabledSnapshot {
                    clearPresentationForDisabledState()
                } else {
                    requireSwitchRecovery(
                        "Startup DNS Proxy resume manager outcome could not be confirmed."
                    )
                }
            } else {
                clearPresentationForDisabledState()
            }
            try? resumeJournal.markFailed(
                operationID: record.operationID,
                attemptID: attemptID,
                code: error is DNSProxyControllerError
                    ? .activationFailed
                    : .outcomeUncertain
            )
            if case .disabled = state {
                lastSwitchFailure = ProxySwitchFailure(
                    code: .targetWriteFailed,
                    targetProfileID: target.profileID,
                    activeProfileID: nil,
                    providerErrorCode: nil,
                    message: error.localizedDescription
                )
            }
        }
        return makeSnapshot()
    }

    func discardStartupResume() {
        try? resumeJournal?.discard(operationID: nil)
    }

    func prepareStartupResumeExtensionUpgrade(
        source: ProxyResumeExtensionBuildIdentity,
        target: ProxyResumeExtensionBuildIdentity
    ) async -> ProxyResumeExtensionUpgradeDecision {
        guard let resumeJournal else { return .notNeeded }
        do {
            guard case let .loaded(record) = try resumeJournal.load() else {
                return .notNeeded
            }
            guard record.phase == .preparedForQuit || record.phase == .disabledConfirmed else {
                return .blocked(.activationFailed)
            }
            let snapshot = try await manager.loadSnapshot()
            guard !snapshot.isEnabled else { return .blocked(.managerChanged) }
            let mismatches = managerSnapshotMismatches(snapshot, record: record)
            guard mismatches.isEmpty else {
                logger.error(
                    "Extension upgrade preparation manager mismatch: \(Self.mismatchDescription(mismatches), privacy: .public)"
                )
                return .blocked(.managerChanged)
            }
            guard let owner = snapshot.ownerIdentity else {
                return .blocked(.managerChanged)
            }
            let prepared = try resumeJournal.prepareExtensionUpgrade(
                operationID: record.operationID,
                source: source,
                target: target,
                localizedDescriptionFingerprint: owner.localizedDescriptionFingerprint
            )
            guard let upgrade = prepared.extensionUpgrade else {
                return .recoveryRequired(.outcomeUncertain)
            }
            let submitted = try resumeJournal.markExtensionUpgradeSubmitted(
                operationID: prepared.operationID,
                upgradeOperationID: upgrade.operationID,
                attemptID: upgrade.replacementAttemptID ?? UUID()
            )
            return .submitted(submitted)
        } catch {
            logger.error(
                "Extension upgrade preparation failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return .recoveryRequired(.outcomeUncertain)
        }
    }

    func confirmStartupResumeExtensionUpgrade(
        target: ProxyResumeExtensionBuildIdentity
    ) async -> ProxyResumeExtensionUpgradeDecision {
        guard let resumeJournal else { return .notNeeded }
        do {
            guard case let .loaded(record) = try resumeJournal.load(),
                  let upgrade = record.extensionUpgrade else {
                return .notNeeded
            }
            guard upgrade.target == target else { return .blocked(.extensionUnavailable) }
            if upgrade.phase == .replacementConfirmed {
                let snapshot = try await manager.loadSnapshot()
                guard !snapshot.isEnabled,
                      managerSnapshotMismatches(snapshot, record: record).isEmpty else {
                    return .blocked(.managerChanged)
                }
                return .confirmed(record)
            }
            guard upgrade.phase == .replacementSubmitted else {
                return .blocked(.extensionUnavailable)
            }
            let snapshot = try await manager.loadSnapshot()
            guard !snapshot.isEnabled, let owner = snapshot.ownerIdentity else {
                return .blocked(.managerChanged)
            }
            let mismatches = managerSnapshotMismatches(snapshot, record: record)
            guard mismatches.isSubset(of: Self.extensionReplacementAllowedMismatches) else {
                logger.error(
                    "Extension upgrade reconciliation manager mismatch: \(Self.mismatchDescription(mismatches), privacy: .public)"
                )
                return .blocked(.managerChanged)
            }
            let confirmed = try resumeJournal.confirmExtensionUpgrade(
                operationID: record.operationID,
                upgradeOperationID: upgrade.operationID,
                ownerConfigurationFingerprint: owner.providerConfigurationFingerprint,
                localizedDescriptionFingerprint: owner.localizedDescriptionFingerprint
            )
            return .confirmed(confirmed)
        } catch {
            logger.error(
                "Extension upgrade reconciliation failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return .recoveryRequired(.outcomeUncertain)
        }
    }

    func controllerSnapshot() -> ProxyControllerSnapshot {
        makeSnapshot()
    }

    func presentationSnapshot() -> (revision: UInt64, snapshot: ProxyControllerSnapshot) {
        (presentationRevision, makeSnapshot())
    }

    func setPresentationChangeHandler(
        _ handler: (@MainActor @Sendable (UInt64, ProxyControllerSnapshot) -> Void)?
    ) {
        presentationChangeHandler = handler
    }

    func acquireProfileDeletionLease(
        deleting profileID: DNSProfile.ID
    ) -> ProfileDeletionLease? {
        guard profileDeletionLeaseID == nil,
              !operationInProgress,
              inFlightTarget == nil,
              pendingTarget == nil,
              !(targetProfileID == profileID && activeTarget?.profileID != profileID) else {
            return nil
        }
        switch state {
        case .preparing, .applying, .repairing, .stopping, .recoveryRequired:
            return nil
        case .disabled, .active, .failed, .degraded:
            break
        }
        let lease = ProfileDeletionLease(id: UUID())
        profileDeletionLeaseID = lease.id
        return lease
    }

    func releaseProfileDeletionLease(_ lease: ProfileDeletionLease) {
        guard profileDeletionLeaseID == lease.id else { return }
        profileDeletionLeaseID = nil
    }

    func activeTargetForOperatingMode() -> DNSProxyTarget? {
        guard case .active = state else { return nil }
        return activeTarget
    }

    func activeProfileIDForMutation() -> UUID? {
        activeTarget?.profileID
    }

    func configurationMutationIsAllowed() -> Bool {
        guard !managerMutationOutcomeUncertain,
              disabledRuntimeQuarantine == nil,
              pendingDeadlineManagerCalls.isEmpty else {
            return false
        }
        switch state {
        case .disabled, .active, .failed, .degraded:
            return true
        case .preparing, .applying, .repairing, .stopping, .recoveryRequired:
            return false
        }
    }

    func loggingMode() -> ProxyLoggingMode {
        if activeLoggingMode == .debug || configuredLoggingMode == .debug {
            return .debug
        }
        return .default
    }

    func updateLoggingMode(_ mode: ProxyLoggingMode) async -> Bool {
        guard !operationInProgress,
              !terminationRequested,
              profileDeletionLeaseID == nil,
              !managerMutationOutcomeUncertain,
              disabledRuntimeQuarantine == nil,
              pendingDeadlineManagerCalls.isEmpty else { return false }

        switch state {
        case .disabled, .failed, .degraded:
            guard activeTarget == nil else { return false }
            configuredLoggingMode = mode
            return true
        case .active:
            guard let target = activeTarget else { return false }
            if configuredLoggingMode == mode, activeLoggingMode == mode { return true }
            let previousMode = configuredLoggingMode
            configuredLoggingMode = mode
            operationInProgress = true
            await performTargetTransaction(target)
            operationInProgress = false
            guard case .active = state,
                  activeTarget == target,
                  activeLoggingMode == mode else {
                if case .active = state {
                    configuredLoggingMode = activeLoggingMode ?? previousMode
                } else if previousMode == .debug || mode == .debug {
                    configuredLoggingMode = .debug
                }
                return false
            }
            return true
        case .preparing, .applying, .repairing, .stopping, .recoveryRequired:
            return false
        }
    }

    func synchronizeState() async -> DNSProxyControllerState {
        guard !operationInProgress, !terminationRequested else { return state }
        guard pendingDeadlineManagerCalls.isEmpty else {
            state = .recoveryRequired(
                "A previous DNS Proxy manager operation has not finished."
            )
            return state
        }
        operationInProgress = true
        defer { operationInProgress = false }

        do {
            let snapshot = try await manager.loadSnapshot()
            managerMutationOutcomeUncertain = false
            if disabledRuntimeQuarantine != nil {
                state = .recoveryRequired(
                    snapshot.isEnabled
                        ? "The DNS Proxy manager changed while runtime quiescence remained unconfirmed."
                        : "The DNS Proxy manager is disabled, but runtime quiescence remains unconfirmed."
                )
                return state
            }
            guard snapshot.isEnabled else {
                clearPresentationForDisabledState()
                return state
            }

            guard let desired = snapshot.persistedConfiguration else {
                throw DNSProxyControllerError.managerStateUnavailable(
                    "The enabled DNS Proxy configuration could not be decoded."
                )
            }
            configuredLoggingMode = desired.value.loggingMode
            let expectedProviderBundleIdentifier = try providerBundleIdentifier()
            guard snapshot.ownerIdentity?.providerBundleIdentifier
                == expectedProviderBundleIdentifier else {
                throw DNSProxyControllerError.managerStateUnavailable(
                    "The enabled DNS Proxy manager is owned by another provider."
                )
            }
            let status = try await runtimeStatus()
            if runtime(status, matches: desired) {
                try checkForTerminationRequest()
                let confirmedSnapshot = try await loadManagerSnapshot()
                try checkForTerminationRequest()
                guard confirmedSnapshot == snapshot else {
                    throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
                }
                setActive(desired.value)
            } else {
                await reconcileStartup(
                    desired: desired,
                    expectedManagerSnapshot: snapshot,
                    baseStatus: status
                )
            }
        } catch {
            activeTarget = nil
            activeGeneration = nil
            state = .recoveryRequired(
                "The DNS Proxy manager state could not be loaded: \(error.localizedDescription)"
            )
        }
        return state
    }

    func enableConfiguredDoH() async -> DNSProxyControllerState {
        guard
            !operationInProgress,
            !terminationRequested,
            !managerMutationOutcomeUncertain,
            disabledRuntimeQuarantine == nil,
            pendingDeadlineManagerCalls.isEmpty
        else { return state }
        operationInProgress = true
        defer { operationInProgress = false }

        let generation = UUID()
        let profileID = UUID()
        var didEnableManager = false
        state = .preparing(generation)

        let initialSnapshot: DNSProxyManagerSnapshot
        do {
            initialSnapshot = try await manager.loadSnapshot()
            try checkForTerminationRequest()
        } catch {
            state = .recoveryRequired(
                "The DNS Proxy manager state could not be loaded: \(error.localizedDescription)"
            )
            return state
        }
        guard !initialSnapshot.isEnabled else {
            state = .recoveryRequired(
                "The DNS Proxy manager is already enabled. Restore system DNS before enabling it again."
            )
            return state
        }

        do {
            try await validate(upstream: configuredUpstream)
            try checkForTerminationRequest()
            let configuration = try ActiveProxyConfiguration(
                generation: generation,
                profileID: profileID,
                upstream: configuredUpstream,
                loggingMode: configuredLoggingMode,
                schemaVersion: 1
            )
            let persistedConfiguration = try PersistedProxyConfiguration(value: configuration)
            switch try await enableManager(
                configuration,
                providerBundleIdentifier: try providerBundleIdentifier()
            ) {
            case .enabled:
                didEnableManager = true
            case .alreadyEnabled:
                state = .recoveryRequired(
                    "The DNS Proxy manager was enabled while preflight was running. Its configuration was not overwritten."
                )
                return state
            }
            try checkForTerminationRequest()
            try await waitUntilReadyCancellable(
                configuration: persistedConfiguration,
                timeout: readinessTimeout
            )
            try checkForTerminationRequest()
            try await requireManagerGeneration(generation)
            try checkForTerminationRequest()
            setActive(configuration)
        } catch {
            if didEnableManager {
                do {
                    try await disableManager(ifGenerationMatches: generation)
                } catch let recoveryError {
                    state = .recoveryRequired(
                        "\(error.localizedDescription) Restore failed: "
                            + recoveryError.localizedDescription
                    )
                    return state
                }
            }
            if case let DNSProxyControllerError.managerStateUnavailable(message) = error {
                state = .recoveryRequired(message)
                return state
            }
            if terminationRequested {
                state = .stopping
                return state
            }
            state = .failed(error.localizedDescription)
        }

        return state
    }

    func activate(_ target: DNSProxyTarget) async -> ProxyControllerSnapshot {
        await enqueue(target)
    }

    func switchTarget(to target: DNSProxyTarget) async -> ProxyControllerSnapshot {
        await enqueue(target)
    }

    func reserveActiveProfileMutation(
        to target: DNSProxyTarget,
        mutationID: UUID,
        runtimeOperationID: UUID
    ) async throws -> ActiveProfileMutationReservation {
        guard reservedActiveProfileMutation == nil, !stagedMutationPreparationInProgress else {
            throw DNSProxyControllerError.activeProfileMutationAlreadyReserved
        }
        guard
            !operationInProgress,
            !terminationRequested,
            !managerMutationOutcomeUncertain,
            disabledRuntimeQuarantine == nil,
            pendingDeadlineManagerCalls.isEmpty
        else {
            throw DNSProxyControllerError.activeProfileMutationAlreadyReserved
        }

        operationInProgress = true
        stagedMutationPreparationInProgress = true
        do {
            let managerSnapshot = try await loadManagerSnapshot()
            try checkForTerminationRequest()
            guard
                managerSnapshot.isEnabled,
                let oldConfiguration = managerSnapshot.persistedConfiguration,
                oldConfiguration.value.generation == activeGeneration,
                oldConfiguration.value.profileID == activeTarget?.profileID,
                try managerSnapshotIsOwned(
                    managerSnapshot,
                    configuration: oldConfiguration
                )
            else {
                throw DNSProxyControllerError.managerStateUnavailable(
                    "The controller no longer owns the exact active DNS Proxy manager."
                )
            }

            let schemaVersion = try await compatibleSchemaVersion(for: target)
            try checkForTerminationRequest()
            if oldConfiguration.value.upstream != target.upstream {
                try await validate(upstream: target.upstream)
            }
            try checkForTerminationRequest()
            let draftValue = try ActiveProxyConfiguration(
                generation: UUID(),
                profileID: target.profileID,
                upstream: target.upstream,
                loggingMode: configuredLoggingMode,
                dnsCacheConfiguration: target.dnsCacheConfiguration,
                schemaVersion: schemaVersion
            )
            let draftConfiguration = try PersistedProxyConfiguration(value: draftValue)
            let runtimeStatus = try await runtimeStatus()
            try checkForTerminationRequest()
            guard
                runtimeStatus.runtimeControlProtocolVersion
                    == DNSProxyXPCContract.currentRuntimeControlProtocolVersion,
                runtime(runtimeStatus, matches: oldConfiguration),
                let providerInstanceID = runtimeStatus.providerInstanceID
            else {
                throw DNSProxyControllerError.managerStateUnavailable(
                    "The controller no longer owns the exact active DNS Proxy runtime."
                )
            }
            let confirmedManager = try await loadManagerSnapshot()
            try checkForTerminationRequest()
            guard confirmedManager == managerSnapshot else {
                throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
            }

            let reservation = ActiveProfileMutationReservation(
                mutationID: mutationID,
                runtimeOperationID: runtimeOperationID,
                oldConfiguration: oldConfiguration,
                draftConfiguration: draftConfiguration,
                controllerIdentity: UUID()
            )
            reservedActiveProfileMutation = ReservedActiveProfileMutation(
                reservation: reservation,
                baseManagerSnapshot: managerSnapshot,
                providerInstanceID: providerInstanceID,
                draftManagerSnapshot: nil
            )
            stagedMutationPreparationInProgress = false
            targetProfileID = target.profileID
            return reservation
        } catch {
            stagedMutationPreparationInProgress = false
            operationInProgress = false
            await drainPendingTargetAfterStagedMutation()
            throw error
        }
    }

    func persistReservedDesired(
        _ reservation: ActiveProfileMutationReservation
    ) async throws {
        var reserved = try requireReservedMutation(reservation)
        guard reserved.draftManagerSnapshot == nil else { return }
        guard !stagedMutationExecutionInProgress else {
            throw DNSProxyControllerError.activeProfileMutationAlreadyReserved
        }
        stagedMutationExecutionInProgress = true
        do {
            let replaceResult = try await manager.replaceEnabledConfiguration(
                reservation.draftConfiguration,
                ifCurrentMatches: reserved.baseManagerSnapshot
            )
            let draftSnapshot: DNSProxyManagerSnapshot
            switch replaceResult {
            case let .replaced(snapshot):
                draftSnapshot = snapshot
            case .configurationChanged:
                throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
            }
            let confirmed = try await loadManagerSnapshot()
            guard confirmed == draftSnapshot else {
                throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
            }
            reserved.draftManagerSnapshot = draftSnapshot
            reservedActiveProfileMutation = reserved
            if terminationRequested {
                _ = try await compensateReservedMutation(reserved)
                stagedMutationExecutionInProgress = false
                reservedActiveProfileMutation = nil
                operationInProgress = false
                throw DNSProxyControllerError.terminationRequested
            }
            stagedMutationExecutionInProgress = false
        } catch DNSProxyControllerError.terminationRequested {
            stagedMutationExecutionInProgress = false
            reservedActiveProfileMutation = nil
            operationInProgress = false
            throw DNSProxyControllerError.terminationRequested
        } catch {
            stagedMutationExecutionInProgress = false
            requireSwitchRecovery(
                "The reserved DNS Proxy desired configuration could not be confirmed: "
                    + error.localizedDescription
            )
            await releaseReservedMutationAndDrain()
            throw error
        }
    }

    func applyReservedMutation(
        _ reservation: ActiveProfileMutationReservation
    ) async -> ActiveProfileMutationResult {
        guard !stagedMutationExecutionInProgress else {
            return mutationResult(
                reservation,
                state: .recoveryRequired(
                    DNSProxyControllerError.activeProfileMutationAlreadyReserved.localizedDescription
                )
            )
        }
        stagedMutationExecutionInProgress = true
        do {
            let reserved = try requireReservedMutation(reservation)
            guard let draftManagerSnapshot = reserved.draftManagerSnapshot else {
                throw DNSProxyControllerError.activeProfileMutationNotPersisted
            }
            let request = ProxyReapplyRequest(
                operationID: reservation.runtimeOperationID,
                expectedProviderInstanceID: reserved.providerInstanceID,
                expectedBaseGeneration: reservation.oldConfiguration.value.generation,
                expectedBaseFingerprint: reservation.oldConfiguration.fingerprint,
                targetConfigurationData: reservation.draftConfiguration.data,
                targetFingerprint: reservation.draftConfiguration.fingerprint
            )
            let resolution = try await resolveRuntimeSwitch(
                request,
                oldConfiguration: reservation.oldConfiguration,
                targetConfiguration: reservation.draftConfiguration,
                applicationDeadline: ContinuousClock().now.advanced(by: readinessTimeout)
            )
            switch resolution.response.disposition {
            case .applied:
                try await waitUntilRuntimeMatches(
                    reservation.draftConfiguration,
                    providerInstanceID: reserved.providerInstanceID,
                    deadline: resolution.verificationDeadline
                )
                let managerSnapshot = try await loadManagerSnapshot(
                    before: resolution.verificationDeadline
                )
                guard managerSnapshot == draftManagerSnapshot else {
                    throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
                }
                setActive(reservation.draftConfiguration.value)
                let result = mutationResult(reservation, state: .draftActive)
                stagedMutationExecutionInProgress = false
                await releaseReservedMutationAndDrain()
                return result

            case .rejectedPreservingBase:
                stagedMutationExecutionInProgress = false
                return mutationResult(reservation, state: .oldRuntimePreserved)

            case .rejected:
                let status = try await runtimeStatus()
                let managerSnapshot = try await loadManagerSnapshot()
                guard
                    runtime(status, matches: reservation.oldConfiguration),
                    managerSnapshot == draftManagerSnapshot
                else {
                    throw DNSProxyControllerError.runtimeControlOutcomeUncertain
                }
                stagedMutationExecutionInProgress = false
                return mutationResult(reservation, state: .oldRuntimePreserved)

            case .unrecoverable:
                await repairStoppedRuntime(
                    expectedManagerSnapshot: draftManagerSnapshot,
                    rejectedTarget: nil,
                    deadline: resolution.verificationDeadline
                )
                let terminalState: ActiveProfileMutationState = if case .degraded = state {
                    .disabled
                } else {
                    .recoveryRequired(state.description)
                }
                let result = mutationResult(reservation, state: terminalState)
                stagedMutationExecutionInProgress = false
                await releaseReservedMutationAndDrain()
                return result
            }
        } catch {
            if terminationRequested,
               let reserved = reservedActiveProfileMutation,
               reserved.reservation == reservation {
                do {
                    terminationRequested = false
                    let result = try await compensateReservedMutation(reserved)
                    terminationRequested = true
                    stagedMutationExecutionInProgress = false
                    reservedActiveProfileMutation = nil
                    operationInProgress = false
                    return result
                } catch {
                    terminationRequested = true
                    // Fall through to recovery-required with the reconciliation error.
                }
            }
            stagedMutationExecutionInProgress = false
            requireSwitchRecovery(
                "The reserved DNS Proxy runtime mutation requires recovery: "
                    + error.localizedDescription
            )
            let result = mutationResult(
                reservation,
                state: .recoveryRequired(error.localizedDescription)
            )
            await releaseReservedMutationAndDrain()
            return result
        }
    }

    func compensateReservedMutation(
        _ reservation: ActiveProfileMutationReservation
    ) async -> ActiveProfileMutationResult {
        guard !stagedMutationExecutionInProgress else {
            return mutationResult(
                reservation,
                state: .recoveryRequired(
                    DNSProxyControllerError.activeProfileMutationAlreadyReserved.localizedDescription
                )
            )
        }
        stagedMutationExecutionInProgress = true
        do {
            let reserved = try requireReservedMutation(reservation)
            let result = try await compensateReservedMutation(reserved)
            stagedMutationExecutionInProgress = false
            await releaseReservedMutationAndDrain()
            return result
        } catch {
            stagedMutationExecutionInProgress = false
            requireSwitchRecovery(
                "The reserved DNS Proxy compensation requires recovery: "
                    + error.localizedDescription
            )
            let result = mutationResult(
                reservation,
                state: .recoveryRequired(error.localizedDescription)
            )
            await releaseReservedMutationAndDrain()
            return result
        }
    }

    func recoverActiveProfileMutation(
        oldConfigurationData: Data,
        draftConfigurationData: Data,
        mutationID: UUID,
        runtimeOperationID: UUID,
        goal: ActiveProfileMutationRecoveryGoal
    ) async throws -> ActiveProfileMutationResult {
        let oldConfiguration = try PersistedProxyConfiguration(data: oldConfigurationData)
        let draftConfiguration = try PersistedProxyConfiguration(data: draftConfigurationData)
        let reservation = ActiveProfileMutationReservation(
            mutationID: mutationID,
            runtimeOperationID: runtimeOperationID,
            oldConfiguration: oldConfiguration,
            draftConfiguration: draftConfiguration,
            controllerIdentity: UUID()
        )
        guard
            reservedActiveProfileMutation == nil,
            !operationInProgress,
            !terminationRequested
        else {
            return mutationResult(
                reservation,
                state: .recoveryRequired(
                    DNSProxyControllerError.activeProfileMutationAlreadyReserved.localizedDescription
                )
            )
        }

        operationInProgress = true
        do {
            let result = try await recoverActiveProfileMutation(
                reservation,
                goal: goal
            )
            operationInProgress = false
            await drainPendingTargetAfterStagedMutation()
            return result
        } catch {
            requireSwitchRecovery(
                "The persisted active Profile mutation could not be recovered: "
                    + error.localizedDescription
            )
            operationInProgress = false
            await drainPendingTargetAfterStagedMutation()
            return mutationResult(
                reservation,
                state: .recoveryRequired(error.localizedDescription)
            )
        }
    }

    func restoreSystemDNS() async -> DNSProxyControllerState {
        guard !operationInProgress, !terminationRequested else { return state }
        guard pendingDeadlineManagerCalls.isEmpty else {
            state = .recoveryRequired(
                "A previous DNS Proxy manager operation has not finished."
            )
            return state
        }
        operationInProgress = true
        defer { operationInProgress = false }

        return await performSystemDNSRestore()
    }

    func restoreSystemDNSForTermination() async -> DNSProxyControllerState {
        await restoreSystemDNSForTerminationResult().state
    }

    func restoreSystemDNSForTerminationResult(
        rememberActiveState: Bool = true
    ) async -> DNSProxyTerminationRestoreResult {
        if
            let reserved = reservedActiveProfileMutation,
            !stagedMutationPreparationInProgress,
            !stagedMutationExecutionInProgress
        {
            pendingTarget = nil
            stagedMutationExecutionInProgress = true
            if reserved.draftManagerSnapshot == nil {
                stagedMutationExecutionInProgress = false
                reservedActiveProfileMutation = nil
                operationInProgress = false
            } else {
                do {
                    let result = try await compensateReservedMutation(reserved)
                    guard result.state == .oldActive || result.state == .disabled else {
                        throw DNSProxyControllerError.runtimeControlOutcomeUncertain
                    }
                    stagedMutationExecutionInProgress = false
                    reservedActiveProfileMutation = nil
                    operationInProgress = false
                } catch {
                    stagedMutationExecutionInProgress = false
                    reservedActiveProfileMutation = nil
                    operationInProgress = false
                    requireSwitchRecovery(
                        "The persisted Profile mutation could not be reconciled before termination: "
                            + error.localizedDescription
                    )
                    return .restoreFailed(state)
                }
            }
        }
        terminationRequested = true
        terminationCancellationRequested = false
        pendingTarget = nil
        targetProfileID = nil
        lastSwitchFailure = nil
        failedTarget = nil
        preflightTask?.cancel()
        readinessTask?.cancel()
        runtimeControlTask?.cancel()

        let clock = ContinuousClock()
        let waitDeadline = clock.now.advanced(by: rollbackTimeout)
        while operationInProgress || !pendingDeadlineManagerCalls.isEmpty {
            guard clock.now < waitDeadline else {
                activeTarget = nil
                activeGeneration = nil
                state = .recoveryRequired(
                    "A previous DNS Proxy operation did not finish before the quit safety deadline."
                )
                return .restoreFailed(state)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        operationInProgress = true
        terminationRestoreOwnsOperation = true
        defer {
            operationInProgress = false
            terminationRestoreOwnsOperation = false
            if terminationCancellationRequested {
                terminationRequested = false
                terminationCancellationRequested = false
            }
        }
        terminationResumePreparationError = nil
        if !rememberActiveState, let resumeJournal {
            do {
                try resumeJournal.discard(operationID: nil)
            } catch {
                terminationResumePreparationError = error.localizedDescription
                return .resumePreparationFailed(state: state, message: error.localizedDescription)
            }
        }
        let restored = await performSystemDNSRestore(
            prepareResumeRecord: rememberActiveState
        )
        if let error = terminationResumePreparationError {
            return .resumePreparationFailed(state: restored, message: error)
        }
        if restored == .disabled { return .disabled }
        return .restoreFailed(restored)
    }

    func cancelTerminationRequest() async {
        if terminationRestoreOwnsOperation {
            terminationCancellationRequested = true
        } else {
            terminationRequested = false
            terminationCancellationRequested = false
        }
        guard !operationInProgress,
              case .active = state,
              let resumeJournal,
               case let .loaded(record) = try? resumeJournal.load(),
               let snapshot = try? await manager.loadSnapshot(),
               snapshot.isEnabled,
               managerSnapshotMismatches(snapshot, record: record).isEmpty else { return }
        try? resumeJournal.discard(operationID: record.operationID)
    }

    func runtimeStatus() async throws -> ProxyRuntimeStatus {
        try await statusProvider.runtimeStatus()
    }

    func runtimeEvidence() async throws -> ProxyRuntimeEvidence {
        try await statusProvider.runtimeEvidence()
    }

    private func requireReservedMutation(
        _ reservation: ActiveProfileMutationReservation
    ) throws -> ReservedActiveProfileMutation {
        guard
            let reserved = reservedActiveProfileMutation,
            reserved.reservation == reservation
        else {
            throw DNSProxyControllerError.activeProfileMutationReservationMismatch
        }
        return reserved
    }

    private func mutationResult(
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

    private func releaseReservedMutationAndDrain() async {
        reservedActiveProfileMutation = nil
        stagedMutationPreparationInProgress = false
        operationInProgress = false
        await drainPendingTargetAfterStagedMutation()
    }

    private func drainPendingTargetAfterStagedMutation() async {
        guard !terminationRequested, let target = pendingTarget else { return }
        pendingTarget = nil
        _ = await enqueue(target)
    }

    private func compensateReservedMutation(
        _ reserved: ReservedActiveProfileMutation
    ) async throws -> ActiveProfileMutationResult {
        let reservation = reserved.reservation
        guard let draftManagerSnapshot = reserved.draftManagerSnapshot else {
            setActive(reservation.oldConfiguration.value)
            return mutationResult(reservation, state: .oldActive)
        }

        let currentManager = try await loadManagerSnapshot()
        let oldManagerSnapshot: DNSProxyManagerSnapshot
        if currentManager == reserved.baseManagerSnapshot {
            oldManagerSnapshot = currentManager
        } else if currentManager == draftManagerSnapshot {
            oldManagerSnapshot = try await replaceEnabledConfiguration(
                reservation.oldConfiguration,
                replacing: draftManagerSnapshot
            )
        } else if !currentManager.isEnabled {
            clearPresentationForDisabledState()
            return mutationResult(reservation, state: .disabled)
        } else {
            throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
        }

        let status = try await runtimeStatus()
        if runtime(status, matches: reservation.oldConfiguration) {
            guard try await loadManagerSnapshot() == oldManagerSnapshot else {
                throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
            }
            setActive(reservation.oldConfiguration.value)
            return mutationResult(reservation, state: .oldActive)
        }
        guard
            runtime(status, matches: reservation.draftConfiguration),
            status.runtimeControlProtocolVersion
                == DNSProxyXPCContract.currentRuntimeControlProtocolVersion,
            status.providerInstanceID == reserved.providerInstanceID
        else {
            throw DNSProxyControllerError.runtimeControlOutcomeUncertain
        }

        let request = ProxyReapplyRequest(
            operationID: reservation.mutationID,
            expectedProviderInstanceID: reserved.providerInstanceID,
            expectedBaseGeneration: reservation.draftConfiguration.value.generation,
            expectedBaseFingerprint: reservation.draftConfiguration.fingerprint,
            targetConfigurationData: reservation.oldConfiguration.data,
            targetFingerprint: reservation.oldConfiguration.fingerprint
        )
        let resolution = try await resolveRuntimeSwitch(
            request,
            oldConfiguration: reservation.draftConfiguration,
            targetConfiguration: reservation.oldConfiguration,
            applicationDeadline: ContinuousClock().now.advanced(by: rollbackTimeout)
        )
        guard resolution.response.disposition == .applied else {
            throw DNSProxyControllerError.runtimeControlOutcomeUncertain
        }
        try await waitUntilRuntimeMatches(
            reservation.oldConfiguration,
            providerInstanceID: reserved.providerInstanceID,
            deadline: resolution.verificationDeadline
        )
        guard try await loadManagerSnapshot(before: resolution.verificationDeadline)
            == oldManagerSnapshot else {
            throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
        }
        setActive(reservation.oldConfiguration.value)
        return mutationResult(reservation, state: .oldActive)
    }

    private func recoverActiveProfileMutation(
        _ reservation: ActiveProfileMutationReservation,
        goal: ActiveProfileMutationRecoveryGoal
    ) async throws -> ActiveProfileMutationResult {
        var managerSnapshot = try await loadManagerSnapshot()
        let managerState = try classifyManagerState(
            managerSnapshot,
            old: reservation.oldConfiguration,
            draft: reservation.draftConfiguration
        )
        guard managerState != .unknown else {
            throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
        }

        let status = try await runtimeStatus()
        let runtimeState = classifyRuntimeState(
            status,
            old: reservation.oldConfiguration,
            draft: reservation.draftConfiguration
        )
        if managerState == .disabled {
            guard runtimeState == .disabled else {
                throw DNSProxyControllerError.runtimeControlOutcomeUncertain
            }
            clearPresentationForDisabledState()
            return mutationResult(reservation, state: .disabled)
        }
        guard runtimeState != .unknown, runtimeState != .disabled else {
            throw DNSProxyControllerError.runtimeControlOutcomeUncertain
        }

        let target = goal == .restoreOld
            ? reservation.oldConfiguration : reservation.draftConfiguration
        let base = goal == .restoreOld
            ? reservation.draftConfiguration : reservation.oldConfiguration
        let targetState: RecoveryObservedState = goal == .restoreOld ? .old : .draft
        let baseState: RecoveryObservedState = goal == .restoreOld ? .draft : .old

        if managerState == baseState {
            managerSnapshot = try await replaceEnabledConfiguration(
                target,
                replacing: managerSnapshot
            )
        }
        guard managerState == targetState || managerState == baseState else {
            throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
        }

        if runtimeState == baseState {
            guard
                status.runtimeControlProtocolVersion
                    == DNSProxyXPCContract.currentRuntimeControlProtocolVersion,
                let providerInstanceID = status.providerInstanceID
            else {
                throw DNSProxyControllerError.runtimeControlOutcomeUncertain
            }
            let request = ProxyReapplyRequest(
                operationID: goal == .restoreOld
                    ? reservation.mutationID : reservation.runtimeOperationID,
                expectedProviderInstanceID: providerInstanceID,
                expectedBaseGeneration: base.value.generation,
                expectedBaseFingerprint: base.fingerprint,
                targetConfigurationData: target.data,
                targetFingerprint: target.fingerprint
            )
            let resolution = try await resolveRuntimeSwitch(
                request,
                oldConfiguration: base,
                targetConfiguration: target,
                applicationDeadline: ContinuousClock().now.advanced(by: rollbackTimeout)
            )
            guard resolution.response.disposition == .applied else {
                throw DNSProxyControllerError.runtimeControlOutcomeUncertain
            }
            try await waitUntilRuntimeMatches(
                target,
                providerInstanceID: providerInstanceID,
                deadline: resolution.verificationDeadline
            )
            guard try await loadManagerSnapshot(before: resolution.verificationDeadline)
                == managerSnapshot else {
                throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
            }
        } else {
            guard runtimeState == targetState else {
                throw DNSProxyControllerError.runtimeControlOutcomeUncertain
            }
            guard try await loadManagerSnapshot() == managerSnapshot else {
                throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
            }
        }

        setActive(target.value)
        return mutationResult(
            reservation,
            state: goal == .restoreOld ? .oldActive : .draftActive
        )
    }

    private func classifyManagerState(
        _ snapshot: DNSProxyManagerSnapshot,
        old: PersistedProxyConfiguration,
        draft: PersistedProxyConfiguration
    ) throws -> RecoveryObservedState {
        guard snapshot.isEnabled else { return .disabled }
        if snapshot.persistedConfiguration == old,
           try managerSnapshotIsOwned(snapshot, configuration: old) {
            return .old
        }
        if snapshot.persistedConfiguration == draft,
           try managerSnapshotIsOwned(snapshot, configuration: draft) {
            return .draft
        }
        return .unknown
    }

    private func managerSnapshotIsOwned(
        _ snapshot: DNSProxyManagerSnapshot,
        configuration: PersistedProxyConfiguration
    ) throws -> Bool {
        snapshot.ownerIdentity?.providerBundleIdentifier == (try providerBundleIdentifier())
            && snapshot.persistedConfiguration == configuration
    }

    private static let extensionReplacementAllowedMismatches: Set<
        ProxyResumeManagerMismatchField
    > = [
        .ownerConfigurationFingerprint,
        .localizedDescriptionFingerprint,
    ]

    private static func mismatchDescription(
        _ mismatches: Set<ProxyResumeManagerMismatchField>
    ) -> String {
        mismatches.map(\.rawValue).sorted().joined(separator: ",")
    }

    private func managerSnapshotMismatches(
        _ snapshot: DNSProxyManagerSnapshot,
        record: ProxyResumeRecord
    ) -> Set<ProxyResumeManagerMismatchField> {
        var mismatches: Set<ProxyResumeManagerMismatchField> = []
        guard let persisted = snapshot.persistedConfiguration else {
            mismatches.insert(.persistedConfigurationUnavailable)
            return mismatches
        }
        guard let owner = snapshot.ownerIdentity else {
            mismatches.insert(.ownerIdentityUnavailable)
            return mismatches
        }
        if owner.providerBundleIdentifier != record.providerBundleIdentifier {
            mismatches.insert(.providerBundleIdentifier)
        }
        if owner.providerConfigurationFingerprint != record.ownerConfigurationFingerprint {
            mismatches.insert(.ownerConfigurationFingerprint)
        }
        if let expectedDescription = record.managerLocalizedDescriptionFingerprint,
           owner.localizedDescriptionFingerprint != expectedDescription {
            mismatches.insert(.localizedDescriptionFingerprint)
        }
        if persisted.value.generation != record.activeGeneration {
            mismatches.insert(.activeGeneration)
        }
        if persisted.value.profileID != record.activeProfileID {
            mismatches.insert(.activeProfileID)
        }
        if persisted.fingerprint != record.activeConfigurationFingerprint {
            mismatches.insert(.activeConfigurationFingerprint)
        }
        return mismatches
    }

    private func classifyRuntimeState(
        _ status: ProxyRuntimeStatus,
        old: PersistedProxyConfiguration,
        draft: PersistedProxyConfiguration
    ) -> RecoveryObservedState {
        if runtime(status, matches: old) { return .old }
        if runtime(status, matches: draft) { return .draft }
        if status.phase == .idle, status.generation == nil { return .disabled }
        return .unknown
    }

    private func replaceEnabledConfiguration(
        _ target: PersistedProxyConfiguration,
        replacing expected: DNSProxyManagerSnapshot
    ) async throws -> DNSProxyManagerSnapshot {
        let result = try await manager.replaceEnabledConfiguration(
            target,
            ifCurrentMatches: expected
        )
        let replaced: DNSProxyManagerSnapshot
        switch result {
        case let .replaced(snapshot):
            replaced = snapshot
        case .configurationChanged:
            throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
        }
        guard try await loadManagerSnapshot() == replaced else {
            throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
        }
        return replaced
    }

    private func enqueue(_ target: DNSProxyTarget) async -> ProxyControllerSnapshot {
        guard !terminationRequested else { return makeSnapshot() }
        guard profileDeletionLeaseID == nil else { return makeSnapshot() }
        guard
            !managerMutationOutcomeUncertain,
            disabledRuntimeQuarantine == nil,
            pendingDeadlineManagerCalls.isEmpty
        else {
            activeTarget = nil
            activeGeneration = nil
            state = .recoveryRequired(
                "A previous DNS Proxy manager operation is still unresolved. Reconnect before switching."
            )
            return makeSnapshot()
        }
        if target == inFlightTarget || target == pendingTarget {
            return makeSnapshot()
        }
        if !operationInProgress, target == activeTarget {
            targetProfileID = nil
            lastSwitchFailure = nil
            failedTarget = nil
            return makeSnapshot()
        }
        if operationInProgress {
            pendingTarget = target
            if failedTarget != target {
                lastSwitchFailure = nil
                failedTarget = nil
            }
            targetProfileID = target.profileID
            return makeSnapshot()
        }

        operationInProgress = true
        var nextTarget: DNSProxyTarget? = target
        while let targetToRun = nextTarget, !terminationRequested {
            if targetToRun == activeTarget {
                targetProfileID = nil
                lastSwitchFailure = nil
                failedTarget = nil
                pendingTarget = nil
                nextTarget = nil
                continue
            }
            inFlightTarget = targetToRun
            pendingTarget = nil
            await performTargetTransaction(targetToRun)
            inFlightTarget = nil
            nextTarget = pendingTarget
        }
        inFlightTarget = nil
        pendingTarget = nil
        operationInProgress = false
        return makeSnapshot()
    }

    private func performTargetTransaction(_ target: DNSProxyTarget) async {
        let targetGeneration = UUID()
        let ownedGeneration = activeGeneration
        let ownedGenerationDescription = ownedGeneration?.uuidString ?? "none"
        logger.notice(
            "DNS profile switch started: targetProfile=\(target.profileID.uuidString, privacy: .public), targetGeneration=\(targetGeneration.uuidString, privacy: .public), activeGeneration=\(ownedGenerationDescription, privacy: .public)"
        )
        if failedTarget != target {
            lastSwitchFailure = nil
            failedTarget = nil
        }
        targetProfileID = target.profileID
        state = .preparing(targetGeneration)

        let initialSnapshot: DNSProxyManagerSnapshot
        do {
            initialSnapshot = try await loadManagerSnapshot()
            try checkForTerminationRequest()
        } catch {
            handlePreDisableFailure(error, target: target, code: .managerStateUnavailable)
            return
        }

        let oldConfiguration = initialSnapshot.isEnabled
            ? initialSnapshot.activeConfiguration
            : nil
        if initialSnapshot.isEnabled, oldConfiguration == nil {
            handlePreDisableFailure(
                DNSProxyControllerError.managerStateUnavailable(
                    "The enabled DNS Proxy configuration could not be decoded."
                ),
                target: target,
                code: .managerStateUnavailable
            )
            return
        }
        guard oldConfiguration?.generation == ownedGeneration else {
            handlePreDisableFailure(
                DNSProxyControllerError.managerConfigurationChangedDuringRollback,
                target: target,
                code: .oldGenerationChanged
            )
            return
        }

        let targetConfiguration: ActiveProxyConfiguration
        let targetPersistedConfiguration: PersistedProxyConfiguration
        do {
            let schemaVersion = try await compatibleSchemaVersion(for: target)
            targetConfiguration = try ActiveProxyConfiguration(
                generation: targetGeneration,
                profileID: target.profileID,
                upstream: target.upstream,
                loggingMode: configuredLoggingMode,
                dnsCacheConfiguration: target.dnsCacheConfiguration,
                schemaVersion: schemaVersion
            )
            targetPersistedConfiguration = try PersistedProxyConfiguration(
                value: targetConfiguration
            )
            try await validate(upstream: target.upstream)
            try checkForTerminationRequest()
        } catch {
            if terminationRequested {
                state = .stopping
            } else {
                let code: ProxySwitchFailureCode
                if case DNSProxyControllerError.unsupportedProviderConfigurationSchema = error {
                    code = .providerCompatibilityUnavailable
                } else if case ActiveProxyConfigurationError.unsupportedLegacyDoHConfiguration = error {
                    code = .providerCompatibilityUnavailable
                } else {
                    code = .targetPreflightFailed
                }
                handlePreDisableFailure(error, target: target, code: code)
            }
            return
        }

        state = .applying(targetGeneration)

        if oldConfiguration != nil,
           let oldPersistedConfiguration = initialSnapshot.persistedConfiguration {
            await performEnabledRuntimeSwitch(
                target: target,
                targetConfiguration: targetConfiguration,
                oldConfiguration: oldPersistedConfiguration,
                initialManagerSnapshot: initialSnapshot
            )
            return
        }

        if let oldConfiguration {
            do {
                try await disableManager(ifGenerationMatches: oldConfiguration.generation)
                try checkForTerminationRequest()
                logger.notice(
                    "DNS profile switch disabled old manager generation: targetGeneration=\(targetGeneration.uuidString, privacy: .public), oldGeneration=\(oldConfiguration.generation.uuidString, privacy: .public)"
                )
            } catch {
                if terminationRequested {
                    state = .stopping
                } else {
                    let code: ProxySwitchFailureCode
                    if case DNSProxyControllerError.managerConfigurationChangedDuringRollback = error {
                        code = .oldGenerationChanged
                    } else {
                        code = .managerStateUnavailable
                    }
                    handlePreDisableFailure(error, target: target, code: code)
                }
                return
            }
        }

        do {
            switch try await enableManager(
                targetConfiguration,
                providerBundleIdentifier: try providerBundleIdentifier()
            ) {
            case .enabled:
                break
            case .alreadyEnabled:
                throw DNSProxyControllerError.managerStateUnavailable(
                    "Another DNS Proxy configuration was enabled before the target write."
                )
            }
            try checkForTerminationRequest()
            logger.notice(
                "DNS profile switch enabled target manager generation: targetGeneration=\(targetGeneration.uuidString, privacy: .public)"
            )
        } catch {
            if terminationRequested {
                state = .stopping
                return
            }
            await recoverAfterTargetFailure(
                error,
                code: .targetWriteFailed,
                target: target,
                targetGeneration: targetGeneration,
                oldConfiguration: oldConfiguration
            )
            return
        }

        do {
            try await waitUntilReadyCancellable(
                configuration: targetPersistedConfiguration,
                timeout: readinessTimeout
            )
            try checkForTerminationRequest()
            logger.notice(
                "DNS profile switch observed target ready: targetGeneration=\(targetGeneration.uuidString, privacy: .public)"
            )
        } catch {
            if terminationRequested {
                state = .stopping
                return
            }
            let code: ProxySwitchFailureCode
            if case DNSProxyControllerError.readinessTimeout = error {
                code = .targetReadinessTimedOut
            } else if case DNSProxyControllerError.providerFailed = error {
                code = .targetProviderFailed
            } else {
                code = .managerStateUnavailable
            }
            await recoverAfterTargetFailure(
                error,
                code: code,
                target: target,
                targetGeneration: targetGeneration,
                oldConfiguration: oldConfiguration
            )
            return
        }

        do {
            try await requireManagerGeneration(targetGeneration)
            try checkForTerminationRequest()
            setActive(targetConfiguration)
        } catch {
            handlePreDisableFailure(error, target: target, code: .managerStateUnavailable)
        }
    }

    private func performEnabledRuntimeSwitch(
        target: DNSProxyTarget,
        targetConfiguration: ActiveProxyConfiguration,
        oldConfiguration: PersistedProxyConfiguration,
        initialManagerSnapshot: DNSProxyManagerSnapshot
    ) async {
        let targetPersisted: PersistedProxyConfiguration
        let providerInstanceID: UUID
        do {
            targetPersisted = try PersistedProxyConfiguration(value: targetConfiguration)
            let expectedProviderBundleIdentifier = try providerBundleIdentifier()
            guard initialManagerSnapshot.ownerIdentity?.providerBundleIdentifier
                == expectedProviderBundleIdentifier else {
                throw DNSProxyControllerError.managerStateUnavailable(
                    "The enabled DNS Proxy manager is owned by another provider."
                )
            }
            let baseStatus = try await runtimeStatus()
            guard
                baseStatus.runtimeControlProtocolVersion
                    == DNSProxyXPCContract.currentRuntimeControlProtocolVersion,
                runtime(baseStatus, matches: oldConfiguration),
                let observedProviderInstanceID = baseStatus.providerInstanceID
            else {
                throw DNSProxyControllerError.managerStateUnavailable(
                    "The active DNS Proxy runtime does not support an identity-safe switch."
                )
            }
            providerInstanceID = observedProviderInstanceID
            try checkForTerminationRequest()
        } catch {
            handlePreDisableFailure(error, target: target, code: .managerStateUnavailable)
            return
        }

        let targetManagerSnapshot: DNSProxyManagerSnapshot
        do {
            switch try await manager.replaceEnabledConfiguration(
                targetPersisted,
                ifCurrentMatches: initialManagerSnapshot
            ) {
            case let .replaced(snapshot):
                targetManagerSnapshot = snapshot
            case .configurationChanged:
                throw DNSProxyControllerError.managerStateUnavailable(
                    "The DNS Proxy manager changed before the enabled target save."
                )
            }
            try checkForTerminationRequest()
            logger.notice(
                "DNS profile switch saved enabled target: targetGeneration=\(targetConfiguration.generation.uuidString, privacy: .public)"
            )
        } catch {
            if terminationRequested {
                state = .stopping
            } else {
                recordFailure(error, code: .targetWriteFailed, target: target)
                requireSwitchRecovery(
                    "The enabled DNS Proxy target save could not be confirmed: "
                        + error.localizedDescription
                )
            }
            return
        }

        let request = ProxyReapplyRequest(
            operationID: UUID(),
            expectedProviderInstanceID: providerInstanceID,
            expectedBaseGeneration: oldConfiguration.value.generation,
            expectedBaseFingerprint: oldConfiguration.fingerprint,
            targetConfigurationData: targetPersisted.data,
            targetFingerprint: targetPersisted.fingerprint
        )
        let clock = ContinuousClock()
        let applicationDeadline = clock.now.advanced(by: readinessTimeout)
        var recoveryDeadline = applicationDeadline

        do {
            let resolution = try await resolveRuntimeSwitch(
                request,
                oldConfiguration: oldConfiguration,
                targetConfiguration: targetPersisted,
                applicationDeadline: applicationDeadline
            )
            let response = resolution.response
            recoveryDeadline = resolution.verificationDeadline
            try checkForTerminationRequest()
            switch response.disposition {
            case .applied:
                guard
                    response.operationID == request.operationID,
                    response.providerInstanceID == providerInstanceID,
                    response.activeGeneration == targetConfiguration.generation,
                    response.activeFingerprint == targetPersisted.fingerprint
                else {
                    throw MachXPCClientError.invalidResponse
                }
                try await waitUntilRuntimeMatches(
                    targetPersisted,
                    providerInstanceID: providerInstanceID,
                    deadline: recoveryDeadline
                )
                try checkForTerminationRequest()
                let confirmedManager = try await loadManagerSnapshot(
                    before: recoveryDeadline
                )
                guard confirmedManager == targetManagerSnapshot else {
                    throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
                }
                setActive(targetConfiguration)

            case .rejectedPreservingBase:
                state = .repairing(targetConfiguration.generation)
                guard
                    response.operationID == request.operationID,
                    response.providerInstanceID == providerInstanceID,
                    response.activeGeneration == oldConfiguration.value.generation,
                    response.activeFingerprint == oldConfiguration.fingerprint,
                    response.preservedConfigurationData == oldConfiguration.data
                else {
                    throw MachXPCClientError.invalidResponse
                }
                let rejection = DNSProxyControllerError.providerFailed(nil)
                recordFailure(rejection, code: .targetProviderFailed, target: target)
                try await restoreConfirmedBase(
                    oldConfiguration,
                    replacing: targetManagerSnapshot,
                    providerInstanceID: providerInstanceID,
                    rejectedTarget: target,
                    deadline: recoveryDeadline
                )

            case .rejected:
                state = .repairing(targetConfiguration.generation)
                let rejection = DNSProxyControllerError.managerStateUnavailable(
                    "The runtime rejected the switch (\(response.rejectionCode?.rawValue ?? "unknown"))."
                )
                recordFailure(rejection, code: .targetWriteFailed, target: target)
                try await restoreBaseIfStillActive(
                    oldConfiguration,
                    replacing: targetManagerSnapshot,
                    providerInstanceID: providerInstanceID,
                    rejectedTarget: target,
                    deadline: recoveryDeadline
                )

            case .unrecoverable:
                state = .repairing(targetConfiguration.generation)
                let failure = DNSProxyControllerError.providerFailed(.internalFailure)
                recordFailure(failure, code: .targetProviderFailed, target: target)
                await repairStoppedRuntime(
                    expectedManagerSnapshot: targetManagerSnapshot,
                    rejectedTarget: target,
                    deadline: recoveryDeadline
                )
            }
        } catch {
            if terminationRequested {
                state = .stopping
                return
            }
            if lastSwitchFailure == nil {
                recordFailure(
                    error,
                    code: switchFailureCode(for: error),
                    target: target
                )
            }
            state = .repairing(targetConfiguration.generation)
            if case DNSProxyControllerError.runtimeControlOutcomeUncertain = error {
                requireSwitchRecovery(
                    "The runtime switch outcome remained uncertain after bounded reconciliation."
                )
                return
            }
            do {
                try await restoreBaseIfStillActive(
                    oldConfiguration,
                    replacing: targetManagerSnapshot,
                    providerInstanceID: providerInstanceID,
                    rejectedTarget: target,
                    deadline: recoveryDeadline
                )
            } catch let recoveryError {
                requireSwitchRecovery(
                    "The runtime switch outcome requires reconciliation: "
                        + recoveryError.localizedDescription
                )
            }
        }
    }

    private func restoreBaseIfStillActive(
        _ oldConfiguration: PersistedProxyConfiguration,
        replacing targetManagerSnapshot: DNSProxyManagerSnapshot,
        providerInstanceID: UUID,
        rejectedTarget: DNSProxyTarget,
        deadline: ContinuousClock.Instant
    ) async throws {
        let status = try await runtimeStatus(before: deadline)
        guard
            status.providerInstanceID == providerInstanceID,
            runtime(status, matches: oldConfiguration)
        else {
            throw DNSProxyControllerError.managerStateUnavailable(
                "The Provider no longer proves the previous exact runtime."
            )
        }
        try await restoreConfirmedBase(
            oldConfiguration,
            replacing: targetManagerSnapshot,
            providerInstanceID: providerInstanceID,
            rejectedTarget: rejectedTarget,
            deadline: deadline
        )
    }

    private func restoreConfirmedBase(
        _ oldConfiguration: PersistedProxyConfiguration,
        replacing targetManagerSnapshot: DNSProxyManagerSnapshot,
        providerInstanceID: UUID,
        rejectedTarget: DNSProxyTarget,
        deadline: ContinuousClock.Instant
    ) async throws {
        let restoredManagerSnapshot: DNSProxyManagerSnapshot
        let replaceResult = try await managerCall(before: deadline) {
            try await self.manager.replaceEnabledConfiguration(
                oldConfiguration,
                ifCurrentMatches: targetManagerSnapshot
            )
        }
        switch replaceResult {
        case let .replaced(snapshot):
            restoredManagerSnapshot = snapshot
        case .configurationChanged:
            throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
        }
        try await waitUntilRuntimeMatches(
            oldConfiguration,
            providerInstanceID: providerInstanceID,
            deadline: deadline
        )
        try checkForTerminationRequest()
        let confirmedManager = try await loadManagerSnapshot(before: deadline)
        guard confirmedManager == restoredManagerSnapshot else {
            throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
        }
        setActive(oldConfiguration.value, retainingFailureFor: rejectedTarget)
    }

    private func repairStoppedRuntime(
        expectedManagerSnapshot: DNSProxyManagerSnapshot,
        rejectedTarget: DNSProxyTarget?,
        deadline: ContinuousClock.Instant
    ) async {
        do {
            try await disableManager(
                ifCurrentMatches: expectedManagerSnapshot,
                deadline: deadline
            )
            activeTarget = nil
            activeGeneration = nil
            targetProfileID = rejectedTarget?.profileID
            state = .degraded(
                "The DNS Proxy runtime stopped after an unrecoverable configuration failure. System DNS is active."
            )
        } catch {
            requireSwitchRecovery(
                "The DNS Proxy runtime stopped, but manager disable could not be confirmed: "
                    + error.localizedDescription
            )
        }
    }

    private func switchFailureCode(for error: any Error) -> ProxySwitchFailureCode {
        if case DNSProxyControllerError.readinessTimeout = error {
            return .targetReadinessTimedOut
        }
        if case DNSProxyControllerError.providerFailed = error {
            return .targetProviderFailed
        }
        return .managerStateUnavailable
    }

    private func requireSwitchRecovery(_ message: String) {
        activeTarget = nil
        activeGeneration = nil
        state = .recoveryRequired(message)
    }

    private func recoverAfterTargetFailure(
        _ error: any Error,
        code: ProxySwitchFailureCode,
        target: DNSProxyTarget,
        targetGeneration: UUID,
        oldConfiguration: ActiveProxyConfiguration?
    ) async {
        recordFailure(error, code: code, target: target)
        state = .repairing(targetGeneration)
        let clock = ContinuousClock()
        let rollbackDeadline = clock.now.advanced(by: rollbackTimeout)
        let oldGenerationDescription = oldConfiguration?.generation.uuidString ?? "none"
        logger.notice(
            "DNS profile switch rollback started: failedGeneration=\(targetGeneration.uuidString, privacy: .public), oldGeneration=\(oldGenerationDescription, privacy: .public)"
        )
        guard let oldConfiguration else {
            do {
                try await disableManager(
                    ifGenerationMatches: targetGeneration,
                    deadline: rollbackDeadline
                )
                activeTarget = nil
                activeGeneration = nil
                state = .failed(error.localizedDescription)
            } catch {
                state = .recoveryRequired(error.localizedDescription)
            }
            return
        }

        let cleanupReserve = min(rollbackTimeout / 4, .seconds(1))
        let rollbackReadinessDeadline = rollbackDeadline - cleanupReserve
        var rollbackGeneration: UUID?
        do {
            try await disableManager(
                ifGenerationMatches: targetGeneration,
                deadline: rollbackDeadline
            )
            try checkForTerminationRequest()
            logger.notice(
                "DNS profile switch rollback disabled failed generation: failedGeneration=\(targetGeneration.uuidString, privacy: .public)"
            )

            let freshRollbackGeneration = UUID()
            rollbackGeneration = freshRollbackGeneration
            let rollbackConfiguration = try ActiveProxyConfiguration(
                generation: freshRollbackGeneration,
                profileID: oldConfiguration.profileID,
                upstream: oldConfiguration.upstream,
                loggingMode: oldConfiguration.loggingMode,
                schemaVersion: oldConfiguration.schemaVersion
            )
            let rollbackPersistedConfiguration = try PersistedProxyConfiguration(
                value: rollbackConfiguration
            )
            switch try await enableManager(
                rollbackConfiguration,
                providerBundleIdentifier: try providerBundleIdentifier(),
                deadline: rollbackDeadline
            ) {
            case .enabled:
                break
            case .alreadyEnabled:
                throw DNSProxyControllerError.managerStateUnavailable(
                    "Another DNS Proxy configuration was enabled before rollback."
                )
            }
            try checkForTerminationRequest()
            logger.notice(
                "DNS profile switch rollback enabled manager generation: rollbackGeneration=\(freshRollbackGeneration.uuidString, privacy: .public)"
            )
            try await waitUntilReadyCancellable(
                configuration: rollbackPersistedConfiguration,
                deadline: rollbackReadinessDeadline
            )
            try checkForTerminationRequest()
            logger.notice(
                "DNS profile switch rollback observed ready: rollbackGeneration=\(freshRollbackGeneration.uuidString, privacy: .public)"
            )
            try await requireManagerGeneration(
                freshRollbackGeneration,
                deadline: rollbackDeadline
            )
            try checkForTerminationRequest()
            setActive(rollbackConfiguration, retainingFailureFor: target)
        } catch {
            if terminationRequested {
                state = .stopping
                return
            }
            await finishFailedRollback(
                rollbackGeneration: rollbackGeneration,
                targetFailure: lastSwitchFailure,
                target: target,
                deadline: rollbackDeadline
            )
        }
    }

    private func finishFailedRollback(
        rollbackGeneration: UUID?,
        targetFailure: ProxySwitchFailure?,
        target: DNSProxyTarget,
        deadline: ContinuousClock.Instant
    ) async {
        do {
            let snapshot = try await loadManagerSnapshot(before: deadline)
            if snapshot.isEnabled {
                guard let rollbackGeneration else {
                    throw DNSProxyControllerError.managerStateUnavailable(
                        "The manager became enabled before a rollback generation was created."
                    )
                }
                guard snapshot.activeConfiguration?.generation == rollbackGeneration else {
                    throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
                }
                try await disableManager(
                    ifGenerationMatches: rollbackGeneration,
                    deadline: deadline
                )
            }
            activeTarget = nil
            activeGeneration = nil
            targetProfileID = target.profileID
            lastSwitchFailure = targetFailure
            state = .degraded(
                "The target failed and the previous DNS Proxy could not be restored. System DNS is active."
            )
        } catch {
            activeTarget = nil
            activeGeneration = nil
            targetProfileID = target.profileID
            lastSwitchFailure = targetFailure
            state = .recoveryRequired(
                "The target and rollback failed, and manager disable could not be confirmed: \(error.localizedDescription)"
            )
        }
    }

    private func handlePreDisableFailure(
        _ error: any Error,
        target: DNSProxyTarget,
        code: ProxySwitchFailureCode
    ) {
        recordFailure(error, code: code, target: target)
        if code == .oldGenerationChanged || code == .managerStateUnavailable {
            activeTarget = nil
            activeGeneration = nil
            state = .recoveryRequired(error.localizedDescription)
        } else if let generation = activeGeneration {
            state = .active(generation)
        } else {
            state = .failed(error.localizedDescription)
        }
    }

    private func recordFailure(
        _ error: any Error,
        code: ProxySwitchFailureCode,
        target: DNSProxyTarget
    ) {
        let providerCode: ProxyRuntimeErrorCode?
        if case let DNSProxyControllerError.providerFailed(code) = error {
            providerCode = code
        } else {
            providerCode = nil
        }
        targetProfileID = target.profileID
        failedTarget = target
        let failure = ProxySwitchFailure(
            code: code,
            targetProfileID: target.profileID,
            activeProfileID: activeTarget?.profileID,
            providerErrorCode: providerCode,
            message: error.localizedDescription
        )
        lastSwitchFailure = failure
        let activeProfile = failure.activeProfileID?.uuidString ?? "none"
        let providerError = failure.providerErrorCode?.rawValue ?? "none"
        logger.error(
            "DNS profile switch failed: code=\(code.rawValue, privacy: .public), target=\(target.profileID.uuidString, privacy: .public), active=\(activeProfile, privacy: .public), provider=\(providerError, privacy: .public)"
        )
        logger.error(
            "DNS profile switch failure detail: \(error.localizedDescription, privacy: .private(mask: .hash))"
        )
    }

    private func performSystemDNSRestore(
        prepareResumeRecord: Bool = false
    ) async -> DNSProxyControllerState {
        state = .stopping
        pendingTarget = nil
        targetProfileID = nil
        lastSwitchFailure = nil
        failedTarget = nil
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: rollbackTimeout)
        let disableReserve = min(rollbackTimeout / 4, .seconds(1))
        let quiescenceDeadline = deadline - disableReserve

        let managerSnapshot: DNSProxyManagerSnapshot
        do {
            managerSnapshot = try await loadManagerSnapshot(before: deadline)
            managerMutationOutcomeUncertain = false
        } catch {
            activeTarget = nil
            activeGeneration = nil
            state = .recoveryRequired(error.localizedDescription)
            return state
        }

        if let quarantine = disabledRuntimeQuarantine {
            return await resolveDisabledRuntimeQuarantine(
                quarantine,
                currentManagerSnapshot: managerSnapshot,
                deadline: deadline
            )
        }
        guard managerSnapshot.isEnabled else {
            clearPresentationForDisabledState()
            return state
        }

        var lifecycleRequest: ProxyLifecycleRequest?
        var preparedResumeOperationID: UUID?
        var quiescenceConfirmed = false
        do {
            let expectedProviderBundleIdentifier = try providerBundleIdentifier()
            guard
                managerSnapshot.ownerIdentity?.providerBundleIdentifier
                    == expectedProviderBundleIdentifier
            else {
                throw DNSProxyControllerError.managerStateUnavailable(
                    "The enabled DNS Proxy manager is owned by another provider."
                )
            }
            let status = try await runtimeStatus(before: quiescenceDeadline)
            guard
                status.runtimeControlProtocolVersion
                    == DNSProxyXPCContract.currentRuntimeControlProtocolVersion,
                status.phase == .ready,
                let providerInstanceID = status.providerInstanceID,
                let generation = status.generation,
                let fingerprint = status.configurationFingerprint
            else {
                throw DNSProxyControllerError.managerStateUnavailable(
                    "The active DNS Proxy runtime could not provide exact quiescence identity."
                )
            }

            if prepareResumeRecord,
               let resumeJournal,
               let appConfigurationFingerprint = resumeAppConfigurationFingerprint,
               let persisted = managerSnapshot.persistedConfiguration,
               let owner = managerSnapshot.ownerIdentity,
               let providerBundleIdentifier = owner.providerBundleIdentifier,
               persisted.value.generation == generation,
               persisted.fingerprint == fingerprint,
               persisted.value.profileID == activeTarget?.profileID {
                do {
                    if case let .loaded(existing) = try resumeJournal.load(),
                       existing.phase == .preparedForQuit,
                       existing.appConfigurationFingerprint == appConfigurationFingerprint,
                       self.managerSnapshotMismatches(
                           managerSnapshot,
                           record: existing
                       ).isEmpty {
                        preparedResumeOperationID = existing.operationID
                    } else {
                        let record = ProxyResumeRecord(
                            operationID: UUID(),
                            phase: .preparedForQuit,
                            appConfigurationFingerprint: appConfigurationFingerprint,
                            providerBundleIdentifier: providerBundleIdentifier,
                            ownerConfigurationFingerprint: owner.providerConfigurationFingerprint,
                            managerLocalizedDescriptionFingerprint: owner
                                .localizedDescriptionFingerprint,
                            activeGeneration: generation,
                            activeConfigurationFingerprint: fingerprint,
                            activeProfileID: persisted.value.profileID
                        )
                        try resumeJournal.prepare(record)
                        preparedResumeOperationID = record.operationID
                    }
                } catch {
                    terminationResumePreparationError = error.localizedDescription
                    setActive(persisted.value)
                    return state
                }
            }
            let request = ProxyLifecycleRequest(
                operationID: UUID(),
                action: .quiesce,
                expectedProviderInstanceID: providerInstanceID,
                expectedGeneration: generation,
                expectedFingerprint: fingerprint
            )
            lifecycleRequest = request
            let response = try await resolveLifecycle(request, before: quiescenceDeadline)
            guard response.disposition == .quiesced else {
                throw DNSProxyControllerError.runtimeControlOutcomeUncertain
            }
            quiescenceConfirmed = true
        } catch {
            logger.error(
                "DNS runtime quiescence was not confirmed before manager disable: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }

        do {
            try await disableManager(ifCurrentMatches: managerSnapshot, deadline: deadline)
        } catch {
            if !quiescenceConfirmed, managerMutationOutcomeUncertain {
                disabledRuntimeQuarantine = DisabledRuntimeQuarantine(
                    expectedManagerSnapshot: managerSnapshot,
                    lifecycleRequest: lifecycleRequest
                )
            }
            if
                quiescenceConfirmed,
                !managerMutationOutcomeUncertain,
                let lifecycleRequest
            {
                do {
                    let current = try await loadManagerSnapshot(before: deadline)
                    guard current == managerSnapshot, current.isEnabled else {
                        throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
                    }
                    let resumeRequest = ProxyLifecycleRequest(
                        operationID: UUID(),
                        action: .resume,
                        expectedProviderInstanceID: lifecycleRequest
                            .expectedProviderInstanceID,
                        expectedGeneration: lifecycleRequest.expectedGeneration,
                        expectedFingerprint: lifecycleRequest.expectedFingerprint
                    )
                    let response = try await resolveLifecycle(resumeRequest, before: deadline)
                    guard response.disposition == .resumed else {
                        throw DNSProxyControllerError.runtimeControlOutcomeUncertain
                    }
                    let resumedManagerSnapshot: DNSProxyManagerSnapshot
                    do {
                        resumedManagerSnapshot = try await loadManagerSnapshot(before: deadline)
                    } catch {
                        await requiesceResumedRuntimeBestEffort(
                            resumeRequest,
                            before: deadline
                        )
                        throw error
                    }
                    guard
                        resumedManagerSnapshot == managerSnapshot,
                        resumedManagerSnapshot.isEnabled
                    else {
                        await requiesceResumedRuntimeBestEffort(
                            resumeRequest,
                            before: deadline
                        )
                        throw DNSProxyControllerError
                            .managerConfigurationChangedDuringRollback
                    }
                    if
                        let persisted = managerSnapshot.persistedConfiguration,
                        persisted.value.generation == resumeRequest.expectedGeneration,
                        persisted.fingerprint == resumeRequest.expectedFingerprint
                    {
                        setActive(persisted.value)
                        return state
                    }
                } catch let resumeError {
                    activeTarget = nil
                    activeGeneration = nil
                    state = .recoveryRequired(
                        "Manager disable failed and runtime resume could not be confirmed: "
                            + resumeError.localizedDescription
                    )
                    return state
                }
            }
            activeTarget = nil
            activeGeneration = nil
            state = .recoveryRequired(error.localizedDescription)
            return state
        }

        if quiescenceConfirmed {
            disabledRuntimeQuarantine = nil
            clearPresentationForDisabledState()
            if let preparedResumeOperationID, let resumeJournal {
                do {
                    try resumeJournal.confirmDisabled(operationID: preparedResumeOperationID)
                } catch {
                    logger.error(
                        "DNS Proxy resume confirmation could not be persisted: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
        } else {
            disabledRuntimeQuarantine = DisabledRuntimeQuarantine(
                expectedManagerSnapshot: managerSnapshot,
                lifecycleRequest: lifecycleRequest
            )
            activeTarget = nil
            activeGeneration = nil
            state = .recoveryRequired(
                "The DNS Proxy manager is disabled, but runtime quiescence was not confirmed."
            )
        }
        return state
    }

    private func resolveDisabledRuntimeQuarantine(
        _ quarantine: DisabledRuntimeQuarantine,
        currentManagerSnapshot: DNSProxyManagerSnapshot,
        deadline: ContinuousClock.Instant
    ) async -> DNSProxyControllerState {
        do {
            guard
                !currentManagerSnapshot.isEnabled,
                currentManagerSnapshot.persistedConfiguration
                    == quarantine.expectedManagerSnapshot.persistedConfiguration,
                currentManagerSnapshot.ownerIdentity
                    == quarantine.expectedManagerSnapshot.ownerIdentity
            else {
                throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
            }
            let request: ProxyLifecycleRequest
            if let lifecycleRequest = quarantine.lifecycleRequest {
                request = lifecycleRequest
            } else {
                let status = try await runtimeStatus(before: deadline)
                let expectedConfiguration = quarantine.expectedManagerSnapshot
                    .persistedConfiguration
                guard
                    status.runtimeControlProtocolVersion
                        == DNSProxyXPCContract.currentRuntimeControlProtocolVersion,
                    status.phase == .ready,
                    let providerInstanceID = status.providerInstanceID,
                    let generation = status.generation,
                    let fingerprint = status.configurationFingerprint,
                    generation == expectedConfiguration?.value.generation,
                    fingerprint == expectedConfiguration?.fingerprint
                else {
                    throw DNSProxyControllerError.runtimeControlOutcomeUncertain
                }
                request = ProxyLifecycleRequest(
                    operationID: UUID(),
                    action: .quiesce,
                    expectedProviderInstanceID: providerInstanceID,
                    expectedGeneration: generation,
                    expectedFingerprint: fingerprint
                )
                disabledRuntimeQuarantine = DisabledRuntimeQuarantine(
                    expectedManagerSnapshot: quarantine.expectedManagerSnapshot,
                    lifecycleRequest: request
                )
            }
            let response = try await resolveLifecycle(request, before: deadline)
            guard response.disposition == .quiesced else {
                throw DNSProxyControllerError.runtimeControlOutcomeUncertain
            }
            let confirmedManagerSnapshot = try await loadManagerSnapshot(before: deadline)
            guard
                !confirmedManagerSnapshot.isEnabled,
                confirmedManagerSnapshot.persistedConfiguration
                    == quarantine.expectedManagerSnapshot.persistedConfiguration,
                confirmedManagerSnapshot.ownerIdentity
                    == quarantine.expectedManagerSnapshot.ownerIdentity
            else {
                throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
            }
            disabledRuntimeQuarantine = nil
            clearPresentationForDisabledState()
        } catch {
            activeTarget = nil
            activeGeneration = nil
            state = .recoveryRequired(
                "The DNS Proxy manager is disabled, but exact runtime quiescence could not be confirmed: "
                    + error.localizedDescription
            )
        }
        return state
    }

    private func requiesceResumedRuntimeBestEffort(
        _ resumeRequest: ProxyLifecycleRequest,
        before deadline: ContinuousClock.Instant
    ) async {
        let clock = ContinuousClock()
        guard clock.now < deadline else { return }
        let request = ProxyLifecycleRequest(
            operationID: UUID(),
            action: .quiesce,
            expectedProviderInstanceID: resumeRequest.expectedProviderInstanceID,
            expectedGeneration: resumeRequest.expectedGeneration,
            expectedFingerprint: resumeRequest.expectedFingerprint
        )
        do {
            let response = try await resolveLifecycle(request, before: deadline)
            guard response.disposition == .quiesced else {
                throw DNSProxyControllerError.runtimeControlOutcomeUncertain
            }
        } catch {
            logger.error(
                "The resumed stale DNS runtime could not be re-quiesced: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
    }

    private func disableManager(ifGenerationMatches expectedGeneration: UUID? = nil) async throws {
        try await disableManager(ifGenerationMatches: expectedGeneration, deadline: nil)
    }

    private func disableManager(
        ifGenerationMatches expectedGeneration: UUID?,
        deadline: ContinuousClock.Instant?
    ) async throws {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let snapshot = try await managerCall(before: deadline) {
                try await self.manager.loadSnapshot()
            }
            try Task.checkCancellation()
            guard snapshot.isEnabled else { return }
            if
                let expectedGeneration,
                snapshot.activeConfiguration?.generation != expectedGeneration
            {
                throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
            }
            do {
                let result = try await managerCall(before: deadline) {
                    try await self.manager.saveDisabled(
                        ifGenerationMatches: expectedGeneration
                    )
                }
                try Task.checkCancellation()
                switch result {
                case .alreadyDisabled:
                    return
                case .disabled:
                    let confirmedSnapshot = try await managerCall(before: deadline) {
                        try await self.manager.loadSnapshot()
                    }
                    try Task.checkCancellation()
                    guard !confirmedSnapshot.isEnabled else {
                        throw DNSProxyControllerError.managerStateUnavailable(
                            "The DNS Proxy remained enabled after the disable save."
                        )
                    }
                    return
                case .generationChanged:
                    throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
                }
            } catch DNSProxyManagerClientError.configurationStale where attempt == 0 {
                continue
            }
        }
    }

    private func disableManager(
        ifCurrentMatches expected: DNSProxyManagerSnapshot,
        deadline: ContinuousClock.Instant
    ) async throws {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            do {
                let result = try await managerCall(before: deadline) {
                    try await self.manager.saveDisabled(ifCurrentMatches: expected)
                }
                try Task.checkCancellation()
                switch result {
                case .disabled, .alreadyDisabled:
                    let confirmed = try await loadManagerSnapshot(before: deadline)
                    guard
                        !confirmed.isEnabled,
                        confirmed.persistedConfiguration == expected.persistedConfiguration,
                        confirmed.ownerIdentity == expected.ownerIdentity
                    else {
                        throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
                    }
                    return
                case .generationChanged:
                    throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
                }
            } catch DNSProxyManagerClientError.configurationStale where attempt == 0 {
                continue
            }
        }
    }

    private func resolveLifecycle(
        _ request: ProxyLifecycleRequest,
        before deadline: ContinuousClock.Instant
    ) async throws -> ProxyLifecycleResponse {
        let clock = ContinuousClock()
        while clock.now < deadline {
            do {
                let runtimeController = self.runtimeController
                let response = try await withDeadline(
                    deadline,
                    timeoutError: DNSProxyControllerError.runtimeControlOutcomeUncertain
                ) {
                    switch request.action {
                    case .quiesce:
                        try await runtimeController.quiesceRuntime(request)
                    case .resume:
                        try await runtimeController.resumeRuntime(request)
                    }
                }
                if response.disposition != .rejected
                    || (response.rejectionCode != .operationInProgress
                        && response.rejectionCode != .rateLimited)
                {
                    return response
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch DNSProxyControllerError.runtimeControlOutcomeUncertain {
                throw DNSProxyControllerError.runtimeControlOutcomeUncertain
            } catch {
                // The exact operation is replayed because a sent mutation is not cancellable.
            }
            try await sleepForReconciliation(before: deadline)
        }
        throw DNSProxyControllerError.runtimeControlOutcomeUncertain
    }

    private func enableManager(
        _ configuration: ActiveProxyConfiguration,
        providerBundleIdentifier: String,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> DNSProxyManagerEnableResult {
        for attempt in 0..<2 {
            try checkForTerminationRequest()
            let snapshot: DNSProxyManagerSnapshot
            do {
                snapshot = try await managerCall(before: deadline) {
                    try await self.manager.loadSnapshot()
                }
                try Task.checkCancellation()
            } catch {
                throw DNSProxyControllerError.managerStateUnavailable(
                    error.localizedDescription
                )
            }
            guard !snapshot.isEnabled else {
                return .alreadyEnabled(snapshot)
            }
            try checkForTerminationRequest()
            do {
                let result = try await managerCall(before: deadline) {
                    try await self.manager.saveEnabledConfigurationIfDisabled(
                        configuration,
                        providerBundleIdentifier: providerBundleIdentifier
                    )
                }
                try Task.checkCancellation()
                return result
            } catch DNSProxyManagerClientError.configurationStale where attempt == 0 {
                continue
            } catch {
                throw DNSProxyControllerError.managerStateUnavailable(
                    error.localizedDescription
                )
            }
        }
        preconditionFailure("DNS Proxy manager retry loop exited unexpectedly")
    }

    private func reconcileStartup(
        desired: PersistedProxyConfiguration,
        expectedManagerSnapshot: DNSProxyManagerSnapshot,
        baseStatus: ProxyRuntimeStatus
    ) async {
        guard
            baseStatus.runtimeControlProtocolVersion
                == DNSProxyXPCContract.currentRuntimeControlProtocolVersion,
            baseStatus.phase == .ready,
            let providerInstanceID = baseStatus.providerInstanceID,
            let baseGeneration = baseStatus.generation,
            let baseFingerprint = baseStatus.configurationFingerprint
        else {
            requireStartupRecovery(
                "The enabled DNS Proxy runtime does not support safe configuration recovery."
            )
            return
        }

        let request = ProxyReapplyRequest(
            operationID: UUID(),
            expectedProviderInstanceID: providerInstanceID,
            expectedBaseGeneration: baseGeneration,
            expectedBaseFingerprint: baseFingerprint,
            targetConfigurationData: desired.data,
            targetFingerprint: desired.fingerprint
        )
        let clock = ContinuousClock()
        let applicationDeadline = clock.now.advanced(by: readinessTimeout)

        do {
            let resolution = try await resolveReapply(
                request,
                target: desired,
                baseGeneration: baseGeneration,
                baseFingerprint: baseFingerprint,
                applicationDeadline: applicationDeadline
            )
            let response = resolution.response
            let recoveryDeadline = resolution.verificationDeadline
            try checkForTerminationRequest()
            switch response.disposition {
            case .applied:
                guard
                    response.operationID == request.operationID,
                    response.providerInstanceID == providerInstanceID,
                    response.activeGeneration == desired.value.generation,
                    response.activeFingerprint == desired.fingerprint
                else {
                    requireStartupRecovery(
                        "The DNS Proxy returned an invalid configuration recovery result."
                    )
                    return
                }
                try await waitUntilRuntimeMatches(
                    desired,
                    providerInstanceID: providerInstanceID,
                    deadline: recoveryDeadline
                )
                try checkForTerminationRequest()
                let managerSnapshot = try await loadManagerSnapshot(
                    before: recoveryDeadline
                )
                try checkForTerminationRequest()
                guard
                    managerSnapshot == expectedManagerSnapshot
                else {
                    throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
                }
                setActive(desired.value)

            case .rejectedPreservingBase:
                guard
                    response.operationID == request.operationID,
                    response.providerInstanceID == providerInstanceID,
                    let preservedData = response.preservedConfigurationData,
                    let preserved = try? PersistedProxyConfiguration(data: preservedData),
                    preserved.value.generation == baseGeneration,
                    preserved.fingerprint == baseFingerprint,
                    response.activeGeneration == baseGeneration,
                    response.activeFingerprint == baseFingerprint
                else {
                    requireStartupRecovery(
                        "The DNS Proxy could not prove which configuration it preserved."
                    )
                    return
                }

                let restoredManagerSnapshot: DNSProxyManagerSnapshot
                let replaceResult = try await managerCall(before: recoveryDeadline) {
                    try await self.manager.replaceEnabledConfiguration(
                        preserved,
                        ifCurrentMatches: expectedManagerSnapshot
                    )
                }
                switch replaceResult {
                case let .replaced(snapshot):
                    restoredManagerSnapshot = snapshot
                case .configurationChanged:
                    throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
                }
                try await waitUntilRuntimeMatches(
                    preserved,
                    providerInstanceID: providerInstanceID,
                    deadline: recoveryDeadline
                )
                try checkForTerminationRequest()
                let managerSnapshot = try await loadManagerSnapshot(
                    before: recoveryDeadline
                )
                try checkForTerminationRequest()
                guard
                    managerSnapshot == restoredManagerSnapshot
                else {
                    throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
                }
                setActive(preserved.value)
                state = .degraded(
                    "The requested DNS configuration was rejected; the previous configuration remains active."
                )

            case .rejected:
                requireStartupRecovery(
                    "The enabled DNS Proxy configuration could not be reconciled safely."
                )
            case .unrecoverable:
                await repairStoppedRuntime(
                    expectedManagerSnapshot: expectedManagerSnapshot,
                    rejectedTarget: nil,
                    deadline: recoveryDeadline
                )
            }
        } catch is CancellationError where terminationRequested {
            state = .stopping
        } catch DNSProxyControllerError.terminationRequested where terminationRequested {
            state = .stopping
        } catch {
            requireStartupRecovery(
                "The enabled DNS Proxy configuration could not be reconciled: "
                    + error.localizedDescription
            )
        }
    }

    private func resolveRuntimeSwitch(
        _ request: ProxyReapplyRequest,
        oldConfiguration: PersistedProxyConfiguration,
        targetConfiguration: PersistedProxyConfiguration,
        applicationDeadline: ContinuousClock.Instant
    ) async throws -> RuntimeReapplyResolution {
        let resolution = try await resolveReapply(
            request,
            target: targetConfiguration,
            baseGeneration: oldConfiguration.value.generation,
            baseFingerprint: oldConfiguration.fingerprint,
            applicationDeadline: applicationDeadline
        )
        let response = resolution.response
        guard
            response.operationID == request.operationID,
            response.providerInstanceID == request.expectedProviderInstanceID
        else {
            throw MachXPCClientError.invalidResponse
        }
        switch response.disposition {
        case .applied:
            guard
                response.activeGeneration == targetConfiguration.value.generation,
                response.activeFingerprint == targetConfiguration.fingerprint
            else {
                throw MachXPCClientError.invalidResponse
            }
        case .rejectedPreservingBase:
            guard
                response.activeGeneration == oldConfiguration.value.generation,
                response.activeFingerprint == oldConfiguration.fingerprint,
                response.preservedConfigurationData == oldConfiguration.data
            else {
                throw MachXPCClientError.invalidResponse
            }
        case .rejected, .unrecoverable:
            break
        }
        return resolution
    }

    private func resolveReapply(
        _ request: ProxyReapplyRequest,
        target: PersistedProxyConfiguration,
        baseGeneration: UUID,
        baseFingerprint: ProxyConfigurationFingerprint,
        applicationDeadline: ContinuousClock.Instant
    ) async throws -> RuntimeReapplyResolution {
        do {
            let response = try await reapplyRuntime(
                request,
                before: applicationDeadline
            )
            if !isTransientReapplyRejection(response) {
                let verificationDeadline = response.disposition == .applied
                    ? applicationDeadline
                    : ContinuousClock().now.advanced(by: rollbackTimeout)
                return RuntimeReapplyResolution(
                    response: response,
                    verificationDeadline: verificationDeadline
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch DNSProxyControllerError.terminationRequested {
            throw DNSProxyControllerError.terminationRequested
        } catch {
            // A sent mutation may still complete. Reconcile by status and exact replay.
        }

        let clock = ContinuousClock()
        let repairDeadline = clock.now.advanced(by: rollbackTimeout)
        while clock.now < repairDeadline {
            try checkForTerminationRequest()
            do {
                let statusDeadline = min(
                    clock.now.advanced(by: pollInterval),
                    repairDeadline
                )
                let status = try await runtimeStatus(before: statusDeadline)
                guard
                    status.runtimeControlProtocolVersion
                        == DNSProxyXPCContract.currentRuntimeControlProtocolVersion,
                    status.providerInstanceID == request.expectedProviderInstanceID
                else {
                    throw DNSProxyControllerError.runtimeControlOutcomeUncertain
                }
                if runtime(status, matches: target) {
                    return RuntimeReapplyResolution(
                        response: ProxyReapplyResponse(
                            operationID: request.operationID,
                            disposition: .applied,
                            providerInstanceID: request.expectedProviderInstanceID,
                            activeGeneration: target.value.generation,
                            activeFingerprint: target.fingerprint
                        ),
                        verificationDeadline: repairDeadline
                    )
                }

                let identifiesBase = status.generation == baseGeneration
                    && status.configurationFingerprint == baseFingerprint
                guard identifiesBase || status.phase == .failed else {
                    try await sleepForReconciliation(before: repairDeadline)
                    continue
                }

                let response = try await reapplyRuntime(
                    request,
                    before: repairDeadline
                )
                if !isTransientReapplyRejection(response) {
                    return RuntimeReapplyResolution(
                        response: response,
                        verificationDeadline: repairDeadline
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch DNSProxyControllerError.terminationRequested {
                throw DNSProxyControllerError.terminationRequested
            } catch DNSProxyControllerError.runtimeControlOutcomeUncertain {
                throw DNSProxyControllerError.runtimeControlOutcomeUncertain
            } catch {
                // Transport failures remain uncertain until the absolute repair deadline.
            }
            try await sleepForReconciliation(before: repairDeadline)
        }
        throw DNSProxyControllerError.runtimeControlOutcomeUncertain
    }

    private func isTransientReapplyRejection(_ response: ProxyReapplyResponse) -> Bool {
        guard response.disposition == .rejected else { return false }
        return response.rejectionCode == .operationInProgress
            || response.rejectionCode == .rateLimited
    }

    private func sleepForReconciliation(
        before deadline: ContinuousClock.Instant
    ) async throws {
        let clock = ContinuousClock()
        guard clock.now < deadline else { return }
        try await Task.sleep(
            until: min(clock.now.advanced(by: pollInterval), deadline),
            clock: .continuous
        )
    }

    private func reapplyRuntime(
        _ request: ProxyReapplyRequest,
        before deadline: ContinuousClock.Instant
    ) async throws -> ProxyReapplyResponse {
        let runtimeController = self.runtimeController
        let task = Task {
            try await runtimeController.reapplyConfiguration(request)
        }
        runtimeControlTask = task
        defer { runtimeControlTask = nil }
        return try await withDeadline(
            deadline,
            timeoutError: DNSProxyControllerError.runtimeControlOutcomeUncertain
        ) {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }

    private func waitUntilRuntimeMatches(
        _ configuration: PersistedProxyConfiguration,
        providerInstanceID: UUID,
        deadline: ContinuousClock.Instant
    ) async throws {
        let clock = ContinuousClock()
        let task = Task {
            while clock.now < deadline {
                try self.checkForTerminationRequest()
                let requestDeadline = min(
                    clock.now.advanced(by: self.pollInterval),
                    deadline
                )
                do {
                    let status = try await self.runtimeStatus(before: requestDeadline)
                    guard status.providerInstanceID == providerInstanceID else {
                        throw DNSProxyControllerError.managerStateUnavailable(
                            "The DNS Proxy provider instance changed during recovery."
                        )
                    }
                    guard status.runtimeControlProtocolVersion
                        == DNSProxyXPCContract.currentRuntimeControlProtocolVersion
                    else {
                        throw DNSProxyControllerError.managerStateUnavailable(
                            "The DNS Proxy runtime control capability changed during recovery."
                        )
                    }
                    if self.runtime(status, matches: configuration) {
                        return
                    }
                    if status.generation == configuration.value.generation,
                       status.phase == .failed {
                        throw DNSProxyControllerError.providerFailed(status.errorCode)
                    }
                } catch DNSProxyControllerError.readinessTimeout {
                    // Continue until the overall readiness deadline expires.
                }
                let nextPoll = min(clock.now.advanced(by: self.pollInterval), deadline)
                try await Task.sleep(until: nextPoll, clock: .continuous)
            }
            throw DNSProxyControllerError.readinessTimeout
        }
        readinessTask = task
        defer { readinessTask = nil }
        try await task.value
    }

    private func runtime(
        _ status: ProxyRuntimeStatus,
        matches configuration: PersistedProxyConfiguration
    ) -> Bool {
        let protocolVersion = status.runtimeControlProtocolVersion
        return (protocolVersion == DNSProxyXPCContract.readOnlyIdentityProtocolVersion
            || protocolVersion == DNSProxyXPCContract.currentRuntimeControlProtocolVersion)
            && status.providerInstanceID != nil
            && status.generation == configuration.value.generation
            && status.configurationFingerprint == configuration.fingerprint
            && status.phase == .ready
    }

    private func requireStartupRecovery(_ message: String) {
        activeTarget = nil
        activeGeneration = nil
        state = .recoveryRequired(message)
    }

    private func waitUntilReadyCancellable(
        configuration: PersistedProxyConfiguration,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        try await waitUntilReadyCancellable(
            configuration: configuration,
            deadline: clock.now.advanced(by: timeout)
        )
    }

    private func waitUntilReadyCancellable(
        configuration: PersistedProxyConfiguration,
        deadline: ContinuousClock.Instant
    ) async throws {
        let task = Task {
            try await self.waitUntilReady(configuration: configuration, deadline: deadline)
        }
        readinessTask = task
        defer { readinessTask = nil }
        try await task.value
    }

    private func waitUntilReady(
        configuration: PersistedProxyConfiguration,
        deadline: ContinuousClock.Instant
    ) async throws {
        let generation = configuration.value.generation
        let clock = ContinuousClock()
        var attempt = 0
        var lastObservation = "none"
        while clock.now < deadline {
            attempt += 1
            try checkForTerminationRequest()
            do {
                let requestDeadline = min(
                    clock.now.advanced(by: pollInterval),
                    deadline
                )
                let status = try await runtimeStatus(before: requestDeadline)
                let observedGeneration = status.generation?.uuidString ?? "none"
                let providerError = status.errorCode?.rawValue ?? "none"
                lastObservation = [
                    "generation=\(observedGeneration)",
                    "phase=\(status.phase.rawValue)",
                    "error=\(providerError)",
                ].joined(separator: ",")
                logger.info(
                    "DNS readiness status: targetGeneration=\(generation.uuidString, privacy: .public), attempt=\(attempt, privacy: .public), observedGeneration=\(observedGeneration, privacy: .public), phase=\(status.phase.rawValue, privacy: .public), providerError=\(providerError, privacy: .public)"
                )
                if runtime(status, matches: configuration) {
                    return
                }
                if status.generation == generation, status.phase == .failed {
                    throw DNSProxyControllerError.providerFailed(status.errorCode)
                }
            } catch DNSProxyControllerError.readinessTimeout {
                lastObservation = "requestTimedOut"
                logger.info(
                    "DNS readiness request timed out: targetGeneration=\(generation.uuidString, privacy: .public), attempt=\(attempt, privacy: .public)"
                )
            } catch let error as DNSProxyControllerError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastObservation = "requestFailed=\(error.localizedDescription)"
                logger.error(
                    "DNS readiness request failed: targetGeneration=\(generation.uuidString, privacy: .public), attempt=\(attempt, privacy: .public), error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
            let nextPoll = min(clock.now.advanced(by: pollInterval), deadline)
            try await Task.sleep(until: nextPoll, clock: .continuous)
        }
        logger.error(
            "DNS readiness deadline expired: targetGeneration=\(generation.uuidString, privacy: .public), attempts=\(attempt, privacy: .public), lastObservation=\(lastObservation, privacy: .private(mask: .hash))"
        )
        throw DNSProxyControllerError.readinessTimeout
    }

    private func runtimeStatus(
        before deadline: ContinuousClock.Instant
    ) async throws -> ProxyRuntimeStatus {
        try await withDeadline(
            deadline,
            timeoutError: DNSProxyControllerError.readinessTimeout
        ) {
            try await self.statusProvider.runtimeStatus()
        }
    }

    private func providerBundleIdentifier() throws -> String {
        guard let identifier = configuredProviderBundleIdentifier, !identifier.isEmpty else {
            throw DNSProxyControllerError.missingExtensionIdentifier
        }
        return identifier
    }

    private func loadManagerSnapshot() async throws -> DNSProxyManagerSnapshot {
        do {
            return try await manager.loadSnapshot()
        } catch {
            throw DNSProxyControllerError.managerStateUnavailable(error.localizedDescription)
        }
    }

    private func loadManagerSnapshot(
        before deadline: ContinuousClock.Instant
    ) async throws -> DNSProxyManagerSnapshot {
        do {
            return try await managerCall(before: deadline) {
                try await self.manager.loadSnapshot()
            }
        } catch let error as DNSProxyControllerError {
            throw error
        } catch {
            throw DNSProxyControllerError.managerStateUnavailable(error.localizedDescription)
        }
    }

    private func requireManagerGeneration(
        _ expectedGeneration: UUID,
        deadline: ContinuousClock.Instant? = nil
    ) async throws {
        let snapshot: DNSProxyManagerSnapshot
        if let deadline {
            snapshot = try await loadManagerSnapshot(before: deadline)
        } else {
            snapshot = try await loadManagerSnapshot()
        }
        guard
            snapshot.isEnabled,
            snapshot.activeConfiguration?.generation == expectedGeneration
        else {
            throw DNSProxyControllerError.managerConfigurationChangedDuringRollback
        }
    }

    private func compatibleSchemaVersion(for target: DNSProxyTarget) async throws -> Int {
        let transportMinimum: Int
        switch target.upstream {
        case .https:
            transportMinimum = 1
        case .plain:
            transportMinimum = 2
        case .tls:
            transportMinimum = 3
        }
        let minimumSchemaVersion = max(
            transportMinimum,
            target.dnsCacheConfiguration == .standard ? 1 : 4
        )

        if minimumSchemaVersion == 1 {
            let maximumSchemaVersion: Int?
            do {
                let clock = ContinuousClock()
                let status = try await runtimeStatus(
                    before: clock.now.advanced(by: pollInterval)
                )
                maximumSchemaVersion = status.maximumConfigurationSchemaVersion
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                maximumSchemaVersion = nil
            }
            return min(maximumSchemaVersion ?? 1, Self.currentConfigurationSchemaVersion)
        }

        let maximumSchemaVersion = try await waitForProviderSchemaCapability()
        guard maximumSchemaVersion >= minimumSchemaVersion else {
            throw DNSProxyControllerError.unsupportedProviderConfigurationSchema(
                required: minimumSchemaVersion,
                available: maximumSchemaVersion
            )
        }
        return min(maximumSchemaVersion, Self.currentConfigurationSchemaVersion)
    }

    private func waitForProviderSchemaCapability() async throws -> Int {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: readinessTimeout)
        while clock.now < deadline {
            try checkForTerminationRequest()
            let requestDeadline = min(clock.now.advanced(by: pollInterval), deadline)
            do {
                let status = try await runtimeStatus(before: requestDeadline)
                if status.providerInstanceID != nil,
                   status.runtimeControlProtocolVersion
                       == DNSProxyXPCContract.currentRuntimeControlProtocolVersion,
                   let maximumSchemaVersion = status.maximumConfigurationSchemaVersion {
                    return maximumSchemaVersion
                }
            } catch DNSProxyControllerError.readinessTimeout {
                // The Extension process can lag its macOS activation state briefly.
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DNSProxyControllerError {
                throw error
            } catch {
                // Retry transient XPC discovery failures until the shared readiness deadline.
            }
            try await sleepForReconciliation(before: deadline)
        }
        throw DNSProxyControllerError.unsupportedProviderConfigurationSchema(
            required: Self.currentConfigurationSchemaVersion,
            available: nil
        )
    }

    private func managerCall<Value: Sendable>(
        before deadline: ContinuousClock.Instant?,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard let deadline else { return try await operation() }
        let callID = UUID()
        let trackedOperation: @Sendable () async throws -> Value = {
            try Task.checkCancellation()
            await self.deadlineManagerCallStarted(callID)
            do {
                let value = try await operation()
                await self.deadlineManagerCallFinished(callID)
                return value
            } catch {
                await self.deadlineManagerCallFinished(callID)
                throw error
            }
        }
        do {
            return try await withDeadline(
                deadline,
                timeoutError: DNSProxyControllerError.rollbackDeadlineExceeded,
                operation: trackedOperation
            )
        } catch DNSProxyControllerError.rollbackDeadlineExceeded {
            managerMutationOutcomeUncertain = true
            throw DNSProxyControllerError.rollbackDeadlineExceeded
        }
    }

    private func deadlineManagerCallStarted(_ callID: UUID) {
        pendingDeadlineManagerCalls.insert(callID)
    }

    private func deadlineManagerCallFinished(_ callID: UUID) {
        pendingDeadlineManagerCalls.remove(callID)
    }

    private func withDeadline<Value: Sendable>(
        _ deadline: ContinuousClock.Instant,
        timeoutError: any Error,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let clock = ContinuousClock()
        guard clock.now < deadline else { throw timeoutError }

        let (stream, continuation) = AsyncThrowingStream<Value, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let operationTask = Task {
            do {
                let value = try await operation()
                continuation.yield(value)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
                continuation.finish(throwing: timeoutError)
            } catch {
                // The operation completed first or the caller was cancelled.
            }
        }
        defer {
            operationTask.cancel()
            timeoutTask.cancel()
        }

        var iterator = stream.makeAsyncIterator()
        guard let value = try await iterator.next() else { throw CancellationError() }
        return value
    }

    private func validate(upstream: DNSUpstream) async throws {
        let validator = self.validator
        let task = Task {
            try await validator.validate(upstream)
        }
        preflightTask = task
        defer { preflightTask = nil }
        try await task.value
    }

    private func setActive(
        _ configuration: ActiveProxyConfiguration,
        retainingFailureFor rejectedTarget: DNSProxyTarget? = nil
    ) {
        activeTarget = DNSProxyTarget(
            profileID: configuration.profileID,
            upstream: configuration.upstream,
            dnsCacheConfiguration: configuration.dnsCacheConfiguration
        )
        activeGeneration = configuration.generation
        activeLoggingMode = configuration.loggingMode
        if let rejectedTarget {
            targetProfileID = rejectedTarget.profileID
        } else {
            targetProfileID = nil
            lastSwitchFailure = nil
            failedTarget = nil
        }
        state = .active(configuration.generation)
    }

    private func clearPresentationForDisabledState() {
        activeTarget = nil
        activeGeneration = nil
        activeLoggingMode = nil
        targetProfileID = nil
        lastSwitchFailure = nil
        failedTarget = nil
        managerMutationOutcomeUncertain = !pendingDeadlineManagerCalls.isEmpty
        state = .disabled
    }

    private func makeSnapshot() -> ProxyControllerSnapshot {
        ProxyControllerSnapshot(
            state: state,
            targetProfileID: targetProfileID,
            activeProfileID: activeTarget?.profileID,
            activeGeneration: activeGeneration,
            lastSwitchFailure: lastSwitchFailure
        )
    }

    private func publishPresentationChange() {
        guard let presentationChangeHandler else { return }
        let revision = presentationRevision
        let snapshot = makeSnapshot()
        Task { @MainActor in presentationChangeHandler(revision, snapshot) }
    }

    private func presentationDidChange() {
        presentationRevision &+= 1
        guard !presentationPublishScheduled else { return }
        presentationPublishScheduled = true
        Task { [weak self] in
            await self?.publishPendingPresentationChange()
        }
    }

    private func publishPendingPresentationChange() {
        presentationPublishScheduled = false
        publishPresentationChange()
    }

    private func checkForTerminationRequest() throws {
        try Task.checkCancellation()
        if terminationRequested {
            throw DNSProxyControllerError.terminationRequested
        }
    }

    private static let currentConfigurationSchemaVersion = ActiveProxyConfiguration.currentSchemaVersion
}
