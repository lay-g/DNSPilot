import Foundation
import Testing
@testable import DNSPilot

enum FakeTestError: LocalizedError, Sendable {
    case unavailable
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Fake runtime status is unavailable."
        case .saveFailed:
            "Fake manager save failed."
        }
    }
}

enum FakeDNSProxyManagerEvent: Sendable, Equatable {
    case load
    case enable(generation: UUID, profileID: UUID)
    case fencedEnable(expectedGeneration: UUID?, targetGeneration: UUID)
    case disable(expectedGeneration: UUID?)
    case replace(expectedGeneration: UUID, targetGeneration: UUID)
}

actor FakeDNSProxyManager: DNSProxyManagerManaging {
    private var snapshot: DNSProxyManagerSnapshot
    private var loadFailures: [FakeManagerFailure]
    private var enableFailures: [FakeManagerFailure]
    private var disableFailures: [FakeManagerFailure]
    private var replaceFailures: [FakeManagerFailure]
    private var disableReplacementBeforeSave: ActiveProxyConfiguration?
    private var reenableAfterDisableSave: ActiveProxyConfiguration?
    private let beforeEnableSave: @Sendable (ActiveProxyConfiguration) async -> Void
    private let beforeDisableSave: @Sendable (UUID?) async -> Void
    private(set) var events: [FakeDNSProxyManagerEvent] = []
    private(set) var loadCount = 0
    private(set) var enableSaveCount = 0
    private(set) var disableSaveCount = 0
    private(set) var enabledConfigurations: [ActiveProxyConfiguration] = []

    init(
        isEnabled: Bool,
        activeConfiguration: ActiveProxyConfiguration? = nil,
        loadFailures: [FakeManagerFailure] = [],
        enableFailures: [FakeManagerFailure] = [],
        disableFailures: [FakeManagerFailure] = [],
        replaceFailures: [FakeManagerFailure] = [],
        disableReplacementBeforeSave: ActiveProxyConfiguration? = nil,
        reenableAfterDisableSave: ActiveProxyConfiguration? = nil,
        beforeEnableSave: @escaping @Sendable (ActiveProxyConfiguration) async -> Void = { _ in },
        beforeDisableSave: @escaping @Sendable (UUID?) async -> Void = { _ in }
    ) {
        snapshot = Self.makeSnapshot(
            isEnabled: isEnabled,
            activeConfiguration: activeConfiguration
        )
        self.loadFailures = loadFailures
        self.enableFailures = enableFailures
        self.disableFailures = disableFailures
        self.replaceFailures = replaceFailures
        self.disableReplacementBeforeSave = disableReplacementBeforeSave
        self.reenableAfterDisableSave = reenableAfterDisableSave
        self.beforeEnableSave = beforeEnableSave
        self.beforeDisableSave = beforeDisableSave
    }

    init(
        isEnabled: Bool,
        persistedConfiguration: PersistedProxyConfiguration?,
        ownerIdentity: DNSProxyManagerOwnerIdentity? = nil
    ) {
        snapshot = DNSProxyManagerSnapshot(
            isEnabled: isEnabled,
            persistedConfiguration: persistedConfiguration,
            ownerIdentity: ownerIdentity ?? persistedConfiguration.map {
                Self.ownerIdentity(for: $0)
            }
        )
        loadFailures = []
        enableFailures = []
        disableFailures = []
        replaceFailures = []
        disableReplacementBeforeSave = nil
        reenableAfterDisableSave = nil
        beforeEnableSave = { _ in }
        beforeDisableSave = { _ in }
    }

    var currentSnapshot: DNSProxyManagerSnapshot {
        snapshot
    }

    func replaceState(
        isEnabled: Bool,
        activeConfiguration: ActiveProxyConfiguration?
    ) {
        snapshot = Self.makeSnapshot(
            isEnabled: isEnabled,
            activeConfiguration: activeConfiguration
        )
    }


    func replaceState(
        isEnabled: Bool,
        persistedConfiguration: PersistedProxyConfiguration?,
        ownerIdentity: DNSProxyManagerOwnerIdentity? = nil
    ) {
        snapshot = DNSProxyManagerSnapshot(
            isEnabled: isEnabled,
            persistedConfiguration: persistedConfiguration,
            ownerIdentity: ownerIdentity ?? persistedConfiguration.map {
                Self.ownerIdentity(for: $0)
            }
        )
    }

    func replaceOwnerIdentity(_ ownerIdentity: DNSProxyManagerOwnerIdentity?) {
        snapshot = DNSProxyManagerSnapshot(
            isEnabled: snapshot.isEnabled,
            persistedConfiguration: snapshot.persistedConfiguration,
            ownerIdentity: ownerIdentity
        )
    }

    func loadSnapshot() throws -> DNSProxyManagerSnapshot {
        events.append(.load)
        loadCount += 1
        try consumeFailure(&loadFailures)
        return snapshot
    }

    func saveEnabledConfigurationIfDisabled(
        _ configuration: ActiveProxyConfiguration,
        providerBundleIdentifier: String
    ) async throws -> DNSProxyManagerEnableResult {
        events.append(.enable(
            generation: configuration.generation,
            profileID: configuration.profileID
        ))
        enableSaveCount += 1
        enabledConfigurations.append(configuration)
        await beforeEnableSave(configuration)
        try consumeFailure(&enableFailures)
        guard !snapshot.isEnabled else { return .alreadyEnabled(snapshot) }
        snapshot = Self.makeSnapshot(
            isEnabled: true,
            activeConfiguration: configuration,
            providerBundleIdentifier: providerBundleIdentifier
        )
        return .enabled
    }

    func saveEnabledConfiguration(
        _ configuration: PersistedProxyConfiguration,
        providerBundleIdentifier: String,
        ifDisabledSnapshotMatches expected: DNSProxyManagerSnapshot
    ) async throws -> DNSProxyManagerFencedEnableResult {
        events.append(.fencedEnable(
            expectedGeneration: expected.activeConfiguration?.generation,
            targetGeneration: configuration.value.generation
        ))
        enableSaveCount += 1
        enabledConfigurations.append(configuration.value)
        await beforeEnableSave(configuration.value)
        try consumeFailure(&enableFailures)
        guard !snapshot.isEnabled, snapshot == expected else {
            return .configurationChanged(snapshot)
        }
        snapshot = Self.makeSnapshot(
            isEnabled: true,
            activeConfiguration: configuration.value,
            providerBundleIdentifier: providerBundleIdentifier
        )
        return .enabled(snapshot)
    }

    func saveDisabled(
        ifGenerationMatches expectedGeneration: UUID?
    ) async throws -> DNSProxyManagerDisableResult {
        events.append(.disable(expectedGeneration: expectedGeneration))
        disableSaveCount += 1
        await beforeDisableSave(expectedGeneration)
        try consumeFailure(&disableFailures)
        if let replacement = disableReplacementBeforeSave {
            disableReplacementBeforeSave = nil
            snapshot = Self.makeSnapshot(
                isEnabled: true,
                activeConfiguration: replacement
            )
        }
        if
            let expectedGeneration,
            snapshot.activeConfiguration?.generation != expectedGeneration
        {
            return .generationChanged(snapshot)
        }
        guard snapshot.isEnabled else { return .alreadyDisabled }
        snapshot = DNSProxyManagerSnapshot(
            isEnabled: false,
            persistedConfiguration: snapshot.persistedConfiguration,
            ownerIdentity: snapshot.ownerIdentity
        )
        if let replacement = reenableAfterDisableSave {
            reenableAfterDisableSave = nil
            snapshot = Self.makeSnapshot(
                isEnabled: true,
                activeConfiguration: replacement
            )
        }
        return .disabled
    }

    func saveDisabled(
        ifCurrentMatches expected: DNSProxyManagerSnapshot
    ) async throws -> DNSProxyManagerDisableResult {
        events.append(.disable(expectedGeneration: expected.activeConfiguration?.generation))
        disableSaveCount += 1
        await beforeDisableSave(expected.activeConfiguration?.generation)
        try consumeFailure(&disableFailures)
        if let replacement = disableReplacementBeforeSave {
            disableReplacementBeforeSave = nil
            snapshot = Self.makeSnapshot(
                isEnabled: true,
                activeConfiguration: replacement
            )
        }
        if !snapshot.isEnabled {
            guard
                snapshot.persistedConfiguration == expected.persistedConfiguration,
                snapshot.ownerIdentity == expected.ownerIdentity
            else {
                return .generationChanged(snapshot)
            }
            return .alreadyDisabled
        }
        guard snapshot == expected else {
            return .generationChanged(snapshot)
        }
        snapshot = DNSProxyManagerSnapshot(
            isEnabled: false,
            persistedConfiguration: snapshot.persistedConfiguration,
            ownerIdentity: snapshot.ownerIdentity
        )
        if let replacement = reenableAfterDisableSave {
            reenableAfterDisableSave = nil
            snapshot = Self.makeSnapshot(
                isEnabled: true,
                activeConfiguration: replacement
            )
        }
        return .disabled
    }

    func replaceEnabledConfiguration(
        _ target: PersistedProxyConfiguration,
        ifCurrentMatches expected: DNSProxyManagerSnapshot
    ) throws -> DNSProxyManagerReplaceResult {
        events.append(.replace(
            expectedGeneration: expected.activeConfiguration?.generation ?? UUID(),
            targetGeneration: target.value.generation
        ))
        try consumeFailure(&replaceFailures)
        guard snapshot.isEnabled, snapshot == expected else {
            return .configurationChanged(snapshot)
        }
        snapshot = DNSProxyManagerSnapshot(
            isEnabled: true,
            persistedConfiguration: target,
            ownerIdentity: DNSProxyManagerOwnerIdentity(
                providerBundleIdentifier: snapshot.ownerIdentity?.providerBundleIdentifier,
                providerConfigurationFingerprint: Self.providerBundleFingerprint(for: target),
                localizedDescription: snapshot.ownerIdentity?.localizedDescription
            )
        )
        return .replaced(snapshot)
    }

    private func consumeFailure(_ failures: inout [FakeManagerFailure]) throws {
        guard !failures.isEmpty else { return }
        switch failures.removeFirst() {
        case .none:
            return
        case .configurationStale:
            throw DNSProxyManagerClientError.configurationStale
        case let .configurationStaleReplacing(configuration):
            snapshot = Self.makeSnapshot(
                isEnabled: true,
                activeConfiguration: configuration
            )
            throw DNSProxyManagerClientError.configurationStale
        case .saveFailed:
            throw FakeTestError.saveFailed
        }
    }

    private static func makeSnapshot(
        isEnabled: Bool,
        activeConfiguration: ActiveProxyConfiguration?,
        providerBundleIdentifier: String = "com.example.DNSProxy"
    ) -> DNSProxyManagerSnapshot {
        let persisted = activeConfiguration.flatMap {
            try? PersistedProxyConfiguration(value: $0)
        }
        return DNSProxyManagerSnapshot(
            isEnabled: isEnabled,
            persistedConfiguration: persisted,
            ownerIdentity: persisted.map {
                ownerIdentity(for: $0, providerBundleIdentifier: providerBundleIdentifier)
            }
        )
    }

    private static func ownerIdentity(
        for configuration: PersistedProxyConfiguration,
        providerBundleIdentifier: String = "com.example.DNSProxy"
    ) -> DNSProxyManagerOwnerIdentity {
        DNSProxyManagerOwnerIdentity(
            providerBundleIdentifier: providerBundleIdentifier,
            providerConfigurationFingerprint: providerBundleFingerprint(for: configuration),
            localizedDescription: "DNSPilot"
        )
    }

    private static func providerBundleFingerprint(
        for configuration: PersistedProxyConfiguration
    ) -> ProxyConfigurationFingerprint {
        ProxyConfigurationFingerprint(
            data: Data("provider-bundle:\(configuration.fingerprint.rawValue)".utf8)
        )
    }
}

enum FakeManagerFailure: Sendable {
    case none
    case configurationStale
    case configurationStaleReplacing(ActiveProxyConfiguration)
    case saveFailed
}

actor CancellationProbe {
    private(set) var wasCancelled = false

    func recordCancellation() {
        wasCancelled = true
    }

    func waitUntilCancelled(timeout: Duration = .seconds(1)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !wasCancelled, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return wasCancelled
    }
}

actor QuiescenceAvailability {
    private var isAvailable = false

    func allow() {
        isAvailable = true
    }

    func response(
        for request: ProxyLifecycleRequest
    ) throws -> ProxyLifecycleResponse {
        guard isAvailable else { throw FakeTestError.unavailable }
        return ProxyLifecycleResponse(
            operationID: request.operationID,
            disposition: .quiesced,
            providerInstanceID: request.expectedProviderInstanceID,
            generation: request.expectedGeneration,
            fingerprint: request.expectedFingerprint
        )
    }
}

actor FakeUpstreamValidator: UpstreamValidating {
    private let action: @Sendable () async throws -> Void
    private(set) var validationCount = 0
    private(set) var validatedUpstream: DNSUpstream?
    private(set) var validatedUpstreams: [DNSUpstream] = []

    init(action: @escaping @Sendable () async throws -> Void = {}) {
        self.action = action
    }

    func validate(_ upstream: DNSUpstream) async throws {
        validationCount += 1
        validatedUpstream = upstream
        validatedUpstreams.append(upstream)
        try await action()
    }
}

actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

actor FakeRuntimeStatusProvider: ProxyRuntimeStatusProviding {
    private let response: @Sendable () async throws -> ProxyRuntimeStatus
    private(set) var requestCount = 0

    init(response: @escaping @Sendable () async throws -> ProxyRuntimeStatus) {
        self.response = response
    }

    func runtimeStatus() async throws -> ProxyRuntimeStatus {
        requestCount += 1
        return try await response()
    }

    func runtimeEvidence() -> ProxyRuntimeEvidence {
        .empty()
    }
}

actor ScriptedRuntimeStatusProvider: ProxyRuntimeStatusProviding {
    private var responses: [ProxyRuntimeStatus]
    private(set) var requestCount = 0

    init(_ responses: [ProxyRuntimeStatus]) {
        precondition(!responses.isEmpty)
        self.responses = responses
    }

    func runtimeStatus() -> ProxyRuntimeStatus {
        requestCount += 1
        if responses.count > 1 {
            return responses.removeFirst()
        }
        return responses[0]
    }

    func runtimeEvidence() -> ProxyRuntimeEvidence {
        .empty()
    }
}

actor FakeRuntimeController: ProxyRuntimeControlling {
    private let response: @Sendable (ProxyReapplyRequest) async throws
        -> ProxyReapplyResponse
    private let quiesceResponse: @Sendable (ProxyLifecycleRequest) async throws
        -> ProxyLifecycleResponse
    private let resumeResponse: @Sendable (ProxyLifecycleRequest) async throws
        -> ProxyLifecycleResponse
    private(set) var requests: [ProxyReapplyRequest] = []
    private(set) var quiesceRequests: [ProxyLifecycleRequest] = []
    private(set) var resumeRequests: [ProxyLifecycleRequest] = []

    init(
        response: @escaping @Sendable (ProxyReapplyRequest) async throws
            -> ProxyReapplyResponse,
        quiesceResponse: @escaping @Sendable (ProxyLifecycleRequest) async throws
            -> ProxyLifecycleResponse = { request in
                ProxyLifecycleResponse(
                    operationID: request.operationID,
                    disposition: .quiesced,
                    providerInstanceID: request.expectedProviderInstanceID,
                    generation: request.expectedGeneration,
                    fingerprint: request.expectedFingerprint
                )
            },
        resumeResponse: @escaping @Sendable (ProxyLifecycleRequest) async throws
            -> ProxyLifecycleResponse = { request in
                ProxyLifecycleResponse(
                    operationID: request.operationID,
                    disposition: .resumed,
                    providerInstanceID: request.expectedProviderInstanceID,
                    generation: request.expectedGeneration,
                    fingerprint: request.expectedFingerprint
                )
            }
    ) {
        self.response = response
        self.quiesceResponse = quiesceResponse
        self.resumeResponse = resumeResponse
    }

    func reapplyConfiguration(
        _ request: ProxyReapplyRequest
    ) async throws -> ProxyReapplyResponse {
        requests.append(request)
        return try await response(request)
    }

    func quiesceRuntime(
        _ request: ProxyLifecycleRequest
    ) async throws -> ProxyLifecycleResponse {
        quiesceRequests.append(request)
        return try await quiesceResponse(request)
    }

    func resumeRuntime(
        _ request: ProxyLifecycleRequest
    ) async throws -> ProxyLifecycleResponse {
        resumeRequests.append(request)
        return try await resumeResponse(request)
    }
}

enum FakeRuntimeReapplyOutcome: Sendable {
    case applied
    case rejectedPreservingBase
    case rejected(ProxyRuntimeControlRejectionCode)
    case unrecoverable
    case failure(FakeTestError)
}

actor FakeRuntimeSession: ProxyRuntimeStatusProviding, ProxyRuntimeControlling {
    private let providerInstanceID: UUID
    private var activeConfiguration: PersistedProxyConfiguration?
    private var quiescedConfiguration: PersistedProxyConfiguration?
    private var outcomes: [FakeRuntimeReapplyOutcome]
    private let beforeResume: @Sendable (ProxyLifecycleRequest) async -> Void
    private(set) var requests: [ProxyReapplyRequest] = []
    private(set) var quiesceRequests: [ProxyLifecycleRequest] = []
    private(set) var resumeRequests: [ProxyLifecycleRequest] = []
    private(set) var statusRequestCount = 0

    init(
        activeConfiguration: PersistedProxyConfiguration?,
        providerInstanceID: UUID = UUID(),
        outcomes: [FakeRuntimeReapplyOutcome] = [.applied],
        beforeResume: @escaping @Sendable (ProxyLifecycleRequest) async -> Void = { _ in }
    ) {
        self.activeConfiguration = activeConfiguration
        self.providerInstanceID = providerInstanceID
        self.outcomes = outcomes
        self.beforeResume = beforeResume
    }

    func runtimeStatus() -> ProxyRuntimeStatus {
        statusRequestCount += 1
        guard let activeConfiguration else {
            if let quiescedConfiguration {
                return ProxyRuntimeStatus(
                    generation: nil,
                    phase: .idle,
                    errorCode: nil,
                    updatedAt: Date(timeIntervalSince1970: 0),
                    maximumConfigurationSchemaVersion: ActiveProxyConfiguration
                        .currentSchemaVersion,
                    runtimeControlProtocolVersion: DNSProxyXPCContract
                        .currentRuntimeControlProtocolVersion,
                    providerInstanceID: providerInstanceID,
                    lastQuiescedGeneration: quiescedConfiguration.value.generation
                )
            }
            return ProxyRuntimeStatus(
                generation: nil,
                phase: .failed,
                errorCode: .internalFailure,
                updatedAt: Date(timeIntervalSince1970: 0),
                maximumConfigurationSchemaVersion: ActiveProxyConfiguration
                    .currentSchemaVersion,
                runtimeControlProtocolVersion: DNSProxyXPCContract
                    .currentRuntimeControlProtocolVersion,
                providerInstanceID: providerInstanceID
            )
        }
        return ProxyRuntimeStatus(
            generation: activeConfiguration.value.generation,
            phase: .ready,
            errorCode: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            maximumConfigurationSchemaVersion: ActiveProxyConfiguration
                .currentSchemaVersion,
            runtimeControlProtocolVersion: DNSProxyXPCContract
                .currentRuntimeControlProtocolVersion,
            providerInstanceID: providerInstanceID,
            configurationFingerprint: activeConfiguration.fingerprint
        )
    }

    func runtimeEvidence() -> ProxyRuntimeEvidence {
        .empty()
    }

    func reapplyConfiguration(
        _ request: ProxyReapplyRequest
    ) throws -> ProxyReapplyResponse {
        requests.append(request)
        let outcome = outcomes.isEmpty ? .applied : outcomes.removeFirst()
        switch outcome {
        case .applied:
            let target = try PersistedProxyConfiguration(
                data: request.targetConfigurationData
            )
            activeConfiguration = target
            return ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .applied,
                providerInstanceID: providerInstanceID,
                activeGeneration: target.value.generation,
                activeFingerprint: target.fingerprint
            )
        case .rejectedPreservingBase:
            let active = activeConfiguration
            return ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .rejectedPreservingBase,
                providerInstanceID: providerInstanceID,
                activeGeneration: active?.value.generation,
                activeFingerprint: active?.fingerprint,
                preservedConfigurationData: active?.data
            )
        case let .rejected(code):
            return ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .rejected,
                providerInstanceID: providerInstanceID,
                rejectionCode: code
            )
        case .unrecoverable:
            activeConfiguration = nil
            return ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .unrecoverable,
                providerInstanceID: providerInstanceID
            )
        case let .failure(error):
            throw error
        }
    }

    func quiesceRuntime(
        _ request: ProxyLifecycleRequest
    ) -> ProxyLifecycleResponse {
        quiesceRequests.append(request)
        guard
            let activeConfiguration,
            request.expectedProviderInstanceID == providerInstanceID,
            request.expectedGeneration == activeConfiguration.value.generation,
            request.expectedFingerprint == activeConfiguration.fingerprint
        else {
            return ProxyLifecycleResponse(
                operationID: request.operationID,
                disposition: .rejected,
                providerInstanceID: providerInstanceID,
                rejectionCode: .staleBaseIdentity
            )
        }
        self.activeConfiguration = nil
        quiescedConfiguration = activeConfiguration
        return ProxyLifecycleResponse(
            operationID: request.operationID,
            disposition: .quiesced,
            providerInstanceID: providerInstanceID,
            generation: activeConfiguration.value.generation,
            fingerprint: activeConfiguration.fingerprint
        )
    }

    func resumeRuntime(
        _ request: ProxyLifecycleRequest
    ) async -> ProxyLifecycleResponse {
        resumeRequests.append(request)
        await beforeResume(request)
        guard
            let quiescedConfiguration,
            request.expectedProviderInstanceID == providerInstanceID,
            request.expectedGeneration == quiescedConfiguration.value.generation,
            request.expectedFingerprint == quiescedConfiguration.fingerprint
        else {
            return ProxyLifecycleResponse(
                operationID: request.operationID,
                disposition: .rejected,
                providerInstanceID: providerInstanceID,
                rejectionCode: .staleBaseIdentity
            )
        }
        self.quiescedConfiguration = nil
        activeConfiguration = quiescedConfiguration
        return ProxyLifecycleResponse(
            operationID: request.operationID,
            disposition: .resumed,
            providerInstanceID: providerInstanceID,
            generation: quiescedConfiguration.value.generation,
            fingerprint: quiescedConfiguration.fingerprint
        )
    }
}

actor LostReplyRuntimeSession: ProxyRuntimeStatusProviding, ProxyRuntimeControlling {
    private let providerInstanceID = UUID()
    private let replyGate: AsyncGate
    private var activeConfiguration: PersistedProxyConfiguration
    private(set) var requests: [ProxyReapplyRequest] = []

    init(
        activeConfiguration: PersistedProxyConfiguration,
        replyGate: AsyncGate
    ) {
        self.activeConfiguration = activeConfiguration
        self.replyGate = replyGate
    }

    func runtimeStatus() -> ProxyRuntimeStatus {
        ProxyRuntimeStatus(
            generation: activeConfiguration.value.generation,
            phase: .ready,
            errorCode: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            runtimeControlProtocolVersion: DNSProxyXPCContract
                .currentRuntimeControlProtocolVersion,
            providerInstanceID: providerInstanceID,
            configurationFingerprint: activeConfiguration.fingerprint
        )
    }

    func runtimeEvidence() -> ProxyRuntimeEvidence {
        .empty()
    }

    func reapplyConfiguration(
        _ request: ProxyReapplyRequest
    ) async throws -> ProxyReapplyResponse {
        requests.append(request)
        let target = try PersistedProxyConfiguration(
            data: request.targetConfigurationData
        )
        activeConfiguration = target
        await replyGate.wait()
        return ProxyReapplyResponse(
            operationID: request.operationID,
            disposition: .applied,
            providerInstanceID: providerInstanceID,
            activeGeneration: target.value.generation,
            activeFingerprint: target.fingerprint
        )
    }

    func quiesceRuntime(
        _ request: ProxyLifecycleRequest
    ) throws -> ProxyLifecycleResponse {
        throw FakeTestError.unavailable
    }

    func resumeRuntime(
        _ request: ProxyLifecycleRequest
    ) throws -> ProxyLifecycleResponse {
        throw FakeTestError.unavailable
    }
}

actor CapabilityThenHangingStatusProvider: ProxyRuntimeStatusProviding {
    private let gate: AsyncGate
    private(set) var requestCount = 0

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func runtimeStatus() async -> ProxyRuntimeStatus {
        requestCount += 1
        if requestCount == 1 {
            return .idle()
        }
        await gate.wait()
        return .idle()
    }

    func runtimeEvidence() -> ProxyRuntimeEvidence {
        .empty()
    }
}

func makeController(
    manager: FakeDNSProxyManager,
    validator: any UpstreamValidating = FakeUpstreamValidator(),
    statusProvider: any ProxyRuntimeStatusProviding = FakeRuntimeStatusProvider {
        throw FakeTestError.unavailable
    },
    runtimeController: any ProxyRuntimeControlling = FakeRuntimeController { request in
        let target = try PersistedProxyConfiguration(
            data: request.targetConfigurationData
        )
        return ProxyReapplyResponse(
            operationID: request.operationID,
            disposition: .applied,
            providerInstanceID: request.expectedProviderInstanceID,
            activeGeneration: target.value.generation,
            activeFingerprint: target.fingerprint
        )
    },
    loggingMode: ProxyLoggingMode = .default,
    upstream: DNSUpstream = .fixedCloudflare,
    readinessTimeout: Duration = .seconds(1),
    rollbackTimeout: Duration = .seconds(1),
    pollInterval: Duration = .milliseconds(10)
) -> DNSProxyController {
    DNSProxyController(
        manager: manager,
        validator: validator,
        statusProvider: statusProvider,
        runtimeController: runtimeController,
        providerBundleIdentifier: "com.example.DNSProxy",
        loggingMode: loggingMode,
        upstream: upstream,
        readinessTimeout: readinessTimeout,
        rollbackTimeout: rollbackTimeout,
        pollInterval: pollInterval
    )
}

func makeConfiguration() throws -> ActiveProxyConfiguration {
    try ActiveProxyConfiguration(
        generation: UUID(),
        profileID: UUID(),
        upstream: .fixedCloudflare
    )
}

func runtimeStatus(
    generation: UUID?,
    phase: ProxyRuntimePhase,
    errorCode: ProxyRuntimeErrorCode? = nil,
    maximumConfigurationSchemaVersion: Int? = ActiveProxyConfiguration.currentSchemaVersion,
    runtimeControlProtocolVersion: Int? = nil,
    providerInstanceID: UUID? = nil,
    configurationFingerprint: ProxyConfigurationFingerprint? = nil
) -> ProxyRuntimeStatus {
    ProxyRuntimeStatus(
        generation: generation,
        phase: phase,
        errorCode: errorCode,
        updatedAt: Date(timeIntervalSince1970: 0),
        maximumConfigurationSchemaVersion: maximumConfigurationSchemaVersion,
        runtimeControlProtocolVersion: runtimeControlProtocolVersion,
        providerInstanceID: providerInstanceID,
        configurationFingerprint: configurationFingerprint
    )
}

func expectRecoveryRequired(
    _ state: DNSProxyControllerState,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard case .recoveryRequired = state else {
        Issue.record("Expected recoveryRequired, got \(state)", sourceLocation: sourceLocation)
        return
    }
}
