import Foundation
import Synchronization
import Testing
@testable import DNSPilot

struct ProxyLifecycleControllerTests {
    @Test func startUsesExactConfigurationAndPublishesReadyIdentity() throws {
        let configuration = try makeLifecycleConfiguration()
        let service = FakeDNSProxyService()
        let status = FakeRuntimeStatusRecorder()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: status
        )

        try lifecycle.start(configuration: configuration)

        #expect(service.snapshot.startedConfigurations == [configuration])
        #expect(status.events == [
            .update(
                generation: configuration.value.generation,
                fingerprint: configuration.fingerprint,
                phase: .starting,
                errorCode: nil
            ),
            .beginEvidence(configuration.value.generation),
            .update(
                generation: configuration.value.generation,
                fingerprint: configuration.fingerprint,
                phase: .ready,
                errorCode: nil
            ),
        ])
    }

    @Test func duplicateStartIsRejectedBeforeServiceOrStatusSideEffects() throws {
        let configuration = try makeLifecycleConfiguration()
        let service = FakeDNSProxyService()
        let status = FakeRuntimeStatusRecorder()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: status
        )
        try lifecycle.start(configuration: configuration)
        let eventsBeforeDuplicate = status.events

        #expect(throws: ProxyLifecycleError.alreadyStarted) {
            try lifecycle.start(configuration: try makeLifecycleConfiguration())
        }
        #expect(service.snapshot.startedConfigurations == [configuration])
        #expect(status.events == eventsBeforeDuplicate)
    }

    @Test func startFailureStopsAndPublishesFailedWithoutBecomingActive() throws {
        let configuration = try makeLifecycleConfiguration()
        let service = FakeDNSProxyService(startShouldFail: true)
        let status = FakeRuntimeStatusRecorder()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: status
        )

        #expect(throws: ProxyLifecycleError.startFailed("startFailed")) {
            try lifecycle.start(configuration: configuration)
        }
        lifecycle.stop()

        #expect(service.snapshot.stopCount == 1)
        #expect(status.events == [
            .update(
                generation: configuration.value.generation,
                fingerprint: configuration.fingerprint,
                phase: .starting,
                errorCode: nil
            ),
            .beginEvidence(configuration.value.generation),
            .endEvidence(configuration.value.generation),
            .update(
                generation: configuration.value.generation,
                fingerprint: configuration.fingerprint,
                phase: .failed,
                errorCode: .engineInitializationFailed
            ),
        ])
    }

    @Test func reapplyBeforeStartIsRejectedWithoutSideEffects() throws {
        let service = FakeDNSProxyService()
        let status = FakeRuntimeStatusRecorder()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: status
        )

        #expect(throws: ProxyLifecycleError.notStarted) {
            try lifecycle.reapply(configuration: try makeLifecycleConfiguration())
        }

        #expect(service.snapshot.reapplyPlans.isEmpty)
        #expect(status.events.isEmpty)
    }

    @Test func successfulReapplyPublishesTargetOnlyAfterServiceSuccess() throws {
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let service = FakeDNSProxyService()
        let status = FakeRuntimeStatusRecorder()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: status
        )
        try lifecycle.start(configuration: old)

        let outcome = try lifecycle.reapply(configuration: target)

        #expect(outcome == .applied(target))
        #expect(status.events.suffix(4) == [
            .update(
                generation: old.value.generation,
                fingerprint: old.fingerprint,
                phase: .starting,
                errorCode: nil
            ),
            .endEvidence(old.value.generation),
            .beginEvidence(target.value.generation),
            .update(
                generation: target.value.generation,
                fingerprint: target.fingerprint,
                phase: .ready,
                errorCode: nil
            ),
        ])
    }

    @Test func identityOnlyReapplyUsesEmptyScopeAndPublishesExactTarget() throws {
        let profileID = UUID()
        let old = try makeLifecycleConfiguration(profileID: profileID)
        let target = try makeLifecycleConfiguration(profileID: profileID)
        let service = FakeDNSProxyService()
        let status = FakeRuntimeStatusRecorder()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: status
        )
        try lifecycle.start(configuration: old)

        let outcome = try lifecycle.reapply(configuration: target)

        #expect(outcome == .applied(target))
        #expect(service.snapshot.reapplyPlans == [
            DNSProxyReloadPlan(
                target: target,
                scope: [],
                loggingModeChanged: false
            ),
        ])
        #expect(status.events.suffix(4) == [
            .update(
                generation: old.value.generation,
                fingerprint: old.fingerprint,
                phase: .starting,
                errorCode: nil
            ),
            .endEvidence(old.value.generation),
            .beginEvidence(target.value.generation),
            .update(
                generation: target.value.generation,
                fingerprint: target.fingerprint,
                phase: .ready,
                errorCode: nil
            ),
        ])
    }

    @Test func unchangedReapplyFailureKeepsOldReadyIdentity() throws {
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let service = FakeDNSProxyService(reapplySteps: [
            .fail(.unchanged("target rejected")),
        ])
        let status = FakeRuntimeStatusRecorder()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: status
        )
        try lifecycle.start(configuration: old)

        let outcome = try lifecycle.reapply(configuration: target)

        #expect(outcome == .rejectedUnchanged(active: old, reason: "target rejected"))
        #expect(status.events.suffix(2) == [
            .update(
                generation: old.value.generation,
                fingerprint: old.fingerprint,
                phase: .starting,
                errorCode: nil
            ),
            .update(
                generation: old.value.generation,
                fingerprint: old.fingerprint,
                phase: .ready,
                errorCode: nil
            ),
        ])
        #expect(!status.events.contains {
            if case .update(target.value.generation, target.fingerprint, .ready, nil) = $0 {
                return true
            }
            return false
        })
    }

    @Test func rolledBackReapplyRepublishesOnlyOldReadyIdentity() throws {
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let service = FakeDNSProxyService(reapplySteps: [
            .fail(.engineMayHaveMutated("target failed")),
            .succeed,
        ])
        let status = FakeRuntimeStatusRecorder()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: status
        )
        try lifecycle.start(configuration: old)

        let outcome = try lifecycle.reapply(configuration: target)

        #expect(outcome == .rejectedRolledBack(active: old, reason: "target failed"))
        #expect(status.events.suffix(2) == [
            .update(
                generation: old.value.generation,
                fingerprint: old.fingerprint,
                phase: .starting,
                errorCode: nil
            ),
            .update(
                generation: old.value.generation,
                fingerprint: old.fingerprint,
                phase: .ready,
                errorCode: nil
            ),
        ])
    }

    @Test func unrecoverableReapplyStopsAndNeverPublishesTargetReady() throws {
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let service = FakeDNSProxyService(reapplySteps: [
            .fail(.engineMayHaveMutated("target failed")),
            .fail(.engineMayHaveMutated("rollback failed")),
        ])
        let status = FakeRuntimeStatusRecorder()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: status
        )
        try lifecycle.start(configuration: old)

        let outcome = try lifecycle.reapply(configuration: target)

        #expect(outcome == .unrecoverable(
            targetReason: "target failed",
            rollbackReason: "rollback failed"
        ))
        #expect(service.snapshot.stopCount == 1)
        #expect(status.events.suffix(3) == [
            .update(
                generation: old.value.generation,
                fingerprint: old.fingerprint,
                phase: .starting,
                errorCode: nil
            ),
            .endEvidence(old.value.generation),
            .update(
                generation: old.value.generation,
                fingerprint: old.fingerprint,
                phase: .failed,
                errorCode: .internalFailure
            ),
        ])
        #expect(!status.events.contains {
            if case .update(target.value.generation, target.fingerprint, .ready, nil) = $0 {
                return true
            }
            return false
        })
    }

    @Test func stopIsIdempotentAndReturnsStatusToIdle() throws {
        let configuration = try makeLifecycleConfiguration()
        let service = FakeDNSProxyService()
        let status = FakeRuntimeStatusRecorder()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: status
        )
        try lifecycle.start(configuration: configuration)

        lifecycle.stop()
        lifecycle.stop()

        #expect(service.snapshot.stopCount == 1)
        #expect(status.events.suffix(3) == [
            .update(
                generation: configuration.value.generation,
                fingerprint: configuration.fingerprint,
                phase: .stopping,
                errorCode: nil
            ),
            .endEvidence(configuration.value.generation),
            .update(
                generation: nil,
                fingerprint: nil,
                phase: .idle,
                errorCode: nil
            ),
        ])
    }

    @Test func quiesceStopsExactRuntimeAndPublishesProof() throws {
        let configuration = try makeLifecycleConfiguration()
        let service = FakeDNSProxyService()
        let status = FakeRuntimeStatusRecorder()
        let lifecycle = ProxyLifecycleController(service: service, statusRecorder: status)
        try lifecycle.start(configuration: configuration)

        let quiesced = try lifecycle.quiesce(
            expectedGeneration: configuration.value.generation,
            expectedFingerprint: configuration.fingerprint
        )
        let replay = try lifecycle.quiesce(
            expectedGeneration: configuration.value.generation,
            expectedFingerprint: configuration.fingerprint
        )

        #expect(quiesced == configuration)
        #expect(replay == configuration)
        #expect(service.snapshot.stopCount == 1)
        #expect(status.events.suffix(3) == [
            .update(
                generation: configuration.value.generation,
                fingerprint: configuration.fingerprint,
                phase: .stopping,
                errorCode: nil
            ),
            .endEvidence(configuration.value.generation),
            .update(generation: nil, fingerprint: nil, phase: .idle, errorCode: nil),
        ])
        #expect(status.lastQuiescedGenerations.last == configuration.value.generation)
        #expect(throws: ProxyLifecycleError.notStarted) {
            try lifecycle.reapply(configuration: try makeLifecycleConfiguration())
        }
    }

    @Test func resumeRestartsOnlyExactQuiescedRuntime() throws {
        let configuration = try makeLifecycleConfiguration()
        let service = FakeDNSProxyService()
        let status = FakeRuntimeStatusRecorder()
        let lifecycle = ProxyLifecycleController(service: service, statusRecorder: status)
        try lifecycle.start(configuration: configuration)
        try lifecycle.quiesce(
            expectedGeneration: configuration.value.generation,
            expectedFingerprint: configuration.fingerprint
        )

        #expect(throws: ProxyLifecycleError.baseIdentityMismatch) {
            try lifecycle.resume(
                expectedGeneration: UUID(),
                expectedFingerprint: configuration.fingerprint
            )
        }
        let resumed = try lifecycle.resume(
            expectedGeneration: configuration.value.generation,
            expectedFingerprint: configuration.fingerprint
        )

        #expect(resumed == configuration)
        #expect(service.snapshot.startedConfigurations == [configuration, configuration])
        #expect(status.events.suffix(3) == [
            .update(
                generation: configuration.value.generation,
                fingerprint: configuration.fingerprint,
                phase: .starting,
                errorCode: nil
            ),
            .beginEvidence(configuration.value.generation),
            .update(
                generation: configuration.value.generation,
                fingerprint: configuration.fingerprint,
                phase: .ready,
                errorCode: nil
            ),
        ])
    }

    @Test func runtimeControlQuiesceAndResumeAreReplaySafe() throws {
        let providerInstanceID = UUID()
        let configuration = try makeLifecycleConfiguration()
        let service = FakeDNSProxyService()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: FakeRuntimeStatusRecorder()
        )
        try lifecycle.start(configuration: configuration)
        let handler = ProxyRuntimeControlHandler(
            providerInstanceID: providerInstanceID,
            lifecycle: lifecycle
        )
        let quiesce = ProxyLifecycleRequest(
            operationID: UUID(),
            action: .quiesce,
            expectedProviderInstanceID: providerInstanceID,
            expectedGeneration: configuration.value.generation,
            expectedFingerprint: configuration.fingerprint
        )
        let quiesceData = try ProxyRuntimeControlCodec.encode(quiesce)

        let first = handler.quiesce(quiesceData)
        let replay = handler.quiesce(quiesceData)
        let wrongSelector = handler.resume(quiesceData)
        let resume = ProxyLifecycleRequest(
            operationID: UUID(),
            action: .resume,
            expectedProviderInstanceID: providerInstanceID,
            expectedGeneration: configuration.value.generation,
            expectedFingerprint: configuration.fingerprint
        )
        let resumeData = try ProxyRuntimeControlCodec.encode(resume)
        let resumed = handler.resume(resumeData)
        let quiescedAfterResume = handler.quiesce(quiesceData)
        let quiesceReplay = handler.quiesce(quiesceData)
        let resumedAfterQuiesce = handler.resume(resumeData)
        let resumeReplay = handler.resume(resumeData)

        #expect(first.disposition == .quiesced)
        #expect(replay == first)
        #expect(wrongSelector.rejectionCode == .invalidLifecycleAction)
        #expect(resumed.disposition == .resumed)
        #expect(quiescedAfterResume.disposition == .quiesced)
        #expect(quiesceReplay == quiescedAfterResume)
        #expect(resumedAfterQuiesce.disposition == .resumed)
        #expect(resumeReplay == resumedAfterQuiesce)
        #expect(service.snapshot.stopCount == 2)
        #expect(service.snapshot.startedConfigurations == [
            configuration,
            configuration,
            configuration,
        ])
    }

    @Test func oldInFlightQuiesceCannotCrossStopAndRestart() async throws {
        let providerInstanceID = UUID()
        let configuration = try makeLifecycleConfiguration()
        let began = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let service = FakeDNSProxyService()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: FakeRuntimeStatusRecorder()
        )
        try lifecycle.start(configuration: configuration)
        let handler = ProxyRuntimeControlHandler(
            providerInstanceID: providerInstanceID,
            lifecycle: lifecycle,
            afterBeginMutation: {
                began.signal()
                release.wait()
            }
        )
        let request = ProxyLifecycleRequest(
            operationID: UUID(),
            action: .quiesce,
            expectedProviderInstanceID: providerInstanceID,
            expectedGeneration: configuration.value.generation,
            expectedFingerprint: configuration.fingerprint
        )
        let requestData = try ProxyRuntimeControlCodec.encode(request)

        let requestTask = Task.detached { handler.quiesce(requestData) }
        #expect(await waitForSemaphore(began, timeout: .now() + 2) == .success)
        lifecycle.stop()
        try lifecycle.start(configuration: configuration)
        release.signal()
        let response = await requestTask.value

        #expect(response.disposition == .rejected)
        #expect(response.rejectionCode == .staleLifecycleEpoch)
        #expect(service.snapshot.stopCount == 1)
        #expect(service.snapshot.startedConfigurations == [configuration, configuration])
    }

    @Test func oldInFlightReapplyCannotCrossStopAndRestart() async throws {
        let providerInstanceID = UUID()
        let base = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let began = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let service = FakeDNSProxyService()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: FakeRuntimeStatusRecorder()
        )
        try lifecycle.start(configuration: base)
        let handler = ProxyRuntimeControlHandler(
            providerInstanceID: providerInstanceID,
            lifecycle: lifecycle,
            afterBeginMutation: {
                began.signal()
                release.wait()
            }
        )
        let request = makeReapplyRequest(
            providerInstanceID: providerInstanceID,
            base: base,
            target: target
        )
        let requestData = try ProxyRuntimeControlCodec.encode(request)

        let requestTask = Task.detached { handler.reapply(requestData) }
        #expect(await waitForSemaphore(began, timeout: .now() + 2) == .success)
        lifecycle.stop()
        try lifecycle.start(configuration: base)
        release.signal()
        let response = await requestTask.value

        #expect(response.disposition == .rejected)
        #expect(response.rejectionCode == .staleLifecycleEpoch)
        #expect(service.snapshot.reapplyPlans.isEmpty)
        #expect(service.snapshot.startedConfigurations == [base, base])
    }

    @Test func concurrentStopWaitsForReapplyThenStopsCommittedTarget() async throws {
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let reapplyEntered = DispatchSemaphore(value: 0)
        let reapplyRelease = DispatchSemaphore(value: 0)
        let stopCallStarted = DispatchSemaphore(value: 0)
        let service = FakeDNSProxyService(
            reapplyEntered: reapplyEntered,
            reapplyRelease: reapplyRelease
        )
        let status = FakeRuntimeStatusRecorder()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: status
        )
        try lifecycle.start(configuration: old)

        let reapplyTask = Task.detached {
            try lifecycle.reapply(configuration: target)
        }
        let reapplyEnteredResult = await waitForSemaphore(
            reapplyEntered,
            timeout: .now() + 2
        )
        #expect(reapplyEnteredResult == .success)

        let stopTask = Task.detached {
            stopCallStarted.signal()
            lifecycle.stop()
        }
        let stopCallStartedResult = await waitForSemaphore(
            stopCallStarted,
            timeout: .now() + 2
        )
        #expect(stopCallStartedResult == .success)
        reapplyRelease.signal()

        let outcome = try await reapplyTask.value
        await stopTask.value

        let plan = DNSProxyReloadPlan(active: old, target: target)
        #expect(outcome == .applied(target))
        #expect(service.snapshot.events.suffix(3) == [
            .reapplyEntered(plan),
            .reapplyReturned(plan),
            .stop,
        ])
        #expect(status.events.suffix(7) == [
            .update(
                generation: old.value.generation,
                fingerprint: old.fingerprint,
                phase: .starting,
                errorCode: nil
            ),
            .endEvidence(old.value.generation),
            .beginEvidence(target.value.generation),
            .update(
                generation: target.value.generation,
                fingerprint: target.fingerprint,
                phase: .ready,
                errorCode: nil
            ),
            .update(
                generation: target.value.generation,
                fingerprint: target.fingerprint,
                phase: .stopping,
                errorCode: nil
            ),
            .endEvidence(target.value.generation),
            .update(
                generation: nil,
                fingerprint: nil,
                phase: .idle,
                errorCode: nil
            ),
        ])
        #expect(throws: ProxyLifecycleError.notStarted) {
            try lifecycle.reapply(configuration: old)
        }
    }

    @Test func concurrentQuiesceWaitsForReapplyThenStopsCommittedTarget() async throws {
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let reapplyEntered = DispatchSemaphore(value: 0)
        let reapplyRelease = DispatchSemaphore(value: 0)
        let service = FakeDNSProxyService(
            reapplyEntered: reapplyEntered,
            reapplyRelease: reapplyRelease
        )
        let status = FakeRuntimeStatusRecorder()
        let lifecycle = ProxyLifecycleController(service: service, statusRecorder: status)
        try lifecycle.start(configuration: old)

        let reapplyTask = Task.detached {
            try lifecycle.reapply(configuration: target)
        }
        #expect(await waitForSemaphore(
            reapplyEntered,
            timeout: .now() + 2
        ) == .success)
        let quiesceTask = Task.detached {
            try lifecycle.quiesce(
                expectedGeneration: target.value.generation,
                expectedFingerprint: target.fingerprint
            )
        }
        reapplyRelease.signal()

        #expect(try await reapplyTask.value == .applied(target))
        #expect(try await quiesceTask.value == target)
        let plan = DNSProxyReloadPlan(active: old, target: target)
        #expect(service.snapshot.events.suffix(3) == [
            .reapplyEntered(plan),
            .reapplyReturned(plan),
            .stop,
        ])
        #expect(status.lastQuiescedGenerations.last == target.value.generation)
    }

    @Test func runtimeControlAppliesOnceAndReplaysTerminalResponse() throws {
        let providerInstanceID = UUID()
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let service = FakeDNSProxyService()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: FakeRuntimeStatusRecorder()
        )
        try lifecycle.start(configuration: old)
        let handler = ProxyRuntimeControlHandler(
            providerInstanceID: providerInstanceID,
            lifecycle: lifecycle
        )
        let request = makeReapplyRequest(
            providerInstanceID: providerInstanceID,
            base: old,
            target: target
        )

        let requestData = try ProxyRuntimeControlCodec.encode(request)
        let first = handler.reapply(requestData)
        let replay = handler.reapply(requestData)

        #expect(first.disposition == .applied)
        #expect(first.activeGeneration == target.value.generation)
        #expect(first.activeFingerprint == target.fingerprint)
        #expect(replay == first)
        #expect(service.snapshot.reapplyPlans.count == 1)
    }

    @Test func runtimeControlRejectsStaleBaseWithoutEngineSideEffects() throws {
        let providerInstanceID = UUID()
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let service = FakeDNSProxyService()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: FakeRuntimeStatusRecorder()
        )
        try lifecycle.start(configuration: old)
        let handler = ProxyRuntimeControlHandler(
            providerInstanceID: providerInstanceID,
            lifecycle: lifecycle
        )
        let request = ProxyReapplyRequest(
            operationID: UUID(),
            expectedProviderInstanceID: providerInstanceID,
            expectedBaseGeneration: UUID(),
            expectedBaseFingerprint: old.fingerprint,
            targetConfigurationData: target.data,
            targetFingerprint: target.fingerprint
        )

        let response = handler.reapply(try ProxyRuntimeControlCodec.encode(request))

        #expect(response.disposition == .rejected)
        #expect(response.rejectionCode == .staleBaseIdentity)
        #expect(service.snapshot.reapplyPlans.isEmpty)
    }

    @Test func runtimeControlRejectsDifferentConfigurationWithBaseGeneration() throws {
        let providerInstanceID = UUID()
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(
            generation: old.value.generation,
            address: "9.9.9.9"
        )
        let service = FakeDNSProxyService()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: FakeRuntimeStatusRecorder()
        )
        try lifecycle.start(configuration: old)
        let handler = ProxyRuntimeControlHandler(
            providerInstanceID: providerInstanceID,
            lifecycle: lifecycle
        )
        let request = makeReapplyRequest(
            providerInstanceID: providerInstanceID,
            base: old,
            target: target
        )

        let response = handler.reapply(try ProxyRuntimeControlCodec.encode(request))

        #expect(response.disposition == .rejected)
        #expect(response.rejectionCode == .invalidTargetConfiguration)
        #expect(service.snapshot.reapplyPlans.isEmpty)
    }

    @Test func runtimeControlRejectsOversizedTargetBeforeConfigurationDecode() throws {
        let providerInstanceID = UUID()
        let old = try makeLifecycleConfiguration()
        let oversizedTarget = Data(
            repeating: 0,
            count: DNSProxyXPCContract.maximumConfigurationSize + 1
        )
        let service = FakeDNSProxyService()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: FakeRuntimeStatusRecorder()
        )
        try lifecycle.start(configuration: old)
        let handler = ProxyRuntimeControlHandler(
            providerInstanceID: providerInstanceID,
            lifecycle: lifecycle
        )
        let request = ProxyReapplyRequest(
            operationID: UUID(),
            expectedProviderInstanceID: providerInstanceID,
            expectedBaseGeneration: old.value.generation,
            expectedBaseFingerprint: old.fingerprint,
            targetConfigurationData: oversizedTarget,
            targetFingerprint: ProxyConfigurationFingerprint(data: oversizedTarget)
        )

        let response = handler.reapply(try ProxyRuntimeControlCodec.encode(request))

        #expect(response.disposition == .rejected)
        #expect(response.rejectionCode == .invalidTargetConfiguration)
        #expect(service.snapshot.reapplyPlans.isEmpty)
    }

    @Test func runtimeControlRejectsUnknownEmbeddedConfigurationKeys() throws {
        let providerInstanceID = UUID()
        let base = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let service = FakeDNSProxyService()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: FakeRuntimeStatusRecorder()
        )
        try lifecycle.start(configuration: base)
        let handler = ProxyRuntimeControlHandler(
            providerInstanceID: providerInstanceID,
            lifecycle: lifecycle
        )

        for location in [
            UnknownConfigurationFieldLocation.topLevel,
            .nestedUpstreamConfiguration,
        ] {
            let targetData = try configurationData(
                byAddingUnknownFieldTo: target,
                at: location
            )
            let request = ProxyReapplyRequest(
                operationID: UUID(),
                expectedProviderInstanceID: providerInstanceID,
                expectedBaseGeneration: base.value.generation,
                expectedBaseFingerprint: base.fingerprint,
                targetConfigurationData: targetData,
                targetFingerprint: ProxyConfigurationFingerprint(data: targetData)
            )

            let response = handler.reapply(try ProxyRuntimeControlCodec.encode(request))
            #expect(response.disposition == .rejected)
            #expect(response.rejectionCode == .invalidTargetConfiguration)
        }
        #expect(service.snapshot.reapplyPlans.isEmpty)
    }

    @Test func runtimeControlReturnsPreservedBaseAfterRejectedReapply() throws {
        let providerInstanceID = UUID()
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let service = FakeDNSProxyService(reapplySteps: [
            .fail(.unchanged("target rejected")),
        ])
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: FakeRuntimeStatusRecorder()
        )
        try lifecycle.start(configuration: old)
        let handler = ProxyRuntimeControlHandler(
            providerInstanceID: providerInstanceID,
            lifecycle: lifecycle
        )

        let request = makeReapplyRequest(
            providerInstanceID: providerInstanceID,
            base: old,
            target: target
        )
        let response = handler.reapply(try ProxyRuntimeControlCodec.encode(request))

        #expect(response.disposition == .rejectedPreservingBase)
        #expect(response.activeGeneration == old.value.generation)
        #expect(response.activeFingerprint == old.fingerprint)
        #expect(response.preservedConfigurationData == old.data)
    }

    @Test func runtimeControlRejectsConcurrentWriteWhileOneIsInFlight() async throws {
        let providerInstanceID = UUID()
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let secondTarget = try makeLifecycleConfiguration(address: "8.8.8.8")
        let reapplyEntered = DispatchSemaphore(value: 0)
        let reapplyRelease = DispatchSemaphore(value: 0)
        let service = FakeDNSProxyService(
            reapplyEntered: reapplyEntered,
            reapplyRelease: reapplyRelease
        )
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: FakeRuntimeStatusRecorder()
        )
        try lifecycle.start(configuration: old)
        let handler = ProxyRuntimeControlHandler(
            providerInstanceID: providerInstanceID,
            lifecycle: lifecycle
        )
        let firstRequest = makeReapplyRequest(
            providerInstanceID: providerInstanceID,
            base: old,
            target: target
        )
        let secondRequest = makeReapplyRequest(
            providerInstanceID: providerInstanceID,
            base: old,
            target: secondTarget
        )

        let firstRequestData = try ProxyRuntimeControlCodec.encode(firstRequest)
        let secondRequestData = try ProxyRuntimeControlCodec.encode(secondRequest)
        let firstTask = Task.detached { handler.reapply(firstRequestData) }
        let entered = await waitForSemaphore(reapplyEntered, timeout: .now() + 2)
        #expect(entered == .success)
        let secondResponse = handler.reapply(secondRequestData)
        reapplyRelease.signal()
        let firstResponse = await firstTask.value

        #expect(secondResponse.rejectionCode == .operationInProgress)
        #expect(firstResponse.disposition == .applied)
        #expect(service.snapshot.reapplyPlans.count == 1)
    }

    @Test func runtimeControlRejectsConflictingInFlightOperationID() async throws {
        let providerInstanceID = UUID()
        let operationID = UUID()
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let conflictingTarget = try makeLifecycleConfiguration(address: "8.8.8.8")
        let reapplyEntered = DispatchSemaphore(value: 0)
        let reapplyRelease = DispatchSemaphore(value: 0)
        let service = FakeDNSProxyService(
            reapplyEntered: reapplyEntered,
            reapplyRelease: reapplyRelease
        )
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: FakeRuntimeStatusRecorder()
        )
        try lifecycle.start(configuration: old)
        let handler = ProxyRuntimeControlHandler(
            providerInstanceID: providerInstanceID,
            lifecycle: lifecycle
        )
        let first = ProxyReapplyRequest(
            operationID: operationID,
            expectedProviderInstanceID: providerInstanceID,
            expectedBaseGeneration: old.value.generation,
            expectedBaseFingerprint: old.fingerprint,
            targetConfigurationData: target.data,
            targetFingerprint: target.fingerprint
        )
        let conflicting = ProxyReapplyRequest(
            operationID: operationID,
            expectedProviderInstanceID: providerInstanceID,
            expectedBaseGeneration: old.value.generation,
            expectedBaseFingerprint: old.fingerprint,
            targetConfigurationData: conflictingTarget.data,
            targetFingerprint: conflictingTarget.fingerprint
        )
        let firstData = try ProxyRuntimeControlCodec.encode(first)
        let conflictingData = try ProxyRuntimeControlCodec.encode(conflicting)

        let firstTask = Task.detached { handler.reapply(firstData) }
        let entered = await waitForSemaphore(reapplyEntered, timeout: .now() + 2)
        #expect(entered == .success)
        let conflictResponse = handler.reapply(conflictingData)
        reapplyRelease.signal()
        let firstResponse = await firstTask.value

        #expect(conflictResponse.rejectionCode == .operationIDConflict)
        #expect(firstResponse.disposition == .applied)
        #expect(service.snapshot.reapplyPlans.count == 1)
    }

    @Test func runtimeControlRateLimitsMalformedAndOversizedIngress() throws {
        let uptime = Mutex<TimeInterval>(0)
        let lifecycle = ProxyLifecycleController(
            service: FakeDNSProxyService(),
            statusRecorder: FakeRuntimeStatusRecorder()
        )
        let handler = ProxyRuntimeControlHandler(
            providerInstanceID: UUID(),
            lifecycle: lifecycle,
            uptime: { uptime.withLock { $0 } }
        )

        for _ in 0..<8 {
            #expect(handler.reapply(Data("invalid".utf8)).rejectionCode == .malformedRequest)
        }
        let oversized = Data(
            repeating: 0,
            count: DNSProxyXPCContract.maximumWriteRequestSize + 1
        )
        for _ in 0..<8 {
            #expect(handler.reapply(oversized).rejectionCode == .requestTooLarge)
        }
        let limited = handler.reapply(Data("invalid".utf8))
        #expect(limited.operationID == nil)
        #expect(limited.rejectionCode == .rateLimited)

        uptime.withLock { $0 += 0.125 }
        #expect(handler.reapply(Data("invalid".utf8)).rejectionCode == .malformedRequest)
        #expect(handler.reapply(Data("invalid".utf8)).rejectionCode == .rateLimited)
    }

    @Test func runtimeControlAppliesBurstLimitAtomically() {
        let lifecycle = ProxyLifecycleController(
            service: FakeDNSProxyService(),
            statusRecorder: FakeRuntimeStatusRecorder()
        )
        let handler = ProxyRuntimeControlHandler(
            providerInstanceID: UUID(),
            lifecycle: lifecycle,
            uptime: { 0 }
        )
        let rejectionCodes = Mutex<[ProxyRuntimeControlRejectionCode?]>([])

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let response = handler.reapply(Data("invalid".utf8))
            rejectionCodes.withLock { $0.append(response.rejectionCode) }
        }
        let result = rejectionCodes.withLock { $0 }

        #expect(result.count(where: { $0 == .malformedRequest }) == 16)
        #expect(result.count(where: { $0 == .rateLimited }) == 16)
    }

    @Test func runtimeControlRateLimitsReplayAndByteDistinctConflict() throws {
        let providerInstanceID = UUID()
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let service = FakeDNSProxyService()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: FakeRuntimeStatusRecorder()
        )
        try lifecycle.start(configuration: old)
        let handler = ProxyRuntimeControlHandler(
            providerInstanceID: providerInstanceID,
            lifecycle: lifecycle,
            uptime: { 0 }
        )
        let request = makeReapplyRequest(
            providerInstanceID: providerInstanceID,
            base: old,
            target: target
        )
        let requestData = try ProxyRuntimeControlCodec.encode(request)
        let payload = try #require(
            PropertyListSerialization.propertyList(from: requestData, format: nil)
                as? [String: Any]
        )
        var reorderedPayload: [String: Any] = [:]
        for key in payload.keys.sorted(by: >) {
            reorderedPayload[key] = payload[key]
        }
        let reorderedData = try PropertyListSerialization.data(
            fromPropertyList: reorderedPayload,
            format: .binary,
            options: 0
        )

        #expect(reorderedData != requestData)
        #expect(try ProxyRuntimeControlCodec.decodeReapplyRequest(reorderedData) == request)
        let applied = handler.reapply(requestData)
        for _ in 0..<7 {
            #expect(handler.reapply(requestData) == applied)
        }
        for _ in 0..<8 {
            #expect(handler.reapply(reorderedData).rejectionCode == .operationIDConflict)
        }

        let limited = handler.reapply(requestData)
        #expect(limited.operationID == nil)
        #expect(limited.rejectionCode == .rateLimited)
        #expect(service.snapshot.reapplyPlans.count == 1)
    }

    @Test func runtimeControlDoesNotReplayTerminalResponseAcrossLifecycleEpoch() throws {
        let providerInstanceID = UUID()
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let restarted = try makeLifecycleConfiguration(address: "8.8.8.8")
        let service = FakeDNSProxyService()
        let lifecycle = ProxyLifecycleController(
            service: service,
            statusRecorder: FakeRuntimeStatusRecorder()
        )
        try lifecycle.start(configuration: old)
        let handler = ProxyRuntimeControlHandler(
            providerInstanceID: providerInstanceID,
            lifecycle: lifecycle
        )
        let request = makeReapplyRequest(
            providerInstanceID: providerInstanceID,
            base: old,
            target: target
        )
        let requestData = try ProxyRuntimeControlCodec.encode(request)
        #expect(handler.reapply(requestData).disposition == .applied)

        lifecycle.stop()
        try lifecycle.start(configuration: restarted)

        let replay = handler.reapply(requestData)
        #expect(replay.disposition == .rejected)
        #expect(replay.rejectionCode == .staleBaseIdentity)
        #expect(service.snapshot.reapplyPlans.count == 1)
    }
}

private func makeReapplyRequest(
    providerInstanceID: UUID,
    base: PersistedProxyConfiguration,
    target: PersistedProxyConfiguration
) -> ProxyReapplyRequest {
    ProxyReapplyRequest(
        operationID: UUID(),
        expectedProviderInstanceID: providerInstanceID,
        expectedBaseGeneration: base.value.generation,
        expectedBaseFingerprint: base.fingerprint,
        targetConfigurationData: target.data,
        targetFingerprint: target.fingerprint
    )
}
