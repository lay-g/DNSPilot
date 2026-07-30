import Foundation
import Testing
@testable import DNSPilot

struct ProxySwitchStateMachineTests {
    @MainActor
    @Test func initialTargetEnablePublishesActiveProfileAndGeneration() async throws {
        let target = DNSProxyTarget(profileID: UUID(), upstream: .fixedCloudflare)
        let manager = FakeDNSProxyManager(isEnabled: false)
        let status = readyStatusFollowingManager(manager)
        let controller = makeController(manager: manager, statusProvider: status)
        let recorder = ProxyPresentationRecorder()
        await controller.setPresentationChangeHandler { revision, snapshot in
            recorder.revisions.append(revision)
            recorder.snapshots.append(snapshot)
            recorder.states.append(snapshot.state)
        }

        let result = await controller.activate(target)
        for _ in 0..<10 where !recorder.states.contains(where: {
            if case .active = $0 { true } else { false }
        }) {
            await Task.yield()
        }
        let configuration = try #require(await manager.currentSnapshot.activeConfiguration)

        #expect(result.state == .active(configuration.generation))
        #expect(result.activeProfileID == target.profileID)
        #expect(result.activeGeneration == configuration.generation)
        #expect(result.targetProfileID == nil)
        #expect(result.lastSwitchFailure == nil)
        #expect(configuration.upstream == target.upstream)
        #expect(recorder.states.contains { if case .preparing = $0 { true } else { false } })
        #expect(recorder.states.contains { if case .applying = $0 { true } else { false } })
        #expect(recorder.states.contains { if case .active = $0 { true } else { false } })
        #expect(recorder.snapshots.contains {
            if case .preparing = $0.state { $0.targetProfileID == target.profileID } else { false }
        })
        #expect(!recorder.snapshots.contains {
            $0.state == .disabled
                && ($0.targetProfileID != nil
                    || $0.activeProfileID != nil
                    || $0.activeGeneration != nil)
        })
        #expect(Set(recorder.revisions).count == recorder.revisions.count)
    }

    @Test func initialPlainTargetWaitsForAuthenticatedProviderCapability() async throws {
        let target = try plainTarget()
        let manager = FakeDNSProxyManager(isEnabled: false)
        let startup = FailFirstRuntimeStatus()
        let providerInstanceID = UUID()
        let status = FakeRuntimeStatusProvider {
            try await startup.checkAvailability()
            guard let persisted = await manager.currentSnapshot.persistedConfiguration else {
                return .idle(
                    runtimeControlProtocolVersion: DNSProxyXPCContract
                        .currentRuntimeControlProtocolVersion,
                    providerInstanceID: providerInstanceID
                )
            }
            return runtimeStatus(
                generation: persisted.value.generation,
                phase: .ready,
                runtimeControlProtocolVersion: DNSProxyXPCContract
                    .currentRuntimeControlProtocolVersion,
                providerInstanceID: providerInstanceID,
                configurationFingerprint: persisted.fingerprint
            )
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            readinessTimeout: .milliseconds(100),
            pollInterval: .milliseconds(2)
        )

        let result = await controller.activate(target)

        #expect(result.activeProfileID == target.profileID)
        #expect(await manager.currentSnapshot.activeConfiguration?.schemaVersion
            == ActiveProxyConfiguration.currentSchemaVersion)
        #expect(await status.requestCount >= 3)
    }

    @Test func initialPlainTargetRejectsUnauthenticatedSchemaClaim() async throws {
        let target = try plainTarget()
        let manager = FakeDNSProxyManager(isEnabled: false)
        let status = FakeRuntimeStatusProvider {
            runtimeStatus(generation: nil, phase: .idle)
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            readinessTimeout: .milliseconds(20),
            pollInterval: .milliseconds(2)
        )

        let result = await controller.activate(target)

        guard case .failed = result.state else {
            Issue.record("Expected compatibility failure, got \(result.state)")
            return
        }
        #expect(result.lastSwitchFailure?.code == .providerCompatibilityUnavailable)
        #expect(await manager.enableSaveCount == 0)
    }

    @MainActor
    @Test func olderPresentationCallbackCannotReplaceNewerSnapshot() {
        let model = DNSPilotAppModel()
        let generation = UUID()
        let profileID = UUID()
        let active = ProxyControllerSnapshot(
            state: .active(generation),
            targetProfileID: nil,
            activeProfileID: profileID,
            activeGeneration: generation,
            lastSwitchFailure: nil
        )
        let stale = ProxyControllerSnapshot(
            state: .applying(UUID()),
            targetProfileID: profileID,
            activeProfileID: nil,
            activeGeneration: nil,
            lastSwitchFailure: nil
        )

        model.applyProxyPresentation(revision: 2, snapshot: active)
        model.applyProxyPresentation(revision: 1, snapshot: stale)

        #expect(model.proxySnapshot == active)
    }

    @Test func successfulSwitchSavesEnabledManagerBeforeRuntimeWithoutDisable() async throws {
        let old = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let oldPersisted = try PersistedProxyConfiguration(value: old)
        let target = try plainTarget()
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: old)
        let runtime = FakeRuntimeSession(activeConfiguration: oldPersisted)
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()

        let result = await controller.switchTarget(to: target)
        let targetGeneration = try #require(result.activeGeneration)

        #expect(result.activeProfileID == target.profileID)
        #expect(targetGeneration != old.generation)
        #expect(await manager.events == [
            .load,
            .load,
            .load,
            .replace(
                expectedGeneration: old.generation,
                targetGeneration: targetGeneration
            ),
            .load,
        ])
        let request = try #require(await runtime.requests.first)
        let savedTargetFingerprint = await manager.currentSnapshot
            .persistedConfiguration?.fingerprint
        #expect(request.expectedBaseGeneration == old.generation)
        #expect(request.expectedBaseFingerprint == oldPersisted.fingerprint)
        #expect(request.targetFingerprint == savedTargetFingerprint)
        #expect(await manager.disableSaveCount == 0)
    }

    @Test func activeLoggingModeChangeUsesRuntimeReapplyWithoutDisable() async throws {
        let old = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let persisted = try PersistedProxyConfiguration(value: old)
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: old)
        let runtime = FakeRuntimeSession(activeConfiguration: persisted)
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()

        #expect(await controller.updateLoggingMode(.debug))

        let active = try #require(await manager.currentSnapshot.activeConfiguration)
        let request = try #require(await runtime.requests.first)
        let requested = try PersistedProxyConfiguration(data: request.targetConfigurationData)
        #expect(active.loggingMode == .debug)
        #expect(requested.value.loggingMode == .debug)
        #expect(await controller.loggingMode() == .debug)
        #expect(await manager.disableSaveCount == 0)
    }

    @Test func rejectedLoggingModeChangeKeepsOldRuntimeAndPreference() async throws {
        let old = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let persisted = try PersistedProxyConfiguration(value: old)
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: old)
        let runtime = FakeRuntimeSession(
            activeConfiguration: persisted,
            outcomes: [.rejectedPreservingBase]
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()

        #expect(!(await controller.updateLoggingMode(.debug)))

        #expect(await manager.currentSnapshot.persistedConfiguration == persisted)
        #expect(await controller.loggingMode() == .default)
        #expect(await manager.disableSaveCount == 0)
    }

    @Test func uncertainLoggingModeChangeConservativelyKeepsDebugWarningEnabled() async throws {
        let old = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: old)
        let runtime = FakeRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: old),
            outcomes: [.unrecoverable]
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()

        #expect(!(await controller.updateLoggingMode(.debug)))
        #expect(await controller.loggingMode() == .debug)
    }

    @Test func startupUsesConfirmedManagerLoggingModeInsteadOfStalePreference() async throws {
        let active = try ActiveProxyConfiguration(
            generation: UUID(),
            profileID: UUID(),
            upstream: .fixedCloudflare,
            loggingMode: .debug
        )
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: active)
        let runtime = FakeRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: active)
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )

        _ = await controller.synchronizeState()

        #expect(await controller.loggingMode() == .debug)
    }

    @Test func targetPreflightFailureLeavesOldRuntimeUntouched() async throws {
        let old = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let target = try plainTarget()
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: old)
        let runtime = FakeRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: old)
        )
        let validator = FakeUpstreamValidator { throw FakeTestError.unavailable }
        let controller = makeController(
            manager: manager,
            validator: validator,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()

        let result = await controller.activate(target)

        #expect(result.state == .active(old.generation))
        #expect(result.activeProfileID == old.profileID)
        #expect(result.activeGeneration == old.generation)
        #expect(result.targetProfileID == target.profileID)
        #expect(result.lastSwitchFailure?.code == .targetPreflightFailed)
        #expect(await manager.events == [.load, .load, .load])
        #expect(await manager.currentSnapshot.activeConfiguration == old)
        #expect(await runtime.requests.isEmpty)
    }

    @Test func differentTargetAndRestoreClearFailurePresentation() async throws {
        let old = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let rejected = try plainTarget()
        let accepted = try httpsTarget(endpoint: "https://dns.alidns.com/dns-query")
        let validation = FailFirstValidation()
        let validator = FakeUpstreamValidator { try await validation.run() }
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: old)
        let runtime = FakeRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: old)
        )
        let controller = makeController(
            manager: manager,
            validator: validator,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()

        let failed = await controller.activate(rejected)
        #expect(failed.targetProfileID == rejected.profileID)
        #expect(failed.lastSwitchFailure?.targetProfileID == rejected.profileID)

        let succeeded = await controller.activate(accepted)
        #expect(succeeded.activeProfileID == accepted.profileID)
        #expect(succeeded.targetProfileID == nil)
        #expect(succeeded.lastSwitchFailure == nil)

        #expect(await controller.restoreSystemDNS() == .disabled)
        let restored = await controller.controllerSnapshot()
        #expect(restored.activeProfileID == nil)
        #expect(restored.activeGeneration == nil)
        #expect(restored.targetProfileID == nil)
        #expect(restored.lastSwitchFailure == nil)
    }

    @Test func targetRejectionRestoresExactManagerBaseWithoutDisable() async throws {
        let old = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let oldPersisted = try PersistedProxyConfiguration(value: old)
        let target = try plainTarget()
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: old)
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

        let result = await controller.activate(target)

        #expect(result.state == .active(old.generation))
        #expect(result.activeProfileID == old.profileID)
        #expect(result.targetProfileID == target.profileID)
        #expect(result.lastSwitchFailure?.code == .targetProviderFailed)
        #expect(result.lastSwitchFailure?.activeProfileID == old.profileID)
        #expect(await manager.currentSnapshot.persistedConfiguration == oldPersisted)
        #expect(await manager.disableSaveCount == 0)
        let replacements = await manager.events.compactMap { event -> UUID? in
            guard case let .replace(_, targetGeneration) = event else { return nil }
            return targetGeneration
        }
        #expect(replacements.count == 2)
        #expect(replacements.last == old.generation)
    }

    @Test func unrecoverableRuntimeDisablesExactTargetAndReportsDegraded() async throws {
        let old = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let target = try plainTarget()
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: old)
        let runtime = FakeRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: old),
            outcomes: [.unrecoverable]
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()

        let result = await controller.activate(target)

        guard case .degraded = result.state else {
            Issue.record("Expected degraded state after exact lifecycle repair")
            return
        }
        #expect(await manager.currentSnapshot.isEnabled == false)
        #expect(await manager.currentSnapshot.activeConfiguration?.profileID == target.profileID)
        #expect(await manager.disableSaveCount == 1)
        #expect(result.activeProfileID == nil)
        #expect(result.targetProfileID == target.profileID)
        #expect(result.lastSwitchFailure?.code == .targetProviderFailed)
    }

    @Test func runtimeTransportFailureReplaysSameOperationAndAppliesTarget() async throws {
        let old = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let target = try plainTarget()
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: old
        )
        let runtime = FakeRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: old),
            outcomes: [.failure(.unavailable)]
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()

        let result = await controller.activate(target)

        guard case .active = result.state else {
            Issue.record("Expected target to apply after exact operation replay")
            return
        }
        #expect(await manager.currentSnapshot.isEnabled)
        #expect(await manager.currentSnapshot.activeConfiguration?.profileID == target.profileID)
        #expect(result.activeProfileID == target.profileID)
        #expect(result.targetProfileID == nil)
        let requests = await runtime.requests
        #expect(requests.count == 2)
        #expect(requests[0] == requests[1])
    }

    @Test func lostMutationReplyReconcilesTargetWithoutWaitingForever() async throws {
        let old = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let target = try plainTarget()
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: old)
        let gate = AsyncGate()
        let runtime = LostReplyRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: old),
            replyGate: gate
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime,
            readinessTimeout: .milliseconds(250),
            rollbackTimeout: .seconds(1),
            pollInterval: .milliseconds(2)
        )
        _ = await controller.synchronizeState()
        let clock = ContinuousClock()
        let started = clock.now

        let result = await controller.activate(target)
        let elapsed = started.duration(to: clock.now)
        await gate.open()

        #expect(result.activeProfileID == target.profileID)
        #expect(await manager.currentSnapshot.activeConfiguration?.profileID == target.profileID)
        #expect(await runtime.requests.count == 1)
        #expect(elapsed < .seconds(2))
    }

    @Test func unrecoverableRuntimeDoesNotDisableChangedManagerOwner() async throws {
        let old = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let external = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let target = try plainTarget()
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: old,
            disableReplacementBeforeSave: external
        )
        let runtime = FakeRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: old),
            outcomes: [.unrecoverable]
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()

        let result = await controller.activate(target)

        expectRecoveryRequired(result.state)
        #expect(await manager.currentSnapshot.isEnabled)
        #expect(await manager.currentSnapshot.activeConfiguration == external)
        #expect(await manager.disableSaveCount == 1)
    }

    @Test func managerChangedBeforeEnabledSaveIsNeverOverwrittenOrDisabled() async throws {
        let old = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let external = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let target = try plainTarget()
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: old,
            replaceFailures: [.configurationStaleReplacing(external)]
        )
        let runtime = FakeRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: old)
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()

        let result = await controller.activate(target)

        expectRecoveryRequired(result.state)
        #expect(result.lastSwitchFailure?.code == .targetWriteFailed)
        #expect(await manager.disableSaveCount == 0)
        #expect(await manager.enableSaveCount == 0)
        #expect(await manager.currentSnapshot.activeConfiguration == external)
        #expect(await runtime.requests.isEmpty)
    }

    @Test func externalReplacementBeforeTransactionLoadIsNotAdopted() async throws {
        let old = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let external = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let target = try plainTarget()
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: old)
        let validator = FakeUpstreamValidator()
        let runtime = FakeRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: old)
        )
        let controller = makeController(
            manager: manager,
            validator: validator,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()
        await manager.replaceState(isEnabled: true, activeConfiguration: external)

        let result = await controller.activate(target)

        expectRecoveryRequired(result.state)
        #expect(result.lastSwitchFailure?.code == .oldGenerationChanged)
        #expect(await validator.validationCount == 0)
        #expect(await manager.disableSaveCount == 0)
        #expect(await manager.enableSaveCount == 0)
        #expect(await manager.currentSnapshot.activeConfiguration == external)
    }

    @Test func externalReplacementAfterRuntimeApplyIsNotPublishedOrMutated() async throws {
        let old = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let external = try configuration(profileID: UUID(), upstream: .fixedCloudflare)
        let target = try plainTarget()
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: old)
        let runtime = FakeRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: old)
        )
        let status = FakeRuntimeStatusProvider {
            let runtimeStatus = await runtime.runtimeStatus()
            if runtimeStatus.generation != old.generation {
                await manager.replaceState(isEnabled: true, activeConfiguration: external)
            }
            return runtimeStatus
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()

        let result = await controller.activate(target)

        expectRecoveryRequired(result.state)
        #expect(result.activeGeneration == nil)
        #expect(await manager.disableSaveCount == 0)
        #expect(await manager.enableSaveCount == 0)
        #expect(await manager.currentSnapshot.activeConfiguration == external)
    }

    @Test func legacyExtensionUsesSchemaOneForDoH() async throws {
        let target = DNSProxyTarget(profileID: UUID(), upstream: .fixedCloudflare)
        let manager = FakeDNSProxyManager(isEnabled: false)
        let providerInstanceID = UUID()
        let status = FakeRuntimeStatusProvider {
            let snapshot = await manager.currentSnapshot
            let persisted = snapshot.persistedConfiguration
            return runtimeStatus(
                generation: snapshot.activeConfiguration?.generation,
                phase: snapshot.isEnabled ? .ready : .idle,
                maximumConfigurationSchemaVersion: nil,
                runtimeControlProtocolVersion: DNSProxyXPCContract
                    .currentRuntimeControlProtocolVersion,
                providerInstanceID: providerInstanceID,
                configurationFingerprint: persisted?.fingerprint
            )
        }
        let controller = makeController(manager: manager, statusProvider: status)

        let result = await controller.activate(target)
        let configuration = try #require(await manager.currentSnapshot.activeConfiguration)

        #expect(result.state == .active(configuration.generation))
        #expect(configuration.schemaVersion == 1)
    }

    @Test func legacyExtensionRejectsPlainBeforeManagerMutation() async throws {
        let old = try ActiveProxyConfiguration(
            generation: UUID(),
            profileID: UUID(),
            upstream: .fixedCloudflare,
            schemaVersion: 1
        )
        let target = try plainTarget()
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: old)
        let validator = FakeUpstreamValidator()
        let persisted = try PersistedProxyConfiguration(value: old)
        let providerInstanceID = UUID()
        let status = FakeRuntimeStatusProvider {
            runtimeStatus(
                generation: old.generation,
                phase: .ready,
                maximumConfigurationSchemaVersion: nil,
                runtimeControlProtocolVersion: DNSProxyXPCContract
                    .readOnlyIdentityProtocolVersion,
                providerInstanceID: providerInstanceID,
                configurationFingerprint: persisted.fingerprint
            )
        }
        let controller = makeController(
            manager: manager,
            validator: validator,
            statusProvider: status
        )
        _ = await controller.synchronizeState()

        let result = await controller.activate(target)

        #expect(result.state == .active(old.generation))
        #expect(result.lastSwitchFailure?.code == .providerCompatibilityUnavailable)
        #expect(await validator.validationCount == 0)
        #expect(await manager.disableSaveCount == 0)
        #expect(await manager.enableSaveCount == 0)
    }

    @Test func rejectedSwitchRestoresLegacyWireSchemaExactly() async throws {
        let old = try ActiveProxyConfiguration(
            generation: UUID(),
            profileID: UUID(),
            upstream: .fixedCloudflare,
            schemaVersion: 1
        )
        let target = try plainTarget()
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: old)
        let runtime = FakeRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: old),
            outcomes: [.rejectedPreservingBase]
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )
        _ = await controller.synchronizeState()

        let result = await controller.activate(target)
        let request = try #require(await runtime.requests.first)
        let attempted = try PersistedProxyConfiguration(
            data: request.targetConfigurationData
        )

        #expect(result.activeProfileID == old.profileID)
        #expect(attempted.value.schemaVersion == 2)
        #expect(await manager.currentSnapshot.activeConfiguration?.schemaVersion == 1)
        #expect(await manager.disableSaveCount == 0)
    }

    @Test func nonCancellingStatusRequestDoesNotDefeatReadinessTimeout() async {
        let target = DNSProxyTarget(profileID: UUID(), upstream: .fixedCloudflare)
        let manager = FakeDNSProxyManager(isEnabled: false)
        let gate = AsyncGate()
        let status = CapabilityThenHangingStatusProvider(gate: gate)
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            readinessTimeout: .milliseconds(250),
            rollbackTimeout: .milliseconds(250),
            pollInterval: .milliseconds(10)
        )
        let clock = ContinuousClock()
        let started = clock.now

        let result = await controller.activate(target)
        let elapsed = started.duration(to: clock.now)
        await gate.open()

        #expect(result.lastSwitchFailure?.code == .targetReadinessTimedOut)
        #expect(await manager.currentSnapshot.isEnabled == false)
        #expect(elapsed < .seconds(2))
    }

    @Test func concurrentTargetsCoalesceToFirstThenLatest() async throws {
        let targetA = DNSProxyTarget(profileID: UUID(), upstream: .fixedCloudflare)
        let targetB = try plainTarget()
        let targetC = try httpsTarget(endpoint: "https://dns.alidns.com/dns-query")
        let gate = AsyncGate()
        let validator = FakeUpstreamValidator { await gate.wait() }
        let manager = FakeDNSProxyManager(isEnabled: false)
        let controller = makeController(
            manager: manager,
            validator: validator,
            statusProvider: readyStatusFollowingManager(manager)
        )
        _ = await controller.synchronizeState()
        let first = Task { await controller.activate(targetA) }
        await waitUntilValidationStarts(validator)

        _ = await controller.activate(targetB)
        _ = await controller.activate(targetC)
        await gate.open()
        _ = await first.value

        let enabledProfiles = await manager.events.compactMap { event -> UUID? in
            guard case let .enable(_, profileID) = event else { return nil }
            return profileID
        }
        let replacementCount = await manager.events.count(where: { event in
            if case .replace = event { return true }
            return false
        })
        let result = await controller.controllerSnapshot()
        #expect(enabledProfiles == [targetA.profileID])
        #expect(replacementCount == 1)
        #expect(result.activeProfileID == targetC.profileID)
        #expect(await validator.validationCount == 2)
    }

    @Test func duplicateInflightAndActiveTargetsAreSuppressed() async {
        let target = DNSProxyTarget(profileID: UUID(), upstream: .fixedCloudflare)
        let gate = AsyncGate()
        let validator = FakeUpstreamValidator { await gate.wait() }
        let manager = FakeDNSProxyManager(isEnabled: false)
        let controller = makeController(
            manager: manager,
            validator: validator,
            statusProvider: readyStatusFollowingManager(manager)
        )
        _ = await controller.synchronizeState()
        let first = Task { await controller.activate(target) }
        await waitUntilValidationStarts(validator)

        _ = await controller.activate(target)
        await gate.open()
        _ = await first.value
        _ = await controller.activate(target)

        #expect(await validator.validationCount == 1)
        #expect(await manager.enableSaveCount == 1)
        #expect(await manager.disableSaveCount == 0)
    }

    @Test func selectingOldActiveDuringSwitchQueuesACompensatingSwitch() async throws {
        let oldTarget = DNSProxyTarget(profileID: UUID(), upstream: .fixedCloudflare)
        let old = try configuration(
            profileID: oldTarget.profileID,
            upstream: oldTarget.upstream
        )
        let target = try plainTarget()
        let gate = AsyncGate()
        let validator = FakeUpstreamValidator { await gate.wait() }
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: old)
        let controller = makeController(
            manager: manager,
            validator: validator,
            statusProvider: readyStatusFollowingManager(manager)
        )
        _ = await controller.synchronizeState()
        let first = Task { await controller.activate(target) }
        await waitUntilValidationStarts(validator)

        _ = await controller.activate(oldTarget)
        await gate.open()
        _ = await first.value

        let replacementCount = await manager.events.count(where: { event in
            if case .replace = event { return true }
            return false
        })
        let result = await controller.controllerSnapshot()
        #expect(replacementCount == 2)
        #expect(await manager.disableSaveCount == 0)
        #expect(result.activeProfileID == oldTarget.profileID)
        #expect(result.targetProfileID == nil)
        #expect(result.lastSwitchFailure == nil)
    }

    @Test func selectingActiveAfterFailedSwitchClearsFailureWithoutWriting() async throws {
        let oldTarget = DNSProxyTarget(profileID: UUID(), upstream: .fixedCloudflare)
        let old = try configuration(
            profileID: oldTarget.profileID,
            upstream: oldTarget.upstream
        )
        let rejected = try plainTarget()
        let manager = FakeDNSProxyManager(isEnabled: true, activeConfiguration: old)
        let validator = FakeUpstreamValidator { throw FakeTestError.unavailable }
        let controller = makeController(
            manager: manager,
            validator: validator,
            statusProvider: readyStatusFollowingManager(manager)
        )
        _ = await controller.synchronizeState()

        let failed = await controller.activate(rejected)
        #expect(failed.lastSwitchFailure != nil)
        let eventCount = await manager.events.count

        let cleared = await controller.activate(oldTarget)

        #expect(cleared.activeProfileID == oldTarget.profileID)
        #expect(cleared.targetProfileID == nil)
        #expect(cleared.lastSwitchFailure == nil)
        #expect(await manager.events.count == eventCount)
    }

    @Test func terminationDuringPreflightDropsPendingAndPreventsEnable() async throws {
        let targetA = DNSProxyTarget(profileID: UUID(), upstream: .fixedCloudflare)
        let targetB = try plainTarget()
        let validator = FakeUpstreamValidator {
            try await Task.sleep(for: .seconds(30))
        }
        let manager = FakeDNSProxyManager(isEnabled: false)
        let controller = makeController(manager: manager, validator: validator)
        let first = Task { await controller.activate(targetA) }
        await waitUntilValidationStarts(validator)
        _ = await controller.activate(targetB)

        #expect(await controller.restoreSystemDNSForTermination() == .disabled)
        _ = await first.value

        #expect(await manager.enableSaveCount == 0)
        #expect(await controller.activate(targetB).state == .disabled)
    }

    @Test func terminationDuringReadinessDropsPendingAndDisablesTarget() async throws {
        let targetA = DNSProxyTarget(profileID: UUID(), upstream: .fixedCloudflare)
        let targetB = try plainTarget()
        let manager = FakeDNSProxyManager(isEnabled: false)
        let status = FakeRuntimeStatusProvider {
            if await managerConfigurationIsAbsent(manager) {
                return .idle()
            }
            try await Task.sleep(for: .seconds(30))
            return .idle()
        }
        let controller = makeController(manager: manager, statusProvider: status)
        let first = Task { await controller.activate(targetA) }
        while await manager.enableSaveCount == 0 {
            await Task.yield()
        }
        while await status.requestCount < 2 {
            await Task.yield()
        }
        _ = await controller.activate(targetB)

        expectRecoveryRequired(await controller.restoreSystemDNSForTermination())
        _ = await first.value

        let enabledProfiles = await manager.events.compactMap { event -> UUID? in
            guard case let .enable(_, profileID) = event else { return nil }
            return profileID
        }
        #expect(enabledProfiles == [targetA.profileID])
        #expect(await manager.currentSnapshot.isEnabled == false)
        expectRecoveryRequired(await controller.activate(targetB).state)
    }
}

@MainActor
private final class ProxyPresentationRecorder {
    var revisions: [UInt64] = []
    var snapshots: [ProxyControllerSnapshot] = []
    var states: [DNSProxyControllerState] = []
}

private func configuration(
    profileID: UUID,
    upstream: DNSUpstream
) throws -> ActiveProxyConfiguration {
    try ActiveProxyConfiguration(
        generation: UUID(),
        profileID: profileID,
        upstream: upstream
    )
}

private func plainTarget() throws -> DNSProxyTarget {
    DNSProxyTarget(
        profileID: UUID(),
        upstream: .plain(try PlainDNSConfiguration(serverAddress: IPAddress("1.1.1.1")))
    )
}

private func httpsTarget(endpoint: String) throws -> DNSProxyTarget {
    let url = try #require(URL(string: endpoint))
    return DNSProxyTarget(
        profileID: UUID(),
        upstream: .https(try DoHConfiguration(
            endpointURL: url,
            bootstrapServers: [try IPAddress("223.5.5.5")]
        ))
    )
}

private func readyStatusFollowingManager(
    _ manager: FakeDNSProxyManager
) -> FakeRuntimeStatusProvider {
    let providerInstanceID = UUID()
    return FakeRuntimeStatusProvider {
        guard let persisted = await manager.currentSnapshot.persistedConfiguration else {
            return .idle()
        }
        return runtimeStatus(
            generation: persisted.value.generation,
            phase: .ready,
            runtimeControlProtocolVersion: DNSProxyXPCContract
                .currentRuntimeControlProtocolVersion,
            providerInstanceID: providerInstanceID,
            configurationFingerprint: persisted.fingerprint
        )
    }
}

private func managerConfigurationIsAbsent(_ manager: FakeDNSProxyManager) async -> Bool {
    await manager.currentSnapshot.activeConfiguration == nil
}

private func waitUntilValidationStarts(_ validator: FakeUpstreamValidator) async {
    while await validator.validationCount == 0 {
        await Task.yield()
    }
}

private actor FailFirstValidation {
    private var shouldFail = true

    func run() throws {
        if shouldFail {
            shouldFail = false
            throw FakeTestError.unavailable
        }
    }
}

private actor FailFirstRuntimeStatus {
    private var shouldFail = true

    func checkAvailability() throws {
        if shouldFail {
            shouldFail = false
            throw FakeTestError.unavailable
        }
    }
}
