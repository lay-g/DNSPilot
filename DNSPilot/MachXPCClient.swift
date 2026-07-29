import Foundation
import Synchronization

enum MachXPCClientError: LocalizedError, Sendable {
    case missingConfiguration(String)
    case invalidCodeSigningRequirement
    case unavailable
    case discoveryTimedOut
    case requestFailed(String)
    case requestTooLarge
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .missingConfiguration(key):
            "Missing Host configuration: \(key)."
        case .invalidCodeSigningRequirement:
            "The System Extension code-signing requirement could not be constructed."
        case .unavailable:
            "The runtime status service is unavailable."
        case .discoveryTimedOut:
            "The runtime status service discovery timed out."
        case let .requestFailed(message):
            "The runtime status request failed: \(message)"
        case .requestTooLarge:
            "The runtime control request exceeds the maximum allowed size."
        case .invalidResponse:
            "The runtime status service returned an invalid response."
        }
    }
}

protocol ProxyRuntimeStatusProviding: Sendable {
    func runtimeStatus() async throws -> ProxyRuntimeStatus
    func runtimeEvidence() async throws -> ProxyRuntimeEvidence
}

protocol ProxyRuntimeControlling: Sendable {
    func reapplyConfiguration(
        _ request: ProxyReapplyRequest
    ) async throws -> ProxyReapplyResponse
    func quiesceRuntime(
        _ request: ProxyLifecycleRequest
    ) async throws -> ProxyLifecycleResponse
    func resumeRuntime(
        _ request: ProxyLifecycleRequest
    ) async throws -> ProxyLifecycleResponse
}

protocol MachXPCRequesting: ProxyRuntimeStatusProviding, ProxyRuntimeControlling {}

struct MachXPCServiceConfiguration: Equatable, Sendable {
    static let historyDefaultsKey = "DNSProxyMachServiceHistory"
    static let successfulServiceDefaultsKey = "DNSProxyLastSuccessfulMachService"
    static let maximumHistoryCount = 16

    let primaryServiceName: String
    let lastSuccessfulServiceName: String?
    let historicalServiceNames: [String]
    let legacyServiceName: String
    let codeSigningRequirement: String

    var candidateServiceNames: [String] {
        var seen: Set<String> = []
        let fallbackServiceNames = if let lastSuccessfulServiceName {
            [lastSuccessfulServiceName] + historicalServiceNames + [legacyServiceName]
        } else {
            [legacyServiceName] + historicalServiceNames
        }
        return ([primaryServiceName] + fallbackServiceNames).filter {
            seen.insert($0).inserted
        }
    }

    init(bundle: Bundle = .main, userDefaults: UserDefaults = .standard) throws {
        primaryServiceName = try Self.requiredString(
            "DNSProxyMachServiceName",
            in: bundle
        )
        legacyServiceName = try Self.requiredString(
            "DNSProxyLegacyMachServiceName",
            in: bundle
        )
        lastSuccessfulServiceName = Self.loadSuccessfulServiceName(
            legacyServiceName: legacyServiceName,
            userDefaults: userDefaults
        )
        historicalServiceNames = Self.loadAndRecordHistory(
            primaryServiceName: primaryServiceName,
            legacyServiceName: legacyServiceName,
            userDefaults: userDefaults
        )
        let teamIdentifier = try Self.requiredString(
            "DNSPilotExpectedTeamIdentifier",
            in: bundle
        )
        let extensionIdentifier = try Self.requiredString(
            "DNSProxyExtensionIdentifier",
            in: bundle
        )
        guard let requirement = DNSProxyXPCContract.codeSigningRequirement(
            teamIdentifier: teamIdentifier,
            bundleIdentifier: extensionIdentifier
        ) else {
            throw MachXPCClientError.invalidCodeSigningRequirement
        }
        codeSigningRequirement = requirement
    }

    init(
        primaryServiceName: String,
        lastSuccessfulServiceName: String? = nil,
        historicalServiceNames: [String] = [],
        legacyServiceName: String,
        codeSigningRequirement: String
    ) {
        self.primaryServiceName = primaryServiceName
        self.lastSuccessfulServiceName = lastSuccessfulServiceName
        self.historicalServiceNames = historicalServiceNames
        self.legacyServiceName = legacyServiceName
        self.codeSigningRequirement = codeSigningRequirement
    }

    private static func requiredString(_ key: String, in bundle: Bundle) throws -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            throw MachXPCClientError.missingConfiguration(key)
        }
        return value
    }

    static func loadAndRecordHistory(
        primaryServiceName: String,
        legacyServiceName: String,
        userDefaults: UserDefaults
    ) -> [String] {
        let history = recordServiceName(
            primaryServiceName,
            legacyServiceName: legacyServiceName,
            userDefaults: userDefaults
        )
        return history.reversed().filter { $0 != primaryServiceName }
    }

    @discardableResult
    static func recordServiceName(
        _ serviceName: String,
        legacyServiceName: String,
        userDefaults: UserDefaults
    ) -> [String] {
        var history = (userDefaults.stringArray(forKey: historyDefaultsKey) ?? []).filter {
            isVersionedServiceName($0, legacyServiceName: legacyServiceName)
        }
        guard isVersionedServiceName(serviceName, legacyServiceName: legacyServiceName) else {
            userDefaults.set(history, forKey: historyDefaultsKey)
            return history
        }
        history.removeAll { $0 == serviceName }
        history.append(serviceName)
        if history.count > maximumHistoryCount {
            history.removeFirst(history.count - maximumHistoryCount)
        }
        userDefaults.set(history, forKey: historyDefaultsKey)
        return history
    }

    static func recordSuccessfulServiceName(
        _ serviceName: String,
        legacyServiceName: String,
        userDefaults: UserDefaults
    ) {
        guard serviceName == legacyServiceName
                || isVersionedServiceName(serviceName, legacyServiceName: legacyServiceName)
        else {
            userDefaults.removeObject(forKey: successfulServiceDefaultsKey)
            return
        }
        userDefaults.set(serviceName, forKey: successfulServiceDefaultsKey)
    }

    private static func loadSuccessfulServiceName(
        legacyServiceName: String,
        userDefaults: UserDefaults
    ) -> String? {
        guard let serviceName = userDefaults.string(forKey: successfulServiceDefaultsKey),
              serviceName == legacyServiceName
                || isVersionedServiceName(serviceName, legacyServiceName: legacyServiceName)
        else {
            return nil
        }
        return serviceName
    }

    private static func isVersionedServiceName(
        _ serviceName: String,
        legacyServiceName: String
    ) -> Bool {
        let prefix = legacyServiceName + ".build"
        guard serviceName.hasPrefix(prefix), serviceName.count <= 255 else { return false }
        let suffix = serviceName.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
        }
    }
}

struct MachXPCServiceHistoryStore: Sendable {
    let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    func recordSuccessfulDiscovery(
        serviceName: String,
        legacyServiceName: String
    ) {
        let userDefaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        MachXPCServiceConfiguration.recordServiceName(
            serviceName,
            legacyServiceName: legacyServiceName,
            userDefaults: userDefaults
        )
        MachXPCServiceConfiguration.recordSuccessfulServiceName(
            serviceName,
            legacyServiceName: legacyServiceName,
            userDefaults: userDefaults
        )
    }
}

actor MachXPCServiceRouter: MachXPCRequesting {
    typealias ClientFactory = @Sendable (
        _ serviceName: String,
        _ codeSigningRequirement: String
    ) throws -> any MachXPCRequesting

    private let configuration: MachXPCServiceConfiguration?
    private let configurationError: MachXPCClientError?
    private let clientFactory: ClientFactory
    private let discoveryTimeout: Duration
    private let historyStore: MachXPCServiceHistoryStore?
    private var serviceNameByProviderInstanceID: [UUID: String] = [:]
    private var evidenceServiceName: String?

    init(
        bundle: Bundle = .main,
        discoveryTimeout: Duration = .milliseconds(125)
    ) {
        do {
            configuration = try MachXPCServiceConfiguration(bundle: bundle)
            configurationError = nil
        } catch let error as MachXPCClientError {
            configuration = nil
            configurationError = error
        } catch {
            configuration = nil
            configurationError = .requestFailed(error.localizedDescription)
        }
        clientFactory = { serviceName, requirement in
            MachXPCClient(
                serviceName: serviceName,
                codeSigningRequirement: requirement
            )
        }
        self.discoveryTimeout = discoveryTimeout
        historyStore = MachXPCServiceHistoryStore()
    }

    init(
        configuration: MachXPCServiceConfiguration,
        discoveryTimeout: Duration = .milliseconds(125),
        historyStore: MachXPCServiceHistoryStore? = nil,
        clientFactory: @escaping ClientFactory
    ) {
        self.configuration = configuration
        configurationError = nil
        self.clientFactory = clientFactory
        self.discoveryTimeout = discoveryTimeout
        self.historyStore = historyStore
    }

    func runtimeStatus() async throws -> ProxyRuntimeStatus {
        let configuration = try requiredConfiguration()
        var lastError: (any Error)?
        for serviceName in configuration.candidateServiceNames {
            do {
                let status = try await discoverStatus(
                    serviceName: serviceName,
                    configuration: configuration
                )
                recordBinding(status: status, serviceName: serviceName)
                evidenceServiceName = serviceName
                return status
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? MachXPCClientError.unavailable
    }

    func runtimeEvidence() async throws -> ProxyRuntimeEvidence {
        let configuration = try requiredConfiguration()
        let serviceName: String
        if let evidenceServiceName {
            serviceName = evidenceServiceName
        } else {
            _ = try await runtimeStatus()
            guard let evidenceServiceName else {
                throw MachXPCClientError.unavailable
            }
            serviceName = evidenceServiceName
        }
        return try await makeClient(
            serviceName: serviceName,
            configuration: configuration
        ).runtimeEvidence()
    }

    func reapplyConfiguration(
        _ request: ProxyReapplyRequest
    ) async throws -> ProxyReapplyResponse {
        let client = try await mutationClient(
            expectedProviderInstanceID: request.expectedProviderInstanceID
        )
        return try await client.reapplyConfiguration(request)
    }

    func quiesceRuntime(
        _ request: ProxyLifecycleRequest
    ) async throws -> ProxyLifecycleResponse {
        let client = try await mutationClient(
            expectedProviderInstanceID: request.expectedProviderInstanceID
        )
        return try await client.quiesceRuntime(request)
    }

    func resumeRuntime(
        _ request: ProxyLifecycleRequest
    ) async throws -> ProxyLifecycleResponse {
        let client = try await mutationClient(
            expectedProviderInstanceID: request.expectedProviderInstanceID
        )
        return try await client.resumeRuntime(request)
    }

    private func mutationClient(
        expectedProviderInstanceID: UUID
    ) async throws -> any MachXPCRequesting {
        let configuration = try requiredConfiguration()
        if let serviceName = serviceNameByProviderInstanceID[expectedProviderInstanceID] {
            return try makeClient(serviceName: serviceName, configuration: configuration)
        }

        for serviceName in configuration.candidateServiceNames {
            do {
                let status = try await discoverStatus(
                    serviceName: serviceName,
                    configuration: configuration
                )
                recordBinding(status: status, serviceName: serviceName)
                if status.providerInstanceID == expectedProviderInstanceID {
                    evidenceServiceName = serviceName
                    return try makeClient(serviceName: serviceName, configuration: configuration)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        throw MachXPCClientError.invalidResponse
    }

    private func requiredConfiguration() throws -> MachXPCServiceConfiguration {
        if let configuration { return configuration }
        throw configurationError ?? MachXPCClientError.unavailable
    }

    private func makeClient(
        serviceName: String,
        configuration: MachXPCServiceConfiguration
    ) throws -> any MachXPCRequesting {
        try clientFactory(serviceName, configuration.codeSigningRequirement)
    }

    private func discoverStatus(
        serviceName: String,
        configuration: MachXPCServiceConfiguration
    ) async throws -> ProxyRuntimeStatus {
        let client = try makeClient(serviceName: serviceName, configuration: configuration)
        return try await withDiscoveryTimeout {
            try await client.runtimeStatus()
        }
    }

    private func recordBinding(status: ProxyRuntimeStatus, serviceName: String) {
        if let providerInstanceID = status.providerInstanceID {
            serviceNameByProviderInstanceID[providerInstanceID] = serviceName
        }
        if let configuration, let historyStore {
            historyStore.recordSuccessfulDiscovery(
                serviceName: serviceName,
                legacyServiceName: configuration.legacyServiceName
            )
        }
    }

    private func withDiscoveryTimeout<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let (stream, continuation) = AsyncThrowingStream<Value, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let operationTask = Task {
            do {
                continuation.yield(try await operation())
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: discoveryTimeout)
                continuation.finish(throwing: MachXPCClientError.discoveryTimedOut)
            } catch {
                // The operation completed first or the caller was cancelled.
            }
        }
        defer {
            operationTask.cancel()
            timeoutTask.cancel()
        }

        var iterator = stream.makeAsyncIterator()
        guard let value = try await iterator.next() else { throw CancellationError() }
        return value
    }
}

struct MachXPCStatusProvider: ProxyRuntimeStatusProviding {
    private let router: MachXPCServiceRouter

    init(router: MachXPCServiceRouter = MachXPCServiceRouter()) {
        self.router = router
    }

    func runtimeStatus() async throws -> ProxyRuntimeStatus {
        try await router.runtimeStatus()
    }

    func runtimeEvidence() async throws -> ProxyRuntimeEvidence {
        try await router.runtimeEvidence()
    }
}

struct MachXPCRuntimeController: ProxyRuntimeControlling {
    private let router: MachXPCServiceRouter

    init(router: MachXPCServiceRouter = MachXPCServiceRouter()) {
        self.router = router
    }

    func reapplyConfiguration(
        _ request: ProxyReapplyRequest
    ) async throws -> ProxyReapplyResponse {
        try await router.reapplyConfiguration(request)
    }

    func quiesceRuntime(
        _ request: ProxyLifecycleRequest
    ) async throws -> ProxyLifecycleResponse {
        try await router.quiesceRuntime(request)
    }

    func resumeRuntime(
        _ request: ProxyLifecycleRequest
    ) async throws -> ProxyLifecycleResponse {
        try await router.resumeRuntime(request)
    }
}

actor MachXPCClient: MachXPCRequesting {
    private enum RequestKind {
        case status
        case evidence
        case reapply(Data)
        case quiesce(Data)
        case resume(Data)

        var isMutation: Bool {
            switch self {
            case .reapply, .quiesce, .resume:
                true
            case .status, .evidence:
                false
            }
        }

        var maximumResponseSize: Int? {
            isMutation ? DNSProxyXPCContract.maximumWriteRequestSize : nil
        }
    }

    final class Reply<Value: Sendable>: Sendable {
        private enum State {
            case pending
            case waiting(CheckedContinuation<Value, any Error>)
            case sent(CheckedContinuation<Value, any Error>)
            case cancelled
            case finished
        }

        private let state = Mutex(State.pending)
        func install(_ continuation: CheckedContinuation<Value, any Error>) {
            let cancelled = state.withLock { state in
                switch state {
                case .pending:
                    state = .waiting(continuation)
                    return false
                case .cancelled:
                    state = .finished
                    return true
                case .waiting, .sent, .finished:
                    preconditionFailure("XPC continuation installed more than once")
                }
            }
            if cancelled {
                continuation.resume(throwing: CancellationError())
            }
        }

        func beginSending() -> Bool {
            state.withLock { state in
                guard case let .waiting(continuation) = state else { return false }
                state = .sent(continuation)
                return true
            }
        }

        func cancel() {
            let continuation = state.withLock { state -> CheckedContinuation<
                Value,
                any Error
            >? in
                switch state {
                case .pending:
                    state = .cancelled
                    return nil
                case let .waiting(continuation):
                    state = .finished
                    return continuation
                case let .sent(continuation):
                    state = .finished
                    return continuation
                case .cancelled, .finished:
                    return nil
                }
            }
            continuation?.resume(throwing: CancellationError())
        }

        func resume(with result: Result<Value, any Error>) {
            let continuation = state.withLock { state -> CheckedContinuation<
                Value,
                any Error
            >? in
                let continuation: CheckedContinuation<Value, any Error>
                switch state {
                case let .waiting(value), let .sent(value):
                    continuation = value
                case .pending, .cancelled, .finished:
                    return nil
                }
                state = .finished
                return continuation
            }
            continuation?.resume(with: result)
        }
    }

    private let connection: NSXPCConnection

    init(serviceName: String, codeSigningRequirement: String) {
        connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.remoteObjectInterface = DNSProxyXPCContract.makeInterface()
        connection.setCodeSigningRequirement(codeSigningRequirement)
        connection.activate()
    }

    func runtimeStatus() async throws -> ProxyRuntimeStatus {
        try await request(ProxyRuntimeStatus.self, kind: .status)
    }

    func runtimeEvidence() async throws -> ProxyRuntimeEvidence {
        try await request(ProxyRuntimeEvidence.self, kind: .evidence)
    }

    func reapplyConfiguration(
        _ reapplyRequest: ProxyReapplyRequest
    ) async throws -> ProxyReapplyResponse {
        guard reapplyRequest.targetConfigurationData.count
            <= DNSProxyXPCContract.maximumConfigurationSize
        else {
            throw MachXPCClientError.requestTooLarge
        }
        let requestData: Data
        do {
            requestData = try ProxyRuntimeControlCodec.encode(reapplyRequest)
        } catch {
            throw MachXPCClientError.requestFailed(error.localizedDescription)
        }
        guard requestData.count <= DNSProxyXPCContract.maximumWriteRequestSize else {
            throw MachXPCClientError.requestTooLarge
        }

        let response = try await request(
            ProxyReapplyResponse.self,
            kind: .reapply(requestData)
        )
        try Self.validateReapplyResponse(response, for: reapplyRequest)
        return response
    }

    func quiesceRuntime(
        _ request: ProxyLifecycleRequest
    ) async throws -> ProxyLifecycleResponse {
        try await sendLifecycleRequest(request, kind: { .quiesce($0) })
    }

    func resumeRuntime(
        _ request: ProxyLifecycleRequest
    ) async throws -> ProxyLifecycleResponse {
        try await sendLifecycleRequest(request, kind: { .resume($0) })
    }

    static func validateReapplyResponse(
        _ response: ProxyReapplyResponse,
        for request: ProxyReapplyRequest
    ) throws {
        guard
            response.schemaVersion == ProxyReapplyResponse.currentSchemaVersion,
            response.runtimeControlProtocolVersion
                == DNSProxyXPCContract.currentRuntimeControlProtocolVersion
        else {
            throw MachXPCClientError.invalidResponse
        }

        let identifiesRequest = response.operationID == request.operationID
            && response.providerInstanceID == request.expectedProviderInstanceID

        switch response.disposition {
        case .applied:
            guard
                identifiesRequest,
                let target = try? PersistedProxyConfiguration(
                    data: request.targetConfigurationData
                ),
                target.fingerprint == request.targetFingerprint,
                response.activeGeneration == target.value.generation,
                response.activeFingerprint == request.targetFingerprint,
                response.preservedConfigurationData == nil,
                response.rejectionCode == nil
            else {
                throw MachXPCClientError.invalidResponse
            }
        case .rejectedPreservingBase:
            guard
                identifiesRequest,
                let preservedData = response.preservedConfigurationData,
                let preserved = try? PersistedProxyConfiguration(data: preservedData),
                preserved.value.generation == request.expectedBaseGeneration,
                preserved.fingerprint == request.expectedBaseFingerprint,
                response.activeGeneration == request.expectedBaseGeneration,
                response.activeFingerprint == request.expectedBaseFingerprint,
                response.rejectionCode == nil
            else {
                throw MachXPCClientError.invalidResponse
            }
        case .unrecoverable:
            guard
                identifiesRequest,
                response.activeGeneration == nil,
                response.activeFingerprint == nil,
                response.preservedConfigurationData == nil,
                response.rejectionCode == nil
            else {
                throw MachXPCClientError.invalidResponse
            }
        case .rejected:
            guard
                response.activeGeneration == nil,
                response.activeFingerprint == nil,
                response.preservedConfigurationData == nil,
                let rejectionCode = response.rejectionCode
            else {
                throw MachXPCClientError.invalidResponse
            }
            switch rejectionCode {
            case .providerInstanceMismatch:
                guard
                    response.operationID == request.operationID,
                    response.providerInstanceID != request.expectedProviderInstanceID
                else {
                    throw MachXPCClientError.invalidResponse
                }
            case .rateLimited, .malformedRequest, .requestTooLarge:
                guard
                    response.operationID == nil,
                    response.providerInstanceID == request.expectedProviderInstanceID
                else {
                    throw MachXPCClientError.invalidResponse
                }
            default:
                guard identifiesRequest else {
                    throw MachXPCClientError.invalidResponse
                }
            }
        }
    }

    static func validateLifecycleResponse(
        _ response: ProxyLifecycleResponse,
        for request: ProxyLifecycleRequest
    ) throws {
        guard
            response.schemaVersion == ProxyLifecycleResponse.currentSchemaVersion,
            response.runtimeControlProtocolVersion
                == DNSProxyXPCContract.currentRuntimeControlProtocolVersion
        else {
            throw MachXPCClientError.invalidResponse
        }

        let identifiesRequest = response.operationID == request.operationID
            && response.providerInstanceID == request.expectedProviderInstanceID
        switch response.disposition {
        case .quiesced, .resumed, .resumeFailed:
            let actionMatches = switch response.disposition {
            case .quiesced:
                request.action == .quiesce
            case .resumed, .resumeFailed:
                request.action == .resume
            case .rejected:
                false
            }
            guard
                identifiesRequest,
                actionMatches,
                response.generation == request.expectedGeneration,
                response.fingerprint == request.expectedFingerprint,
                response.rejectionCode == nil
            else {
                throw MachXPCClientError.invalidResponse
            }
        case .rejected:
            guard
                response.generation == nil,
                response.fingerprint == nil,
                let rejectionCode = response.rejectionCode
            else {
                throw MachXPCClientError.invalidResponse
            }
            switch rejectionCode {
            case .providerInstanceMismatch:
                guard
                    response.operationID == request.operationID,
                    response.providerInstanceID != request.expectedProviderInstanceID
                else {
                    throw MachXPCClientError.invalidResponse
                }
            case .rateLimited, .malformedRequest, .requestTooLarge:
                guard
                    response.operationID == nil,
                    response.providerInstanceID == request.expectedProviderInstanceID
                else {
                    throw MachXPCClientError.invalidResponse
                }
            default:
                guard identifiesRequest else {
                    throw MachXPCClientError.invalidResponse
                }
            }
        }
    }

    private func sendLifecycleRequest(
        _ lifecycleRequest: ProxyLifecycleRequest,
        kind: (Data) -> RequestKind
    ) async throws -> ProxyLifecycleResponse {
        let requestData: Data
        do {
            requestData = try ProxyRuntimeControlCodec.encode(lifecycleRequest)
        } catch {
            throw MachXPCClientError.requestFailed(error.localizedDescription)
        }
        guard requestData.count <= DNSProxyXPCContract.maximumWriteRequestSize else {
            throw MachXPCClientError.requestTooLarge
        }
        let response = try await request(
            ProxyLifecycleResponse.self,
            kind: kind(requestData)
        )
        try Self.validateLifecycleResponse(response, for: lifecycleRequest)
        return response
    }

    private func request<Value: Decodable & Sendable>(
        _ type: Value.Type,
        kind: RequestKind
    ) async throws -> Value {
        let reply = Reply<Value>()
        defer { connection.invalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                let errorHandler: (any Error) -> Void = { error in
                    reply.resume(with: .failure(
                        MachXPCClientError.requestFailed(error.localizedDescription)
                    ))
                }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler)
                    as? DNSProxyXPCProtocol else {
                    reply.resume(with: .failure(MachXPCClientError.unavailable))
                    return
                }

                let callback: (Data?, NSError?) -> Void = { data, error in
                    if let error {
                        reply.resume(with: .failure(
                            MachXPCClientError.requestFailed(error.localizedDescription)
                        ))
                        return
                    }
                    guard let data else {
                        reply.resume(with: .failure(MachXPCClientError.invalidResponse))
                        return
                    }
                    if let maximumResponseSize = kind.maximumResponseSize,
                       data.count > maximumResponseSize {
                        reply.resume(with: .failure(MachXPCClientError.invalidResponse))
                        return
                    }
                    do {
                        let value = try PropertyListDecoder().decode(
                            type,
                            from: data
                        )
                        reply.resume(with: .success(value))
                    } catch {
                        reply.resume(with: .failure(MachXPCClientError.invalidResponse))
                    }
                }

                guard reply.beginSending() else { return }
                switch kind {
                case .status:
                    proxy.runtimeStatus(reply: callback)
                case .evidence:
                    proxy.runtimeEvidence(reply: callback)
                case let .reapply(requestData):
                    proxy.reapplyConfiguration(requestData, reply: callback)
                case let .quiesce(requestData):
                    proxy.quiesceRuntime(requestData, reply: callback)
                case let .resume(requestData):
                    proxy.resumeRuntime(requestData, reply: callback)
                }
            }
        } onCancel: {
            reply.cancel()
        }
    }
}
