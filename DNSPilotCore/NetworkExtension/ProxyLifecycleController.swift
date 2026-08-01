import Foundation
import NetworkExtension
import Synchronization

struct DNSProxyReloadScope: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let settings = Self(rawValue: 1 << 0)
    static let filters = Self(rawValue: 1 << 1)
    static let all: Self = [.settings, .filters]
}

struct DNSProxyReloadPlan: Equatable, Sendable {
    let target: PersistedProxyConfiguration
    let scope: DNSProxyReloadScope
    let loggingModeChanged: Bool

    init(
        target: PersistedProxyConfiguration,
        scope: DNSProxyReloadScope,
        loggingModeChanged: Bool
    ) {
        self.target = target
        self.scope = scope
        self.loggingModeChanged = loggingModeChanged
    }

    init(
        active: PersistedProxyConfiguration,
        target: PersistedProxyConfiguration
    ) {
        var scope: DNSProxyReloadScope = []
        let loggingModeChanged = active.value.loggingMode != target.value.loggingMode

        if active.value.upstream != target.value.upstream
            || active.value.dnsCacheConfiguration != target.value.dnsCacheConfiguration {
            scope.insert(.settings)
        }

        self.init(
            target: target,
            scope: scope,
            loggingModeChanged: loggingModeChanged
        )
    }
}

enum DNSProxyServiceReapplyError: Error, Equatable, Sendable {
    case unchanged(String)
    case engineMayHaveMutated(String)

    var reason: String {
        switch self {
        case let .unchanged(reason), let .engineMayHaveMutated(reason):
            reason
        }
    }
}

// Calls are synchronous and must not reenter the lifecycle controller.
protocol DNSProxyServicing: AnyObject, Sendable {
    func start(configuration: PersistedProxyConfiguration) throws
    func reapply(_ plan: DNSProxyReloadPlan) throws
    func stop()
    func handle(_ flow: NEAppProxyFlow) -> Bool
}

// Recording must be synchronous and must not reenter the lifecycle controller.
protocol ProxyRuntimeStatusRecording: AnyObject, Sendable {
    func update(
        generation: UUID?,
        configurationFingerprint: ProxyConfigurationFingerprint?,
        phase: ProxyRuntimePhase,
        lastQuiescedGeneration: UUID?,
        errorCode: ProxyRuntimeErrorCode?
    )
    func beginEvidence(generation: UUID)
    func endEvidence(generation: UUID)
}

enum DNSProxyReloadOutcome: Equatable, Sendable {
    case applied(PersistedProxyConfiguration)
    case rejectedUnchanged(active: PersistedProxyConfiguration, reason: String)
    case rejectedRolledBack(active: PersistedProxyConfiguration, reason: String)
    case unrecoverable(targetReason: String, rollbackReason: String)
}

struct ReloadCoordinator: Sendable {
    func apply(
        plan: DNSProxyReloadPlan,
        active: PersistedProxyConfiguration,
        service: DNSProxyServicing
    ) -> DNSProxyReloadOutcome {
        do {
            try service.reapply(plan)
            return .applied(plan.target)
        } catch let error as DNSProxyServiceReapplyError {
            switch error {
            case let .unchanged(reason):
                return .rejectedUnchanged(active: active, reason: reason)
            case let .engineMayHaveMutated(reason):
                return rollback(
                    targetReason: reason,
                    plan: plan,
                    active: active,
                    service: service
                )
            }
        } catch {
            return rollback(
                targetReason: String(describing: error),
                plan: plan,
                active: active,
                service: service
            )
        }
    }

    private func rollback(
        targetReason: String,
        plan: DNSProxyReloadPlan,
        active: PersistedProxyConfiguration,
        service: DNSProxyServicing
    ) -> DNSProxyReloadOutcome {
        let rollbackPlan = DNSProxyReloadPlan(
            target: active,
            scope: plan.scope,
            loggingModeChanged: plan.loggingModeChanged
        )

        do {
            try service.reapply(rollbackPlan)
            return .rejectedRolledBack(active: active, reason: targetReason)
        } catch let error as DNSProxyServiceReapplyError {
            service.stop()
            return .unrecoverable(
                targetReason: targetReason,
                rollbackReason: error.reason
            )
        } catch {
            service.stop()
            return .unrecoverable(
                targetReason: targetReason,
                rollbackReason: String(describing: error)
            )
        }
    }
}

enum ProxyLifecycleError: Error, Equatable, Sendable {
    case alreadyStarted
    case notStarted
    case baseIdentityMismatch
    case staleLifecycleEpoch
    case startFailed(String)
    case resumeFailed(String)
}

struct ProxyLifecycleMutationResult<Value: Sendable>: Sendable {
    let value: Value
    let lifecycleEpoch: UInt64
}

final class ProxyLifecycleController: Sendable {
    private enum RuntimeState: Sendable {
        case idle
        case active(PersistedProxyConfiguration)
        case quiesced(PersistedProxyConfiguration)
    }

    private struct State: Sendable {
        var runtime: RuntimeState = .idle
        var lifecycleEpoch: UInt64 = 0
    }

    private let service: DNSProxyServicing
    private let statusRecorder: ProxyRuntimeStatusRecording
    private let reloadCoordinator: ReloadCoordinator
    private let state = Mutex(State())

    init(
        service: DNSProxyServicing,
        statusRecorder: ProxyRuntimeStatusRecording,
        reloadCoordinator: ReloadCoordinator = ReloadCoordinator()
    ) {
        self.service = service
        self.statusRecorder = statusRecorder
        self.reloadCoordinator = reloadCoordinator
    }

    func start(configuration: PersistedProxyConfiguration) throws {
        try state.withLock { state in
            guard case .idle = state.runtime else {
                throw ProxyLifecycleError.alreadyStarted
            }

            publish(configuration, phase: .starting)
            statusRecorder.beginEvidence(generation: configuration.value.generation)

            do {
                try service.start(configuration: configuration)
                state.runtime = .active(configuration)
                advanceLifecycleEpoch(state: &state)
                publish(configuration, phase: .ready)
            } catch {
                service.stop()
                statusRecorder.endEvidence(generation: configuration.value.generation)
                advanceLifecycleEpoch(state: &state)
                publish(
                    configuration,
                    phase: .failed,
                    errorCode: .engineInitializationFailed
                )
                throw ProxyLifecycleError.startFailed(String(describing: error))
            }
        }
    }

    func reapply(
        configuration target: PersistedProxyConfiguration
    ) throws -> DNSProxyReloadOutcome {
        try state.withLock { state in
            guard case let .active(active) = state.runtime else {
                throw ProxyLifecycleError.notStarted
            }

            return reapplyLocked(target: target, active: active, state: &state)
        }
    }

    func reapply(
        configuration target: PersistedProxyConfiguration,
        expectedBaseGeneration: UUID,
        expectedBaseFingerprint: ProxyConfigurationFingerprint
    ) throws -> DNSProxyReloadOutcome {
        try reapplyForRuntimeControl(
            configuration: target,
            expectedBaseGeneration: expectedBaseGeneration,
            expectedBaseFingerprint: expectedBaseFingerprint,
            expectedLifecycleEpoch: nil
        ).value
    }

    func reapplyForRuntimeControl(
        configuration target: PersistedProxyConfiguration,
        expectedBaseGeneration: UUID,
        expectedBaseFingerprint: ProxyConfigurationFingerprint,
        expectedLifecycleEpoch: UInt64
    ) throws -> ProxyLifecycleMutationResult<DNSProxyReloadOutcome> {
        try reapplyForRuntimeControl(
            configuration: target,
            expectedBaseGeneration: expectedBaseGeneration,
            expectedBaseFingerprint: expectedBaseFingerprint,
            expectedLifecycleEpoch: Optional(expectedLifecycleEpoch)
        )
    }

    private func reapplyForRuntimeControl(
        configuration target: PersistedProxyConfiguration,
        expectedBaseGeneration: UUID,
        expectedBaseFingerprint: ProxyConfigurationFingerprint,
        expectedLifecycleEpoch: UInt64?
    ) throws -> ProxyLifecycleMutationResult<DNSProxyReloadOutcome> {
        try state.withLock { state in
            try validateLifecycleEpoch(expectedLifecycleEpoch, state: state)
            guard case let .active(active) = state.runtime else {
                throw ProxyLifecycleError.notStarted
            }
            guard
                active.value.generation == expectedBaseGeneration,
                active.fingerprint == expectedBaseFingerprint
            else {
                throw ProxyLifecycleError.baseIdentityMismatch
            }

            let outcome = reapplyLocked(target: target, active: active, state: &state)
            return ProxyLifecycleMutationResult(
                value: outcome,
                lifecycleEpoch: state.lifecycleEpoch
            )
        }
    }

    private func reapplyLocked(
        target: PersistedProxyConfiguration,
        active: PersistedProxyConfiguration,
        state: inout State
    ) -> DNSProxyReloadOutcome {
        publish(active, phase: .starting)
        let plan = DNSProxyReloadPlan(active: active, target: target)
        let outcome = reloadCoordinator.apply(
            plan: plan,
            active: active,
            service: service
        )

        switch outcome {
        case .applied:
            statusRecorder.endEvidence(generation: active.value.generation)
            statusRecorder.beginEvidence(generation: target.value.generation)
            state.runtime = .active(target)
            advanceLifecycleEpoch(state: &state)
            publish(target, phase: .ready)
        case .rejectedUnchanged, .rejectedRolledBack:
            publish(active, phase: .ready)
        case .unrecoverable:
            state.runtime = .idle
            advanceLifecycleEpoch(state: &state)
            statusRecorder.endEvidence(generation: active.value.generation)
            publish(active, phase: .failed, errorCode: .internalFailure)
        }

        return outcome
    }

    @discardableResult
    func quiesce(
        expectedGeneration: UUID,
        expectedFingerprint: ProxyConfigurationFingerprint
    ) throws -> PersistedProxyConfiguration {
        try quiesceForRuntimeControl(
            expectedGeneration: expectedGeneration,
            expectedFingerprint: expectedFingerprint,
            expectedLifecycleEpoch: nil
        ).value
    }

    func quiesceForRuntimeControl(
        expectedGeneration: UUID,
        expectedFingerprint: ProxyConfigurationFingerprint,
        expectedLifecycleEpoch: UInt64
    ) throws -> ProxyLifecycleMutationResult<PersistedProxyConfiguration> {
        try quiesceForRuntimeControl(
            expectedGeneration: expectedGeneration,
            expectedFingerprint: expectedFingerprint,
            expectedLifecycleEpoch: Optional(expectedLifecycleEpoch)
        )
    }

    private func quiesceForRuntimeControl(
        expectedGeneration: UUID,
        expectedFingerprint: ProxyConfigurationFingerprint,
        expectedLifecycleEpoch: UInt64?
    ) throws -> ProxyLifecycleMutationResult<PersistedProxyConfiguration> {
        try state.withLock { state in
            try validateLifecycleEpoch(expectedLifecycleEpoch, state: state)
            let configuration: PersistedProxyConfiguration
            switch state.runtime {
            case let .active(active), let .quiesced(active):
                configuration = active
            case .idle:
                throw ProxyLifecycleError.notStarted
            }
            guard
                configuration.value.generation == expectedGeneration,
                configuration.fingerprint == expectedFingerprint
            else {
                throw ProxyLifecycleError.baseIdentityMismatch
            }
            if case .quiesced = state.runtime {
                return ProxyLifecycleMutationResult(
                    value: configuration,
                    lifecycleEpoch: state.lifecycleEpoch
                )
            }

            publish(configuration, phase: .stopping)
            service.stop()
            statusRecorder.endEvidence(generation: configuration.value.generation)
            state.runtime = .quiesced(configuration)
            advanceLifecycleEpoch(state: &state)
            statusRecorder.update(
                generation: nil,
                configurationFingerprint: nil,
                phase: .idle,
                lastQuiescedGeneration: configuration.value.generation,
                errorCode: nil
            )
            return ProxyLifecycleMutationResult(
                value: configuration,
                lifecycleEpoch: state.lifecycleEpoch
            )
        }
    }

    @discardableResult
    func resume(
        expectedGeneration: UUID,
        expectedFingerprint: ProxyConfigurationFingerprint
    ) throws -> PersistedProxyConfiguration {
        try resumeForRuntimeControl(
            expectedGeneration: expectedGeneration,
            expectedFingerprint: expectedFingerprint,
            expectedLifecycleEpoch: nil
        ).value
    }

    func resumeForRuntimeControl(
        expectedGeneration: UUID,
        expectedFingerprint: ProxyConfigurationFingerprint,
        expectedLifecycleEpoch: UInt64
    ) throws -> ProxyLifecycleMutationResult<PersistedProxyConfiguration> {
        try resumeForRuntimeControl(
            expectedGeneration: expectedGeneration,
            expectedFingerprint: expectedFingerprint,
            expectedLifecycleEpoch: Optional(expectedLifecycleEpoch)
        )
    }

    private func resumeForRuntimeControl(
        expectedGeneration: UUID,
        expectedFingerprint: ProxyConfigurationFingerprint,
        expectedLifecycleEpoch: UInt64?
    ) throws -> ProxyLifecycleMutationResult<PersistedProxyConfiguration> {
        try state.withLock { state in
            try validateLifecycleEpoch(expectedLifecycleEpoch, state: state)
            guard case let .quiesced(configuration) = state.runtime else {
                throw ProxyLifecycleError.notStarted
            }
            guard
                configuration.value.generation == expectedGeneration,
                configuration.fingerprint == expectedFingerprint
            else {
                throw ProxyLifecycleError.baseIdentityMismatch
            }

            publish(configuration, phase: .starting)
            statusRecorder.beginEvidence(generation: configuration.value.generation)
            do {
                try service.start(configuration: configuration)
                state.runtime = .active(configuration)
                advanceLifecycleEpoch(state: &state)
                publish(configuration, phase: .ready)
                return ProxyLifecycleMutationResult(
                    value: configuration,
                    lifecycleEpoch: state.lifecycleEpoch
                )
            } catch {
                service.stop()
                statusRecorder.endEvidence(generation: configuration.value.generation)
                state.runtime = .quiesced(configuration)
                statusRecorder.update(
                    generation: nil,
                    configurationFingerprint: nil,
                    phase: .failed,
                    lastQuiescedGeneration: configuration.value.generation,
                    errorCode: .engineInitializationFailed
                )
                throw ProxyLifecycleError.resumeFailed(String(describing: error))
            }
        }
    }

    func stop() {
        state.withLock { state in
            let configuration: PersistedProxyConfiguration
            switch state.runtime {
            case .idle:
                return
            case let .active(active), let .quiesced(active):
                configuration = active
            }

            if case .active = state.runtime {
                publish(configuration, phase: .stopping)
                service.stop()
                statusRecorder.endEvidence(generation: configuration.value.generation)
            }
            state.runtime = .idle
            advanceLifecycleEpoch(state: &state)
            statusRecorder.update(
                generation: nil,
                configurationFingerprint: nil,
                phase: .idle,
                lastQuiescedGeneration: configuration.value.generation,
                errorCode: nil
            )
        }
    }

    func handle(_ flow: NEAppProxyFlow) -> Bool {
        state.withLock { state in
            guard case .active = state.runtime else {
                return false
            }
            return service.handle(flow)
        }
    }

    func withLifecycleEpoch<Result>(
        _ body: (UInt64) throws -> Result
    ) rethrows -> Result {
        try state.withLock { state in
            try body(state.lifecycleEpoch)
        }
    }

    var lifecycleEpoch: UInt64 {
        state.withLock { $0.lifecycleEpoch }
    }

    private func validateLifecycleEpoch(
        _ expectedLifecycleEpoch: UInt64?,
        state: State
    ) throws {
        guard expectedLifecycleEpoch == nil
            || expectedLifecycleEpoch == state.lifecycleEpoch else {
            throw ProxyLifecycleError.staleLifecycleEpoch
        }
    }

    private func advanceLifecycleEpoch(state: inout State) {
        state.lifecycleEpoch &+= 1
    }

    private func publish(
        _ configuration: PersistedProxyConfiguration,
        phase: ProxyRuntimePhase,
        errorCode: ProxyRuntimeErrorCode? = nil
    ) {
        statusRecorder.update(
            generation: configuration.value.generation,
            configurationFingerprint: configuration.fingerprint,
            phase: phase,
            lastQuiescedGeneration: nil,
            errorCode: errorCode
        )
    }
}
