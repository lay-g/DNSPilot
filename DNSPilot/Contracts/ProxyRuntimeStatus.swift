import Foundation

enum ProxyRuntimePhase: String, Codable, Sendable {
    case idle
    case starting
    case ready
    case failed
    case stopping
}

enum ProxyRuntimeErrorCode: String, Codable, Sendable {
    case invalidConfiguration
    case engineInitializationFailed
    case internalFailure
}

struct ProxyRuntimeStatus: Codable, Equatable, Sendable {
    let runtimeControlProtocolVersion: Int?
    let providerInstanceID: UUID?
    let transitionSequence: UInt64?
    let generation: UUID?
    let configurationFingerprint: ProxyConfigurationFingerprint?
    let phase: ProxyRuntimePhase
    let preparedTransactionID: UUID?
    let preparedGeneration: UUID?
    let lastQuiescedGeneration: UUID?
    let errorCode: ProxyRuntimeErrorCode?
    let updatedAt: Date
    let maximumConfigurationSchemaVersion: Int?

    init(
        generation: UUID?,
        phase: ProxyRuntimePhase,
        errorCode: ProxyRuntimeErrorCode?,
        updatedAt: Date,
        maximumConfigurationSchemaVersion: Int? = ActiveProxyConfiguration.currentSchemaVersion,
        runtimeControlProtocolVersion: Int? = nil,
        providerInstanceID: UUID? = nil,
        transitionSequence: UInt64? = nil,
        configurationFingerprint: ProxyConfigurationFingerprint? = nil,
        preparedTransactionID: UUID? = nil,
        preparedGeneration: UUID? = nil,
        lastQuiescedGeneration: UUID? = nil
    ) {
        self.runtimeControlProtocolVersion = runtimeControlProtocolVersion
        self.providerInstanceID = providerInstanceID
        self.transitionSequence = transitionSequence
        self.generation = generation
        self.configurationFingerprint = configurationFingerprint
        self.phase = phase
        self.preparedTransactionID = preparedTransactionID
        self.preparedGeneration = preparedGeneration
        self.lastQuiescedGeneration = lastQuiescedGeneration
        self.errorCode = errorCode
        self.updatedAt = updatedAt
        self.maximumConfigurationSchemaVersion = maximumConfigurationSchemaVersion
    }

    static func idle(
        at date: Date = Date(),
        runtimeControlProtocolVersion: Int? = nil,
        providerInstanceID: UUID? = nil,
        transitionSequence: UInt64? = nil
    ) -> Self {
        Self(
            generation: nil,
            phase: .idle,
            errorCode: nil,
            updatedAt: date,
            runtimeControlProtocolVersion: runtimeControlProtocolVersion,
            providerInstanceID: providerInstanceID,
            transitionSequence: transitionSequence
        )
    }

    func transitioning(
        generation: UUID?,
        configurationFingerprint: ProxyConfigurationFingerprint? = nil,
        phase: ProxyRuntimePhase,
        lastQuiescedGeneration: UUID? = nil,
        errorCode: ProxyRuntimeErrorCode? = nil,
        at date: Date = Date()
    ) -> Self {
        let nextSequence = transitionSequence.map { sequence in
            precondition(sequence < UInt64.max, "Runtime transition sequence exhausted")
            return sequence + 1
        }
        return Self(
            generation: generation,
            phase: phase,
            errorCode: errorCode,
            updatedAt: date,
            maximumConfigurationSchemaVersion: maximumConfigurationSchemaVersion,
            runtimeControlProtocolVersion: runtimeControlProtocolVersion,
            providerInstanceID: providerInstanceID,
            transitionSequence: nextSequence,
            configurationFingerprint: configurationFingerprint,
            lastQuiescedGeneration: lastQuiescedGeneration
        )
    }
}

struct ProxyRuntimeEvidence: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generation: UUID?
    let udpFlowsOffered: UInt64
    let tcpFlowsOffered: UInt64
    let otherFlowsOffered: UInt64
    let flowsAccepted: UInt64
    let flowsRejected: UInt64
    let requestsProcessed: UInt64
    let startedAt: Date?
    let updatedAt: Date

    static func empty(at date: Date = Date()) -> Self {
        Self(
            schemaVersion: currentSchemaVersion,
            generation: nil,
            udpFlowsOffered: 0,
            tcpFlowsOffered: 0,
            otherFlowsOffered: 0,
            flowsAccepted: 0,
            flowsRejected: 0,
            requestsProcessed: 0,
            startedAt: nil,
            updatedAt: date
        )
    }
}
