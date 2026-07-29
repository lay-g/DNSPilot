import Foundation
import Testing
@testable import DNSPilot

struct NetworkMonitorTests {
    @Test func defaultDebounceIsOneSecond() {
        #expect(NetworkMonitor.defaultDebounceDuration == .seconds(1))
    }

    @Test func burstCancelsOlderWorkAndEmitsOnlyLatestContext() async throws {
        let fixture = Fixture()
        await fixture.monitor.start()
        await fixture.source.emit(path(.requiresConnection))
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.source.emit(path(.satisfied))
        try await eventually { await fixture.sleeper.waiterCount == 2 }

        await fixture.sleeper.releaseAll()

        try await eventually { await fixture.output.values.count == 1 }
        #expect(await fixture.output.values.map(\.status) == [.satisfied])
        await fixture.monitor.stop()
    }

    @Test func equalContextsAreSuppressed() async throws {
        let fixture = Fixture()
        await fixture.monitor.start()

        await fixture.source.emit(path(.satisfied))
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()
        try await eventually { await fixture.output.values.count == 1 }

        await fixture.source.emit(path(.satisfied))
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()
        try await Task.sleep(for: .milliseconds(10))

        #expect(await fixture.output.values.count == 1)
        await fixture.monitor.stop()
    }

    @Test func inactiveGUISessionStopsAndRejectsStaleCallbacksThenRestarts() async throws {
        let fixture = Fixture()
        await fixture.monitor.start()
        #expect(await fixture.source.startCount == 1)

        _ = await fixture.monitor.setGUISessionActive(false)
        #expect(await fixture.source.stopCount == 1)
        await fixture.source.emit(path(.unsatisfied), fromStart: 0)
        try await Task.sleep(for: .milliseconds(10))
        #expect(await fixture.sleeper.waiterCount == 0)

        _ = await fixture.monitor.setGUISessionActive(true)
        #expect(await fixture.source.startCount == 2)
        await fixture.source.emit(path(.satisfied), fromStart: 1)
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()
        try await eventually { await fixture.output.values.count == 1 }

        #expect(await fixture.output.values.map(\.status) == [.satisfied])
        await fixture.monitor.stop()
    }

    @Test func wakeWaitsForFreshPathBeforeResamplingContext() async throws {
        let fixture = Fixture()
        await fixture.monitor.start()
        await fixture.source.emit(path(.satisfied))
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()
        try await eventually { await fixture.output.values.count == 1 }
        #expect(await fixture.collector.callCount == 1)

        await fixture.monitor.handleWake()

        #expect(await fixture.source.stopCount == 1)
        #expect(await fixture.source.startCount == 2)
        try await Task.sleep(for: .milliseconds(10))
        #expect(await fixture.sleeper.waiterCount == 0)
        #expect(await fixture.collector.callCount == 1)

        await fixture.source.emit(path(.satisfied), fromStart: 1)
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()
        try await eventually { await fixture.collector.callCount == 2 }
        #expect(await fixture.output.values.count == 2)
        await fixture.monitor.stop()
    }

    @Test func resumedSessionWaitsForFreshPathBeforeResamplingContext() async throws {
        let fixture = Fixture()
        await fixture.monitor.start()
        await fixture.source.emit(path(.satisfied))
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()
        try await eventually { await fixture.collector.callCount == 1 }
        try await eventually { await fixture.output.values.count == 1 }

        _ = await fixture.monitor.setGUISessionActive(false)
        _ = await fixture.monitor.setGUISessionActive(true)

        try await Task.sleep(for: .milliseconds(10))
        #expect(await fixture.sleeper.waiterCount == 0)
        #expect(await fixture.collector.callCount == 1)

        await fixture.source.emit(path(.satisfied), fromStart: 1)
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()
        try await eventually { await fixture.collector.callCount == 2 }
        try await eventually { await fixture.output.sessionEpochs == [0, 2] }
        #expect(await fixture.output.sessionEpochs == [0, 2])
        await fixture.monitor.stop()
    }

    @Test func collectorResampleEventRefreshesContextWithoutPathChange() async throws {
        let fixture = Fixture()
        await fixture.monitor.start()
        await fixture.source.emit(path(.satisfied))
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()
        try await eventually { await fixture.output.values.count == 1 }

        await fixture.collector.setSSID("Office")
        await fixture.collector.emitResample()
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()

        try await eventually { await fixture.output.values.count == 2 }
        #expect(await fixture.output.values.map(\.ssid) == [nil, "Office"])
        await fixture.monitor.stop()
    }

    @Test func explicitResampleRefreshesContextWithoutPathChange() async throws {
        let fixture = Fixture()
        await fixture.monitor.start()
        await fixture.source.emit(path(.satisfied))
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()
        try await eventually { await fixture.output.values.count == 1 }

        await fixture.collector.setSSID("Office")
        let resample = Task { await fixture.monitor.requestResample() }
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()

        #expect(await resample.value)
        try await eventually { await fixture.output.values.count == 2 }
        #expect(await fixture.output.values.map(\.ssid) == [nil, "Office"])
        await fixture.monitor.stop()
    }

    @Test func explicitResampleIsIgnoredWithoutActivePath() async throws {
        let fixture = Fixture()
        #expect(await fixture.monitor.requestResample() == false)
        await fixture.monitor.start()
        #expect(await fixture.monitor.requestResample() == false)
        try await Task.sleep(for: .milliseconds(10))

        #expect(await fixture.sleeper.waiterCount == 0)
        #expect(await fixture.collector.callCount == 0)
        await fixture.monitor.stop()
    }

    @Test func explicitEqualResampleCompletesWithoutDuplicateEmission() async throws {
        let fixture = Fixture()
        await fixture.monitor.start()
        await fixture.source.emit(path(.satisfied))
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()
        try await eventually { await fixture.output.values.count == 1 }

        let resample = Task { await fixture.monitor.requestResample() }
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()

        #expect(await resample.value)
        #expect(await fixture.output.values.count == 1)
        await fixture.monitor.stop()
    }

    @Test func inFlightCollectionBeforeExplicitResampleCannotCompleteIt() async throws {
        let fixture = Fixture()
        let completion = BooleanCompletion()
        await fixture.monitor.start()
        await fixture.collector.setSSID("Old")
        await fixture.collector.blockNextCollection()
        await fixture.source.emit(path(.satisfied))
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()
        await fixture.collector.waitUntilCollectionIsBlocked()

        await fixture.collector.setSSID("New")
        let resample = Task {
            let result = await fixture.monitor.requestResample()
            await completion.finish(result)
            return result
        }
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.collector.releaseBlockedCollection()
        try await Task.sleep(for: .milliseconds(10))

        #expect(await completion.value == nil)
        await fixture.sleeper.releaseAll()
        #expect(await resample.value)
        #expect(await fixture.output.values.map(\.ssid) == ["New"])
        await fixture.monitor.stop()
    }

    @Test func cancellingExplicitResampleReturnsFalseWithoutWaitingForCollection() async throws {
        let fixture = Fixture()
        await fixture.monitor.start()
        await fixture.source.emit(path(.satisfied))
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()
        try await eventually { await fixture.output.values.count == 1 }

        let resample = Task { await fixture.monitor.requestResample() }
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        resample.cancel()

        #expect(await resample.value == false)
        await fixture.sleeper.releaseAll()
        await fixture.monitor.stop()
    }

    @Test func stoppingMonitorCompletesExplicitResampleAsFalse() async throws {
        let fixture = Fixture()
        await fixture.monitor.start()
        await fixture.source.emit(path(.satisfied))
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()
        try await eventually { await fixture.output.values.count == 1 }

        let resample = Task { await fixture.monitor.requestResample() }
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.monitor.stop()

        #expect(await resample.value == false)
        await fixture.sleeper.releaseAll()
    }

    @Test func contextCallbacksNeverOverlap() async throws {
        let source = FakeNetworkPathSource()
        let collector = FakeNetworkContextCollector()
        let sleeper = ControlledSleeper()
        let output = BlockingContextOutput()
        let monitor = NetworkMonitor(
            source: source,
            collector: collector,
            sleeper: sleeper
        ) { event in
            await output.append(event)
        }
        await monitor.start()
        await collector.setSSID("First")
        await source.emit(path(.satisfied))
        try await eventually { await sleeper.waiterCount == 1 }
        await sleeper.releaseAll()
        await output.waitUntilFirstCallbackIsBlocked()

        await collector.setSSID("Second")
        await source.emit(path(.satisfied))
        try await eventually { await sleeper.waiterCount == 1 }
        await sleeper.releaseAll()
        try await eventually { await collector.callCount == 2 }

        #expect(await output.startedCount == 1)
        #expect(await output.maximumConcurrentCallbacks == 1)
        await output.releaseFirstCallback()
        try await eventually { await output.values.count == 2 }
        #expect(await output.maximumConcurrentCallbacks == 1)
        #expect(await output.values.map(\.ssid) == ["First", "Second"])
        await monitor.stop()
    }

    @Test func wakeDropsContextQueuedByPreviousMonitorEpoch() async throws {
        let source = FakeNetworkPathSource()
        let collector = FakeNetworkContextCollector()
        let sleeper = ControlledSleeper()
        let output = BlockingContextOutput()
        let monitor = NetworkMonitor(
            source: source,
            collector: collector,
            sleeper: sleeper
        ) { event in
            await output.append(event)
        }
        await monitor.start()
        await collector.setSSID("First")
        await source.emit(path(.satisfied))
        try await eventually { await sleeper.waiterCount == 1 }
        await sleeper.releaseAll()
        await output.waitUntilFirstCallbackIsBlocked()

        await collector.setSSID("Stale")
        await source.emit(path(.satisfied))
        try await eventually { await sleeper.waiterCount == 1 }
        await sleeper.releaseAll()
        try await eventually { await collector.callCount == 2 }
        await monitor.handleWake()
        await output.releaseFirstCallback()

        await collector.setSSID("Fresh")
        await source.emit(path(.satisfied), fromStart: 1)
        try await eventually { await sleeper.waiterCount == 1 }
        await sleeper.releaseAll()
        try await eventually { await output.values.count == 2 }

        #expect(await output.values.map(\.ssid) == ["First", "Fresh"])
        #expect(await output.maximumConcurrentCallbacks == 1)
        await monitor.stop()
    }

    @Test func explicitStopPreventsAutomaticRestartOnSessionOrWake() async {
        let fixture = Fixture()
        await fixture.monitor.start()
        await fixture.monitor.stop()
        _ = await fixture.monitor.setGUISessionActive(false)
        _ = await fixture.monitor.setGUISessionActive(true)
        await fixture.monitor.handleWake()

        #expect(await fixture.source.startCount == 1)
        #expect(await fixture.source.stopCount == 1)
    }

    @Test func supersededSessionDeactivationCannotStopTheResumedSource() async throws {
        let fixture = Fixture()
        await fixture.monitor.start()
        await fixture.source.blockNextStop()

        let resign = Task { await fixture.monitor.setGUISessionActive(false) }
        await fixture.source.waitUntilStopIsBlocked()
        let become = Task { await fixture.monitor.setGUISessionActive(true) }
        #expect(await become.value == 2)
        await fixture.source.releaseBlockedStop()

        #expect(await resign.value == nil)
        try await eventually { await fixture.source.startCount == 2 }
        await fixture.source.emit(path(.satisfied), fromStart: 1)
        try await eventually { await fixture.sleeper.waiterCount == 1 }
        await fixture.sleeper.releaseAll()
        try await eventually { await fixture.output.sessionEpochs == [2] }
        await fixture.monitor.stop()
    }

    @Test func stopCancelsPendingDebounce() async throws {
        let fixture = Fixture()
        await fixture.monitor.start()
        await fixture.source.emit(path(.satisfied))
        try await eventually { await fixture.sleeper.waiterCount == 1 }

        await fixture.monitor.stop()
        await fixture.sleeper.releaseAll()
        try await Task.sleep(for: .milliseconds(10))

        #expect(await fixture.collector.callCount == 0)
        #expect(await fixture.output.values.isEmpty)
    }

    private func path(_ status: NetworkPathStatusInput) -> NetworkPathInput {
        NetworkPathInput(
            status: status,
            interfaces: [NetworkPathInterfaceInput(name: "en0", type: .wifi, isUsed: true)]
        )
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            guard clock.now < deadline else {
                Issue.record("Condition did not become true before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private final class Fixture: Sendable {
        let source = FakeNetworkPathSource()
        let collector = FakeNetworkContextCollector()
        let sleeper = ControlledSleeper()
        let output = ContextOutput()
        let monitor: NetworkMonitor

        init() {
            monitor = NetworkMonitor(
                source: source,
                collector: collector,
                sleeper: sleeper
            ) { [output] event in
                await output.append(event)
            }
        }
    }
}

private actor FakeNetworkPathSource: NetworkPathSourcing {
    private var handlers: [@Sendable (NetworkPathInput) -> Void] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var shouldBlockNextStop = false
    private var stopBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedStopContinuation: CheckedContinuation<Void, Never>?

    func start(handler: @escaping @Sendable (NetworkPathInput) -> Void) {
        startCount += 1
        handlers.append(handler)
    }

    func stop() async {
        stopCount += 1
        guard shouldBlockNextStop else { return }
        shouldBlockNextStop = false
        let waiters = stopBlockedWaiters
        stopBlockedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            blockedStopContinuation = continuation
        }
    }

    func blockNextStop() {
        shouldBlockNextStop = true
    }

    func waitUntilStopIsBlocked() async {
        guard blockedStopContinuation == nil, shouldBlockNextStop else { return }
        await withCheckedContinuation { continuation in
            stopBlockedWaiters.append(continuation)
        }
    }

    func releaseBlockedStop() {
        blockedStopContinuation?.resume()
        blockedStopContinuation = nil
    }

    func emit(_ path: NetworkPathInput, fromStart index: Int? = nil) {
        guard let handler = index.map({ handlers[$0] }) ?? handlers.last else { return }
        handler(path)
    }
}

private actor FakeNetworkContextCollector: NetworkContextCollecting, NetworkContextResampleSourcing {
    private(set) var callCount = 0
    private var ssid: String?
    private var resampleHandler: (@Sendable () -> Void)?
    private var shouldBlockNextCollection = false
    private var blockedCollectionContinuation: CheckedContinuation<Void, Never>?
    private var blockedCollectionWaiters: [CheckedContinuation<Void, Never>] = []

    func context(for path: NetworkPathInput) async -> NetworkContext {
        callCount += 1
        let capturedSSID = ssid
        if shouldBlockNextCollection {
            shouldBlockNextCollection = false
            await withCheckedContinuation { continuation in
                blockedCollectionContinuation = continuation
                let waiters = blockedCollectionWaiters
                blockedCollectionWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        let status: NetworkStatus = switch path.status {
        case .satisfied: .satisfied
        case .requiresConnection: .requiresConnection
        case .unsatisfied: .unsatisfied
        }
        return NetworkContext(
            status: status,
            ssid: capturedSSID,
            ssidAvailability: capturedSSID == nil ? .temporarilyUnavailable : .available,
            activeInterfaceTypes: [.wifi],
            addresses: []
        )
    }

    func startResampling(handler: @escaping @Sendable () -> Void) {
        resampleHandler = handler
    }

    func stopResampling() {
        resampleHandler = nil
    }

    func setSSID(_ ssid: String?) {
        self.ssid = ssid
    }

    func emitResample() {
        resampleHandler?()
    }

    func blockNextCollection() {
        shouldBlockNextCollection = true
    }

    func waitUntilCollectionIsBlocked() async {
        guard blockedCollectionContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            blockedCollectionWaiters.append(continuation)
        }
    }

    func releaseBlockedCollection() {
        blockedCollectionContinuation?.resume()
        blockedCollectionContinuation = nil
    }
}

private actor ControlledSleeper: NetworkMonitorSleeping {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { waiters.count }

    func sleep(for duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        try Task.checkCancellation()
    }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor ContextOutput {
    private(set) var values: [NetworkContext] = []
    private(set) var sessionEpochs: [UInt64] = []

    func append(_ event: NetworkContextEvent) {
        values.append(event.context)
        sessionEpochs.append(event.sessionEpoch)
    }
}

private actor BooleanCompletion {
    private(set) var value: Bool?

    func finish(_ value: Bool) {
        self.value = value
    }
}

private actor BlockingContextOutput {
    private(set) var values: [NetworkContext] = []
    private(set) var startedCount = 0
    private(set) var maximumConcurrentCallbacks = 0
    private var activeCallbacks = 0
    private var firstCallbackContinuation: CheckedContinuation<Void, Never>?
    private var firstCallbackWaiters: [CheckedContinuation<Void, Never>] = []

    func append(_ event: NetworkContextEvent) async {
        startedCount += 1
        activeCallbacks += 1
        maximumConcurrentCallbacks = max(maximumConcurrentCallbacks, activeCallbacks)
        if startedCount == 1 {
            await withCheckedContinuation { continuation in
                firstCallbackContinuation = continuation
                let waiters = firstCallbackWaiters
                firstCallbackWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        values.append(event.context)
        activeCallbacks -= 1
    }

    func waitUntilFirstCallbackIsBlocked() async {
        guard firstCallbackContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            firstCallbackWaiters.append(continuation)
        }
    }

    func releaseFirstCallback() {
        firstCallbackContinuation?.resume()
        firstCallbackContinuation = nil
    }
}
