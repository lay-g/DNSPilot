import Foundation
import Testing
@testable import DNSPilot

struct DNSProxyControllerTests {
    @Test func profileDeletionLeaseSerializesDeletionChecks() async throws {
        let controller = makeController(
            manager: FakeDNSProxyManager(isEnabled: false),
            statusProvider: FakeRuntimeStatusProvider { .idle() },
            runtimeController: FakeRuntimeController { _ in throw FakeTestError.unavailable }
        )
        let profileID = UUID()

        let first = try #require(await controller.acquireProfileDeletionLease(
            deleting: profileID
        ))
        #expect(await controller.acquireProfileDeletionLease(deleting: profileID) == nil)

        await controller.releaseProfileDeletionLease(first)
        #expect(await controller.acquireProfileDeletionLease(deleting: profileID) != nil)
    }

    @Test func switchFailureDiagnosticSummaryIncludesStructuredCause() {
        let failure = ProxySwitchFailure(
            code: .targetProviderFailed,
            targetProfileID: UUID(),
            activeProfileID: UUID(),
            providerErrorCode: .engineInitializationFailed,
            message: "The target provider failed."
        )

        #expect(
            failure.diagnosticSummary
                == "targetProviderFailed | provider=engineInitializationFailed | The target provider failed."
        )
    }

    @Test func startupReportsDisabledWithoutReadingRuntimeStatus() async {
        let manager = FakeDNSProxyManager(isEnabled: false)
        let status = FakeRuntimeStatusProvider { .idle() }
        let runtime = FakeRuntimeController { _ in
            throw FakeTestError.unavailable
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            runtimeController: runtime
        )

        #expect(await controller.synchronizeState() == .disabled)
        #expect(await status.requestCount == 0)
        #expect(await runtime.requests.isEmpty)
    }

    @Test func startupConfirmsMatchingReadyGeneration() async throws {
        let configuration = try makeConfiguration()
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: configuration
        )
        let persisted = try PersistedProxyConfiguration(value: configuration)
        let providerInstanceID = UUID()
        let status = FakeRuntimeStatusProvider {
            runtimeStatus(
                generation: configuration.generation,
                phase: .ready,
                runtimeControlProtocolVersion: DNSProxyXPCContract
                    .currentRuntimeControlProtocolVersion,
                providerInstanceID: providerInstanceID,
                configurationFingerprint: persisted.fingerprint
            )
        }
        let runtime = FakeRuntimeController { _ in
            throw FakeTestError.unavailable
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            runtimeController: runtime
        )

        #expect(await controller.synchronizeState() == .active(configuration.generation))
        #expect(await runtime.requests.isEmpty)
    }

    @Test func startupAcceptsExactReadyReadOnlyIdentityWithoutWrite() async throws {
        let configuration = try makeConfiguration()
        let persisted = try PersistedProxyConfiguration(value: configuration)
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: configuration
        )
        let status = FakeRuntimeStatusProvider {
            runtimeStatus(
                generation: configuration.generation,
                phase: .ready,
                runtimeControlProtocolVersion: DNSProxyXPCContract
                    .readOnlyIdentityProtocolVersion,
                providerInstanceID: UUID(),
                configurationFingerprint: persisted.fingerprint
            )
        }
        let runtime = FakeRuntimeController { _ in
            throw FakeTestError.unavailable
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            runtimeController: runtime
        )

        #expect(await controller.synchronizeState() == .active(configuration.generation))
        #expect(await runtime.requests.isEmpty)
    }

    @Test func startupReappliesManagerExactDesiredToCompatibleReadyRuntime() async throws {
        let providerInstanceID = UUID()
        let base = try PersistedProxyConfiguration(value: makeConfiguration())
        let target = try PersistedProxyConfiguration(value: makeConfiguration())
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: target.value
        )
        let status = ScriptedRuntimeStatusProvider([
            runtimeStatus(
                generation: base.value.generation,
                phase: .ready,
                runtimeControlProtocolVersion: DNSProxyXPCContract
                    .currentRuntimeControlProtocolVersion,
                providerInstanceID: providerInstanceID,
                configurationFingerprint: base.fingerprint
            ),
            runtimeStatus(
                generation: target.value.generation,
                phase: .ready,
                runtimeControlProtocolVersion: DNSProxyXPCContract
                    .currentRuntimeControlProtocolVersion,
                providerInstanceID: providerInstanceID,
                configurationFingerprint: target.fingerprint
            ),
        ])
        let runtime = FakeRuntimeController { request in
            ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .applied,
                providerInstanceID: providerInstanceID,
                activeGeneration: target.value.generation,
                activeFingerprint: target.fingerprint
            )
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            runtimeController: runtime
        )

        #expect(await controller.synchronizeState() == .active(target.value.generation))
        let request = try #require(await runtime.requests.first)
        #expect(request.expectedProviderInstanceID == providerInstanceID)
        #expect(request.expectedBaseGeneration == base.value.generation)
        #expect(request.expectedBaseFingerprint == base.fingerprint)
        #expect(request.targetConfigurationData == target.data)
        #expect(request.targetFingerprint == target.fingerprint)
        #expect(await manager.events.contains(where: {
            if case .replace = $0 { return true }
            return false
        }) == false)
    }

    @Test func startupLegacyRuntimeFailsClosedWithoutWrite() async throws {
        let target = try makeConfiguration()
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: target
        )
        let status = FakeRuntimeStatusProvider {
            runtimeStatus(generation: UUID(), phase: .ready)
        }
        let runtime = FakeRuntimeController { _ in
            throw FakeTestError.unavailable
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            runtimeController: runtime
        )

        expectRecoveryRequired(await controller.synchronizeState())
        #expect(await runtime.requests.isEmpty)
    }

    @Test func startupRefusesManagerOwnedByAnotherProvider() async throws {
        let configuration = try makeConfiguration()
        let persisted = try PersistedProxyConfiguration(value: configuration)
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: configuration
        )
        await manager.replaceOwnerIdentity(DNSProxyManagerOwnerIdentity(
            providerBundleIdentifier: "com.example.ForeignProxy",
            providerConfigurationFingerprint: persisted.fingerprint,
            localizedDescription: "Foreign Proxy"
        ))
        let status = FakeRuntimeStatusProvider {
            runtimeStatus(
                generation: configuration.generation,
                phase: .ready,
                runtimeControlProtocolVersion: DNSProxyXPCContract
                    .currentRuntimeControlProtocolVersion,
                providerInstanceID: UUID(),
                configurationFingerprint: persisted.fingerprint
            )
        }
        let runtime = FakeRuntimeController { _ in
            throw FakeTestError.unavailable
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            runtimeController: runtime
        )

        expectRecoveryRequired(await controller.synchronizeState())
        #expect(await status.requestCount == 0)
        #expect(await runtime.requests.isEmpty)
    }

    @Test func startupRollbackResponseRestoresManagerExactBase() async throws {
        let providerInstanceID = UUID()
        let base = try PersistedProxyConfiguration(value: makeConfiguration())
        let target = try PersistedProxyConfiguration(value: makeConfiguration())
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: target.value
        )
        let status = ScriptedRuntimeStatusProvider([
            runtimeStatus(
                generation: base.value.generation,
                phase: .ready,
                runtimeControlProtocolVersion: 3,
                providerInstanceID: providerInstanceID,
                configurationFingerprint: base.fingerprint
            ),
            runtimeStatus(
                generation: base.value.generation,
                phase: .ready,
                runtimeControlProtocolVersion: 3,
                providerInstanceID: providerInstanceID,
                configurationFingerprint: base.fingerprint
            ),
        ])
        let runtime = FakeRuntimeController { request in
            ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .rejectedPreservingBase,
                providerInstanceID: providerInstanceID,
                activeGeneration: base.value.generation,
                activeFingerprint: base.fingerprint,
                preservedConfigurationData: base.data
            )
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            runtimeController: runtime
        )

        guard case .degraded = await controller.synchronizeState() else {
            Issue.record("Expected degraded state after startup rollback")
            return
        }
        #expect(await manager.currentSnapshot.persistedConfiguration == base)
        #expect(await controller.controllerSnapshot().activeGeneration == base.value.generation)
    }

    @Test func startupUnrecoverableRuntimeDisablesExactDesiredManager() async throws {
        let base = try PersistedProxyConfiguration(value: makeConfiguration())
        let target = try PersistedProxyConfiguration(value: makeConfiguration())
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: target.value
        )
        let runtime = FakeRuntimeSession(
            activeConfiguration: base,
            outcomes: [.unrecoverable]
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )

        guard case .degraded = await controller.synchronizeState() else {
            Issue.record("Expected degraded state after startup lifecycle repair")
            return
        }
        #expect(await manager.currentSnapshot.isEnabled == false)
        #expect(await manager.currentSnapshot.persistedConfiguration == target)
        #expect(await manager.disableSaveCount == 1)
    }

    @Test func startupManagerRollbackFailureRequiresRecovery() async throws {
        let providerInstanceID = UUID()
        let base = try PersistedProxyConfiguration(value: makeConfiguration())
        let target = try PersistedProxyConfiguration(value: makeConfiguration())
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: target.value,
            replaceFailures: [.saveFailed]
        )
        let status = FakeRuntimeStatusProvider {
            runtimeStatus(
                generation: base.value.generation,
                phase: .ready,
                runtimeControlProtocolVersion: 3,
                providerInstanceID: providerInstanceID,
                configurationFingerprint: base.fingerprint
            )
        }
        let runtime = FakeRuntimeController { request in
            ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .rejectedPreservingBase,
                providerInstanceID: providerInstanceID,
                activeGeneration: base.value.generation,
                activeFingerprint: base.fingerprint,
                preservedConfigurationData: base.data
            )
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            runtimeController: runtime
        )

        expectRecoveryRequired(await controller.synchronizeState())
        #expect(await manager.currentSnapshot.persistedConfiguration == target)
    }

    @Test func startupRollbackRefusesOwnerChangedAfterInitialLoad() async throws {
        let providerInstanceID = UUID()
        let base = try PersistedProxyConfiguration(value: makeConfiguration())
        let target = try PersistedProxyConfiguration(value: makeConfiguration())
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: target.value
        )
        let status = FakeRuntimeStatusProvider {
            runtimeStatus(
                generation: base.value.generation,
                phase: .ready,
                runtimeControlProtocolVersion: 3,
                providerInstanceID: providerInstanceID,
                configurationFingerprint: base.fingerprint
            )
        }
        let runtime = FakeRuntimeController { request in
            await manager.replaceOwnerIdentity(DNSProxyManagerOwnerIdentity(
                providerBundleIdentifier: "com.example.DNSProxy",
                providerConfigurationFingerprint: ProxyConfigurationFingerprint(
                    data: Data("changed-owner-fields".utf8)
                ),
                localizedDescription: "Changed"
            ))
            return ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .rejectedPreservingBase,
                providerInstanceID: providerInstanceID,
                activeGeneration: base.value.generation,
                activeFingerprint: base.fingerprint,
                preservedConfigurationData: base.data
            )
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            runtimeController: runtime
        )

        expectRecoveryRequired(await controller.synchronizeState())
        #expect(await manager.currentSnapshot.persistedConfiguration == target)
    }

    @Test func startupRequiresRecoveryWhenGenerationCannotBeConfirmed() async throws {
        let configuration = try makeConfiguration()
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: configuration
        )
        let status = FakeRuntimeStatusProvider { throw FakeTestError.unavailable }
        let controller = makeController(manager: manager, statusProvider: status)

        expectRecoveryRequired(await controller.synchronizeState())
        #expect(await manager.enableSaveCount == 0)
        #expect(await manager.disableSaveCount == 0)
    }

    @Test func enableDoesNotPreflightOrWriteWhenManagerIsAlreadyEnabled() async throws {
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: try makeConfiguration()
        )
        let validator = FakeUpstreamValidator()
        let controller = makeController(manager: manager, validator: validator)

        expectRecoveryRequired(await controller.enableConfiguredDoH())
        #expect(await validator.validationCount == 0)
        #expect(await manager.enableSaveCount == 0)
    }

    @Test func enableRequiresRecoveryWhenInitialManagerLoadFails() async {
        let manager = FakeDNSProxyManager(
            isEnabled: false,
            loadFailures: [.saveFailed]
        )
        let validator = FakeUpstreamValidator()
        let controller = makeController(manager: manager, validator: validator)

        expectRecoveryRequired(await controller.enableConfiguredDoH())
        #expect(await validator.validationCount == 0)
        #expect(await manager.enableSaveCount == 0)
    }

    @Test func enableDoesNotOverwriteManagerEnabledDuringPreflight() async throws {
        let manager = FakeDNSProxyManager(isEnabled: false)
        let externalConfiguration = try makeConfiguration()
        let validator = FakeUpstreamValidator {
            await manager.replaceState(
                isEnabled: true,
                activeConfiguration: externalConfiguration
            )
        }
        let controller = makeController(manager: manager, validator: validator)

        expectRecoveryRequired(await controller.enableConfiguredDoH())
        #expect(await manager.enableSaveCount == 0)
        #expect(await manager.currentSnapshot.activeConfiguration == externalConfiguration)
    }

    @Test func enableRetriesOneStaleSaveAndReachesReady() async {
        let manager = FakeDNSProxyManager(
            isEnabled: false,
            enableFailures: [.configurationStale]
        )
        let status = FakeRuntimeStatusProvider {
            let persisted = try #require(
                await manager.currentSnapshot.persistedConfiguration
            )
            return exactReadyStatus(persisted)
        }
        let controller = makeController(manager: manager, statusProvider: status)

        let result = await controller.enableConfiguredDoH()

        guard case .active = result else {
            Issue.record("Expected active after one stale save retry, got \(result)")
            return
        }
        #expect(await manager.enableSaveCount == 2)
        #expect(await manager.loadCount == 4)
    }

    @Test func enablePersistsConfiguredDebugLoggingMode() async {
        let manager = FakeDNSProxyManager(isEnabled: false)
        let status = FakeRuntimeStatusProvider {
            let persisted = try #require(
                await manager.currentSnapshot.persistedConfiguration
            )
            return exactReadyStatus(persisted)
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            loggingMode: .debug
        )

        guard case .active = await controller.enableConfiguredDoH() else {
            Issue.record("Expected active DNS Proxy state")
            return
        }
        #expect(await manager.currentSnapshot.activeConfiguration?.loggingMode == .debug)
    }

    @Test func enableValidatesAndPersistsConfiguredUpstream() async throws {
        let endpoint = try #require(URL(string: "https://dns.alidns.com/dns-query"))
        let upstream = DNSUpstream.https(try DoHConfiguration(
            endpointURL: endpoint,
            bootstrapServers: [IPAddress("223.5.5.5"), IPAddress("223.6.6.6")]
        ))
        let manager = FakeDNSProxyManager(isEnabled: false)
        let validator = FakeUpstreamValidator()
        let status = FakeRuntimeStatusProvider {
            let persisted = try #require(
                await manager.currentSnapshot.persistedConfiguration
            )
            return exactReadyStatus(persisted)
        }
        let controller = makeController(
            manager: manager,
            validator: validator,
            statusProvider: status,
            upstream: upstream
        )

        guard case .active = await controller.enableConfiguredDoH() else {
            Issue.record("Expected active DNS Proxy state")
            return
        }
        #expect(await validator.validatedUpstream == upstream)
        #expect(await manager.currentSnapshot.activeConfiguration?.upstream == upstream)
    }

    @Test func staleEnableRetryPreservesConfigurationEnabledByAnotherProcess() async throws {
        let externalConfiguration = try makeConfiguration()
        let manager = FakeDNSProxyManager(
            isEnabled: false,
            enableFailures: [.configurationStaleReplacing(externalConfiguration)]
        )
        let controller = makeController(manager: manager)

        expectRecoveryRequired(await controller.enableConfiguredDoH())
        #expect(await manager.enableSaveCount == 1)
        #expect(await manager.currentSnapshot.activeConfiguration == externalConfiguration)
    }

    @Test func providerFailureDisablesManagerAndReportsFailure() async {
        let manager = FakeDNSProxyManager(isEnabled: false)
        let status = FakeRuntimeStatusProvider {
            let generation = try #require(await manager.currentSnapshot.activeConfiguration?.generation)
            return runtimeStatus(
                generation: generation,
                phase: .failed,
                errorCode: .engineInitializationFailed
            )
        }
        let controller = makeController(manager: manager, statusProvider: status)

        let result = await controller.enableConfiguredDoH()

        guard case let .failed(message) = result else {
            Issue.record("Expected provider failure, got \(result)")
            return
        }
        #expect(message.contains(ProxyRuntimeErrorCode.engineInitializationFailed.rawValue))
        #expect(await manager.currentSnapshot.isEnabled == false)
        #expect(await manager.disableSaveCount == 1)
    }

    @Test func repeatedStaleEnableFailureRequiresRecovery() async {
        let manager = FakeDNSProxyManager(
            isEnabled: false,
            enableFailures: [.configurationStale, .configurationStale]
        )
        let controller = makeController(manager: manager)

        expectRecoveryRequired(await controller.enableConfiguredDoH())
        #expect(await manager.enableSaveCount == 2)
        #expect(await manager.loadCount == 3)
        #expect(await manager.currentSnapshot.isEnabled == false)
    }

    @Test func readinessTimeoutDisablesManager() async {
        let manager = FakeDNSProxyManager(isEnabled: false)
        let cancellation = CancellationProbe()
        let status = FakeRuntimeStatusProvider {
            do {
                try await Task.sleep(for: .seconds(30))
                throw FakeTestError.unavailable
            } catch is CancellationError {
                await cancellation.recordCancellation()
                throw CancellationError()
            }
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            readinessTimeout: .milliseconds(20),
            pollInterval: .milliseconds(2)
        )

        let result = await controller.enableConfiguredDoH()

        guard case let .failed(message) = result else {
            Issue.record("Expected readiness timeout, got \(result)")
            return
        }
        #expect(message.contains("five seconds"))
        #expect(await manager.currentSnapshot.isEnabled == false)
        let statusRequestCount = await status.requestCount
        let requestDidNotOutliveDeadline = if statusRequestCount == 0 {
            true
        } else {
            await cancellation.waitUntilCancelled()
        }
        #expect(requestDidNotOutliveDeadline)
    }

    @Test func generationOnlyReadyStatusDoesNotSatisfyReadiness() async {
        let manager = FakeDNSProxyManager(isEnabled: false)
        let status = FakeRuntimeStatusProvider {
            let generation = try #require(
                await manager.currentSnapshot.activeConfiguration?.generation
            )
            return runtimeStatus(generation: generation, phase: .ready)
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            readinessTimeout: .milliseconds(20),
            pollInterval: .milliseconds(2)
        )

        guard case .failed = await controller.enableConfiguredDoH() else {
            Issue.record("Expected incomplete runtime identity to time out")
            return
        }
        #expect(await manager.currentSnapshot.isEnabled == false)
        #expect(await manager.disableSaveCount == 1)
    }

    @Test func rollbackFailureRequiresRecovery() async {
        let manager = FakeDNSProxyManager(
            isEnabled: false,
            disableFailures: [.saveFailed]
        )
        let status = FakeRuntimeStatusProvider { throw FakeTestError.unavailable }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            readinessTimeout: .milliseconds(20),
            pollInterval: .milliseconds(2)
        )

        let result = await controller.enableConfiguredDoH()

        expectRecoveryRequired(result)
        #expect(await manager.currentSnapshot.isEnabled)
    }

    @Test func rollbackDoesNotDisableNewerGeneration() async throws {
        let manager = FakeDNSProxyManager(isEnabled: false)
        let replacement = try makeConfiguration()
        let status = FakeRuntimeStatusProvider {
            let originalGeneration = try #require(
                await manager.currentSnapshot.activeConfiguration?.generation
            )
            await manager.replaceState(
                isEnabled: true,
                activeConfiguration: replacement
            )
            return runtimeStatus(
                generation: originalGeneration,
                phase: .failed,
                errorCode: .engineInitializationFailed
            )
        }
        let controller = makeController(manager: manager, statusProvider: status)

        expectRecoveryRequired(await controller.enableConfiguredDoH())
        #expect(await manager.disableSaveCount == 0)
        #expect(await manager.currentSnapshot.activeConfiguration == replacement)
    }

    @Test func rollbackHonorsGenerationChangeReportedDuringDisableSave() async throws {
        let replacement = try makeConfiguration()
        let manager = FakeDNSProxyManager(
            isEnabled: false,
            disableReplacementBeforeSave: replacement
        )
        let status = FakeRuntimeStatusProvider {
            let originalGeneration = try #require(
                await manager.currentSnapshot.activeConfiguration?.generation
            )
            return runtimeStatus(
                generation: originalGeneration,
                phase: .failed,
                errorCode: .engineInitializationFailed
            )
        }
        let controller = makeController(manager: manager, statusProvider: status)

        expectRecoveryRequired(await controller.enableConfiguredDoH())
        #expect(await manager.disableSaveCount == 1)
        #expect(await manager.currentSnapshot.activeConfiguration == replacement)
    }

    @Test func restoreRetriesOneStaleSave() async {
        let configuration = try? makeConfiguration()
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: configuration,
            disableFailures: [.configurationStale]
        )
        let persisted = configuration.flatMap { try? PersistedProxyConfiguration(value: $0) }
        let runtime = FakeRuntimeSession(activeConfiguration: persisted)
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )

        #expect(await controller.restoreSystemDNS() == .disabled)
        #expect(await manager.disableSaveCount == 2)
        #expect(await manager.loadCount == 2)
        #expect(await runtime.quiesceRequests.count == 1)
    }

    @Test func repeatedStaleRestoreFailureResumesExactRuntime() async throws {
        let configuration = try makeConfiguration()
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: configuration,
            disableFailures: [.configurationStale, .configurationStale]
        )
        let persisted = try PersistedProxyConfiguration(value: configuration)
        let runtime = FakeRuntimeSession(activeConfiguration: persisted)
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )

        #expect(await controller.restoreSystemDNS() == .active(configuration.generation))
        #expect(await manager.disableSaveCount == 2)
        #expect(await manager.currentSnapshot.isEnabled)
        #expect(await runtime.quiesceRequests.count == 1)
        #expect(await runtime.resumeRequests.count == 1)
    }

    @Test func ordinaryRestoreSaveFailureResumesExactRuntime() async throws {
        let configuration = try makeConfiguration()
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: configuration,
            disableFailures: [.saveFailed]
        )
        let persisted = try PersistedProxyConfiguration(value: configuration)
        let runtime = FakeRuntimeSession(activeConfiguration: persisted)
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )

        #expect(await controller.restoreSystemDNS() == .active(configuration.generation))
        #expect(await manager.disableSaveCount == 1)
        #expect(await manager.currentSnapshot.isEnabled)
        #expect(await runtime.resumeRequests.count == 1)
    }

    @Test func disabledManagerRemainsQuarantinedUntilExactQuiescenceReplay() async throws {
        let configuration = try makeConfiguration()
        let persisted = try PersistedProxyConfiguration(value: configuration)
        let providerInstanceID = UUID()
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: configuration
        )
        let status = FakeRuntimeStatusProvider {
            runtimeStatus(
                generation: configuration.generation,
                phase: .ready,
                runtimeControlProtocolVersion: DNSProxyXPCContract
                    .currentRuntimeControlProtocolVersion,
                providerInstanceID: providerInstanceID,
                configurationFingerprint: persisted.fingerprint
            )
        }
        let availability = QuiescenceAvailability()
        let runtime = FakeRuntimeController(
            response: { _ in throw FakeTestError.unavailable },
            quiesceResponse: { request in
                try await availability.response(for: request)
            }
        )
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            runtimeController: runtime,
            rollbackTimeout: .seconds(1),
            pollInterval: .milliseconds(5)
        )

        expectRecoveryRequired(await controller.restoreSystemDNS())
        #expect(await manager.currentSnapshot.isEnabled == false)
        let firstAttemptCount = await runtime.quiesceRequests.count
        #expect(firstAttemptCount > 0)

        expectRecoveryRequired(await controller.synchronizeState())
        #expect(await runtime.quiesceRequests.count == firstAttemptCount)
        expectRecoveryRequired(await controller.restoreSystemDNS())
        let unresolvedRequests = await runtime.quiesceRequests
        #expect(unresolvedRequests.count > firstAttemptCount)
        #expect(Set(unresolvedRequests.map(\.operationID)).count == 1)

        await availability.allow()
        #expect(await controller.restoreSystemDNS() == .disabled)
        let resolvedRequests = await runtime.quiesceRequests
        #expect(Set(resolvedRequests.map(\.operationID)).count == 1)
    }

    @Test func ownerChangeAfterPreResumeCheckNeverPublishesActive() async throws {
        let configuration = try makeConfiguration()
        let persisted = try PersistedProxyConfiguration(value: configuration)
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: configuration,
            disableFailures: [.saveFailed]
        )
        let changedOwner = DNSProxyManagerOwnerIdentity(
            providerBundleIdentifier: "com.example.DNSProxy",
            providerConfigurationFingerprint: ProxyConfigurationFingerprint(
                data: Data("changed-after-resume-fence".utf8)
            ),
            localizedDescription: "Changed owner"
        )
        let runtime = FakeRuntimeSession(
            activeConfiguration: persisted,
            beforeResume: { _ in
                await manager.replaceOwnerIdentity(changedOwner)
            }
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )

        #expect(await controller.synchronizeState() == .active(configuration.generation))
        expectRecoveryRequired(await controller.restoreSystemDNS())
        #expect(await manager.currentSnapshot.ownerIdentity == changedOwner)
        #expect(await runtime.resumeRequests.count == 1)
        #expect(await runtime.quiesceRequests.count == 2)
        #expect(await runtime.runtimeStatus().phase == .idle)
        #expect(await controller.controllerSnapshot().activeGeneration == nil)
    }

    @Test func quarantineCannotClearAfterManagerOwnerChangesDuringProof() async throws {
        let configuration = try makeConfiguration()
        let replacement = try makeConfiguration()
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: configuration
        )
        let persisted = try PersistedProxyConfiguration(value: configuration)
        let providerInstanceID = UUID()
        let status = FakeRuntimeStatusProvider {
            runtimeStatus(
                generation: configuration.generation,
                phase: .ready,
                runtimeControlProtocolVersion: DNSProxyXPCContract
                    .currentRuntimeControlProtocolVersion,
                providerInstanceID: providerInstanceID,
                configurationFingerprint: persisted.fingerprint
            )
        }
        let script = QuarantineQuiesceScript(
            manager: manager,
            replacement: replacement
        )
        let runtime = FakeRuntimeController(
            response: { _ in throw FakeTestError.unavailable },
            quiesceResponse: { request in
                try await script.response(for: request)
            }
        )
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            runtimeController: runtime,
            rollbackTimeout: .seconds(1)
        )

        expectRecoveryRequired(await controller.restoreSystemDNS())
        #expect(await manager.currentSnapshot.isEnabled == false)

        await script.allowOwnerChange()
        expectRecoveryRequired(await controller.restoreSystemDNS())
        #expect(await manager.currentSnapshot.isEnabled)
        #expect(await manager.currentSnapshot.activeConfiguration == replacement)
        #expect(await controller.controllerSnapshot().activeGeneration == nil)
    }

    @Test func terminationWaitForPendingManagerCallIsBounded() async throws {
        let configuration = try makeConfiguration()
        let disableGate = AsyncGate()
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: configuration,
            beforeDisableSave: { _ in await disableGate.wait() }
        )
        let runtime = FakeRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: configuration)
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime,
            rollbackTimeout: .seconds(1)
        )

        expectRecoveryRequired(await controller.restoreSystemDNSForTermination())
        let clock = ContinuousClock()
        let started = clock.now
        expectRecoveryRequired(await controller.restoreSystemDNSForTermination())
        #expect(started.duration(to: clock.now) < .seconds(2))

        await disableGate.open()
    }

    @Test func cancelAfterWaitingForOrdinaryOperationClearsTerminationFence() async throws {
        let enableGate = AsyncGate()
        let manager = FakeDNSProxyManager(
            isEnabled: false,
            beforeEnableSave: { _ in await enableGate.wait() }
        )
        let providerInstanceID = UUID()
        let status = FakeRuntimeStatusProvider {
            let snapshot = await manager.currentSnapshot
            guard let active = snapshot.persistedConfiguration else {
                return .idle(
                    runtimeControlProtocolVersion: DNSProxyXPCContract
                        .currentRuntimeControlProtocolVersion,
                    providerInstanceID: providerInstanceID
                )
            }
            return runtimeStatus(
                generation: active.value.generation,
                phase: .ready,
                runtimeControlProtocolVersion: DNSProxyXPCContract
                    .currentRuntimeControlProtocolVersion,
                providerInstanceID: providerInstanceID,
                configurationFingerprint: active.fingerprint
            )
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            rollbackTimeout: .seconds(1)
        )
        let enableTask = Task { await controller.enableConfiguredDoH() }
        while await manager.enableSaveCount == 0 {
            await Task.yield()
        }

        expectRecoveryRequired(await controller.restoreSystemDNSForTermination())
        await controller.cancelTerminationRequest()
        await enableGate.open()
        _ = await enableTask.value

        _ = await controller.restoreSystemDNS()
        #expect(await manager.currentSnapshot.isEnabled == false)
    }

    @Test func uncertainRestoreSaveDoesNotResumeUntilManagerCallFinishes() async throws {
        let configuration = try makeConfiguration()
        let disableGate = AsyncGate()
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: configuration,
            beforeDisableSave: { _ in await disableGate.wait() }
        )
        let runtime = FakeRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: configuration)
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime,
            rollbackTimeout: .seconds(1)
        )

        expectRecoveryRequired(await controller.restoreSystemDNS())
        #expect(await manager.currentSnapshot.isEnabled)
        #expect(await runtime.quiesceRequests.count == 1)
        #expect(await runtime.resumeRequests.isEmpty)

        await disableGate.open()
        while await manager.currentSnapshot.isEnabled {
            await Task.yield()
        }
        #expect(await controller.synchronizeState() == .disabled)
    }

    @Test func terminationRestoreCancelsPreflightAndPreventsEnable() async {
        let manager = FakeDNSProxyManager(isEnabled: false)
        let validator = FakeUpstreamValidator {
            try await Task.sleep(for: .seconds(30))
        }
        let controller = makeController(manager: manager, validator: validator)
        let enableTask = Task { await controller.enableConfiguredDoH() }

        while await validator.validationCount == 0 {
            await Task.yield()
        }

        #expect(await controller.restoreSystemDNSForTermination() == .disabled)
        _ = await enableTask.value
        #expect(await manager.enableSaveCount == 0)
        #expect(await controller.enableConfiguredDoH() == .disabled)
    }

    @Test func terminationRestoreCancelsStartupRuntimeControl() async throws {
        let providerInstanceID = UUID()
        let base = try PersistedProxyConfiguration(value: makeConfiguration())
        let desired = try PersistedProxyConfiguration(value: makeConfiguration())
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: desired.value
        )
        let status = FakeRuntimeStatusProvider {
            runtimeStatus(
                generation: base.value.generation,
                phase: .ready,
                runtimeControlProtocolVersion: DNSProxyXPCContract
                    .currentRuntimeControlProtocolVersion,
                providerInstanceID: providerInstanceID,
                configurationFingerprint: base.fingerprint
            )
        }
        let cancellation = CancellationProbe()
        let runtime = FakeRuntimeController { request in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                await cancellation.recordCancellation()
                throw CancellationError()
            }
            return ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .applied,
                providerInstanceID: providerInstanceID,
                activeGeneration: desired.value.generation,
                activeFingerprint: desired.fingerprint
            )
        }
        let controller = makeController(
            manager: manager,
            statusProvider: status,
            runtimeController: runtime
        )
        let synchronizeTask = Task { await controller.synchronizeState() }
        while await runtime.requests.isEmpty {
            await Task.yield()
        }

        #expect(await controller.restoreSystemDNSForTermination() == .disabled)
        _ = await synchronizeTask.value
        #expect(await cancellation.waitUntilCancelled())
        #expect(await manager.disableSaveCount == 1)
    }

    @Test func terminationRestoreConfirmsDisabledManager() async throws {
        let configuration = try makeConfiguration()
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: configuration
        )
        let runtime = FakeRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: configuration)
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )

        #expect(await controller.restoreSystemDNSForTermination() == .disabled)
        #expect(await manager.disableSaveCount == 1)
        #expect(await manager.loadCount == 2)
        #expect(await runtime.quiesceRequests.count == 1)
    }

    @Test func terminationRestoreRequiresRecoveryWhenFinalLoadIsEnabled() async throws {
        let configuration = try makeConfiguration()
        let replacement = try makeConfiguration()
        let manager = FakeDNSProxyManager(
            isEnabled: true,
            activeConfiguration: configuration,
            reenableAfterDisableSave: replacement
        )
        let runtime = FakeRuntimeSession(
            activeConfiguration: try PersistedProxyConfiguration(value: configuration)
        )
        let controller = makeController(
            manager: manager,
            statusProvider: runtime,
            runtimeController: runtime
        )

        expectRecoveryRequired(await controller.restoreSystemDNSForTermination())
        #expect(await manager.currentSnapshot.activeConfiguration == replacement)
        #expect(await runtime.resumeRequests.isEmpty)
    }
}

private actor QuarantineQuiesceScript {
    private let manager: FakeDNSProxyManager
    private let replacement: ActiveProxyConfiguration
    private var ownerChangeAllowed = false

    init(
        manager: FakeDNSProxyManager,
        replacement: ActiveProxyConfiguration
    ) {
        self.manager = manager
        self.replacement = replacement
    }

    func response(for request: ProxyLifecycleRequest) async throws
        -> ProxyLifecycleResponse {
        guard ownerChangeAllowed else { throw FakeTestError.unavailable }
        await manager.replaceState(
            isEnabled: true,
            activeConfiguration: replacement
        )
        return ProxyLifecycleResponse(
            operationID: request.operationID,
            disposition: .quiesced,
            providerInstanceID: request.expectedProviderInstanceID,
            generation: request.expectedGeneration,
            fingerprint: request.expectedFingerprint
        )
    }

    func allowOwnerChange() {
        ownerChangeAllowed = true
    }
}

struct DNSRestoreOperationTests {
    @Test func completedOperationIsNotReusableForNewTerminationAttempt() async {
        let operation = DNSRestoreOperation.start { .disabled }

        #expect(await operation.value(timeout: .seconds(1)) == .disabled)
        #expect(operation.reusableForNewTerminationAttempt() == nil)
    }

    @Test func runningOperationCanBeObservedByTheCurrentTerminationAttempt() async {
        let gate = AsyncGate()
        let operation = DNSRestoreOperation.start {
            await gate.wait()
            return .disabled
        }

        #expect(operation.reusableForNewTerminationAttempt() === operation)
        await gate.open()
        #expect(await operation.value(timeout: .seconds(1)) == .disabled)
    }
}

struct DNSProxyManagerFailureInjectorTests {
    @Test func ignoresInjectionWhenBuildDoesNotAllowIt() {
        var injector = DNSProxyManagerFailureInjector(
            allowed: false,
            arguments: injectionArguments("fail-next-disable-save")
        )

        #expect(injector.consume() == nil)
    }

    @Test func consumesImmediateFailureOnlyOnce() {
        var injector = DNSProxyManagerFailureInjector(
            allowed: true,
            arguments: injectionArguments("fail-next-disable-save")
        )

        #expect(injector.consume() == .failNextDisableSave)
        #expect(injector.consume() == nil)
    }

    @Test func consumesSixSecondDelayOnlyOnce() {
        var injector = DNSProxyManagerFailureInjector(
            allowed: true,
            arguments: injectionArguments("delay-next-disable-save")
        )

        #expect(injector.consume() == .delayNextDisableSave(.seconds(6)))
        #expect(injector.consume() == nil)
    }

    @Test func ignoresUnknownOrMissingInjectionValue() {
        var unknown = DNSProxyManagerFailureInjector(
            allowed: true,
            arguments: injectionArguments("unsupported")
        )
        var missing = DNSProxyManagerFailureInjector(
            allowed: true,
            arguments: [DNSProxyManagerFailureInjector.argumentName]
        )

        #expect(unknown.consume() == nil)
        #expect(missing.consume() == nil)
    }
}

private func exactReadyStatus(
    _ configuration: PersistedProxyConfiguration,
    providerInstanceID: UUID = UUID()
) -> ProxyRuntimeStatus {
    runtimeStatus(
        generation: configuration.value.generation,
        phase: .ready,
        runtimeControlProtocolVersion: DNSProxyXPCContract.currentRuntimeControlProtocolVersion,
        providerInstanceID: providerInstanceID,
        configurationFingerprint: configuration.fingerprint
    )
}

private func injectionArguments(_ value: String) -> [String] {
    ["DNSPilotDev", DNSProxyManagerFailureInjector.argumentName, value]
}
