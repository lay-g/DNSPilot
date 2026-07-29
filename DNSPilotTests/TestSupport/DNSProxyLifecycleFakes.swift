import Foundation
import NetworkExtension
import Synchronization
@testable import DNSPilot

final class FakeDNSProxyService: DNSProxyServicing {
    enum Event: Equatable, Sendable {
        case reapplyEntered(DNSProxyReloadPlan)
        case reapplyReturned(DNSProxyReloadPlan)
        case stop
    }

    enum ReapplyStep: Sendable {
        case succeed
        case fail(DNSProxyServiceReapplyError)
    }

    struct Snapshot: Sendable {
        let startedConfigurations: [PersistedProxyConfiguration]
        let reapplyPlans: [DNSProxyReloadPlan]
        let stopCount: Int
        let events: [Event]
    }

    private struct State {
        var startedConfigurations: [PersistedProxyConfiguration] = []
        var reapplyPlans: [DNSProxyReloadPlan] = []
        var reapplySteps: [ReapplyStep]
        var startShouldFail: Bool
        var stopCount = 0
        var events: [Event] = []
    }

    private let state: Mutex<State>
    private let reapplyEntered: DispatchSemaphore?
    private let reapplyRelease: DispatchSemaphore?

    init(
        reapplySteps: [ReapplyStep] = [],
        startShouldFail: Bool = false,
        reapplyEntered: DispatchSemaphore? = nil,
        reapplyRelease: DispatchSemaphore? = nil
    ) {
        state = Mutex(State(
            reapplySteps: reapplySteps,
            startShouldFail: startShouldFail
        ))
        self.reapplyEntered = reapplyEntered
        self.reapplyRelease = reapplyRelease
    }

    func start(configuration: PersistedProxyConfiguration) throws {
        let shouldFail = state.withLock { state in
            state.startedConfigurations.append(configuration)
            return state.startShouldFail
        }
        if shouldFail {
            throw FakeDNSProxyServiceError.startFailed
        }
    }

    func reapply(_ plan: DNSProxyReloadPlan) throws {
        let step = state.withLock { state in
            state.reapplyPlans.append(plan)
            state.events.append(.reapplyEntered(plan))
            return state.reapplySteps.isEmpty ? .succeed : state.reapplySteps.removeFirst()
        }
        reapplyEntered?.signal()
        reapplyRelease?.wait()
        state.withLock { $0.events.append(.reapplyReturned(plan)) }
        if case let .fail(error) = step {
            throw error
        }
    }

    func stop() {
        state.withLock {
            $0.stopCount += 1
            $0.events.append(.stop)
        }
    }

    func handle(_ flow: NEAppProxyFlow) -> Bool {
        false
    }

    var snapshot: Snapshot {
        state.withLock {
            Snapshot(
                startedConfigurations: $0.startedConfigurations,
                reapplyPlans: $0.reapplyPlans,
                stopCount: $0.stopCount,
                events: $0.events
            )
        }
    }
}

final class FakeRuntimeStatusRecorder: ProxyRuntimeStatusRecording {
    enum Event: Equatable, Sendable {
        case update(
            generation: UUID?,
            fingerprint: ProxyConfigurationFingerprint?,
            phase: ProxyRuntimePhase,
            errorCode: ProxyRuntimeErrorCode?
        )
        case beginEvidence(UUID)
        case endEvidence(UUID)
    }

    private let recordedEvents = Mutex<[Event]>([])
    private let recordedQuiescedGenerations = Mutex<[UUID?]>([])

    func update(
        generation: UUID?,
        configurationFingerprint: ProxyConfigurationFingerprint?,
        phase: ProxyRuntimePhase,
        lastQuiescedGeneration: UUID?,
        errorCode: ProxyRuntimeErrorCode?
    ) {
        recordedEvents.withLock {
            $0.append(.update(
                generation: generation,
                fingerprint: configurationFingerprint,
                phase: phase,
                errorCode: errorCode
            ))
        }
        recordedQuiescedGenerations.withLock { $0.append(lastQuiescedGeneration) }
    }

    func beginEvidence(generation: UUID) {
        recordedEvents.withLock { $0.append(.beginEvidence(generation)) }
    }

    func endEvidence(generation: UUID) {
        recordedEvents.withLock { $0.append(.endEvidence(generation)) }
    }

    var events: [Event] {
        recordedEvents.withLock { $0 }
    }

    var lastQuiescedGenerations: [UUID?] {
        recordedQuiescedGenerations.withLock { $0 }
    }
}

enum FakeDNSProxyServiceError: Error {
    case startFailed
}

func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: timeout))
        }
    }
}

func makeLifecycleConfiguration(
    generation: UUID = UUID(),
    profileID: UUID = UUID(),
    address: String = "1.1.1.1",
    loggingMode: ProxyLoggingMode = .default
) throws -> PersistedProxyConfiguration {
    try PersistedProxyConfiguration(value: ActiveProxyConfiguration(
        generation: generation,
        profileID: profileID,
        upstream: .plain(try PlainDNSConfiguration(
            serverAddress: IPAddress(address)
        )),
        loggingMode: loggingMode
    ))
}

enum UnknownConfigurationFieldLocation: Sendable {
    case topLevel
    case nestedUpstreamConfiguration
}

func configurationData(
    byAddingUnknownFieldTo configuration: PersistedProxyConfiguration,
    at location: UnknownConfigurationFieldLocation
) throws -> Data {
    var payload = try PropertyListSerialization.propertyList(
        from: configuration.data,
        options: [],
        format: nil
    ) as? [String: Any] ?? [:]
    switch location {
    case .topLevel:
        payload["futureConfigurationField"] = true
    case .nestedUpstreamConfiguration:
        var upstream = payload["upstream"] as? [String: Any] ?? [:]
        var nestedConfiguration = upstream["configuration"] as? [String: Any] ?? [:]
        nestedConfiguration["futureUpstreamField"] = true
        upstream["configuration"] = nestedConfiguration
        payload["upstream"] = upstream
    }
    return try PropertyListSerialization.data(
        fromPropertyList: payload,
        format: .binary,
        options: 0
    )
}
