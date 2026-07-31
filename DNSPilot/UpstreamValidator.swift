import AGDnsProxy
import Foundation
import Synchronization

enum ProfileTestFailure: Error, Equatable, Sendable {
    case upstreamRejected(String)

    var diagnosticDescription: String {
        switch self {
        case let .upstreamRejected(description):
            description
        }
    }

    static func dnsLibs(_ error: NSError) -> Self {
        .upstreamRejected("\(error.domain)(\(error.code)): \(error.localizedDescription)")
    }
}

protocol UpstreamValidating: Sendable {
    func validate(_ upstream: DNSUpstream) async throws
}

final class UpstreamValidator: UpstreamValidating, Sendable {
    private final class Operation: Sendable {
        private enum State {
            case pending
            case waiting(CheckedContinuation<Void, any Error>)
            case cancelled
            case finished
        }

        private let state = Mutex(State.pending)

        func install(_ continuation: CheckedContinuation<Void, any Error>) {
            let cancelled = state.withLock { state in
                switch state {
                case .pending:
                    state = .waiting(continuation)
                    return false
                case .cancelled:
                    state = .finished
                    return true
                case .waiting, .finished:
                    preconditionFailure("Validation continuation installed more than once")
                }
            }
            if cancelled {
                continuation.resume(throwing: CancellationError())
            }
        }

        func cancel() {
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                switch state {
                case .pending:
                    state = .cancelled
                    return nil
                case let .waiting(continuation):
                    state = .finished
                    return continuation
                case .cancelled, .finished:
                    return nil
                }
            }
            continuation?.resume(throwing: CancellationError())
        }

        func complete(_ result: Result<Void, any Error>) {
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard case let .waiting(continuation) = state else { return nil }
                state = .finished
                return continuation
            }
            continuation?.resume(with: result)
        }
    }

    private let queue = DispatchQueue(label: "DNSPilot.upstream-validation")

    func validate(_ upstream: DNSUpstream) async throws {
        let operation = Operation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                queue.async {
                    do {
                        let mappedUpstream = try AGDnsConfigurationAdapter.makeUpstream(from: upstream)
                        if let error = AGDnsUtils.test(
                            mappedUpstream,
                            timeoutMs: 5_000,
                            ipv6Available: true,
                            offline: false
                        ) {
                            throw ProfileTestFailure.dnsLibs(error as NSError)
                        }
                        operation.complete(.success(()))
                    } catch {
                        operation.complete(.failure(error))
                    }
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }
}
