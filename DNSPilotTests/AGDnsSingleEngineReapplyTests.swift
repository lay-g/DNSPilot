import AGDnsProxy
import Foundation
import Synchronization
import Testing

@Suite("AGDnsProxy single-engine reapply", .serialized)
struct AGDnsSingleEngineReapplyTests {
    private static let domain = "reapply-gate.invalid"
    private static let oldAddress = "192.0.2.10"
    private static let targetAddress = "198.51.100.20"
    private static let filteredAddress = "203.0.113.30"
    private static let mebibyte: UInt64 = 1_024 * 1_024

    @Test("public options reapply settings and filters on one proxy")
    func publicReapplyOptionsChangeAnswers() async throws {
        #expect(AGDnsProxyReapplyOptions().rawValue == 0)
        #expect(AGDnsProxyReapplyOptions.settings.rawValue == 1)
        #expect(AGDnsProxyReapplyOptions.filters.rawValue == 2)
        #expect(
            AGDnsProxyReapplyOptions.settings
                .union(.filters).rawValue == 3
        )

        let oldConfiguration = try Self.makeConfiguration(
            blockingAddress: Self.oldAddress,
            filterRule: "||\(Self.domain)^"
        )
        let fixture = try ReapplyFixture(configuration: oldConfiguration)
        defer { fixture.stop() }

        #expect(try await fixture.answerAddress(for: Self.domain) == Self.oldAddress)

        let targetSettings = try Self.makeConfiguration(
            blockingAddress: Self.targetAddress,
            filterRule: ""
        )
        let settingsResult = fixture.reapply(targetSettings, options: .settings)
        #expect(settingsResult.applied)
        #expect(settingsResult.issue == nil)
        #expect(try await fixture.answerAddress(for: Self.domain) == Self.targetAddress)

        let targetFilters = try Self.makeConfiguration(
            blockingAddress: Self.oldAddress,
            filterRule: "\(Self.domain)$dnsrewrite=\(Self.filteredAddress)"
        )
        let filtersResult = fixture.reapply(targetFilters, options: .filters)
        #expect(filtersResult.applied)
        #expect(filtersResult.issue == nil)
        #expect(try await fixture.answerAddress(for: Self.domain) == Self.filteredAddress)

        let noOpResult = fixture.reapply(oldConfiguration, options: [])
        #expect(noOpResult.applied)
        #expect(noOpResult.issue == nil)
        #expect(try await fixture.answerAddress(for: Self.domain) == Self.filteredAddress)

        let resetResult = fixture.reapply(
            oldConfiguration,
            options: .settings.union(.filters)
        )
        #expect(resetResult.applied)
        #expect(resetResult.issue == nil)
        #expect(try await fixture.answerAddress(for: Self.domain) == Self.oldAddress)

        let combinedTarget = try Self.makeConfiguration(
            blockingAddress: Self.targetAddress,
            filterRule: "\(Self.domain)$dnsrewrite=\(Self.filteredAddress)"
        )
        let combinedResult = fixture.reapply(
            combinedTarget,
            options: .settings.union(.filters)
        )
        #expect(combinedResult.applied)
        #expect(combinedResult.issue == nil)
        #expect(try await fixture.answerAddress(for: Self.domain) == Self.filteredAddress)

        let settingsCheck = try Self.makeConfiguration(
            blockingAddress: Self.oldAddress,
            filterRule: "||\(Self.domain)^"
        )
        let settingsCheckResult = fixture.reapply(settingsCheck, options: .filters)
        #expect(settingsCheckResult.applied)
        #expect(settingsCheckResult.issue == nil)
        #expect(try await fixture.answerAddress(for: Self.domain) == Self.targetAddress)
    }

    @Test("failed settings reapply requires and accepts explicit rollback")
    func failedSettingsReapplyCanRollback() async throws {
        let oldConfiguration = try Self.makeConfiguration(
            blockingAddress: Self.oldAddress,
            filterRule: "||\(Self.domain)^"
        )
        let fixture = try ReapplyFixture(configuration: oldConfiguration)
        defer { fixture.stop() }

        #expect(try await fixture.answerAddress(for: Self.domain) == Self.oldAddress)

        let invalidTarget = try Self.makeConfiguration(
            blockingAddress: Self.targetAddress,
            filterRule: "",
            upstreamAddress: "invalid://reapply-gate"
        )
        let targetResult = fixture.reapply(invalidTarget, options: .settings)
        #expect(!targetResult.applied)
        #expect(targetResult.issue != nil)

        let responseAfterFailure = await fixture.response(for: Self.domain)
        #expect(responseAfterFailure?.isEmpty == true)

        let rollbackResult = fixture.reapply(oldConfiguration, options: .settings)
        #expect(rollbackResult.applied)
        #expect(rollbackResult.issue == nil)
        #expect(try await fixture.answerAddress(for: Self.domain) == Self.oldAddress)
    }

    @Test("failed filters reapply requires and accepts explicit rollback")
    func failedFiltersReapplyCanRollback() async throws {
        let oldConfiguration = try Self.makeConfiguration(
            blockingAddress: Self.oldAddress,
            filterRule: "||\(Self.domain)^"
        )
        let fixture = try ReapplyFixture(configuration: oldConfiguration)
        defer { fixture.stop() }

        #expect(try await fixture.answerAddress(for: Self.domain) == Self.oldAddress)

        let invalidTarget = try Self.makeConfiguration(
            blockingAddress: Self.targetAddress,
            filterRule: "/non/existent/dnspilot-reapply-filter.txt",
            filterIsInMemory: false
        )
        let targetResult = fixture.reapply(invalidTarget, options: .filters)
        #expect(!targetResult.applied)
        #expect(targetResult.issue != nil)
        #expect(try await fixture.answerAddress(for: Self.domain) == Self.oldAddress)

        let rollbackResult = fixture.reapply(oldConfiguration, options: .filters)
        #expect(rollbackResult.applied)
        #expect(rollbackResult.issue == nil)
        #expect(try await fixture.answerAddress(for: Self.domain) == Self.oldAddress)
    }

    @Test(
        "repeated reapply returns only valid or retryable responses",
        .timeLimit(.minutes(1))
    )
    func repeatedReapplyResponsesAreRetryableAndBounded() async throws {
        let oldConfiguration = try Self.makeConfiguration(
            blockingAddress: Self.oldAddress,
            filterRule: "||\(Self.domain)^"
        )
        let targetConfiguration = try Self.makeConfiguration(
            blockingAddress: Self.targetAddress,
            filterRule: ""
        )
        let fixture = try ReapplyFixture(configuration: oldConfiguration)
        defer { fixture.stop() }

        let baseline = try TestProcessSample.current()
        let queryCount = 500
        async let traffic = fixture.collectResponses(
            domain: Self.domain,
            count: queryCount
        )

        var samples: [TestProcessSample] = []
        samples.reserveCapacity(100)
        for iteration in 0..<100 {
            let configuration = iteration.isMultiple(of: 2)
                ? targetConfiguration
                : oldConfiguration
            let result = fixture.reapply(configuration, options: .settings)
            #expect(result.applied, "iteration \(iteration): \(String(describing: result.issue))")
            #expect(result.issue == nil)
            samples.append(try TestProcessSample.current())
            await Task.yield()
        }

        let observedResponses = await traffic
        let timedOutCount = observedResponses.count(where: { $0 == nil })
        let responses = observedResponses.compactMap { $0 }
        let emptyCount = responses.count(where: \.isEmpty)
        let answers = responses.compactMap {
            try? DNSWireResponse.ipv4Address(in: $0)
        }
        let invalidCount = responses.count - emptyCount - answers.count
        #expect(observedResponses.count == queryCount)
        #expect(timedOutCount == 0, "reapply timed out \(timedOutCount) DNS callbacks")
        #expect(responses.count == queryCount)
        #expect(invalidCount == 0, "reapply returned \(invalidCount) malformed DNS responses")
        #expect(answers.allSatisfy {
            $0 == Self.oldAddress || $0 == Self.targetAddress
        })
        #expect(try await fixture.answerAddress(for: Self.domain) == Self.oldAddress)

        let maximumResident = samples.map(\.residentBytes).max() ?? baseline.residentBytes
        let maximumFDs = samples.map(\.openFileDescriptorCount).max()
            ?? baseline.openFileDescriptorCount
        let maximumThreads = samples.map(\.threadCount).max() ?? baseline.threadCount
        let summary = """
        Reapply gate: iterations=100, queries=\(queryCount), retryableEmpty=\(emptyCount), timedOut=\(timedOutCount), malformed=\(invalidCount), \
        baseline={rssMiB:\(Self.mebibytes(baseline.residentBytes)),fd:\(baseline.openFileDescriptorCount),threads:\(baseline.threadCount)}, \
        max={rssMiB:\(Self.mebibytes(maximumResident)),fd:\(maximumFDs),threads:\(maximumThreads)}
        """
        print(summary)

        #expect(maximumResident <= baseline.residentBytes + 64 * Self.mebibyte, "\(summary)")
        #expect(maximumFDs <= baseline.openFileDescriptorCount + 8, "\(summary)")
        #expect(maximumThreads <= baseline.threadCount + 8, "\(summary)")
    }

    private static func makeConfiguration(
        blockingAddress: String,
        filterRule: String,
        filterIsInMemory: Bool = true,
        upstreamAddress: String = "192.0.2.1:53"
    ) throws -> AGDnsProxyConfig {
        guard let configuration = AGDnsProxyConfig.getDefault() else {
            throw ReapplyGateError.defaultConfigurationUnavailable
        }

        let upstream = AGDnsUpstream()
        upstream.id = 1
        upstream.address = upstreamAddress
        upstream.bootstrap = []
        configuration.upstreams = [upstream]
        configuration.fallbacks = []
        configuration.fallbackDomains = []
        configuration.listeners = []
        configuration.customBlockingIpv4 = blockingAddress
        configuration.adblockRulesBlockingMode = try #require(
            AGDnsBlockingMode(rawValue: 2)
        )
        configuration.dnsCacheSize = 0
        configuration.upstreamTimeoutMs = 250
        configuration.optimisticCache = false
        configuration.enableParallelUpstreamQueries = false
        configuration.enableFallbackOnUpstreamsFailure = false
        configuration.enableServfailOnUpstreamsFailure = true
        configuration.enableHttp3 = false

        if filterRule.isEmpty {
            configuration.filters = []
        } else {
            let filter = AGDnsFilterParams()
            filter.id = 1
            filter.data = filterRule
            filter.inMemory = filterIsInMemory
            configuration.filters = [filter]
        }
        return configuration
    }

    private static func mebibytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / Double(mebibyte))
    }
}

private final class ReapplyFixture: @unchecked Sendable {
    private let events: AGDnsProxyEvents
    private let proxy: AGDnsProxy
    private let flowManager: AGDnsAppProxyFlowManager
    private var isStopped = false

    init(configuration: AGDnsProxyConfig) throws {
        let events = AGDnsProxyEvents()

        var initializationIssue: NSError?
        guard let proxy = AGDnsProxy(
            config: configuration,
            handler: events,
            error: &initializationIssue
        ) else {
            throw ReapplyGateError.initializationFailed(
                initializationIssue?.localizedDescription ?? "unknown error"
            )
        }
        if let initializationIssue {
            proxy.stop()
            throw ReapplyGateError.initializationFailed(
                initializationIssue.localizedDescription
            )
        }

        self.events = events
        self.proxy = proxy
        flowManager = AGDnsAppProxyFlowManager(
            dnsProxy: proxy,
            maxLocalFlowCount: 256
        )
    }

    func reapply(
        _ configuration: AGDnsProxyConfig,
        options: AGDnsProxyReapplyOptions
    ) -> (applied: Bool, issue: NSError?) {
        var issue: NSError?
        let applied = proxy.reapplySettings(
            configuration,
            options: options,
            error: &issue
        )
        return (applied, issue)
    }

    func response(for domain: String) async -> Data? {
        let operation = beginResponse(for: domain)
        return await operation.value(timeout: .milliseconds(100))
    }

    private func beginResponse(for domain: String) -> DNSResponseOperation {
        let query = DNSWireQuery.makeAQuery(domain: domain)
        let info = AGDnsMessageInfo()
        info.isTcp = false
        info.transparent = false
        let operation = DNSResponseOperation()
        proxy.handleMessage(query, with: info) { response in
            operation.finish(response ?? Data())
        }
        return operation
    }

    func answerAddress(for domain: String) async throws -> String {
        guard let response = await response(for: domain) else {
            throw ReapplyGateError.responseTimedOut
        }
        return try DNSWireResponse.ipv4Address(in: response)
    }

    func collectResponses(domain: String, count: Int) async -> [Data?] {
        var responses: [Data?] = []
        responses.reserveCapacity(count)
        for _ in 0..<count {
            responses.append(await response(for: domain))
            await Task.yield()
        }
        return responses
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

private final class DNSResponseOperation: Sendable {
    private enum State {
        case awaiting(CheckedContinuation<Data?, Never>?)
        case finished(Data)
        case timedOut
    }

    private let state = Mutex(State.awaiting(nil))

    func value(timeout: Duration) async -> Data? {
        await withCheckedContinuation { continuation in
            let result = state.withLock { state -> Data? in
                switch state {
                case .awaiting(nil):
                    state = .awaiting(continuation)
                    return nil
                case .awaiting(.some):
                    preconditionFailure("DNS response operation may only have one waiter")
                case let .finished(response):
                    return response
                case .timedOut:
                    return nil
                }
            }
            if let result {
                continuation.resume(returning: result)
                return
            }

            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.timeout()
            }
        }
    }

    func finish(_ response: Data) {
        let continuation = state.withLock { state -> CheckedContinuation<
            Data?,
            Never
        >? in
            guard case let .awaiting(continuation) = state else { return nil }
            state = .finished(response)
            return continuation
        }
        continuation?.resume(returning: response)
    }

    private func timeout() {
        let continuation = state.withLock { state -> CheckedContinuation<
            Data?,
            Never
        >? in
            guard case let .awaiting(.some(continuation)) = state else {
                return nil
            }
            state = .timedOut
            return continuation
        }
        continuation?.resume(returning: nil)
    }
}

private enum DNSWireQuery {
    static func makeAQuery(domain: String) -> Data {
        var bytes: [UInt8] = [
            0x47, 0x11,
            0x01, 0x00,
            0x00, 0x01,
            0x00, 0x00,
            0x00, 0x00,
            0x00, 0x00,
        ]
        for label in domain.split(separator: ".") {
            let labelBytes = Array(label.utf8)
            precondition(labelBytes.count <= 63)
            bytes.append(UInt8(labelBytes.count))
            bytes.append(contentsOf: labelBytes)
        }
        bytes.append(0)
        bytes.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        return Data(bytes)
    }
}

private enum DNSWireResponse {
    static func ipv4Address(in response: Data) throws -> String {
        let bytes = [UInt8](response)
        guard bytes.count >= 12 else {
            throw ReapplyGateError.invalidDNSResponse("response is empty or shorter than header")
        }

        var offset = 4
        let questionCount = try readUInt16(bytes, offset: &offset)
        let answerCount = try readUInt16(bytes, offset: &offset)
        offset += 4

        for _ in 0..<questionCount {
            try skipName(bytes, offset: &offset)
            guard offset + 4 <= bytes.count else {
                throw ReapplyGateError.invalidDNSResponse("truncated question")
            }
            offset += 4
        }

        for _ in 0..<answerCount {
            try skipName(bytes, offset: &offset)
            let type = try readUInt16(bytes, offset: &offset)
            let dnsClass = try readUInt16(bytes, offset: &offset)
            guard offset + 6 <= bytes.count else {
                throw ReapplyGateError.invalidDNSResponse("truncated answer metadata")
            }
            offset += 4
            let dataLength = Int(try readUInt16(bytes, offset: &offset))
            guard offset + dataLength <= bytes.count else {
                throw ReapplyGateError.invalidDNSResponse("truncated answer data")
            }
            if type == 1, dnsClass == 1, dataLength == 4 {
                return bytes[offset..<(offset + 4)].map(String.init).joined(separator: ".")
            }
            offset += dataLength
        }
        throw ReapplyGateError.invalidDNSResponse("response has no IPv4 answer")
    }

    private static func readUInt16(_ bytes: [UInt8], offset: inout Int) throws -> UInt16 {
        guard offset + 2 <= bytes.count else {
            throw ReapplyGateError.invalidDNSResponse("truncated 16-bit value")
        }
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func skipName(_ bytes: [UInt8], offset: inout Int) throws {
        while true {
            guard offset < bytes.count else {
                throw ReapplyGateError.invalidDNSResponse("truncated DNS name")
            }
            let length = bytes[offset]
            if length & 0xC0 == 0xC0 {
                guard offset + 2 <= bytes.count else {
                    throw ReapplyGateError.invalidDNSResponse("truncated compression pointer")
                }
                offset += 2
                return
            }
            offset += 1
            if length == 0 {
                return
            }
            guard length <= 63, offset + Int(length) <= bytes.count else {
                throw ReapplyGateError.invalidDNSResponse("invalid DNS label")
            }
            offset += Int(length)
        }
    }
}

private enum ReapplyGateError: Error, CustomStringConvertible, Sendable {
    case defaultConfigurationUnavailable
    case initializationFailed(String)
    case invalidDNSResponse(String)
    case responseTimedOut

    var description: String {
        switch self {
        case .defaultConfigurationUnavailable:
            "AGDnsProxyConfig.getDefault() returned nil"
        case let .initializationFailed(message):
            "AGDnsProxy initialization failed: \(message)"
        case let .invalidDNSResponse(message):
            "Invalid DNS response: \(message)"
        case .responseTimedOut:
            "DNS response callback timed out"
        }
    }
}
