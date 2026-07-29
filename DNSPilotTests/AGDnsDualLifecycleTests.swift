import AGDnsProxy
import Darwin
import Foundation
import Testing

@Suite("AGDnsProxy dual lifecycle", .serialized)
struct AGDnsDualLifecycleTests {
    private static let warmUpIterations = 10
    private static let measuredIterations = 100
    private static let mebibyte: UInt64 = 1_024 * 1_024

    @Test("two proxies and flow managers have bounded lifecycle resources", .timeLimit(.minutes(2)))
    func dualLifecycleResourcesRemainBounded() async throws {
        for iteration in 0..<Self.warmUpIterations {
            try autoreleasepool {
                _ = try Self.runCycle(iteration: iteration)
            }
        }

        let baseline = try await Self.waitForStableProcessSample(maximumWait: .seconds(2))
        let clock = ContinuousClock()
        let startedAt = clock.now
        var liveSamples: [TestProcessSample] = []
        var stoppedSamples: [TestProcessSample] = []
        liveSamples.reserveCapacity(Self.measuredIterations)
        stoppedSamples.reserveCapacity(Self.measuredIterations)

        for iteration in 0..<Self.measuredIterations {
            let liveSample = try autoreleasepool {
                try Self.runCycle(iteration: iteration)
            }
            liveSamples.append(liveSample)
            stoppedSamples.append(try TestProcessSample.current())
        }

        let measuredElapsed = startedAt.duration(to: clock.now)
        let final = try await Self.waitForTeardown(
            relativeTo: baseline,
            maximumWait: .seconds(2)
        )
        let totalElapsed = startedAt.duration(to: clock.now)

        let maximumLiveResident = liveSamples.map(\.residentBytes).max()
            ?? baseline.residentBytes
        let maximumLiveFDs = liveSamples.map(\.openFileDescriptorCount).max()
            ?? baseline.openFileDescriptorCount
        let maximumLiveThreads = liveSamples.map(\.threadCount).max()
            ?? baseline.threadCount

        let earlyStopped = stoppedSamples.prefix(10)
        let lateStopped = stoppedSamples.suffix(10)
        let residentTrend = Self.positiveGrowth(
            from: Self.median(earlyStopped.map(\.residentBytes)),
            to: Self.median(lateStopped.map(\.residentBytes))
        )
        let fdTrend = Self.positiveGrowth(
            from: Self.median(earlyStopped.map(\.openFileDescriptorCount)),
            to: Self.median(lateStopped.map(\.openFileDescriptorCount))
        )
        let threadTrend = Self.positiveGrowth(
            from: Self.median(earlyStopped.map(\.threadCount)),
            to: Self.median(lateStopped.map(\.threadCount))
        )

        let summary = """
        Gate B: warmUp=\(Self.warmUpIterations), measured=\(Self.measuredIterations), \
        measuredWall=\(measuredElapsed), totalWall=\(totalElapsed), \
        baseline={rssMiB:\(Self.mebibytes(baseline.residentBytes)),fd:\(baseline.openFileDescriptorCount),threads:\(baseline.threadCount)}, \
        maxLive={rssMiB:\(Self.mebibytes(maximumLiveResident)),fd:\(maximumLiveFDs),threads:\(maximumLiveThreads)}, \
        final={rssMiB:\(Self.mebibytes(final.residentBytes)),fd:\(final.openFileDescriptorCount),threads:\(final.threadCount)}, \
        stoppedTrend={rssMiB:\(Self.mebibytes(residentTrend)),fd:\(fdTrend),threads:\(threadTrend)}
        """
        print(summary)

        #expect(measuredElapsed < .seconds(60), "\(summary)")
        #expect(totalElapsed < .seconds(65), "\(summary)")
        #expect(
            maximumLiveResident <= baseline.residentBytes + 128 * Self.mebibyte,
            "\(summary)"
        )
        #expect(
            maximumLiveFDs <= baseline.openFileDescriptorCount + 64,
            "\(summary)"
        )
        #expect(
            maximumLiveThreads <= baseline.threadCount + 64,
            "\(summary)"
        )
        #expect(
            final.residentBytes <= baseline.residentBytes + 64 * Self.mebibyte,
            "\(summary)"
        )
        #expect(
            final.openFileDescriptorCount <= baseline.openFileDescriptorCount + 8,
            "\(summary)"
        )
        #expect(final.threadCount <= baseline.threadCount + 8, "\(summary)")
        #expect(residentTrend <= 32 * Self.mebibyte, "\(summary)")
        #expect(fdTrend <= 4, "\(summary)")
        #expect(threadTrend <= 4, "\(summary)")
    }

    private static func runCycle(iteration: Int) throws -> TestProcessSample {
        var first: LivePair? = try LivePair(iteration: iteration, pair: 1)
        var second: LivePair?
        defer {
            second?.stop()
            first?.stop()
        }

        second = try LivePair(iteration: iteration, pair: 2)
        let liveSample = try TestProcessSample.current()

        if iteration.isMultiple(of: 2) {
            stop(&first)
            stop(&second)
        } else {
            stop(&second)
            stop(&first)
        }
        return liveSample
    }

    private static func stop(_ pair: inout LivePair?) {
        pair?.stop()
        pair = nil
    }

    private static func waitForStableProcessSample(
        maximumWait: Duration
    ) async throws -> TestProcessSample {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maximumWait)
        var previous = try TestProcessSample.current()
        var stableCount = 0

        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            let current = try TestProcessSample.current()
            if current.openFileDescriptorCount == previous.openFileDescriptorCount,
               current.threadCount == previous.threadCount {
                stableCount += 1
                if stableCount == 5 {
                    return current
                }
            } else {
                stableCount = 0
            }
            previous = current
        }
        return previous
    }

    private static func waitForTeardown(
        relativeTo baseline: TestProcessSample,
        maximumWait: Duration
    ) async throws -> TestProcessSample {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maximumWait)
        var current = try TestProcessSample.current()

        while clock.now < deadline,
              current.openFileDescriptorCount > baseline.openFileDescriptorCount + 4
                || current.threadCount > baseline.threadCount + 4 {
            try await Task.sleep(for: .milliseconds(10))
            current = try TestProcessSample.current()
        }
        return current
    }

    private static func median(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func positiveGrowth(from start: UInt64, to end: UInt64) -> UInt64 {
        end > start ? end - start : 0
    }

    private static func mebibytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / Double(mebibyte))
    }
}

private final class LivePair {
    private let events: AGDnsProxyEvents
    private let proxy: AGDnsProxy
    private let flowManager: AGDnsAppProxyFlowManager
    private var isStopped = false

    init(iteration: Int, pair: Int) throws {
        guard let configuration = AGDnsProxyConfig.getDefault() else {
            throw GateBError.defaultConfigurationUnavailable
        }

        let upstream = AGDnsUpstream()
        upstream.id = pair
        upstream.address = "192.0.2.1:53"
        upstream.bootstrap = []
        configuration.upstreams = [upstream]
        configuration.fallbacks = []
        configuration.fallbackDomains = []
        configuration.filters = []
        configuration.listeners = []
        configuration.upstreamTimeoutMs = 1_000
        configuration.optimisticCache = false
        configuration.enableParallelUpstreamQueries = false
        configuration.enableFallbackOnUpstreamsFailure = false
        configuration.enableHttp3 = false

        let events = AGDnsProxyEvents()
        var initializationIssue: NSError?
        guard let proxy = AGDnsProxy(
            config: configuration,
            handler: events,
            error: &initializationIssue
        ) else {
            throw GateBError.initializationFailed(
                iteration: iteration,
                pair: pair,
                message: initializationIssue?.localizedDescription ?? "unknown error"
            )
        }
        if let initializationIssue {
            proxy.stop()
            throw GateBError.initializationFailed(
                iteration: iteration,
                pair: pair,
                message: initializationIssue.localizedDescription
            )
        }

        self.events = events
        self.proxy = proxy
        flowManager = AGDnsAppProxyFlowManager(
            dnsProxy: proxy,
            maxLocalFlowCount: 256
        )
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        flowManager.stop()
        proxy.stop()
        _ = events
    }

    deinit {
        stop()
    }
}

struct TestProcessSample: Sendable {
    let residentBytes: UInt64
    let openFileDescriptorCount: UInt64
    let threadCount: UInt64

    static func current() throws -> Self {
        Self(
            residentBytes: try residentMemoryBytes(),
            openFileDescriptorCount: try openFileDescriptors(),
            threadCount: try threads()
        )
    }

    private static func residentMemoryBytes() throws -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw GateBError.machCallFailed(name: "task_info", code: result)
        }
        return UInt64(info.resident_size)
    }

    private static func openFileDescriptors() throws -> UInt64 {
        let descriptorStride = MemoryLayout<proc_fdinfo>.stride
        let requiredBytes = proc_pidinfo(
            getpid(),
            PROC_PIDLISTFDS,
            0,
            nil,
            0
        )
        guard requiredBytes >= 0 else {
            throw GateBError.processCallFailed(
                name: "proc_pidinfo(PROC_PIDLISTFDS)",
                detail: "errno \(errno)"
            )
        }

        let capacity = max(Int(requiredBytes) + 32 * descriptorStride, descriptorStride)
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: capacity,
            alignment: MemoryLayout<proc_fdinfo>.alignment
        )
        defer { buffer.deallocate() }

        let usedBytes = proc_pidinfo(
            getpid(),
            PROC_PIDLISTFDS,
            0,
            buffer,
            Int32(capacity)
        )
        guard usedBytes >= 0 else {
            throw GateBError.processCallFailed(
                name: "proc_pidinfo(PROC_PIDLISTFDS)",
                detail: "errno \(errno)"
            )
        }
        return UInt64(Int(usedBytes) / descriptorStride)
    }

    private static func threads() throws -> UInt64 {
        var info = proc_taskinfo()
        let expectedBytes = MemoryLayout<proc_taskinfo>.size
        let usedBytes = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                getpid(),
                PROC_PIDTASKINFO,
                0,
                pointer,
                Int32(expectedBytes)
            )
        }
        guard Int(usedBytes) == expectedBytes else {
            let detail = usedBytes < 0
                ? "errno \(errno)"
                : "returned \(usedBytes) bytes, expected \(expectedBytes)"
            throw GateBError.processCallFailed(
                name: "proc_pidinfo(PROC_PIDTASKINFO)",
                detail: detail
            )
        }
        return UInt64(info.pti_threadnum)
    }
}

private enum GateBError: Error, CustomStringConvertible, Sendable {
    case defaultConfigurationUnavailable
    case initializationFailed(iteration: Int, pair: Int, message: String)
    case machCallFailed(name: String, code: kern_return_t)
    case processCallFailed(name: String, detail: String)

    var description: String {
        switch self {
        case .defaultConfigurationUnavailable:
            "AGDnsProxyConfig.getDefault() returned nil"
        case let .initializationFailed(iteration, pair, message):
            "AGDnsProxy initialization failed at iteration \(iteration), pair \(pair): \(message)"
        case let .machCallFailed(name, code):
            "\(name) failed with kern_return_t \(code)"
        case let .processCallFailed(name, detail):
            "\(name) failed: \(detail)"
        }
    }
}
