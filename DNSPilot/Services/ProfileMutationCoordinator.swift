import Foundation

struct ProfileDeletionPlan: Equatable, Sendable {
    let ruleReplacements: [DNSRule.ID: DNSProfile.ID]
    let defaultReplacementProfileID: DNSProfile.ID?
    let manualReplacementProfileID: DNSProfile.ID?
    let activeReplacementProfileID: DNSProfile.ID?

    init(
        ruleReplacements: [DNSRule.ID: DNSProfile.ID] = [:],
        defaultReplacementProfileID: DNSProfile.ID? = nil,
        manualReplacementProfileID: DNSProfile.ID? = nil,
        activeReplacementProfileID: DNSProfile.ID? = nil
    ) {
        self.ruleReplacements = ruleReplacements
        self.defaultReplacementProfileID = defaultReplacementProfileID
        self.manualReplacementProfileID = manualReplacementProfileID
        self.activeReplacementProfileID = activeReplacementProfileID
    }
}

enum ProfileMutationIntent: Equatable, Sendable {
    case create(DNSProfile)
    case duplicate(sourceProfileID: DNSProfile.ID, duplicate: DNSProfile)
    case edit(DNSProfile)
    case delete(profileID: DNSProfile.ID, plan: ProfileDeletionPlan)
    case updateDNSCache(DNSCacheConfiguration)
    case reset
}

struct ProfileMutationRequest: Equatable, Sendable {
    let operationID: UUID
    let expectedConfigurationFingerprint: AppConfigurationFingerprint
    let intent: ProfileMutationIntent
}

enum ProfileDeletionPlanError: Equatable, Sendable {
    case missingRuleReplacement(DNSRule.ID)
    case unexpectedRuleReplacement(DNSRule.ID)
    case missingDefaultReplacement
    case unexpectedDefaultReplacement
    case missingManualReplacement
    case unexpectedManualReplacement
    case missingActiveReplacement
    case unexpectedActiveReplacement
    case invalidReplacementProfile(DNSProfile.ID)
}

enum ProfileMutationFailure: Equatable, Sendable {
    case operationInProgress
    case operationConflict
    case expectedConfigurationMismatch
    case profileNotFound(DNSProfile.ID)
    case profileAlreadyExists(DNSProfile.ID)
    case invalidDuplicateIdentity
    case invalidDuplicatePayload
    case invalidDeletionPlan(ProfileDeletionPlanError)
    case invalidConfiguration
    case configurationConflict
    case configurationCommitFailed
    case controllerPreparationFailed
    case providerCompatibilityUnavailable
    case desiredPersistenceFailed
    case journalWriteFailed
    case runtimeRejected
}

enum ProfileMutationRecoveryReason: Equatable, Sendable {
    case journal(ProfileMutationJournalLoadResult)
    case journalUnavailable
    case officialConfigurationUnavailable
    case unknownOfficialConfiguration
    case journalPhaseUpdateFailed
    case configurationCommitUncertain
    case compensationUncertain
    case runtimeUncertain
    case cleanupFailed
}

enum ProfileMutationResult: Equatable, Sendable {
    case committed(PersistedAppConfiguration)
    case rejected(ProfileMutationFailure)
    case recoveryRequired(ProfileMutationRecoveryReason)
}

enum ProfileMutationRecoveryResult: Equatable, Sendable {
    case noPendingMutation
    case restoredOld(PersistedAppConfiguration)
    case finishedDraft(PersistedAppConfiguration)
    case disabled(PersistedAppConfiguration)
    case recoveryRequired(ProfileMutationRecoveryReason)
}

enum ProfileMutationStartupResult: Equatable, Sendable {
    case synchronized(
        recovery: ProfileMutationRecoveryResult,
        controllerState: DNSProxyControllerState
    )
    case recoveryRequired(ProfileMutationRecoveryReason)
}

struct AppConfigurationWriterSnapshot: Equatable, Sendable {
    let configuration: PersistedAppConfiguration
    let revision: UInt64
}

enum OperatingModePersistenceResult: Equatable, Sendable {
    case persisted(AppConfigurationWriterSnapshot)
    case current(AppConfigurationWriterSnapshot)
    case conflict(AppConfigurationWriterSnapshot)
    case recoveryRequired(AppConfigurationWriterSnapshot)
}

enum RoutingConfigurationMutationResult: Equatable, Sendable {
    case committed(AppConfigurationWriterSnapshot)
    case current(AppConfigurationWriterSnapshot)
    case invalid(AppConfigurationWriterSnapshot)
    case conflict(AppConfigurationWriterSnapshot)
    case recoveryRequired(AppConfigurationWriterSnapshot)
}

struct OperatingModeSubmissionLease: Hashable, Sendable {
    let id: UUID
    let configurationRevision: UInt64
}

protocol OperatingModePersisting: Sendable {
    func configurationWriterSnapshot() async -> AppConfigurationWriterSnapshot
    func acquireOperatingModeSubmissionLease(
        expectedConfigurationFingerprint: AppConfigurationFingerprint,
        expectedConfigurationRevision: UInt64
    ) async -> OperatingModeSubmissionLease?
    func releaseOperatingModeSubmissionLease(_ lease: OperatingModeSubmissionLease) async
    func persistOperatingMode(
        _ mode: OperatingMode,
        expectedConfigurationFingerprint: AppConfigurationFingerprint,
        expectedConfigurationRevision: UInt64
    ) async -> OperatingModePersistenceResult
}

protocol ActiveProfileMutationControlling: Sendable {
    func configurationMutationIsAllowed() async -> Bool
    func synchronizeState() async -> DNSProxyControllerState
    func activeProfileIDForMutation() async -> UUID?
    func reserveActiveProfileMutation(
        to target: DNSProxyTarget,
        mutationID: UUID,
        runtimeOperationID: UUID
    ) async throws -> ActiveProfileMutationReservation
    func persistReservedDesired(_ reservation: ActiveProfileMutationReservation) async throws
    func applyReservedMutation(
        _ reservation: ActiveProfileMutationReservation
    ) async -> ActiveProfileMutationResult
    func compensateReservedMutation(
        _ reservation: ActiveProfileMutationReservation
    ) async -> ActiveProfileMutationResult
    func recoverActiveProfileMutation(
        oldConfigurationData: Data,
        draftConfigurationData: Data,
        mutationID: UUID,
        runtimeOperationID: UUID,
        goal: ActiveProfileMutationRecoveryGoal
    ) async throws -> ActiveProfileMutationResult
}

extension DNSProxyController: ActiveProfileMutationControlling {}

extension ActiveProfileMutationControlling {
    func configurationMutationIsAllowed() async -> Bool { true }
}

actor ProfileMutationCoordinator {
    private struct CompletedOperation: Sendable {
        let request: ProfileMutationRequest
        let result: ProfileMutationResult
    }

    func replaceRulesAndDefault(
        rules: [DNSRule],
        defaultProfileID: DNSProfile.ID?,
        expectedConfigurationFingerprint: AppConfigurationFingerprint,
        expectedConfigurationRevision: UInt64
    ) async -> RoutingConfigurationMutationResult {
        guard !mutationInProgress, !configurationWriteFenced,
              expectedConfigurationFingerprint == currentConfiguration.fingerprint,
              expectedConfigurationRevision == configurationRevision else {
            return .conflict(writerSnapshot())
        }
        guard journalIsClear() else {
            return .recoveryRequired(writerSnapshot())
        }
        configurationWriteFenced = true
        defer { configurationWriteFenced = false }
        await waitForSubmissionLeasesToDrain()
        guard expectedConfigurationFingerprint == currentConfiguration.fingerprint,
              expectedConfigurationRevision == configurationRevision else {
            return .conflict(writerSnapshot())
        }
        guard await controller.configurationMutationIsAllowed() else {
            return .recoveryRequired(writerSnapshot())
        }

        do {
            let current = currentConfiguration.value
            let value = try AppConfiguration(
                schemaVersion: current.schemaVersion,
                profiles: current.profiles,
                rules: rules,
                defaultProfileID: defaultProfileID,
                operatingMode: current.operatingMode,
                dnsCacheConfiguration: current.dnsCacheConfiguration
            )
            let persisted = try configurationStore.encode(value)
            guard persisted != currentConfiguration else {
                return .current(writerSnapshot())
            }
            try configurationStore.commit(
                persisted,
                replacing: expectedConfigurationFingerprint
            )
            updateCurrentConfiguration(persisted)
            return .committed(writerSnapshot())
        } catch is AppConfigurationError {
            return .invalid(writerSnapshot())
        } catch ConfigurationStoreError.compareAndSwapConflict {
            return .conflict(writerSnapshot())
        } catch {
            return .recoveryRequired(writerSnapshot())
        }
    }

    private let configurationStore: any ConfigurationStoring
    private let journal: any ProfileMutationJournalStoring
    private let controller: any ActiveProfileMutationControlling
    private var currentConfiguration: PersistedAppConfiguration
    private var configurationRevision: UInt64 = 0
    private var completedOperations: [UUID: CompletedOperation] = [:]
    private var mutationInProgress = false
    private var configurationWriteFenced = false
    private var activeSubmissionLeases: [UUID: UInt64] = [:]
    private var submissionLeaseDrainWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        currentConfiguration: PersistedAppConfiguration,
        configurationStore: any ConfigurationStoring,
        journal: any ProfileMutationJournalStoring,
        controller: any ActiveProfileMutationControlling
    ) {
        self.currentConfiguration = currentConfiguration
        self.configurationStore = configurationStore
        self.journal = journal
        self.controller = controller
    }

    func configuration() -> PersistedAppConfiguration {
        currentConfiguration
    }

    func configurationWriterSnapshot() -> AppConfigurationWriterSnapshot {
        writerSnapshot()
    }

    func acquireOperatingModeSubmissionLease(
        expectedConfigurationFingerprint: AppConfigurationFingerprint,
        expectedConfigurationRevision: UInt64
    ) -> OperatingModeSubmissionLease? {
        guard !configurationWriteFenced,
              expectedConfigurationFingerprint == currentConfiguration.fingerprint,
              expectedConfigurationRevision == configurationRevision else {
            return nil
        }
        let lease = OperatingModeSubmissionLease(
            id: UUID(),
            configurationRevision: configurationRevision
        )
        activeSubmissionLeases[lease.id] = lease.configurationRevision
        return lease
    }

    func releaseOperatingModeSubmissionLease(_ lease: OperatingModeSubmissionLease) {
        guard activeSubmissionLeases.removeValue(forKey: lease.id)
            == lease.configurationRevision else { return }
        guard activeSubmissionLeases.isEmpty else { return }
        let waiters = submissionLeaseDrainWaiters
        submissionLeaseDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func persistOperatingMode(
        _ mode: OperatingMode,
        expectedConfigurationFingerprint: AppConfigurationFingerprint,
        expectedConfigurationRevision: UInt64
    ) async -> OperatingModePersistenceResult {
        guard !mutationInProgress, !configurationWriteFenced,
               expectedConfigurationFingerprint == currentConfiguration.fingerprint,
               expectedConfigurationRevision == configurationRevision else {
            return .conflict(writerSnapshot())
        }
        guard journalIsClear() else {
            return .recoveryRequired(writerSnapshot())
        }
        configurationWriteFenced = true
        defer { configurationWriteFenced = false }
        await waitForSubmissionLeasesToDrain()
        guard expectedConfigurationFingerprint == currentConfiguration.fingerprint,
              expectedConfigurationRevision == configurationRevision else {
            return .conflict(writerSnapshot())
        }
        guard await controller.configurationMutationIsAllowed() else {
            return .recoveryRequired(writerSnapshot())
        }
        guard currentConfiguration.value.operatingMode != mode else {
            return .current(writerSnapshot())
        }

        do {
            let current = currentConfiguration.value
            let value = try AppConfiguration(
                schemaVersion: current.schemaVersion,
                profiles: current.profiles,
                rules: current.rules,
                defaultProfileID: current.defaultProfileID,
                operatingMode: mode,
                dnsCacheConfiguration: current.dnsCacheConfiguration
            )
            let persisted = try configurationStore.encode(value)
            try configurationStore.commit(
                persisted,
                replacing: expectedConfigurationFingerprint
            )
            updateCurrentConfiguration(persisted)
            return .persisted(writerSnapshot())
        } catch ConfigurationStoreError.compareAndSwapConflict {
            return .conflict(writerSnapshot())
        } catch {
            return .recoveryRequired(writerSnapshot())
        }
    }

    func mutate(_ request: ProfileMutationRequest) async -> ProfileMutationResult {
        if let completed = completedOperations[request.operationID] {
            return completed.request == request ? completed.result : .rejected(.operationConflict)
        }
        guard !mutationInProgress, !configurationWriteFenced else {
            return .rejected(.operationInProgress)
        }
        guard request.expectedConfigurationFingerprint == currentConfiguration.fingerprint else {
            return .rejected(.expectedConfigurationMismatch)
        }
        guard await controller.configurationMutationIsAllowed() else {
            return .recoveryRequired(.runtimeUncertain)
        }
        do {
            let pendingEvidence = try journal.load()
            guard pendingEvidence == .missing else {
                return .recoveryRequired(.journal(pendingEvidence))
            }
        } catch {
            return .recoveryRequired(.journalUnavailable)
        }

        mutationInProgress = true
        configurationWriteFenced = true
        defer {
            configurationWriteFenced = false
            mutationInProgress = false
        }
        await waitForSubmissionLeasesToDrain()
        guard request.expectedConfigurationFingerprint == currentConfiguration.fingerprint else {
            return .rejected(.expectedConfigurationMismatch)
        }
        let activeProfileID = await controller.activeProfileIDForMutation()

        let draft: PersistedAppConfiguration
        do {
            let value = try makeDraft(
                request.intent,
                from: currentConfiguration.value,
                activeProfileID: activeProfileID
            )
            draft = try configurationStore.encode(value)
        } catch let failure as DraftFailure {
            return remember(.rejected(failure.mutationFailure), for: request)
        } catch {
            return remember(.rejected(.invalidConfiguration), for: request)
        }

        guard draft != currentConfiguration else {
            return remember(.committed(currentConfiguration), for: request)
        }

        let activeTarget = activeRuntimeTarget(
            for: request.intent,
            draft: draft.value,
            activeProfileID: activeProfileID
        )
        guard let activeTarget else {
            return remember(commitInactive(
                request: request,
                draft: draft
            ), for: request)
        }

        return await mutateActive(
            request: request,
            draft: draft,
            target: activeTarget
        )
    }

    func recoverPendingMutation() async -> ProfileMutationRecoveryResult {
        guard !mutationInProgress, !configurationWriteFenced else {
            return .recoveryRequired(.runtimeUncertain)
        }
        mutationInProgress = true
        configurationWriteFenced = true
        defer {
            configurationWriteFenced = false
            mutationInProgress = false
        }
        await waitForSubmissionLeasesToDrain()

        let loaded: ProfileMutationJournalLoadResult
        do {
            loaded = try journal.load()
        } catch {
            return .recoveryRequired(.journalUnavailable)
        }
        guard case let .loaded(entry, payload) = loaded else {
            if loaded == .missing { return .noPendingMutation }
            return .recoveryRequired(.journal(loaded))
        }

        let official: PersistedAppConfiguration
        switch loadOfficialConfiguration(requireExisting: true) {
        case let .success(configuration):
            official = configuration
        case .failure:
            return .recoveryRequired(.officialConfigurationUnavailable)
        }

        let goal: ActiveProfileMutationRecoveryGoal
        let expectedState: ActiveProfileMutationState
        if official.fingerprint == entry.oldAppConfigurationFingerprint,
           official.data == payload.oldAppConfigurationJSON {
            goal = .restoreOld
            expectedState = .oldActive
        } else if official.fingerprint == entry.draftAppConfigurationFingerprint,
                  official.data == payload.draftAppConfigurationJSON {
            goal = .finishDraft
            expectedState = .draftActive
        } else {
            return .recoveryRequired(.unknownOfficialConfiguration)
        }

        let result: ActiveProfileMutationResult
        do {
            result = try await controller.recoverActiveProfileMutation(
                oldConfigurationData: payload.oldRuntimePropertyList,
                draftConfigurationData: payload.draftRuntimePropertyList,
                mutationID: entry.operationIdentity.operationID,
                runtimeOperationID: entry.operationIdentity.runtimeTransactionID,
                goal: goal
            )
        } catch {
            return .recoveryRequired(.runtimeUncertain)
        }

        guard result.state == expectedState || result.state == .disabled else {
            return .recoveryRequired(.runtimeUncertain)
        }
        do {
            try journal.cleanup(operationIdentity: entry.operationIdentity)
        } catch {
            return .recoveryRequired(.cleanupFailed)
        }
        updateCurrentConfiguration(official)
        if result.state == .disabled { return .disabled(official) }
        return goal == .restoreOld ? .restoredOld(official) : .finishedDraft(official)
    }

    func recoverPendingMutationThenSynchronizeState() async -> ProfileMutationStartupResult {
        let recovery = await recoverPendingMutation()
        if case let .recoveryRequired(reason) = recovery {
            return .recoveryRequired(reason)
        }
        return .synchronized(
            recovery: recovery,
            controllerState: await controller.synchronizeState()
        )
    }

    private func commitInactive(
        request: ProfileMutationRequest,
        draft: PersistedAppConfiguration
    ) -> ProfileMutationResult {
        do {
            try configurationStore.commit(
                draft,
                replacing: request.expectedConfigurationFingerprint
            )
            updateCurrentConfiguration(draft)
            return .committed(draft)
        } catch ConfigurationStoreError.compareAndSwapConflict {
            return .rejected(.configurationConflict)
        } catch {
            return .recoveryRequired(.configurationCommitUncertain)
        }
    }

    private func mutateActive(
        request: ProfileMutationRequest,
        draft: PersistedAppConfiguration,
        target: DNSProxyTarget
    ) async -> ProfileMutationResult {
        let runtimeOperationID = UUID()
        let reservation: ActiveProfileMutationReservation
        do {
            reservation = try await controller.reserveActiveProfileMutation(
                to: target,
                mutationID: request.operationID,
                runtimeOperationID: runtimeOperationID
            )
        } catch DNSProxyControllerError.unsupportedProviderConfigurationSchema {
            return remember(.rejected(.providerCompatibilityUnavailable), for: request)
        } catch {
            return remember(.rejected(.controllerPreparationFailed), for: request)
        }

        let identity = ProfileMutationOperationIdentity(
            operationID: request.operationID,
            runtimeTransactionID: runtimeOperationID
        )
        let payload = ProfileMutationRecoveryPayload(
            operationIdentity: identity,
            oldAppConfigurationJSON: currentConfiguration.data,
            draftAppConfigurationJSON: draft.data,
            oldRuntimePropertyList: reservation.oldConfiguration.data,
            draftRuntimePropertyList: reservation.draftConfiguration.data
        )
        let entry: ProfileMutationJournalEntry
        do {
            entry = ProfileMutationJournalEntry(
                operationIdentity: identity,
                phase: .prepared,
                oldAppConfigurationFingerprint: currentConfiguration.fingerprint,
                draftAppConfigurationFingerprint: draft.fingerprint,
                oldProfileID: reservation.oldConfiguration.value.profileID,
                draftProfileID: reservation.draftConfiguration.value.profileID,
                oldRuntimeIdentity: runtimeIdentity(reservation.oldConfiguration),
                draftRuntimeIdentity: runtimeIdentity(reservation.draftConfiguration),
                payloadChecksum: try journal.payloadChecksum(for: payload)
            )
            try journal.write(entry: entry, payload: payload)
        } catch {
            let compensation = await controller.compensateReservedMutation(reservation)
            guard compensation.state == .oldActive || compensation.state == .disabled else {
                return .recoveryRequired(.compensationUncertain)
            }
            do {
                let evidence = try journal.load()
                guard evidence == .missing else {
                    return .recoveryRequired(.journal(evidence))
                }
                return remember(.rejected(.journalWriteFailed), for: request)
            } catch {
                return .recoveryRequired(.journalUnavailable)
            }
        }

        do {
            try await controller.persistReservedDesired(reservation)
        } catch {
            return await finishCompensation(
                reservation: reservation,
                identity: identity,
                request: request,
                failure: .desiredPersistenceFailed
            )
        }

        let commitResult = commitActiveJSON(draft: draft)
        if let commitFailure = commitResult {
            return await finishCompensation(
                reservation: reservation,
                identity: identity,
                request: request,
                failure: commitFailure
            )
        }

        do {
            try journal.updatePhase(operationIdentity: identity, to: .configurationCommitted)
        } catch {
            return .recoveryRequired(.journalPhaseUpdateFailed)
        }

        let runtimeResult = await controller.applyReservedMutation(reservation)
        switch runtimeResult.state {
        case .draftActive:
            do {
                try journal.cleanup(operationIdentity: identity)
                return remember(.committed(draft), for: request)
            } catch {
                return .recoveryRequired(.cleanupFailed)
            }
        case .oldRuntimePreserved, .oldActive:
            return await rollbackCommittedMutation(
                reservation: reservation,
                identity: identity,
                request: request
            )
        case .disabled:
            do {
                try journal.cleanup(operationIdentity: identity)
                return remember(.committed(draft), for: request)
            } catch {
                return .recoveryRequired(.cleanupFailed)
            }
        case .recoveryRequired:
            return .recoveryRequired(.runtimeUncertain)
        }
    }

    private func commitActiveJSON(draft: PersistedAppConfiguration) -> ProfileMutationFailure? {
        do {
            try configurationStore.commit(draft, replacing: currentConfiguration.fingerprint)
            updateCurrentConfiguration(draft)
            return nil
        } catch ConfigurationStoreError.compareAndSwapConflict {
            return .configurationConflict
        } catch {
            return .configurationCommitFailed
        }
    }

    private func finishCompensation(
        reservation: ActiveProfileMutationReservation,
        identity: ProfileMutationOperationIdentity,
        request: ProfileMutationRequest,
        failure: ProfileMutationFailure
    ) async -> ProfileMutationResult {
        let compensation = await controller.compensateReservedMutation(reservation)
        guard compensation.state == .oldActive || compensation.state == .disabled else {
            return .recoveryRequired(.compensationUncertain)
        }
        guard restoreOldJSONIfNeeded() else {
            return .recoveryRequired(.configurationCommitUncertain)
        }
        do {
            try journal.cleanup(operationIdentity: identity)
            return remember(.rejected(failure), for: request)
        } catch {
            return .recoveryRequired(.cleanupFailed)
        }
    }

    private func rollbackCommittedMutation(
        reservation: ActiveProfileMutationReservation,
        identity: ProfileMutationOperationIdentity,
        request: ProfileMutationRequest
    ) async -> ProfileMutationResult {
        let old = try? PersistedAppConfiguration(data: reservationPayloadOldApp(identity: identity))
        guard let old else { return .recoveryRequired(.configurationCommitUncertain) }
        do {
            try configurationStore.commit(old, replacing: currentConfiguration.fingerprint)
            updateCurrentConfiguration(old)
        } catch {
            return .recoveryRequired(.configurationCommitUncertain)
        }
        let compensation = await controller.compensateReservedMutation(reservation)
        guard compensation.state == .oldActive || compensation.state == .disabled else {
            return .recoveryRequired(.compensationUncertain)
        }
        do {
            try journal.cleanup(operationIdentity: identity)
            return remember(.rejected(.runtimeRejected), for: request)
        } catch {
            return .recoveryRequired(.cleanupFailed)
        }
    }

    private func reservationPayloadOldApp(identity: ProfileMutationOperationIdentity) -> Data {
        guard case let .loaded(entry, payload) = try? journal.load(),
              entry.operationIdentity == identity else { return Data() }
        return payload.oldAppConfigurationJSON
    }

    private func restoreOldJSONIfNeeded() -> Bool {
        guard case let .loaded(entry, payload) = try? journal.load() else { return false }
        guard let official = loadOfficialConfiguration(requireExisting: true).value else {
            return false
        }
        if official.fingerprint == entry.oldAppConfigurationFingerprint,
           official.data == payload.oldAppConfigurationJSON {
            updateCurrentConfiguration(official)
            return true
        }
        guard official.fingerprint == entry.draftAppConfigurationFingerprint,
              official.data == payload.draftAppConfigurationJSON,
              let old = try? PersistedAppConfiguration(data: payload.oldAppConfigurationJSON)
        else { return false }
        do {
            try configurationStore.commit(old, replacing: official.fingerprint)
            updateCurrentConfiguration(old)
            return true
        } catch {
            return false
        }
    }

    private func loadOfficialConfiguration(
        requireExisting: Bool
    ) -> Result<PersistedAppConfiguration, any Error> {
        do {
            switch try configurationStore.load() {
            case let .loaded(configuration):
                return .success(configuration)
            case let .missing(configuration):
                return requireExisting
                    ? .failure(OfficialConfigurationError.unavailable)
                    : .success(configuration)
            case .newerSchema, .unsupportedSchema, .corrupt:
                return .failure(OfficialConfigurationError.unavailable)
            }
        } catch {
            return .failure(error)
        }
    }

    private func makeDraft(
        _ intent: ProfileMutationIntent,
        from configuration: AppConfiguration,
        activeProfileID: DNSProfile.ID?
    ) throws -> AppConfiguration {
        var profiles = configuration.profiles
        var rules = configuration.rules
        var defaultProfileID = configuration.defaultProfileID
        var operatingMode = configuration.operatingMode
        var dnsCacheConfiguration = configuration.dnsCacheConfiguration

        switch intent {
        case let .create(profile):
            guard !profiles.contains(where: { $0.id == profile.id }) else {
                throw DraftFailure(.profileAlreadyExists(profile.id))
            }
            profiles.append(profile)
        case let .duplicate(sourceProfileID, duplicate):
            guard let source = profiles.first(where: { $0.id == sourceProfileID }) else {
                throw DraftFailure(.profileNotFound(sourceProfileID))
            }
            guard duplicate.id != sourceProfileID else {
                throw DraftFailure(.invalidDuplicateIdentity)
            }
            guard !profiles.contains(where: { $0.id == duplicate.id }) else {
                throw DraftFailure(.profileAlreadyExists(duplicate.id))
            }
            guard duplicate.upstream == source.upstream else {
                throw DraftFailure(.invalidDuplicatePayload)
            }
            profiles.append(duplicate)
        case let .edit(profile):
            guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
                throw DraftFailure(.profileNotFound(profile.id))
            }
            profiles[index] = profile
        case let .delete(profileID, plan):
            guard profiles.contains(where: { $0.id == profileID }) else {
                throw DraftFailure(.profileNotFound(profileID))
            }
            let validReplacements = Set(profiles.map(\.id)).subtracting([profileID])
            func requireValid(_ replacement: DNSProfile.ID?) throws -> DNSProfile.ID {
                guard let replacement, validReplacements.contains(replacement) else {
                    throw DraftFailure(.invalidDeletionPlan(
                        replacement.map(ProfileDeletionPlanError.invalidReplacementProfile)
                            ?? .invalidReplacementProfile(profileID)
                    ))
                }
                return replacement
            }

            let affectedRuleIDs = Set(rules.filter { $0.profileID == profileID }.map(\.id))
            for ruleID in affectedRuleIDs where plan.ruleReplacements[ruleID] == nil {
                throw DraftFailure(.invalidDeletionPlan(.missingRuleReplacement(ruleID)))
            }
            for ruleID in plan.ruleReplacements.keys where !affectedRuleIDs.contains(ruleID) {
                throw DraftFailure(.invalidDeletionPlan(.unexpectedRuleReplacement(ruleID)))
            }
            rules = try rules.map { rule in
                guard rule.profileID == profileID else { return rule }
                let replacement = try requireValid(plan.ruleReplacements[rule.id])
                return try DNSRule(
                    id: rule.id,
                    name: rule.name,
                    isEnabled: rule.isEnabled,
                    conditions: rule.conditions,
                    profileID: replacement
                )
            }

            if defaultProfileID == profileID {
                guard plan.defaultReplacementProfileID != nil else {
                    throw DraftFailure(.invalidDeletionPlan(.missingDefaultReplacement))
                }
                defaultProfileID = try requireValid(plan.defaultReplacementProfileID)
            } else if plan.defaultReplacementProfileID != nil {
                throw DraftFailure(.invalidDeletionPlan(.unexpectedDefaultReplacement))
            }

            if case let .manual(manualProfileID) = operatingMode,
               manualProfileID == profileID {
                guard plan.manualReplacementProfileID != nil else {
                    throw DraftFailure(.invalidDeletionPlan(.missingManualReplacement))
                }
                operatingMode = .manual(profileID: try requireValid(plan.manualReplacementProfileID))
            } else if plan.manualReplacementProfileID != nil {
                throw DraftFailure(.invalidDeletionPlan(.unexpectedManualReplacement))
            }

            if activeProfileID == profileID {
                guard plan.activeReplacementProfileID != nil else {
                    throw DraftFailure(.invalidDeletionPlan(.missingActiveReplacement))
                }
                _ = try requireValid(plan.activeReplacementProfileID)
            } else if plan.activeReplacementProfileID != nil {
                throw DraftFailure(.invalidDeletionPlan(.unexpectedActiveReplacement))
            }
            profiles.removeAll { $0.id == profileID }
        case let .updateDNSCache(configuration):
            dnsCacheConfiguration = configuration
        case .reset:
            profiles.removeAll()
            rules.removeAll()
            defaultProfileID = nil
            operatingMode = .automatic
            dnsCacheConfiguration = .standard
        }

        return try AppConfiguration(
            profiles: profiles,
            rules: rules,
            defaultProfileID: defaultProfileID,
            operatingMode: operatingMode,
            dnsCacheConfiguration: dnsCacheConfiguration
        )
    }

    private func activeRuntimeTarget(
        for intent: ProfileMutationIntent,
        draft: AppConfiguration,
        activeProfileID: DNSProfile.ID?
    ) -> DNSProxyTarget? {
        guard let activeProfileID else { return nil }
        let targetID: DNSProfile.ID?
        switch intent {
        case let .edit(profile) where profile.id == activeProfileID:
            targetID = profile.id
        case let .delete(profileID, plan) where profileID == activeProfileID:
            targetID = plan.activeReplacementProfileID
        case .updateDNSCache:
            targetID = activeProfileID
        default:
            targetID = nil
        }
        guard let targetID,
              let profile = draft.profiles.first(where: { $0.id == targetID }) else { return nil }
        return DNSProxyTarget(
            profileID: profile.id,
            upstream: profile.upstream,
            dnsCacheConfiguration: draft.dnsCacheConfiguration
        )
    }

    private func runtimeIdentity(
        _ configuration: PersistedProxyConfiguration
    ) -> ProfileMutationRuntimeIdentity {
        ProfileMutationRuntimeIdentity(
            profileID: configuration.value.profileID,
            generation: configuration.value.generation,
            configurationFingerprint: configuration.fingerprint
        )
    }

    private func remember(
        _ result: ProfileMutationResult,
        for request: ProfileMutationRequest
    ) -> ProfileMutationResult {
        completedOperations[request.operationID] = CompletedOperation(
            request: request,
            result: result
        )
        return result
    }

    private func writerSnapshot() -> AppConfigurationWriterSnapshot {
        AppConfigurationWriterSnapshot(
            configuration: currentConfiguration,
            revision: configurationRevision
        )
    }

    private func journalIsClear() -> Bool {
        do {
            return try journal.load() == .missing
        } catch {
            return false
        }
    }

    private func waitForSubmissionLeasesToDrain() async {
        while !activeSubmissionLeases.isEmpty {
            await withCheckedContinuation { continuation in
                submissionLeaseDrainWaiters.append(continuation)
            }
        }
    }

    private func updateCurrentConfiguration(_ configuration: PersistedAppConfiguration) {
        guard configuration != currentConfiguration else { return }
        currentConfiguration = configuration
        configurationRevision &+= 1
    }

    private struct DraftFailure: Error {
        let mutationFailure: ProfileMutationFailure

        init(_ mutationFailure: ProfileMutationFailure) {
            self.mutationFailure = mutationFailure
        }
    }

    private enum OfficialConfigurationError: Error {
        case unavailable
    }
}

extension ProfileMutationCoordinator: OperatingModePersisting {}

private extension Result {
    var value: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }
}
