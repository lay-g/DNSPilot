import Darwin
import Foundation
import Synchronization

private enum ProbeError: LocalizedError, Sendable {
    case invalidArguments(String)
    case invalidServerRequirement
    case unavailable(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message):
            message
        case .invalidServerRequirement:
            "The server code-signing requirement is invalid."
        case let .unavailable(message):
            "The Mach XPC service rejected or failed the request: \(message)"
        case .invalidResponse:
            "The Mach XPC service returned an invalid response."
        }
    }

    var exitCode: Int32 {
        switch self {
        case .invalidArguments:
            64
        case .invalidServerRequirement:
            65
        case .unavailable:
            69
        case .invalidResponse:
            70
        }
    }
}

private enum ProbeRequest: String, Sendable {
    case status
    case evidence
    case both
}

private struct ProbeArguments: Sendable {
    let serviceName: String
    let serverTeamIdentifier: String
    let serverBundleIdentifier: String
    let request: ProbeRequest
    let timeoutSeconds: Int64

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else {
                throw ProbeError.invalidArguments("Every option must have a value.")
            }
            values[key] = arguments[index + 1]
            index += 2
        }

        guard let serviceName = values["--service"], !serviceName.isEmpty else {
            throw ProbeError.invalidArguments("Missing --service.")
        }
        guard let teamIdentifier = values["--server-team"], !teamIdentifier.isEmpty else {
            throw ProbeError.invalidArguments("Missing --server-team.")
        }
        guard let bundleIdentifier = values["--server-identifier"], !bundleIdentifier.isEmpty else {
            throw ProbeError.invalidArguments("Missing --server-identifier.")
        }
        guard let request = ProbeRequest(rawValue: values["--request"] ?? "both") else {
            throw ProbeError.invalidArguments("--request must be status, evidence, or both.")
        }
        guard
            let timeoutSeconds = Int64(values["--timeout-seconds"] ?? "5"),
            timeoutSeconds > 0
        else {
            throw ProbeError.invalidArguments("--timeout-seconds must be a positive integer.")
        }

        self.serviceName = serviceName
        serverTeamIdentifier = teamIdentifier
        serverBundleIdentifier = bundleIdentifier
        self.request = request
        self.timeoutSeconds = timeoutSeconds
    }
}

private final class ProbeReply<Value: Sendable>: Sendable {
    private enum State {
        case waiting(CheckedContinuation<Value, any Error>)
        case finished
    }

    private let state: Mutex<State>

    init(continuation: CheckedContinuation<Value, any Error>) {
        state = Mutex(.waiting(continuation))
    }

    func resume(with result: Result<Value, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Value, any Error>? in
            guard case let .waiting(continuation) = state else { return nil }
            state = .finished
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private actor ProbeClient {
    private enum RequestKind {
        case status
        case evidence
    }

    private let arguments: ProbeArguments

    init(arguments: ProbeArguments) {
        self.arguments = arguments
    }

    func status() async throws -> ProxyRuntimeStatus {
        try await request(ProxyRuntimeStatus.self, kind: .status)
    }

    func evidence() async throws -> ProxyRuntimeEvidence {
        try await request(ProxyRuntimeEvidence.self, kind: .evidence)
    }

    private func request<Value: Decodable & Sendable>(
        _ type: Value.Type,
        kind: RequestKind
    ) async throws -> Value {
        guard let requirement = DNSProxyXPCContract.codeSigningRequirement(
            teamIdentifier: arguments.serverTeamIdentifier,
            bundleIdentifier: arguments.serverBundleIdentifier
        ) else {
            throw ProbeError.invalidServerRequirement
        }

        let connection = NSXPCConnection(
            machServiceName: arguments.serviceName,
            options: .privileged
        )
        connection.remoteObjectInterface = DNSProxyXPCContract.makeInterface()
        connection.setCodeSigningRequirement(requirement)
        connection.activate()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let reply = ProbeReply<Value>(continuation: continuation)
            let errorHandler: (any Error) -> Void = { error in
                reply.resume(with: .failure(ProbeError.unavailable(error.localizedDescription)))
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler)
                as? DNSProxyXPCProtocol else {
                reply.resume(with: .failure(ProbeError.unavailable("No remote proxy.")))
                return
            }

            let callback: (Data?, NSError?) -> Void = { data, error in
                if let error {
                    reply.resume(with: .failure(ProbeError.unavailable(error.localizedDescription)))
                    return
                }
                guard let data else {
                    reply.resume(with: .failure(ProbeError.invalidResponse))
                    return
                }
                do {
                    reply.resume(with: .success(
                        try PropertyListDecoder().decode(type, from: data)
                    ))
                } catch {
                    reply.resume(with: .failure(ProbeError.invalidResponse))
                }
            }

            switch kind {
            case .status:
                proxy.runtimeStatus(reply: callback)
            case .evidence:
                proxy.runtimeEvidence(reply: callback)
            }
        }
    }
}

@main
private struct MachXPCProbe {
    static func main() async {
        do {
            let arguments = try ProbeArguments(arguments: Array(CommandLine.arguments.dropFirst()))
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(arguments.timeoutSeconds))
                guard !Task.isCancelled else { return }
                writeError("Mach XPC probe timed out.\n")
                exit(124)
            }
            defer { timeoutTask.cancel() }

            let client = ProbeClient(arguments: arguments)
            if arguments.request == .status || arguments.request == .both {
                let status = try await client.status()
                let fingerprint = status.configurationFingerprint.map {
                    String($0.rawValue.prefix(12))
                } ?? "none"
                print(
                    "status phase=\(status.phase.rawValue) "
                        + "provider=\(status.providerInstanceID?.uuidString ?? "none") "
                        + "sequence=\(status.transitionSequence.map(String.init) ?? "none") "
                        + "generation=\(status.generation?.uuidString ?? "none") "
                        + "fingerprint=\(fingerprint) "
                        + "error=\(status.errorCode?.rawValue ?? "none")"
                )
            }
            if arguments.request == .evidence || arguments.request == .both {
                let evidence = try await client.evidence()
                print(
                    "evidence generation=\(evidence.generation?.uuidString ?? "none") "
                        + "udp=\(evidence.udpFlowsOffered) tcp=\(evidence.tcpFlowsOffered) "
                        + "other=\(evidence.otherFlowsOffered) "
                        + "accepted=\(evidence.flowsAccepted) rejected=\(evidence.flowsRejected) "
                        + "requests=\(evidence.requestsProcessed)"
                )
            }
        } catch let error as ProbeError {
            writeError((error.errorDescription ?? "Mach XPC probe failed.") + "\n")
            exit(error.exitCode)
        } catch {
            writeError("Mach XPC probe failed: \(error.localizedDescription)\n")
            exit(1)
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
