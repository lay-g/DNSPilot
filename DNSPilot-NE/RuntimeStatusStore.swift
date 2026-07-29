import Foundation
import Synchronization

final class RuntimeStatusStore: ProxyRuntimeStatusRecording, Sendable {
    static let shared = RuntimeStatusStore()

    let providerInstanceID: UUID
    private let status: Mutex<ProxyRuntimeStatus>
    private let evidence: Mutex<ProxyRuntimeEvidence>

    private init() {
        let now = Date()
        let providerInstanceID = UUID()
        self.providerInstanceID = providerInstanceID
        status = Mutex(ProxyRuntimeStatus.idle(
            at: now,
            runtimeControlProtocolVersion: DNSProxyXPCContract.currentRuntimeControlProtocolVersion,
            providerInstanceID: providerInstanceID,
            transitionSequence: 0
        ))
        evidence = Mutex(ProxyRuntimeEvidence.empty(at: now))
    }

    func snapshot() -> ProxyRuntimeStatus {
        status.withLock { $0 }
    }

    func evidenceSnapshot() -> ProxyRuntimeEvidence {
        evidence.withLock { $0 }
    }

    func update(
        generation: UUID?,
        configurationFingerprint: ProxyConfigurationFingerprint? = nil,
        phase: ProxyRuntimePhase,
        lastQuiescedGeneration: UUID? = nil,
        errorCode: ProxyRuntimeErrorCode? = nil
    ) {
        status.withLock {
            $0 = $0.transitioning(
                generation: generation,
                configurationFingerprint: configurationFingerprint,
                phase: phase,
                lastQuiescedGeneration: lastQuiescedGeneration,
                errorCode: errorCode,
                at: Date()
            )
        }
    }

    func beginEvidence(generation: UUID) {
        let date = Date()
        evidence.withLock {
            $0 = ProxyRuntimeEvidence(
                schemaVersion: ProxyRuntimeEvidence.currentSchemaVersion,
                generation: generation,
                udpFlowsOffered: 0,
                tcpFlowsOffered: 0,
                otherFlowsOffered: 0,
                flowsAccepted: 0,
                flowsRejected: 0,
                requestsProcessed: 0,
                startedAt: date,
                updatedAt: date
            )
        }
    }

    func endEvidence(generation: UUID) {
        let date = Date()
        evidence.withLock { current in
            guard current.generation == generation else { return }
            current = .empty(at: date)
        }
    }

    func recordFlow(
        generation: UUID,
        kind: RuntimeFlowKind,
        accepted: Bool,
        at date: Date = Date()
    ) {
        evidence.withLock { current in
            guard current.generation == generation else { return }
            current = ProxyRuntimeEvidence(
                schemaVersion: current.schemaVersion,
                generation: current.generation,
                udpFlowsOffered: current.udpFlowsOffered + (kind == .udp ? 1 : 0),
                tcpFlowsOffered: current.tcpFlowsOffered + (kind == .tcp ? 1 : 0),
                otherFlowsOffered: current.otherFlowsOffered + (kind == .other ? 1 : 0),
                flowsAccepted: current.flowsAccepted + (accepted ? 1 : 0),
                flowsRejected: current.flowsRejected + (accepted ? 0 : 1),
                requestsProcessed: current.requestsProcessed,
                startedAt: current.startedAt,
                updatedAt: date
            )
        }
    }

    func recordRequest(generation: UUID, at date: Date = Date()) {
        evidence.withLock { current in
            guard current.generation == generation else { return }
            current = ProxyRuntimeEvidence(
                schemaVersion: current.schemaVersion,
                generation: current.generation,
                udpFlowsOffered: current.udpFlowsOffered,
                tcpFlowsOffered: current.tcpFlowsOffered,
                otherFlowsOffered: current.otherFlowsOffered,
                flowsAccepted: current.flowsAccepted,
                flowsRejected: current.flowsRejected,
                requestsProcessed: current.requestsProcessed + 1,
                startedAt: current.startedAt,
                updatedAt: date
            )
        }
    }
}

enum RuntimeFlowKind: Sendable {
    case udp
    case tcp
    case other
}
