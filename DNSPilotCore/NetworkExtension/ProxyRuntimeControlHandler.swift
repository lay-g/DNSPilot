import Foundation
import Synchronization

final class ProxyRuntimeControlHandler: Sendable {
    private enum MutationResponse: Sendable {
        case reapply(ProxyReapplyResponse)
        case lifecycle(ProxyLifecycleResponse)
    }

    private enum BeginResult: Sendable {
        case proceed(UInt64)
        case replay(MutationResponse)
        case reject(ProxyRuntimeControlRejectionCode)
    }

    private struct InFlightOperation: Sendable {
        let operationID: UUID
        let requestData: Data
        let lifecycleEpoch: UInt64
    }

    private struct TerminalOperation: Sendable {
        let requestData: Data
        let response: MutationResponse
        let lifecycleEpoch: UInt64
    }

    private struct State: Sendable {
        var inFlightOperation: InFlightOperation?
        var terminalOperations: [UUID: TerminalOperation] = [:]
        var terminalOrder: [UUID] = []
        var availableTokens = 16.0
        var lastRefillTime: TimeInterval
    }

    private let providerInstanceID: UUID
    private let lifecycle: ProxyLifecycleController
    private let uptime: @Sendable () -> TimeInterval
    private let afterBeginMutation: @Sendable () -> Void
    private let state: Mutex<State>

    init(
        providerInstanceID: UUID,
        lifecycle: ProxyLifecycleController,
        uptime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        afterBeginMutation: @escaping @Sendable () -> Void = {}
    ) {
        self.providerInstanceID = providerInstanceID
        self.lifecycle = lifecycle
        self.uptime = uptime
        self.afterBeginMutation = afterBeginMutation
        state = Mutex(State(lastRefillTime: uptime()))
    }

    func reapply(_ requestData: Data) -> ProxyReapplyResponse {
        guard admitIngress() else {
            return rejection(code: .rateLimited)
        }

        let request: ProxyReapplyRequest
        do {
            request = try ProxyRuntimeControlCodec.decodeReapplyRequest(requestData)
        } catch ProxyRuntimeControlCodecError.requestTooLarge {
            return rejection(code: .requestTooLarge)
        } catch {
            return rejection(code: .malformedRequest)
        }

        let beginResult = begin(
            operationID: request.operationID,
            requestData: requestData
        )
        let lifecycleEpoch: UInt64
        switch beginResult {
        case let .proceed(epoch):
            lifecycleEpoch = epoch
            afterBeginMutation()
        case let .replay(.reapply(response)):
            return response
        case .replay(.lifecycle), .reject(.operationIDConflict):
            return rejection(operationID: request.operationID, code: .operationIDConflict)
        case let .reject(code):
            return rejection(operationID: request.operationID, code: code)
        }

        let (response, terminalEpoch) = perform(
            request,
            expectedLifecycleEpoch: lifecycleEpoch
        )
        finish(
            operationID: request.operationID,
            requestData: requestData,
            response: .reapply(response),
            operationLifecycleEpoch: lifecycleEpoch,
            terminalLifecycleEpoch: terminalEpoch
        )
        return response
    }

    func quiesce(_ requestData: Data) -> ProxyLifecycleResponse {
        lifecycle(requestData, action: .quiesce)
    }

    func resume(_ requestData: Data) -> ProxyLifecycleResponse {
        lifecycle(requestData, action: .resume)
    }

    func rejection(
        operationID: UUID? = nil,
        code: ProxyRuntimeControlRejectionCode
    ) -> ProxyReapplyResponse {
        ProxyReapplyResponse(
            operationID: operationID,
            disposition: .rejected,
            providerInstanceID: providerInstanceID,
            rejectionCode: code
        )
    }

    private func begin(
        operationID: UUID,
        requestData: Data
    ) -> BeginResult {
        state.withLock { state in
            if let inFlight = state.inFlightOperation {
                if inFlight.operationID == operationID,
                   inFlight.requestData != requestData {
                    return .reject(.operationIDConflict)
                }
                return .reject(.operationInProgress)
            }

            return lifecycle.withLifecycleEpoch { lifecycleEpoch in
                discardTerminalOperations(
                    notMatching: lifecycleEpoch,
                    state: &state
                )
                if let terminal = state.terminalOperations[operationID] {
                    return terminal.requestData == requestData
                        ? .replay(terminal.response)
                        : .reject(.operationIDConflict)
                }

                state.inFlightOperation = InFlightOperation(
                    operationID: operationID,
                    requestData: requestData,
                    lifecycleEpoch: lifecycleEpoch
                )
                return .proceed(lifecycleEpoch)
            }
        }
    }

    private func admitIngress() -> Bool {
        state.withLock { state in
            consumeToken(state: &state)
        }
    }

    private func consumeToken(state: inout State) -> Bool {
        let now = uptime()
        let elapsed = max(0, now - state.lastRefillTime)
        state.availableTokens = min(16, state.availableTokens + elapsed * 8)
        state.lastRefillTime = now
        guard state.availableTokens >= 1 else { return false }
        state.availableTokens -= 1
        return true
    }

    private func perform(
        _ request: ProxyReapplyRequest,
        expectedLifecycleEpoch: UInt64
    ) -> (ProxyReapplyResponse, UInt64) {
        guard request.schemaVersion == ProxyReapplyRequest.currentSchemaVersion else {
            return (
                rejection(operationID: request.operationID, code: .unsupportedSchemaVersion),
                expectedLifecycleEpoch
            )
        }
        guard
            request.runtimeControlProtocolVersion
                == DNSProxyXPCContract.currentRuntimeControlProtocolVersion
        else {
            return (
                rejection(operationID: request.operationID, code: .unsupportedProtocolVersion),
                expectedLifecycleEpoch
            )
        }
        guard request.expectedProviderInstanceID == providerInstanceID else {
            return (
                rejection(operationID: request.operationID, code: .providerInstanceMismatch),
                expectedLifecycleEpoch
            )
        }
        guard ProxyConfigurationFingerprint(data: request.targetConfigurationData)
            == request.targetFingerprint
        else {
            return (
                rejection(operationID: request.operationID, code: .fingerprintMismatch),
                expectedLifecycleEpoch
            )
        }
        guard request.targetConfigurationData.count
            <= DNSProxyXPCContract.maximumConfigurationSize
        else {
            return (
                rejection(operationID: request.operationID, code: .invalidTargetConfiguration),
                expectedLifecycleEpoch
            )
        }

        let target: PersistedProxyConfiguration
        do {
            target = try PersistedProxyConfiguration(data: request.targetConfigurationData)
        } catch {
            return (
                rejection(operationID: request.operationID, code: .invalidTargetConfiguration),
                expectedLifecycleEpoch
            )
        }
        guard target.value.generation != request.expectedBaseGeneration else {
            return (
                rejection(operationID: request.operationID, code: .invalidTargetConfiguration),
                expectedLifecycleEpoch
            )
        }

        do {
            let result = try lifecycle.reapplyForRuntimeControl(
                configuration: target,
                expectedBaseGeneration: request.expectedBaseGeneration,
                expectedBaseFingerprint: request.expectedBaseFingerprint,
                expectedLifecycleEpoch: expectedLifecycleEpoch
            )
            let response = switch result.value {
            case let .applied(active):
                activeResponse(
                    request: request,
                    disposition: .applied,
                    active: active
                )
            case let .rejectedUnchanged(active, _), let .rejectedRolledBack(active, _):
                activeResponse(
                    request: request,
                    disposition: .rejectedPreservingBase,
                    active: active,
                    includeConfiguration: true
                )
            case .unrecoverable:
                ProxyReapplyResponse(
                    operationID: request.operationID,
                    disposition: .unrecoverable,
                    providerInstanceID: providerInstanceID
                )
            }
            return (response, result.lifecycleEpoch)
        } catch ProxyLifecycleError.staleLifecycleEpoch {
            return (
                rejection(operationID: request.operationID, code: .staleLifecycleEpoch),
                lifecycle.lifecycleEpoch
            )
        } catch ProxyLifecycleError.baseIdentityMismatch {
            return (
                rejection(operationID: request.operationID, code: .staleBaseIdentity),
                expectedLifecycleEpoch
            )
        } catch ProxyLifecycleError.notStarted {
            return (
                rejection(operationID: request.operationID, code: .runtimeUnavailable),
                expectedLifecycleEpoch
            )
        } catch {
            return (
                rejection(operationID: request.operationID, code: .internalFailure),
                expectedLifecycleEpoch
            )
        }
    }

    private func activeResponse(
        request: ProxyReapplyRequest,
        disposition: ProxyReapplyDisposition,
        active: PersistedProxyConfiguration,
        includeConfiguration: Bool = false
    ) -> ProxyReapplyResponse {
        ProxyReapplyResponse(
            operationID: request.operationID,
            disposition: disposition,
            providerInstanceID: providerInstanceID,
            activeGeneration: active.value.generation,
            activeFingerprint: active.fingerprint,
            preservedConfigurationData: includeConfiguration ? active.data : nil
        )
    }

    private func lifecycle(
        _ requestData: Data,
        action: ProxyLifecycleAction
    ) -> ProxyLifecycleResponse {
        guard admitIngress() else {
            return lifecycleRejection(code: .rateLimited)
        }

        let request: ProxyLifecycleRequest
        do {
            request = try ProxyRuntimeControlCodec.decodeLifecycleRequest(requestData)
        } catch ProxyRuntimeControlCodecError.requestTooLarge {
            return lifecycleRejection(code: .requestTooLarge)
        } catch {
            return lifecycleRejection(code: .malformedRequest)
        }
        guard request.action == action else {
            return lifecycleRejection(
                operationID: request.operationID,
                code: .invalidLifecycleAction
            )
        }

        let beginResult = begin(
            operationID: request.operationID,
            requestData: requestData
        )
        let lifecycleEpoch: UInt64
        switch beginResult {
        case let .proceed(epoch):
            lifecycleEpoch = epoch
            afterBeginMutation()
        case let .replay(.lifecycle(response)):
            return response
        case .replay(.reapply), .reject(.operationIDConflict):
            return lifecycleRejection(
                operationID: request.operationID,
                code: .operationIDConflict
            )
        case let .reject(code):
            return lifecycleRejection(operationID: request.operationID, code: code)
        }

        let (response, terminalEpoch) = performLifecycle(
            request,
            action: action,
            expectedLifecycleEpoch: lifecycleEpoch
        )
        finish(
            operationID: request.operationID,
            requestData: requestData,
            response: .lifecycle(response),
            operationLifecycleEpoch: lifecycleEpoch,
            terminalLifecycleEpoch: terminalEpoch
        )
        return response
    }

    private func performLifecycle(
        _ request: ProxyLifecycleRequest,
        action: ProxyLifecycleAction,
        expectedLifecycleEpoch: UInt64
    ) -> (ProxyLifecycleResponse, UInt64) {
        guard request.schemaVersion == ProxyLifecycleRequest.currentSchemaVersion else {
            return (
                lifecycleRejection(
                    operationID: request.operationID,
                    code: .unsupportedSchemaVersion
                ),
                expectedLifecycleEpoch
            )
        }
        guard request.runtimeControlProtocolVersion
            == DNSProxyXPCContract.currentRuntimeControlProtocolVersion else {
            return (
                lifecycleRejection(
                    operationID: request.operationID,
                    code: .unsupportedProtocolVersion
                ),
                expectedLifecycleEpoch
            )
        }
        guard request.expectedProviderInstanceID == providerInstanceID else {
            return (
                lifecycleRejection(
                    operationID: request.operationID,
                    code: .providerInstanceMismatch
                ),
                expectedLifecycleEpoch
            )
        }
        do {
            let result: ProxyLifecycleMutationResult<PersistedProxyConfiguration>
            let disposition: ProxyLifecycleDisposition
            switch action {
            case .quiesce:
                result = try lifecycle.quiesceForRuntimeControl(
                    expectedGeneration: request.expectedGeneration,
                    expectedFingerprint: request.expectedFingerprint,
                    expectedLifecycleEpoch: expectedLifecycleEpoch
                )
                disposition = .quiesced
            case .resume:
                result = try lifecycle.resumeForRuntimeControl(
                    expectedGeneration: request.expectedGeneration,
                    expectedFingerprint: request.expectedFingerprint,
                    expectedLifecycleEpoch: expectedLifecycleEpoch
                )
                disposition = .resumed
            }
            return (
                ProxyLifecycleResponse(
                    operationID: request.operationID,
                    disposition: disposition,
                    providerInstanceID: providerInstanceID,
                    generation: result.value.value.generation,
                    fingerprint: result.value.fingerprint
                ),
                result.lifecycleEpoch
            )
        } catch ProxyLifecycleError.staleLifecycleEpoch {
            return (
                lifecycleRejection(
                    operationID: request.operationID,
                    code: .staleLifecycleEpoch
                ),
                lifecycle.lifecycleEpoch
            )
        } catch ProxyLifecycleError.baseIdentityMismatch {
            return (
                lifecycleRejection(
                    operationID: request.operationID,
                    code: .staleBaseIdentity
                ),
                expectedLifecycleEpoch
            )
        } catch ProxyLifecycleError.notStarted {
            return (
                lifecycleRejection(
                    operationID: request.operationID,
                    code: .runtimeUnavailable
                ),
                expectedLifecycleEpoch
            )
        } catch ProxyLifecycleError.resumeFailed {
            return (
                ProxyLifecycleResponse(
                    operationID: request.operationID,
                    disposition: .resumeFailed,
                    providerInstanceID: providerInstanceID,
                    generation: request.expectedGeneration,
                    fingerprint: request.expectedFingerprint
                ),
                expectedLifecycleEpoch
            )
        } catch {
            return (
                lifecycleRejection(
                    operationID: request.operationID,
                    code: .internalFailure
                ),
                expectedLifecycleEpoch
            )
        }
    }

    private func lifecycleRejection(
        operationID: UUID? = nil,
        code: ProxyRuntimeControlRejectionCode
    ) -> ProxyLifecycleResponse {
        ProxyLifecycleResponse(
            operationID: operationID,
            disposition: .rejected,
            providerInstanceID: providerInstanceID,
            rejectionCode: code
        )
    }

    private func finish(
        operationID: UUID,
        requestData: Data,
        response: MutationResponse,
        operationLifecycleEpoch: UInt64,
        terminalLifecycleEpoch: UInt64
    ) {
        state.withLock { state in
            let shouldCache = state.inFlightOperation?.operationID == operationID
                && state.inFlightOperation?.requestData == requestData
                && state.inFlightOperation?.lifecycleEpoch == operationLifecycleEpoch
            if state.inFlightOperation?.operationID == operationID,
               state.inFlightOperation?.requestData == requestData {
                state.inFlightOperation = nil
            }
            guard shouldCache else { return }
            state.terminalOperations[operationID] = TerminalOperation(
                requestData: requestData,
                response: response,
                lifecycleEpoch: terminalLifecycleEpoch
            )
            state.terminalOrder.append(operationID)
            if state.terminalOrder.count > 32 {
                let evicted = state.terminalOrder.removeFirst()
                state.terminalOperations.removeValue(forKey: evicted)
            }
        }
    }

    private func discardTerminalOperations(
        notMatching lifecycleEpoch: UInt64,
        state: inout State
    ) {
        let staleOperationIDs = Set(state.terminalOrder.filter { operationID in
            state.terminalOperations[operationID]?.lifecycleEpoch != lifecycleEpoch
        })
        guard !staleOperationIDs.isEmpty else { return }
        for operationID in staleOperationIDs {
            state.terminalOperations.removeValue(forKey: operationID)
        }
        state.terminalOrder.removeAll { staleOperationIDs.contains($0) }
    }
}
