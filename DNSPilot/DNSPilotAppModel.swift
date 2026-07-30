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
    private var diagnostics = ProductDiagnosticsSnapshot.unavailable("Not refreshed")
    private var proxyPresentationRevision: UInt64 = 0
#if DNSPILOT_DEBUG_LOCAL
    @Published private(set) var m5Acceptance = M5AcceptanceSnapshot()
#endif

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
#if DNSPILOT_DEBUG_LOCAL
            await refreshM5AcceptanceSnapshot()
#endif
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
            loggingMode: loggingMode
        )
    }

    func performProductIntent(_ intent: ProductIntent) async -> ProductActionOutcome {
        let outcome: ProductActionOutcome
        switch intent {
        case let .preflightProfile(profile):
            do {
                try await upstreamValidator.validate(profile.upstream)
                outcome = .completed
            } catch {
                outcome = .failed(.rejected(error.localizedDescription))
            }
        case let .createProfile(profile):
            outcome = await mutateProductProfile(.create(profile))
        case let .duplicateProfile(sourceProfileID, duplicate):
            outcome = await mutateProductProfile(.duplicate(
                sourceProfileID: sourceProfileID,
                duplicate: duplicate
            ))
        case let .editProfile(profile):
            outcome = await mutateProductProfile(.edit(profile))
        case let .deleteProfile(profileID, plan):
            outcome = await deleteProductProfile(profileID: profileID, plan: plan)
        case let .saveRule(rule):
            outcome = await mutateProductRouting { configuration in
                var rules = configuration.rules
                if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                    rules[index] = rule
                } else {
                    rules.append(rule)
                }
                return (rules, configuration.defaultProfileID)
            }
        case let .deleteRule(ruleID):
            outcome = await mutateProductRouting { configuration in
                (configuration.rules.filter { $0.id != ruleID }, configuration.defaultProfileID)
            }
        case let .reorderRules(ruleIDs):
            outcome = await mutateProductRouting { configuration in
                guard ruleIDs.count == configuration.rules.count,
                      Set(ruleIDs) == Set(configuration.rules.map(\.id)) else { return nil }
                let rulesByID = Dictionary(
                    uniqueKeysWithValues: configuration.rules.map { ($0.id, $0) }
                )
                return (ruleIDs.compactMap { rulesByID[$0] }, configuration.defaultProfileID)
            }
        case let .setDefaultProfile(profileID):
            outcome = await mutateProductRouting { configuration in
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
                    outcome = restarted ? .completed : .failed(.startupUnavailable)
                } else {
                    outcome = .completed
                }
            } else {
                outcome = .failed(.rejected("restoreSystemDNSFailed"))
            }
        case .reconnect:
            if startupFailure != nil {
                startupFailure = nil
                outcome = await start() ? .completed : .failed(.startupUnavailable)
            } else {
                _ = await proxyController.synchronizeState()
                await refreshProxyPresentation()
                switch proxySnapshot.state {
                case .active, .disabled:
                    outcome = .completed
                case .recoveryRequired:
                    outcome = .failed(.recoveryRequired)
                case .preparing, .applying, .repairing, .stopping, .failed, .degraded:
                    outcome = .failed(.rejected("reconnectFailed"))
                }
            }
        case .resetOnboardingConfiguration:
            await restoreSystemDNS()
            guard proxySnapshot.state == .disabled else {
                outcome = .failed(.rejected("restoreSystemDNSFailed"))
                break
            }
            outcome = await mutateProductProfile(.reset)
        case let .createNewConfiguration(recoveryArtifactURL):
            await restoreSystemDNS()
            guard proxySnapshot.state == .disabled else {
                outcome = .failed(.rejected("restoreSystemDNSFailed"))
                break
            }
            do {
                let store = try configurationStoreFactory()
                try store.replaceCorruptConfiguration(
                    with: AppConfiguration(),
                    matching: recoveryArtifactURL
                )
                startupFailure = nil
                outcome = await start() ? .completed : .failed(.startupUnavailable)
            } catch {
                outcome = .failed(.rejected(error.localizedDescription))
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
                outcome = .failed(.rejected("debugLoggingUpdateFailed"))
            }
        case .requestLocationAuthorization:
            requestNetworkLocationAuthorization()
            outcome = .completed
        }
        productChangeHandler?()
        return outcome
    }

    private func mutateProductProfile(
        _ intent: ProfileMutationIntent
    ) async -> ProductActionOutcome {
        guard let profileMutationCoordinator else { return .failed(.startupUnavailable) }
        let current = await profileMutationCoordinator.configurationWriterSnapshot()
        let result = await profileMutationCoordinator.mutate(ProfileMutationRequest(
            operationID: UUID(),
            expectedConfigurationFingerprint: current.configuration.fingerprint,
            intent: intent
        ))
        switch result {
        case .committed:
            _ = await operatingModeCoordinator?.bootstrapFromWriter()
            await refreshProxyPresentation()
            return .completed
        case let .rejected(failure):
            return switch failure {
            case .expectedConfigurationMismatch, .configurationConflict, .operationConflict:
                .failed(.conflict)
            default:
                .failed(.rejected(String(describing: failure)))
            }
        case .recoveryRequired:
            return .failed(.recoveryRequired)
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
            return .failed(.conflict)
        }
        let outcome = await mutateProductProfile(.delete(profileID: profileID, plan: plan))
        await proxyController.releaseProfileDeletionLease(lease)
        await refreshProxyPresentation()
        return outcome
    }

    private func mutateProductRouting(
        _ mutation: (AppConfiguration) -> ([DNSRule], DNSProfile.ID?)?
    ) async -> ProductActionOutcome {
        guard let profileMutationCoordinator else { return .failed(.startupUnavailable) }
        let current = await profileMutationCoordinator.configurationWriterSnapshot()
        guard let (rules, defaultProfileID) = mutation(current.configuration.value) else {
            return .failed(.invalidConfiguration)
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
            return .failed(.invalidConfiguration)
        case .conflict:
            return .failed(.conflict)
        case .recoveryRequired:
            return .failed(.recoveryRequired)
        }
    }

    private func setProductOperatingMode(_ mode: OperatingMode) async -> ProductActionOutcome {
        guard let operatingModeCoordinator else { return .failed(.startupUnavailable) }
        let result = await operatingModeCoordinator.setMode(mode)
        await refreshProxyPresentation()
        switch result {
        case .persisted, .current, .submitted, .suppressed(.equalTarget),
             .suppressed(.proxyInactive), .suppressed(.awaitingNetworkContext):
            return .completed
        case .conflict:
            return .failed(.conflict)
        case .recoveryRequired:
            return .failed(.recoveryRequired)
        case let .suppressed(reason):
            return .failed(.rejected(String(describing: reason)))
        }
    }

    private func turnOnDNSProxyFromCurrentSelection() async -> ProductActionOutcome {
        guard let profileMutationCoordinator else { return .failed(.startupUnavailable) }
        let configuration = await profileMutationCoordinator.configuration().value
        let profileID: DNSProfile.ID
        switch configuration.operatingMode {
        case let .manual(manualProfileID):
            profileID = manualProfileID
        case .automatic:
            guard let defaultProfileID = configuration.defaultProfileID else {
                return .failed(.invalidConfiguration)
            }
            guard let context = await operatingModeCoordinator?.snapshot().latestNetworkContext,
                  context.status == .satisfied else {
                return .failed(.networkUnavailable)
            }
            profileID = RuleEngine.resolveProfile(
                context: context,
                rules: configuration.rules,
                defaultProfileID: defaultProfileID
            ).profileID
        }
        guard let profile = configuration.profiles.first(where: { $0.id == profileID }) else {
            return .failed(.invalidConfiguration)
        }
        _ = await proxyController.activate(DNSProxyTarget(
            profileID: profile.id,
            upstream: profile.upstream
        ))
        await refreshProxyPresentation()
        if case .active = proxySnapshot.state { return .completed }
        return .failed(.rejected("dnsProxyActivationFailed"))
    }

#if DNSPILOT_DEBUG_LOCAL
    func installM5AcceptanceFixture() async {
        guard let profileMutationCoordinator else {
            setM5AcceptanceAction("Startup unavailable")
            return
        }
        do {
            let fixtureProfiles = try M5AcceptanceFixture.profiles()
            let allowedIDs = Set(fixtureProfiles.map(\.id))
            var current = await profileMutationCoordinator.configurationWriterSnapshot()
            guard current.configuration.value.profiles.allSatisfy({ allowedIDs.contains($0.id) }) else {
                setM5AcceptanceAction("Existing configuration protected")
                return
            }
            for profile in fixtureProfiles
            where !current.configuration.value.profiles.contains(where: { $0.id == profile.id }) {
                let request = ProfileMutationRequest(
                    operationID: UUID(),
                    expectedConfigurationFingerprint: current.configuration.fingerprint,
                    intent: .create(profile)
                )
                guard case .committed = await profileMutationCoordinator.mutate(request) else {
                    setM5AcceptanceAction("Fixture profile failed")
                    return
                }
                current = await profileMutationCoordinator.configurationWriterSnapshot()
            }
            guard await replaceM5Routing(
                rules: [],
                defaultProfileID: M5AcceptanceFixture.dohProfileID,
                action: "Fixture installed"
            ) != .failed else { return }
            await refreshM5AcceptanceSnapshot()
        } catch {
            setM5AcceptanceAction("Fixture invalid")
        }
    }

    func captureM5AcceptanceRules() async {
        guard let snapshot = await operatingModeCoordinator?.snapshot(),
              let context = snapshot.latestNetworkContext else {
            setM5AcceptanceAction("Awaiting network context")
            return
        }
        do {
            let rules = try M5AcceptanceFixture.rules(for: context)
            guard !rules.isEmpty else {
                setM5AcceptanceAction("No usable network evidence")
                return
            }
            guard await replaceM5Routing(
                rules: rules,
                defaultProfileID: M5AcceptanceFixture.dohProfileID,
                action: "Current rules captured"
            ) != .failed else { return }
            await refreshM5AcceptanceSnapshot()
        } catch {
            setM5AcceptanceAction("Rule capture failed")
        }
    }

    func rotateM5AcceptanceRules() async {
        guard let profileMutationCoordinator else { return }
        let snapshot = await profileMutationCoordinator.configurationWriterSnapshot()
        var rules = snapshot.configuration.value.rules
        guard rules.count > 1 else {
            setM5AcceptanceAction("Need multiple rules")
            return
        }
        rules.append(rules.removeFirst())
        guard await replaceM5Routing(
            rules: rules,
            defaultProfileID: snapshot.configuration.value.defaultProfileID,
            action: "Rule order rotated"
        ) != .failed else { return }
        await refreshM5AcceptanceSnapshot()
    }

    func disableM5AcceptanceRules() async {
        guard let profileMutationCoordinator else { return }
        let snapshot = await profileMutationCoordinator.configurationWriterSnapshot()
        do {
            let rules = try snapshot.configuration.value.rules.map { rule in
                try DNSRule(
                    id: rule.id,
                    name: rule.name,
                    isEnabled: false,
                    conditions: rule.conditions,
                    profileID: rule.profileID
                )
            }
            guard await replaceM5Routing(
                rules: rules,
                defaultProfileID: snapshot.configuration.value.defaultProfileID,
                action: "Rules disabled"
            ) != .failed else { return }
            await refreshM5AcceptanceSnapshot()
        } catch {
            setM5AcceptanceAction("Rule update failed")
        }
    }

    func toggleFirstM5AcceptanceRule() async {
        guard let profileMutationCoordinator else { return }
        let snapshot = await profileMutationCoordinator.configurationWriterSnapshot()
        guard let first = snapshot.configuration.value.rules.first else {
            setM5AcceptanceAction("No rule available")
            return
        }
        do {
            var rules = snapshot.configuration.value.rules
            rules[0] = try DNSRule(
                id: first.id,
                name: first.name,
                isEnabled: !first.isEnabled,
                conditions: first.conditions,
                profileID: first.profileID
            )
            guard await replaceM5Routing(
                rules: rules,
                defaultProfileID: snapshot.configuration.value.defaultProfileID,
                action: "First rule toggled"
            ) != .failed else { return }
            await refreshM5AcceptanceSnapshot()
        } catch {
            setM5AcceptanceAction("Rule update failed")
        }
    }

    func toggleM5AcceptanceDefault() async {
        guard let profileMutationCoordinator else { return }
        let snapshot = await profileMutationCoordinator.configurationWriterSnapshot()
        let next = snapshot.configuration.value.defaultProfileID == M5AcceptanceFixture.dohProfileID
            ? M5AcceptanceFixture.plainProfileID
            : M5AcceptanceFixture.dohProfileID
        guard await replaceM5Routing(
            rules: snapshot.configuration.value.rules,
            defaultProfileID: next,
            action: "Default changed"
        ) != .failed else { return }
        await refreshM5AcceptanceSnapshot()
    }

    func setM5AcceptanceMode(_ mode: OperatingMode) async {
        guard let operatingModeCoordinator,
              await hasM5AcceptanceFixture() else {
            setM5AcceptanceAction("Fixture required")
            return
        }
        let result = await operatingModeCoordinator.setMode(mode)
        switch result {
        case .persisted, .current, .submitted, .suppressed(.equalTarget),
             .suppressed(.proxyInactive), .suppressed(.awaitingNetworkContext):
            setM5AcceptanceAction("Mode updated")
        case .suppressed, .conflict, .recoveryRequired:
            setM5AcceptanceAction("Mode update failed")
        }
        await refreshProxyPresentation()
        await refreshM5AcceptanceSnapshot()
    }

    func activateM5AcceptanceDefault() async {
        guard let profileMutationCoordinator else { return }
        let configuration = await profileMutationCoordinator.configuration().value
        guard M5AcceptanceFixture.owns(configuration) else {
            setM5AcceptanceAction("Fixture required")
            return
        }
        guard let defaultProfileID = configuration.defaultProfileID,
              let profile = configuration.profiles.first(where: { $0.id == defaultProfileID }) else {
            setM5AcceptanceAction("Default unavailable")
            return
        }
        _ = await proxyController.activate(
            DNSProxyTarget(profileID: profile.id, upstream: profile.upstream)
        )
        await refreshProxyPresentation()
        let defaultTarget = DNSProxyTarget(profileID: profile.id, upstream: profile.upstream)
        guard await proxyController.activeTargetForOperatingMode() == defaultTarget else {
            setM5AcceptanceAction("Activation failed")
            await refreshM5AcceptanceSnapshot()
            return
        }
        _ = await operatingModeCoordinator?.bootstrapFromWriter()
        let refreshedConfiguration = await profileMutationCoordinator.configuration().value
        let context = await operatingModeCoordinator?.snapshot().latestNetworkContext
        guard let expectedTarget = m5ExpectedTarget(
            configuration: refreshedConfiguration,
            context: context
        ), await proxyController.activeTargetForOperatingMode() == expectedTarget else {
            setM5AcceptanceAction("Mode reconciliation failed")
            await refreshM5AcceptanceSnapshot()
            return
        }
        await refreshProxyPresentation()
        setM5AcceptanceAction("Fixture enabled")
        await refreshM5AcceptanceSnapshot()
    }

    func editM5AcceptanceActiveProfile() async {
        guard let profileMutationCoordinator,
              let activeTarget = await proxyController.activeTargetForOperatingMode() else {
            setM5AcceptanceAction("No active fixture profile")
            return
        }
        let activeProfileID = activeTarget.profileID
        let snapshot = await profileMutationCoordinator.configurationWriterSnapshot()
        guard M5AcceptanceFixture.owns(snapshot.configuration.value),
              M5AcceptanceFixture.profileIDs.contains(activeProfileID) else {
            setM5AcceptanceAction("Fixture required")
            return
        }
        guard let profile = snapshot.configuration.value.profiles.first(
            where: { $0.id == activeProfileID }
        ) else {
            setM5AcceptanceAction("Active profile missing")
            return
        }
        let upstream = profile.upstream == Self.diagnosticPlainTarget.upstream
            ? Self.diagnosticDoHTarget.upstream
            : Self.diagnosticPlainTarget.upstream
        do {
            let edited = try DNSProfile(id: profile.id, name: profile.name, upstream: upstream)
            let result = await profileMutationCoordinator.mutate(ProfileMutationRequest(
                operationID: UUID(),
                expectedConfigurationFingerprint: snapshot.configuration.fingerprint,
                intent: .edit(edited)
            ))
            guard case .committed = result else {
                setM5AcceptanceAction("Active edit failed")
                return
            }
            await refreshProxyPresentation()
            let expectedTarget = DNSProxyTarget(profileID: edited.id, upstream: edited.upstream)
            guard await proxyController.activeTargetForOperatingMode() == expectedTarget else {
                setM5AcceptanceAction("Active edit persisted; runtime mismatch")
                await refreshM5AcceptanceSnapshot()
                return
            }
            setM5AcceptanceAction("Active profile edited")
            await refreshM5AcceptanceSnapshot()
        } catch {
            setM5AcceptanceAction("Active edit invalid")
        }
    }

    func deleteM5AcceptanceActiveProfile() async {
        guard let profileMutationCoordinator,
              let activeTarget = await proxyController.activeTargetForOperatingMode() else {
            setM5AcceptanceAction("No active fixture profile")
            return
        }
        let activeProfileID = activeTarget.profileID
        let snapshot = await profileMutationCoordinator.configurationWriterSnapshot()
        let configuration = snapshot.configuration.value
        guard M5AcceptanceFixture.owns(configuration),
              M5AcceptanceFixture.profileIDs.contains(activeProfileID) else {
            setM5AcceptanceAction("Fixture required")
            return
        }
        guard let replacement = configuration.profiles.first(where: { $0.id != activeProfileID }) else {
            setM5AcceptanceAction("Replacement unavailable")
            return
        }
        let affectedRules = configuration.rules.filter { $0.profileID == activeProfileID }
        let plan = ProfileDeletionPlan(
            ruleReplacements: Dictionary(uniqueKeysWithValues: affectedRules.map { ($0.id, replacement.id) }),
            defaultReplacementProfileID: configuration.defaultProfileID == activeProfileID
                ? replacement.id : nil,
            manualReplacementProfileID: configuration.operatingMode == .manual(profileID: activeProfileID)
                ? replacement.id : nil,
            activeReplacementProfileID: replacement.id
        )
        let result = await profileMutationCoordinator.mutate(ProfileMutationRequest(
            operationID: UUID(),
            expectedConfigurationFingerprint: snapshot.configuration.fingerprint,
            intent: .delete(profileID: activeProfileID, plan: plan)
        ))
        guard case .committed = result else {
            setM5AcceptanceAction("Active delete failed")
            return
        }
        let replacementTarget = DNSProxyTarget(
            profileID: replacement.id,
            upstream: replacement.upstream
        )
        let mutationApplied = await proxyController.activeTargetForOperatingMode() == replacementTarget
        _ = await operatingModeCoordinator?.bootstrapFromWriter()
        await refreshProxyPresentation()
        let refreshedConfiguration = await profileMutationCoordinator.configuration().value
        let context = await operatingModeCoordinator?.snapshot().latestNetworkContext
        guard mutationApplied,
              let expectedTarget = m5ExpectedTarget(
                  configuration: refreshedConfiguration,
                  context: context
              ), await proxyController.activeTargetForOperatingMode() == expectedTarget else {
            setM5AcceptanceAction("Active delete persisted; runtime mismatch")
            await refreshM5AcceptanceSnapshot()
            return
        }
        setM5AcceptanceAction("Active profile deleted")
        await refreshM5AcceptanceSnapshot()
    }

    func requestM5AcceptanceLocation() {
        requestNetworkLocationAuthorization()
        setM5AcceptanceAction("Location requested")
    }

    func resampleM5AcceptanceNetwork() async {
        guard let networkMonitor else {
            setM5AcceptanceAction("Monitor unavailable")
            return
        }
        let refreshed = await networkMonitor.requestResample()
        if refreshed,
           let operatingModeCoordinator,
           let context = await operatingModeCoordinator.snapshot().latestNetworkContext {
            _ = await operatingModeCoordinator.updateNetworkContext(context)
            await refreshProxyPresentation()
        }
        setM5AcceptanceAction(refreshed ? "Resample complete" : "Resample unavailable")
        await refreshM5AcceptanceSnapshot()
    }

    func refreshM5AcceptanceSnapshot() async {
        guard let profileMutationCoordinator else { return }
        let configuration = await profileMutationCoordinator.configuration().value
        let context = await operatingModeCoordinator?.snapshot().latestNetworkContext
        let mode: String = switch configuration.operatingMode {
        case .automatic: "Automatic"
        case let .manual(profileID): "Manual: \(M5AcceptanceFixture.profileName(profileID))"
        }
        let interfaces = context?.activeInterfaceTypes
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")
        m5Acceptance = M5AcceptanceSnapshot(
            profileCount: configuration.profiles.count,
            ruleSummary: M5AcceptanceFixture.ruleSummary(configuration.rules),
            defaultProfile: M5AcceptanceFixture.profileName(configuration.defaultProfileID),
            operatingMode: mode,
            ssidAvailability: context?.ssidAvailability.rawValue ?? "Awaiting context",
            interfaceSummary: interfaces?.isEmpty == false ? interfaces! : "None",
            hasIPv4: context?.addresses.contains(where: { $0.address.family == .ipv4 }) ?? false,
            hasIPv6: context?.addresses.contains(where: { $0.address.family == .ipv6 }) ?? false,
            lastAction: m5Acceptance.lastAction
        )
    }

    private func replaceM5Routing(
        rules: [DNSRule],
        defaultProfileID: DNSProfile.ID?,
        action: String
    ) async -> M5AcceptanceRoutingState {
        guard let profileMutationCoordinator else { return .failed }
        let snapshot = await profileMutationCoordinator.configurationWriterSnapshot()
        guard M5AcceptanceFixture.owns(snapshot.configuration.value) else {
            setM5AcceptanceAction("Fixture required")
            return .failed
        }
        let result = await profileMutationCoordinator.replaceRulesAndDefault(
            rules: rules,
            defaultProfileID: defaultProfileID,
            expectedConfigurationFingerprint: snapshot.configuration.fingerprint,
            expectedConfigurationRevision: snapshot.revision
        )
        switch result {
        case .committed, .current:
            let decision = await operatingModeCoordinator?.bootstrapFromWriter()
            await refreshProxyPresentation()
            switch decision {
            case let .submitted(target, _):
                guard await proxyController.activeTargetForOperatingMode() == target else {
                    setM5AcceptanceAction("\(action): runtime mismatch")
                    return .failed
                }
                setM5AcceptanceAction("\(action): applied")
                return .applied
            case .suppressed(.equalTarget):
                setM5AcceptanceAction("\(action): already active")
                return .applied
            case .suppressed(.proxyInactive), .suppressed(.awaitingNetworkContext),
                 .suppressed(.noDefaultProfile), .current, .persisted:
                setM5AcceptanceAction("\(action): persisted")
                return .persisted
            case .none, .suppressed, .conflict, .recoveryRequired:
                setM5AcceptanceAction("\(action): decision failed")
                return .failed
            }
        case .invalid, .conflict, .recoveryRequired:
            setM5AcceptanceAction("Routing update failed")
            return .failed
        }
    }

    private func m5ExpectedTarget(
        configuration: AppConfiguration,
        context: NetworkContext?
    ) -> DNSProxyTarget? {
        let profileID: DNSProfile.ID
        switch configuration.operatingMode {
        case let .manual(manualProfileID):
            profileID = manualProfileID
        case .automatic:
            guard let defaultProfileID = configuration.defaultProfileID else { return nil }
            profileID = context.map {
                RuleEngine.resolveProfile(
                    context: $0,
                    rules: configuration.rules,
                    defaultProfileID: defaultProfileID
                ).profileID
            } ?? defaultProfileID
        }
        guard let profile = configuration.profiles.first(where: { $0.id == profileID }) else {
            return nil
        }
        return DNSProxyTarget(profileID: profile.id, upstream: profile.upstream)
    }

    private func hasM5AcceptanceFixture() async -> Bool {
        guard let profileMutationCoordinator else { return false }
        return M5AcceptanceFixture.owns(
            await profileMutationCoordinator.configuration().value
        )
    }

    private func setM5AcceptanceAction(_ action: String) {
        m5Acceptance.lastAction = action
    }
#endif

    func apply(_ target: DNSProxyTarget) async {
        requestedTargetProfileID = target.profileID
        _ = await proxyController.activate(target)
        await refreshProxyPresentation()
        requestedTargetProfileID = proxySnapshot.targetProfileID
    }

    func restoreSystemDNS() async {
        _ = await proxyController.restoreSystemDNS()
        await refreshProxyPresentation()
        requestedTargetProfileID = nil
    }

    func restoreSystemDNSForTermination() async -> DNSProxyControllerState {
        networkWorkspaceAdapter?.stop()
        if let operatingModeCoordinator {
            _ = await operatingModeCoordinator.fenceForTermination()
        }
        if let networkMonitor {
            await networkMonitor.stop()
        }
        let state = await proxyController.restoreSystemDNSForTermination()
        await refreshProxyPresentation()
        requestedTargetProfileID = nil
        return state
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

    static let diagnosticDoHTarget = DNSProxyTarget(
        profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        upstream: .fixedForCurrentBuild
    )

    static let diagnosticPlainTarget: DNSProxyTarget = {
        do {
            return DNSProxyTarget(
                profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                upstream: .plain(try PlainDNSConfiguration(
                    serverAddress: IPAddress("223.5.5.5")
                ))
            )
        } catch {
            preconditionFailure("Invalid built-in Plain DNS target: \(error)")
        }
    }()

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
        guard startupGeneration == expectedStartupGeneration else { return }
        let presentation = await proxyController.presentationSnapshot()
        guard startupGeneration == expectedStartupGeneration else { return }
        applyProxyPresentation(
            revision: presentation.revision,
            snapshot: presentation.snapshot
        )
#if DNSPILOT_DEBUG_LOCAL
        await refreshM5AcceptanceSnapshot()
#endif
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
