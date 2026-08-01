import Combine
import Foundation
import OSLog

@MainActor
final class DNSPilotAppModel: ObservableObject, ProductRuntimeBacking {
    static let shared = DNSPilotAppModel()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "DNSPilot",
        category: "AppModel"
    )

    @Published private(set) var proxySnapshot = ProxyControllerSnapshot(
        state: .disabled,
        targetProfileID: nil,
        activeProfileID: nil,
        activeGeneration: nil,
        lastSwitchFailure: nil
    )
    @Published private(set) var requestedTargetProfileID: UUID?
    @Published private(set) var startupFailure: ProductStartupFailure?
    @Published private(set) var proxyResumeState = ProductProxyResumeState.none
    private var diagnostics = ProductDiagnosticsSnapshot.unavailable("Not refreshed")
    private var proxyPresentationRevision: UInt64 = 0
    private let proxyController: DNSProxyController
    private let upstreamValidator: any UpstreamValidating
    private let userDefaults: UserDefaults
    private let configurationStoreFactory: @MainActor () throws -> ConfigurationStore
    private var profileMutationCoordinator: ProfileMutationCoordinator?
    private var operatingModeCoordinator: OperatingModeCoordinator?
    private var networkMonitor: NetworkMonitor?
    private var networkWorkspaceAdapter: NetworkMonitorWorkspaceAdapter?
    private var ssidProvider: SystemSSIDSnapshotProvider?
    private var didStart = false
    private var startupGeneration: UInt64 = 0
    private var networkSessionEpoch: UInt64 = 0
    private var productChangeHandler: (@MainActor () -> Void)?
    private var pendingResumeRecord: ProxyResumeRecord?
    private var proxyResumeAllowed = false
    private var proxyResumeJournal: (any ProxyResumeJournalStoring)?
    private var proxyResumeAttemptInProgress = false

    var proxyState: DNSProxyControllerState {
        proxySnapshot.state
    }

    init(
        proxyController: DNSProxyController? = nil,
        upstreamValidator: any UpstreamValidating = UpstreamValidator(),
        userDefaults: UserDefaults = .standard,
        configurationStoreFactory: @escaping @MainActor () throws -> ConfigurationStore = {
            try ConfigurationStore.live()
        }
    ) {
        let persistedMode = userDefaults.string(forKey: ProductWindowPolicy.debugLoggingModeKey)
            .flatMap(ProxyLoggingMode.init(rawValue:)) ?? .default
        self.proxyController = proxyController ?? DNSProxyController(loggingMode: persistedMode)
        self.upstreamValidator = upstreamValidator
        self.userDefaults = userDefaults
        self.configurationStoreFactory = configurationStoreFactory
    }

    func start() async -> Bool {
        guard !didStart else { return false }
        didStart = true
        startupGeneration &+= 1
        let activeStartupGeneration = startupGeneration
        networkSessionEpoch = 0
        startupFailure = nil
        var startupCompleted = false
        defer {
            if !startupCompleted {
                didStart = false
            }
        }

        do {
            try Task.checkCancellation()
            DNSLogBridge.configure(process: "Host", mode: await proxyController.loggingMode())
            await proxyController.setPresentationChangeHandler { [weak self] revision, snapshot in
                guard let self else { return }
                self.applyProxyPresentation(revision: revision, snapshot: snapshot)
                self.productChangeHandler?()
            }
            let store = try configurationStoreFactory()
            let persisted = try loadOrCreateConfiguration(from: store)
            let resumeJournal = ProxyResumeJournal(directoryURL: store.directoryURL)
            proxyResumeJournal = resumeJournal
            await proxyController.configureResumeJournal(
                resumeJournal,
                appConfigurationFingerprint: persisted.fingerprint
            )
            let journal = ProfileMutationJournal(directoryURL: store.directoryURL)
            let mutationCoordinator = ProfileMutationCoordinator(
                currentConfiguration: persisted,
                configurationStore: store,
                journal: journal,
                controller: proxyController
            )
            profileMutationCoordinator = mutationCoordinator

            switch await mutationCoordinator.recoverPendingMutationThenSynchronizeState() {
            case .synchronized:
                break
            case let .recoveryRequired(reason):
                Self.logger.error(
                    "Startup recovery is required: \(String(describing: reason), privacy: .private)"
                )
                startupFailure = .recoveryRequired(
                    "Configuration recovery is required: \(String(describing: reason))"
                )
                await refreshProxyPresentation()
                resetStartupComponents()
                return false
            }
            try Task.checkCancellation()

            await refreshProxyPresentation()
            switch await proxyController.evaluateStartupResume() {
            case .none:
                pendingResumeRecord = nil
                proxyResumeState = .none
            case let .pending(record):
                pendingResumeRecord = record
                proxyResumeState = .waitingForExtension
            case let .failed(reason), let .recoveryRequired(reason):
                pendingResumeRecord = nil
                proxyResumeState = .failed(reason)
            }
            let modeCoordinator = OperatingModeCoordinator(
                modePersister: mutationCoordinator,
                targetSubmitter: proxyController
            )
            operatingModeCoordinator = modeCoordinator
            _ = await modeCoordinator.bootstrapFromWriter()
            try Task.checkCancellation()

            let ssidProvider = SystemSSIDSnapshotProvider()
            self.ssidProvider = ssidProvider
            let collector = SystemNetworkContextCollector(
                addressProvider: SystemNetworkAddressProvider(),
                ssidProvider: ssidProvider
            )
            let monitor = NetworkMonitor(
                source: SystemNetworkPathSource(),
                collector: collector
            ) { [weak self] event in
                await self?.handleNetworkContextEvent(
                    event,
                    startupGeneration: activeStartupGeneration
                )
            }
            networkMonitor = monitor
            let workspaceAdapter = NetworkMonitorWorkspaceAdapter(
                monitor: monitor
            ) { [weak self] active, epoch in
                guard self?.startupGeneration == activeStartupGeneration else { return }
                self?.handleGUISessionChange(active, epoch: epoch)
            }
            networkWorkspaceAdapter = workspaceAdapter
            workspaceAdapter.start()
            await monitor.start()
            try Task.checkCancellation()
            startupCompleted = true
            productChangeHandler?()
        } catch is CancellationError {
            await stopAndResetStartupComponents()
        } catch let error as AppStartupError {
            await stopAndResetStartupComponents()
            Self.logger.error(
                "Startup failed: \(error.localizedDescription, privacy: .private)"
            )
            startupFailure = error.productFailure
        } catch {
            await stopAndResetStartupComponents()
            Self.logger.error(
                "Startup failed: \(error.localizedDescription, privacy: .private)"
            )
            startupFailure = .unavailable(error.localizedDescription)
        }
        return startupCompleted
    }

    func synchronizeProxyState() async {
        _ = await proxyController.synchronizeState()
        await refreshProxyPresentation()
    }

    func requestNetworkLocationAuthorization() {
        ssidProvider?.requestAuthorization()
    }

    func setProductChangeHandler(_ handler: (@MainActor () -> Void)?) {
        productChangeHandler = handler
    }

    func productSnapshot() async -> ProductRuntimeSnapshot {
        let configuration = await profileMutationCoordinator?.configuration().value
        let network = await operatingModeCoordinator?.snapshot().latestNetworkContext
        let loggingMode = await proxyController.loggingMode()
        return ProductRuntimeSnapshot(
            configuration: configuration,
            proxy: proxySnapshot,
            network: network,
            locationAuthorization: ssidProvider?.authorizationStatus() ?? .notDetermined,
            startupFailure: startupFailure,
            diagnostics: diagnostics,
            loggingMode: loggingMode,
            proxyResumeState: proxyResumeState
        )
    }

    func performProductIntent(_ intent: ProductIntent) async -> ProductActionOutcome {
        let outcome: ProductActionOutcome
        switch intent {
        case let .preflightProfile(profile):
            do {
                try await upstreamValidator.validate(profile.upstream)
                outcome = .completed
            } catch is CancellationError {
                outcome = .failed(ProductActionFailure(
                    action: .profileTest,
                    reason: .cancelled
                ))
            } catch let failure as ProfileTestFailure {
                outcome = .failed(ProductActionFailure(
                    action: .profileTest,
                    reason: .upstreamTestUnclassified,
                    diagnosticDescription: failure.diagnosticDescription
                ))
            } catch {
                outcome = .failed(ProductActionFailure(
                    action: .profileTest,
                    reason: .unknown,
                    diagnosticDescription: error.localizedDescription
                ))
            }
        case let .createProfile(profile):
            outcome = await mutateProductProfile(.create(profile), action: .profileCreate)
        case let .duplicateProfile(sourceProfileID, duplicate):
            outcome = await mutateProductProfile(.duplicate(
                sourceProfileID: sourceProfileID,
                duplicate: duplicate
            ), action: .profileDuplicate)
        case let .editProfile(profile):
            outcome = await mutateProductProfile(.edit(profile), action: .profileEdit)
        case let .deleteProfile(profileID, plan):
            outcome = await deleteProductProfile(profileID: profileID, plan: plan)
        case let .saveRule(rule):
            outcome = await mutateProductRouting(action: .ruleSave) { configuration in
                var rules = configuration.rules
                if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                    rules[index] = rule
                } else {
                    rules.append(rule)
                }
                return (rules, configuration.defaultProfileID)
            }
        case let .deleteRule(ruleID):
            outcome = await mutateProductRouting(action: .ruleDelete) { configuration in
                (configuration.rules.filter { $0.id != ruleID }, configuration.defaultProfileID)
            }
        case let .reorderRules(ruleIDs):
            outcome = await mutateProductRouting(action: .ruleReorder) { configuration in
                guard ruleIDs.count == configuration.rules.count,
                      Set(ruleIDs) == Set(configuration.rules.map(\.id)) else { return nil }
                let rulesByID = Dictionary(
                    uniqueKeysWithValues: configuration.rules.map { ($0.id, $0) }
                )
                return (ruleIDs.compactMap { rulesByID[$0] }, configuration.defaultProfileID)
            }
        case let .setDefaultProfile(profileID):
            outcome = await mutateProductRouting(action: .defaultProfileUpdate) { configuration in
                guard configuration.profiles.contains(where: { $0.id == profileID }) else {
                    return nil
                }
                return (configuration.rules, profileID)
            }
        case let .setOperatingMode(mode):
            outcome = await setProductOperatingMode(mode)
        case .turnOnDNSProxy:
            outcome = await turnOnDNSProxyFromCurrentSelection()
        case .restoreSystemDNS:
            await restoreSystemDNS()
            if proxySnapshot.state == .disabled {
                if startupFailure != nil {
                    startupFailure = nil
                    let restarted = await start()
                    outcome = restarted ? .completed : .failed(ProductActionFailure(
                        action: .systemDNSRestore,
                        reason: .notReady
                    ))
                } else {
                    outcome = .completed
                }
            } else {
                outcome = .failed(ProductActionFailure(
                    action: .systemDNSRestore,
                    reason: .systemDNSRestoreUnconfirmed,
                    diagnosticDescription: proxySnapshot.state.description
                ))
            }
        case .reconnect:
            if startupFailure != nil {
                startupFailure = nil
                outcome = await start() ? .completed : .failed(ProductActionFailure(
                    action: .reconnect,
                    reason: .notReady
                ))
            } else {
                _ = await proxyController.synchronizeState()
                await refreshProxyPresentation()
                switch proxySnapshot.state {
                case .active, .disabled:
                    outcome = .completed
                case .recoveryRequired:
                    outcome = .failed(ProductActionFailure(
                        action: .reconnect,
                        reason: .recoveryRequired,
                        diagnosticDescription: proxySnapshot.state.description
                    ))
                case .preparing, .applying, .repairing, .stopping, .failed, .degraded:
                    outcome = .failed(ProductActionFailure(
                        action: .reconnect,
                        reason: .reconnectUnresolved,
                        diagnosticDescription: proxySnapshot.state.description
                    ))
                }
            }
        case .resetOnboardingConfiguration:
            await restoreSystemDNS()
            guard proxySnapshot.state == .disabled else {
                outcome = .failed(ProductActionFailure(
                    action: .onboardingReset,
                    reason: .systemDNSRestoreUnconfirmed,
                    diagnosticDescription: proxySnapshot.state.description
                ))
                break
            }
            outcome = await mutateProductProfile(.reset, action: .onboardingReset)
        case let .createNewConfiguration(recoveryArtifactURL):
            await restoreSystemDNS()
            guard proxySnapshot.state == .disabled else {
                outcome = .failed(ProductActionFailure(
                    action: .configurationReplace,
                    reason: .systemDNSRestoreUnconfirmed,
                    diagnosticDescription: proxySnapshot.state.description
                ))
                break
            }
            do {
                let store = try configurationStoreFactory()
                try store.replaceCorruptConfiguration(
                    with: AppConfiguration(),
                    matching: recoveryArtifactURL
                )
                startupFailure = nil
                outcome = await start() ? .completed : .failed(ProductActionFailure(
                    action: .configurationReplace,
                    reason: .notReady
                ))
            } catch {
                outcome = .failed(ProductActionFailure(
                    action: .configurationReplace,
                    reason: .persistenceFailed,
                    diagnosticDescription: error.localizedDescription
                ))
            }
        case .refreshDiagnostics:
            do {
                let status = try await proxyController.runtimeStatus()
                diagnostics = .available(
                    runtimeControlProtocolVersion: status.runtimeControlProtocolVersion,
                    providerInstanceID: status.providerInstanceID,
                    activeGeneration: status.generation,
                    phase: status.phase,
                    errorCode: status.errorCode,
                    configurationFingerprint: status.configurationFingerprint,
                    transitionSequence: status.transitionSequence,
                    lastQuiescedGeneration: status.lastQuiescedGeneration
                )
            } catch {
                Self.logger.error(
                    "Runtime diagnostics refresh failed: \(error.localizedDescription, privacy: .private)"
                )
                diagnostics = .unavailable(error.localizedDescription)
            }
            outcome = .completed
        case let .setDebugLogging(enabled):
            let mode = enabled ? ProxyLoggingMode.debug : .default
            if await proxyController.updateLoggingMode(mode) {
                userDefaults.set(mode.rawValue, forKey: ProductWindowPolicy.debugLoggingModeKey)
                DNSLogBridge.configure(process: "Host", mode: mode)
                await refreshProxyPresentation()
                outcome = .completed
            } else {
                await refreshProxyPresentation()
                outcome = .failed(ProductActionFailure(
                    action: .debugLoggingUpdate,
                    reason: .runtimeRejected
                ))
            }
        case let .setDNSCacheConfiguration(configuration):
            outcome = await mutateProductProfile(
                .updateDNSCache(configuration),
                action: .dnsCacheUpdate
            )
        case .requestLocationAuthorization:
            requestNetworkLocationAuthorization()
            outcome = .completed
        }
        productChangeHandler?()
        return outcome
    }

    private func mutateProductProfile(
        _ intent: ProfileMutationIntent,
        action: ProductAction
    ) async -> ProductActionOutcome {
        guard let profileMutationCoordinator else {
            return .failed(ProductActionFailure(action: action, reason: .notReady))
        }
        let current = await profileMutationCoordinator.configurationWriterSnapshot()
        let result = await profileMutationCoordinator.mutate(ProfileMutationRequest(
            operationID: UUID(),
            expectedConfigurationFingerprint: current.configuration.fingerprint,
            intent: intent
        ))
        switch result {
        case .committed:
            if case .updateDNSCache = intent {
                await operatingModeCoordinator?.synchronizeConfigurationFromWriter()
            } else {
                _ = await operatingModeCoordinator?.bootstrapFromWriter()
            }
            await refreshProxyPresentation()
            return .completed
        case let .rejected(failure):
            return .failed(ProductActionFailure(
                action: action,
                reason: failure.productFailureReason,
                diagnosticDescription: String(describing: failure)
            ))
        case let .recoveryRequired(reason):
            return .failed(ProductActionFailure(
                action: action,
                reason: .recoveryRequired,
                diagnosticDescription: String(describing: reason)
            ))
        }
    }

    private func deleteProductProfile(
        profileID: DNSProfile.ID,
        plan: ProfileDeletionPlan
    ) async -> ProductActionOutcome {
        guard let lease = await proxyController.acquireProfileDeletionLease(
            deleting: profileID
        ) else {
            await refreshProxyPresentation()
            return .failed(ProductActionFailure(
                action: .profileDelete,
                reason: .conflict
            ))
        }
        let outcome = await mutateProductProfile(
            .delete(profileID: profileID, plan: plan),
            action: .profileDelete
        )
        await proxyController.releaseProfileDeletionLease(lease)
        await refreshProxyPresentation()
        return outcome
    }

    private func mutateProductRouting(
        action: ProductAction,
        _ mutation: (AppConfiguration) -> ([DNSRule], DNSProfile.ID?)?
    ) async -> ProductActionOutcome {
        guard let profileMutationCoordinator else {
            return .failed(ProductActionFailure(action: action, reason: .notReady))
        }
        let current = await profileMutationCoordinator.configurationWriterSnapshot()
        guard let (rules, defaultProfileID) = mutation(current.configuration.value) else {
            return .failed(ProductActionFailure(action: action, reason: .invalidConfiguration))
        }
        let result = await profileMutationCoordinator.replaceRulesAndDefault(
            rules: rules,
            defaultProfileID: defaultProfileID,
            expectedConfigurationFingerprint: current.configuration.fingerprint,
            expectedConfigurationRevision: current.revision
        )
        switch result {
        case .committed, .current:
            _ = await operatingModeCoordinator?.bootstrapFromWriter()
            await refreshProxyPresentation()
            return .completed
        case .invalid:
            return .failed(ProductActionFailure(action: action, reason: .invalidConfiguration))
        case .conflict:
            return .failed(ProductActionFailure(action: action, reason: .conflict))
        case .recoveryRequired:
            return .failed(ProductActionFailure(action: action, reason: .recoveryRequired))
        }
    }

    private func setProductOperatingMode(_ mode: OperatingMode) async -> ProductActionOutcome {
        guard let operatingModeCoordinator else {
            return .failed(ProductActionFailure(
                action: .operatingModeUpdate,
                reason: .notReady
            ))
        }
        let result = await operatingModeCoordinator.setMode(mode)
        await refreshProxyPresentation()
        switch result {
        case .persisted, .current, .submitted, .suppressed(.equalTarget),
             .suppressed(.proxyInactive), .suppressed(.awaitingNetworkContext):
            return .completed
        case .conflict:
            return .failed(ProductActionFailure(
                action: .operatingModeUpdate,
                reason: .conflict
            ))
        case .recoveryRequired:
            return .failed(ProductActionFailure(
                action: .operatingModeUpdate,
                reason: .recoveryRequired
            ))
        case let .suppressed(reason):
            return .failed(ProductActionFailure(
                action: .operatingModeUpdate,
                reason: .unknown,
                diagnosticDescription: String(describing: reason)
            ))
        }
    }

    private func turnOnDNSProxyFromCurrentSelection() async -> ProductActionOutcome {
        guard let profileMutationCoordinator else {
            return .failed(ProductActionFailure(action: .dnsProxyEnable, reason: .notReady))
        }
        let configuration = await profileMutationCoordinator.configuration().value
        let profileID: DNSProfile.ID
        switch configuration.operatingMode {
        case let .manual(manualProfileID):
            profileID = manualProfileID
        case .automatic:
            guard let defaultProfileID = configuration.defaultProfileID else {
                return .failed(ProductActionFailure(
                    action: .dnsProxyEnable,
                    reason: .invalidConfiguration
                ))
            }
            guard let context = await operatingModeCoordinator?.snapshot().latestNetworkContext,
                  context.status == .satisfied else {
                return .failed(ProductActionFailure(
                    action: .dnsProxyEnable,
                    reason: .networkUnavailable
                ))
            }
            profileID = RuleEngine.resolveProfile(
                context: context,
                rules: configuration.rules,
                defaultProfileID: defaultProfileID
            ).profileID
        }
        guard let profile = configuration.profiles.first(where: { $0.id == profileID }) else {
            return .failed(ProductActionFailure(
                action: .dnsProxyEnable,
                reason: .invalidConfiguration
            ))
        }
        _ = await proxyController.activate(DNSProxyTarget(
            profileID: profile.id,
            upstream: profile.upstream,
            dnsCacheConfiguration: configuration.dnsCacheConfiguration
        ))
        await refreshProxyPresentation()
        if case .active = proxySnapshot.state { return .completed }
        if let failure = proxySnapshot.lastSwitchFailure {
            return .failed(ProductActionFailure(
                action: .dnsProxyEnable,
                reason: failure.code.productFailureReason,
                diagnosticDescription: failure.diagnosticSummary
            ))
        }
        return .failed(ProductActionFailure(
            action: .dnsProxyEnable,
            reason: .unknown,
            diagnosticDescription: proxySnapshot.state.description
        ))
    }

    func apply(_ target: DNSProxyTarget) async {
        requestedTargetProfileID = target.profileID
        _ = await proxyController.activate(target)
        await refreshProxyPresentation()
        requestedTargetProfileID = proxySnapshot.targetProfileID
    }

    func restoreSystemDNS() async {
        pendingResumeRecord = nil
        proxyResumeState = .none
        await proxyController.discardStartupResume()
        _ = await proxyController.restoreSystemDNS()
        await refreshProxyPresentation()
        requestedTargetProfileID = nil
    }

    func restoreSystemDNSForTermination() async -> DNSProxyControllerState {
        await restoreSystemDNSForTerminationResult(rememberActiveState: true).state
    }

    func restoreSystemDNSForTerminationResult(
        rememberActiveState: Bool
    ) async -> DNSProxyTerminationRestoreResult {
        networkWorkspaceAdapter?.stop()
        if let operatingModeCoordinator {
            _ = await operatingModeCoordinator.fenceForTermination()
        }
        if let networkMonitor {
            await networkMonitor.stop()
        }
        if let configuration = await profileMutationCoordinator?.configuration(),
           let proxyResumeJournal {
            await proxyController.configureResumeJournal(
                proxyResumeJournal,
                appConfigurationFingerprint: configuration.fingerprint
            )
        }
        let result = await proxyController.restoreSystemDNSForTerminationResult(
            rememberActiveState: rememberActiveState
        )
        await refreshProxyPresentation()
        requestedTargetProfileID = nil
        return result
    }

    func setProxyResumeAllowed(_ allowed: Bool) async {
        proxyResumeAllowed = allowed
        guard pendingResumeRecord != nil else { return }
        if !allowed {
            proxyResumeState = .waitingForExtension
            productChangeHandler?()
            return
        }
        await attemptPendingResume()
    }

    func prepareProxyResumeExtensionUpgrade(
        source: ProxyResumeExtensionBuildIdentity,
        target: ProxyResumeExtensionBuildIdentity
    ) async -> ProxyResumeExtensionUpgradeDecision {
        let decision = await proxyController.prepareStartupResumeExtensionUpgrade(
            source: source,
            target: target
        )
        applyExtensionUpgradeDecision(decision)
        return decision
    }

    func confirmProxyResumeExtensionUpgrade(
        target: ProxyResumeExtensionBuildIdentity
    ) async -> ProxyResumeExtensionUpgradeDecision {
        let decision = await proxyController.confirmStartupResumeExtensionUpgrade(target: target)
        applyExtensionUpgradeDecision(decision)
        return decision
    }

    func retryProxyResume() async {
        guard let proxyResumeJournal else { return }
        do {
            let result = try proxyResumeJournal.load()
            guard case let .loaded(record) = result else { return }
            pendingResumeRecord = try proxyResumeJournal.prepareRetry(
                operationID: record.operationID
            )
            proxyResumeState = proxyResumeAllowed
                ? .waitingForNetwork
                : .waitingForExtension
            if proxyResumeAllowed { await attemptPendingResume() }
        } catch {
            proxyResumeState = .failed(.outcomeUncertain)
            productChangeHandler?()
        }
    }

    func keepSystemDNSAfterResumeFailure() async {
        await proxyController.discardStartupResume()
        pendingResumeRecord = nil
        proxyResumeState = .none
        productChangeHandler?()
    }

    func cancelTerminationRequest() async {
        await proxyController.cancelTerminationRequest()
        networkSessionEpoch &+= 1
        if let networkMonitor {
            networkSessionEpoch = await networkMonitor.invalidateSession()
        }
        if let operatingModeCoordinator {
            _ = await operatingModeCoordinator.cancelTerminationFence(
                sessionEpoch: networkSessionEpoch
            )
        }
        networkWorkspaceAdapter?.start()
        if let networkMonitor {
            await networkMonitor.start()
        }
        await refreshProxyPresentation()
    }

    func runtimeStatus() async throws -> ProxyRuntimeStatus {
        try await proxyController.runtimeStatus()
    }

    func runtimeEvidence() async throws -> ProxyRuntimeEvidence {
        try await proxyController.runtimeEvidence()
    }

    func applyProxyPresentation(
        revision: UInt64,
        snapshot: ProxyControllerSnapshot
    ) {
        guard revision > proxyPresentationRevision else { return }
        proxyPresentationRevision = revision
        proxySnapshot = snapshot
    }

    private func refreshProxyPresentation() async {
        let presentation = await proxyController.presentationSnapshot()
        guard presentation.revision >= proxyPresentationRevision else { return }
        proxyPresentationRevision = presentation.revision
        proxySnapshot = presentation.snapshot
    }

    private func loadOrCreateConfiguration(
        from store: ConfigurationStore
    ) throws -> PersistedAppConfiguration {
        switch try store.load() {
        case let .missing(initial):
            try store.commit(initial, replacing: nil)
            return initial
        case let .loaded(configuration):
            return configuration
        case let .newerSchema(version):
            throw AppStartupError.newerConfigurationSchema(version)
        case let .unsupportedSchema(version):
            throw AppStartupError.unsupportedConfigurationSchema(version)
        case let .corrupt(recoveryArtifactURL):
            throw AppStartupError.corruptConfiguration(recoveryArtifactURL)
        }
    }

    private func attemptPendingResume() async {
        guard proxyResumeAllowed,
              !proxyResumeAttemptInProgress,
              let record = pendingResumeRecord,
              let mutationCoordinator = profileMutationCoordinator,
              let proxyResumeJournal else { return }
        proxyResumeAttemptInProgress = true
        defer { proxyResumeAttemptInProgress = false }
        let configuration = await mutationCoordinator.configuration()
        let profileID: DNSProfile.ID
        switch configuration.value.operatingMode {
        case let .manual(manualProfileID):
            profileID = manualProfileID
        case .automatic:
            guard let modeSnapshot = await operatingModeCoordinator?.snapshot(),
                  modeSnapshot.isSessionActive,
                  let context = modeSnapshot.latestNetworkContext,
                  context.status == .satisfied,
                  let defaultProfileID = configuration.value.defaultProfileID else {
                proxyResumeState = .waitingForNetwork
                productChangeHandler?()
                return
            }
            profileID = RuleEngine.resolveProfile(
                context: context,
                rules: configuration.value.rules,
                defaultProfileID: defaultProfileID
            ).profileID
        }
        guard let profile = configuration.value.profiles.first(where: { $0.id == profileID }) else {
            proxyResumeState = .failed(.profileUnavailable)
            productChangeHandler?()
            return
        }

        await proxyController.configureResumeJournal(
            proxyResumeJournal,
            appConfigurationFingerprint: configuration.fingerprint
        )
        proxyResumeState = .restoring
        productChangeHandler?()
        let snapshot = await proxyController.resumeAfterSafeQuit(
            target: DNSProxyTarget(
                profileID: profile.id,
                upstream: profile.upstream,
                dnsCacheConfiguration: configuration.value.dnsCacheConfiguration
            ),
            record: record,
            appConfigurationFingerprint: configuration.fingerprint
        )
        proxySnapshot = snapshot
        if case .active = snapshot.state {
            pendingResumeRecord = nil
            proxyResumeState = .none
        } else {
            proxyResumeState = .failed(.activationFailed)
        }
        productChangeHandler?()
    }

    private func applyExtensionUpgradeDecision(
        _ decision: ProxyResumeExtensionUpgradeDecision
    ) {
        switch decision {
        case .notNeeded:
            break
        case let .submitted(record), let .confirmed(record):
            pendingResumeRecord = record
            proxyResumeState = .waitingForExtension
        case let .blocked(reason), let .recoveryRequired(reason):
            pendingResumeRecord = nil
            proxyResumeState = .failed(reason)
        }
        productChangeHandler?()
    }

    private func handleGUISessionChange(_ active: Bool, epoch: UInt64) {
        networkSessionEpoch = epoch
        let callbackStartupGeneration = startupGeneration
        guard let operatingModeCoordinator else { return }
        Task { [weak self] in
            _ = await operatingModeCoordinator.updateGUISession(
                isActive: active,
                epoch: epoch
            )
            guard let self, self.startupGeneration == callbackStartupGeneration else { return }
            let presentation = await self.proxyController.presentationSnapshot()
            guard self.startupGeneration == callbackStartupGeneration else { return }
            self.applyProxyPresentation(
                revision: presentation.revision,
                snapshot: presentation.snapshot
            )
        }
    }

    private func handleNetworkContextEvent(
        _ event: NetworkContextEvent,
        startupGeneration expectedStartupGeneration: UInt64
    ) async {
        guard startupGeneration == expectedStartupGeneration,
              let operatingModeCoordinator else { return }
        _ = await operatingModeCoordinator.updateNetworkContext(
            event.context,
            sessionEpoch: event.sessionEpoch
        )
        if proxyResumeAllowed, pendingResumeRecord != nil {
            await attemptPendingResume()
        }
        guard startupGeneration == expectedStartupGeneration else { return }
        let presentation = await proxyController.presentationSnapshot()
        guard startupGeneration == expectedStartupGeneration else { return }
        applyProxyPresentation(
            revision: presentation.revision,
            snapshot: presentation.snapshot
        )
        productChangeHandler?()
    }

    private func stopAndResetStartupComponents() async {
        networkWorkspaceAdapter?.stop()
        if let operatingModeCoordinator {
            _ = await operatingModeCoordinator.fenceForTermination()
        }
        if let networkMonitor {
            await networkMonitor.stop()
        }
        resetStartupComponents()
    }

    private func resetStartupComponents() {
        startupGeneration &+= 1
        networkWorkspaceAdapter = nil
        networkMonitor = nil
        ssidProvider = nil
        operatingModeCoordinator = nil
        profileMutationCoordinator = nil
    }
}


private enum AppStartupError: LocalizedError {
    case newerConfigurationSchema(Int)
    case unsupportedConfigurationSchema(Int)
    case corruptConfiguration(URL)

    var errorDescription: String? {
        switch self {
        case let .newerConfigurationSchema(version):
            "This configuration was created by a newer DNSPilot schema (\(version))."
        case let .unsupportedConfigurationSchema(version):
            "This DNSPilot configuration schema is unsupported (\(version))."
        case let .corruptConfiguration(url):
            "The DNSPilot configuration is corrupt. Recovery copy: \(url.lastPathComponent)"
        }
    }

    var productFailure: ProductStartupFailure {
        let message = errorDescription ?? "DNSPilot could not load its configuration."
        return switch self {
        case let .newerConfigurationSchema(version):
            .newerConfigurationSchema(version: version, message: message)
        case let .unsupportedConfigurationSchema(version):
            .unsupportedConfigurationSchema(version: version, message: message)
        case let .corruptConfiguration(url):
            .corruptConfiguration(message: message, recoveryArtifactURL: url)
        }
    }
}
