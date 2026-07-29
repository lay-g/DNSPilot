import Foundation

@objc(DNSProxyXPCProtocol)
protocol DNSProxyXPCProtocol {
    func runtimeStatus(reply: @escaping (Data?, NSError?) -> Void)
    func runtimeEvidence(reply: @escaping (Data?, NSError?) -> Void)
    func reapplyConfiguration(
        _ requestData: Data,
        reply: @escaping (Data?, NSError?) -> Void
    )
    func quiesceRuntime(
        _ requestData: Data,
        reply: @escaping (Data?, NSError?) -> Void
    )
    func resumeRuntime(
        _ requestData: Data,
        reply: @escaping (Data?, NSError?) -> Void
    )
}

enum DNSProxyXPCContract {
    static let readOnlyIdentityProtocolVersion = 2
    static let currentRuntimeControlProtocolVersion = 3
    static let maximumWriteRequestSize = 64 * 1_024
    static let maximumConfigurationSize = 48 * 1_024

    static func makeInterface() -> NSXPCInterface {
        NSXPCInterface(with: DNSProxyXPCProtocol.self)
    }

    static func codeSigningRequirement(teamIdentifier: String, bundleIdentifier: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard
            !teamIdentifier.isEmpty,
            !bundleIdentifier.isEmpty,
            teamIdentifier.unicodeScalars.allSatisfy(allowed.contains),
            bundleIdentifier.unicodeScalars.allSatisfy(allowed.contains)
        else {
            return nil
        }

        return "anchor apple generic and identifier \"\(bundleIdentifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

struct ProxyReapplyRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let runtimeControlProtocolVersion: Int
    let operationID: UUID
    let expectedProviderInstanceID: UUID
    let expectedBaseGeneration: UUID
    let expectedBaseFingerprint: ProxyConfigurationFingerprint
    let targetConfigurationData: Data
    let targetFingerprint: ProxyConfigurationFingerprint

    init(
        operationID: UUID,
        expectedProviderInstanceID: UUID,
        expectedBaseGeneration: UUID,
        expectedBaseFingerprint: ProxyConfigurationFingerprint,
        targetConfigurationData: Data,
        targetFingerprint: ProxyConfigurationFingerprint,
        schemaVersion: Int = Self.currentSchemaVersion,
        runtimeControlProtocolVersion: Int = DNSProxyXPCContract
            .currentRuntimeControlProtocolVersion
    ) {
        self.schemaVersion = schemaVersion
        self.runtimeControlProtocolVersion = runtimeControlProtocolVersion
        self.operationID = operationID
        self.expectedProviderInstanceID = expectedProviderInstanceID
        self.expectedBaseGeneration = expectedBaseGeneration
        self.expectedBaseFingerprint = expectedBaseFingerprint
        self.targetConfigurationData = targetConfigurationData
        self.targetFingerprint = targetFingerprint
    }
}

enum ProxyReapplyDisposition: String, Codable, Sendable {
    case applied
    case rejectedPreservingBase
    case unrecoverable
    case rejected
}

enum ProxyRuntimeControlRejectionCode: String, Codable, Sendable {
    case malformedRequest
    case requestTooLarge
    case unsupportedSchemaVersion
    case unsupportedProtocolVersion
    case invalidTargetConfiguration
    case fingerprintMismatch
    case providerInstanceMismatch
    case staleBaseIdentity
    case staleLifecycleEpoch
    case operationInProgress
    case operationIDConflict
    case rateLimited
    case runtimeUnavailable
    case invalidLifecycleAction
    case internalFailure
}

struct ProxyReapplyResponse: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let runtimeControlProtocolVersion: Int
    let operationID: UUID?
    let disposition: ProxyReapplyDisposition
    let providerInstanceID: UUID
    let activeGeneration: UUID?
    let activeFingerprint: ProxyConfigurationFingerprint?
    let preservedConfigurationData: Data?
    let rejectionCode: ProxyRuntimeControlRejectionCode?

    init(
        operationID: UUID?,
        disposition: ProxyReapplyDisposition,
        providerInstanceID: UUID,
        activeGeneration: UUID? = nil,
        activeFingerprint: ProxyConfigurationFingerprint? = nil,
        preservedConfigurationData: Data? = nil,
        rejectionCode: ProxyRuntimeControlRejectionCode? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        runtimeControlProtocolVersion = DNSProxyXPCContract.currentRuntimeControlProtocolVersion
        self.operationID = operationID
        self.disposition = disposition
        self.providerInstanceID = providerInstanceID
        self.activeGeneration = activeGeneration
        self.activeFingerprint = activeFingerprint
        self.preservedConfigurationData = preservedConfigurationData
        self.rejectionCode = rejectionCode
    }
}

enum ProxyLifecycleAction: String, Codable, Sendable {
    case quiesce
    case resume
}

struct ProxyLifecycleRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let runtimeControlProtocolVersion: Int
    let operationID: UUID
    let action: ProxyLifecycleAction
    let expectedProviderInstanceID: UUID
    let expectedGeneration: UUID
    let expectedFingerprint: ProxyConfigurationFingerprint

    init(
        operationID: UUID,
        action: ProxyLifecycleAction,
        expectedProviderInstanceID: UUID,
        expectedGeneration: UUID,
        expectedFingerprint: ProxyConfigurationFingerprint,
        schemaVersion: Int = Self.currentSchemaVersion,
        runtimeControlProtocolVersion: Int = DNSProxyXPCContract
            .currentRuntimeControlProtocolVersion
    ) {
        self.schemaVersion = schemaVersion
        self.runtimeControlProtocolVersion = runtimeControlProtocolVersion
        self.operationID = operationID
        self.action = action
        self.expectedProviderInstanceID = expectedProviderInstanceID
        self.expectedGeneration = expectedGeneration
        self.expectedFingerprint = expectedFingerprint
    }
}

enum ProxyLifecycleDisposition: String, Codable, Sendable {
    case quiesced
    case resumed
    case resumeFailed
    case rejected
}

struct ProxyLifecycleResponse: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let runtimeControlProtocolVersion: Int
    let operationID: UUID?
    let disposition: ProxyLifecycleDisposition
    let providerInstanceID: UUID
    let generation: UUID?
    let fingerprint: ProxyConfigurationFingerprint?
    let rejectionCode: ProxyRuntimeControlRejectionCode?

    init(
        operationID: UUID?,
        disposition: ProxyLifecycleDisposition,
        providerInstanceID: UUID,
        generation: UUID? = nil,
        fingerprint: ProxyConfigurationFingerprint? = nil,
        rejectionCode: ProxyRuntimeControlRejectionCode? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        runtimeControlProtocolVersion = DNSProxyXPCContract.currentRuntimeControlProtocolVersion
        self.operationID = operationID
        self.disposition = disposition
        self.providerInstanceID = providerInstanceID
        self.generation = generation
        self.fingerprint = fingerprint
        self.rejectionCode = rejectionCode
    }
}

enum ProxyRuntimeControlCodecError: Error, Equatable, Sendable {
    case requestTooLarge
    case malformedRequest
}

enum ProxyRuntimeControlCodec {
    private static let reapplyRequestKeys: Set<String> = [
        "schemaVersion",
        "runtimeControlProtocolVersion",
        "operationID",
        "expectedProviderInstanceID",
        "expectedBaseGeneration",
        "expectedBaseFingerprint",
        "targetConfigurationData",
        "targetFingerprint",
    ]
    private static let lifecycleRequestKeys: Set<String> = [
        "schemaVersion",
        "runtimeControlProtocolVersion",
        "operationID",
        "action",
        "expectedProviderInstanceID",
        "expectedGeneration",
        "expectedFingerprint",
    ]

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    static func decodeReapplyRequest(_ data: Data) throws -> ProxyReapplyRequest {
        try decodeStrictRequest(
            data,
            keys: reapplyRequestKeys,
            as: ProxyReapplyRequest.self
        )
    }

    static func decodeLifecycleRequest(_ data: Data) throws -> ProxyLifecycleRequest {
        try decodeStrictRequest(
            data,
            keys: lifecycleRequestKeys,
            as: ProxyLifecycleRequest.self
        )
    }

    private static func decodeStrictRequest<Value: Decodable>(
        _ data: Data,
        keys: Set<String>,
        as type: Value.Type
    ) throws -> Value {
        guard data.count <= DNSProxyXPCContract.maximumWriteRequestSize else {
            throw ProxyRuntimeControlCodecError.requestTooLarge
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        guard
            let payload = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            ),
            format == .binary,
            let dictionary = payload as? [String: Any],
            Set(dictionary.keys) == keys,
            let request = try? PropertyListDecoder().decode(type, from: data)
        else {
            throw ProxyRuntimeControlCodecError.malformedRequest
        }
        return request
    }
}
