import AGDnsProxy
import Foundation
import Synchronization

protocol DNSQueryTesting: Sendable {
    func query(_ request: DNSQueryRequest) async throws -> DNSQueryResult
}

final class DNSQueryTester: DNSQueryTesting, Sendable {
    // DnsLibs objects never leave the owned serial queue; this wrapper only carries them to cleanup.
    private final class Runtime: @unchecked Sendable {
        let events: AGDnsProxyEvents
        let proxy: AGDnsProxy

        init(events: AGDnsProxyEvents, proxy: AGDnsProxy) {
            self.events = events
            self.proxy = proxy
        }

        func stop() {
            proxy.stop()
        }
    }

    private final class Operation: @unchecked Sendable {
        fileprivate typealias Continuation = CheckedContinuation<DNSQueryResult, any Error>

        private enum State {
            case pending
            case waiting(Continuation)
            case running(Continuation, Runtime)
            case cancelled
            case finished
        }

        private let state = Mutex(State.pending)

        func install(_ continuation: Continuation) {
            let cancelled = state.withLock { state in
                switch state {
                case .pending:
                    state = .waiting(continuation)
                    return false
                case .cancelled:
                    state = .finished
                    return true
                case .waiting, .running, .finished:
                    preconditionFailure("DNS query continuation installed more than once")
                }
            }
            if cancelled {
                continuation.resume(throwing: CancellationError())
            }
        }

        func attach(_ runtime: Runtime) -> Bool {
            state.withLock { state in
                guard case let .waiting(continuation) = state else { return false }
                state = .running(continuation, runtime)
                return true
            }
        }

        func complete(_ result: Result<DNSQueryResult, any Error>) {
            let completion = state.withLock { state -> (Continuation, Runtime?)? in
                switch state {
                case let .waiting(continuation):
                    state = .finished
                    return (continuation, nil)
                case let .running(continuation, runtime):
                    state = .finished
                    return (continuation, runtime)
                case .pending, .cancelled, .finished:
                    return nil
                }
            }
            completion?.1?.stop()
            completion?.0.resume(with: result)
        }

        func cancel() {
            let completion = state.withLock { state -> (Continuation, Runtime?)? in
                switch state {
                case .pending:
                    state = .cancelled
                    return nil
                case let .waiting(continuation):
                    state = .finished
                    return (continuation, nil)
                case let .running(continuation, runtime):
                    state = .finished
                    return (continuation, runtime)
                case .cancelled, .finished:
                    return nil
                }
            }
            completion?.1?.stop()
            completion?.0.resume(throwing: CancellationError())
        }
    }

    private let queue = DispatchQueue(label: "DNSPilot.dns-query")

    func query(_ request: DNSQueryRequest) async throws -> DNSQueryResult {
        let operation = Operation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                queue.async { [self] in
                    start(request, operation: operation)
                }
            }
        } onCancel: { [queue] in
            queue.async {
                operation.cancel()
            }
        }
    }

    private func start(_ request: DNSQueryRequest, operation: Operation) {
        do {
            let configuration = try AGDnsConfigurationAdapter.makeQueryProxyConfig(
                from: request.upstream
            )
            let events = AGDnsProxyEvents()
            events.onRequestProcessed = { [queue] event in
                guard let event else { return }
                let result = Result { try Self.snapshot(event, for: request) }
                queue.async {
                    operation.complete(result)
                }
            }

            var initializationIssue: NSError?
            guard let proxy = AGDnsProxy(
                config: configuration,
                handler: events,
                error: &initializationIssue
            ) else {
                throw DNSQueryServiceError.initializationFailed(
                    initializationIssue?.localizedDescription ?? "Unknown initialization failure"
                )
            }
            if let initializationIssue {
                proxy.stop()
                throw DNSQueryServiceError.initializationFailed(
                    initializationIssue.localizedDescription
                )
            }

            let runtime = Runtime(events: events, proxy: proxy)
            guard operation.attach(runtime) else {
                runtime.stop()
                return
            }

            let query = DNSWireQueryEncoder.encode(
                request,
                identifier: UInt16.random(in: UInt16.min...UInt16.max)
            )
            let info = AGDnsMessageInfo()
            info.isTcp = false
            info.transparent = false
            proxy.handleMessage(query, with: info) { _ in }

            queue.asyncAfter(deadline: .now() + .seconds(6)) {
                operation.complete(.failure(DNSQueryServiceError.timedOut))
            }
        } catch let error as DNSQueryServiceError {
            operation.complete(.failure(error))
        } catch {
            operation.complete(.failure(DNSQueryServiceError.initializationFailed(
                error.localizedDescription
            )))
        }
    }

    static func snapshot(
        _ event: AGDnsRequestProcessedEvent,
        for request: DNSQueryRequest
    ) throws -> DNSQueryResult {
        let error = event.error ?? ""
        guard error.isEmpty else {
            throw DNSQueryServiceError.exchangeFailed(error)
        }
        return DNSQueryResult(
            domain: request.domain,
            type: request.type,
            status: event.status ?? "UNKNOWN",
            answer: event.answer ?? "",
            server: ProfileDisplayIdentity.summary(for: request.upstream),
            elapsedMilliseconds: event.elapsed,
            bytesSent: event.bytesSent,
            bytesReceived: event.bytesReceived
        )
    }
}
