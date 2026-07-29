import Foundation
import SystemConfiguration

enum MachXPCServerError: LocalizedError {
    case missingConfiguration(String)
    case invalidCodeSigningRequirement

    var errorDescription: String? {
        switch self {
        case let .missingConfiguration(key):
            "Missing System Extension configuration: \(key)."
        case .invalidCodeSigningRequirement:
            "The Host code-signing requirement could not be constructed."
        }
    }
}

final class MachXPCServer: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let service: RuntimeStatusService

    init(
        bundle: Bundle = .main,
        statusStore: RuntimeStatusStore = .shared,
        runtimeControlHandler: ProxyRuntimeControlHandler = DNSProxyExtensionRuntime
            .runtimeControlHandler
    ) throws {
        guard
            let networkExtension = bundle.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any],
            let serviceName = networkExtension["NEMachServiceName"] as? String,
            !serviceName.isEmpty
        else {
            throw MachXPCServerError.missingConfiguration("NetworkExtension.NEMachServiceName")
        }
        guard
            let hostBundleIdentifier = bundle.object(
                forInfoDictionaryKey: "DNSPilotExpectedHostBundleIdentifier"
            ) as? String,
            !hostBundleIdentifier.isEmpty
        else {
            throw MachXPCServerError.missingConfiguration("DNSPilotExpectedHostBundleIdentifier")
        }
        guard
            let teamIdentifier = bundle.object(
                forInfoDictionaryKey: "DNSPilotExpectedTeamIdentifier"
            ) as? String,
            !teamIdentifier.isEmpty
        else {
            throw MachXPCServerError.missingConfiguration("DNSPilotExpectedTeamIdentifier")
        }
        guard let requirement = DNSProxyXPCContract.codeSigningRequirement(
            teamIdentifier: teamIdentifier,
            bundleIdentifier: hostBundleIdentifier
        ) else {
            throw MachXPCServerError.invalidCodeSigningRequirement
        }

        listener = NSXPCListener(machServiceName: serviceName)
        service = RuntimeStatusService(
            statusStore: statusStore,
            runtimeControlHandler: runtimeControlHandler
        )
        super.init()
        listener.delegate = self
        listener.setConnectionCodeSigningRequirement(requirement)
    }

    func activate() {
        listener.activate()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard let consoleUserIdentifier, newConnection.effectiveUserIdentifier == consoleUserIdentifier else {
            return false
        }

        newConnection.exportedInterface = DNSProxyXPCContract.makeInterface()
        newConnection.exportedObject = service
        newConnection.activate()
        return true
    }

    private var consoleUserIdentifier: uid_t? {
        var userIdentifier: uid_t = 0
        var groupIdentifier: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &userIdentifier, &groupIdentifier) else {
            return nil
        }
        let userName = name as String
        guard !userName.isEmpty, userName != "loginwindow" else { return nil }
        return userIdentifier
    }
}

private final class RuntimeStatusService: NSObject, DNSProxyXPCProtocol {
    private let statusStore: RuntimeStatusStore
    private let runtimeControlHandler: ProxyRuntimeControlHandler

    init(
        statusStore: RuntimeStatusStore,
        runtimeControlHandler: ProxyRuntimeControlHandler
    ) {
        self.statusStore = statusStore
        self.runtimeControlHandler = runtimeControlHandler
    }

    func runtimeStatus(reply: @escaping (Data?, NSError?) -> Void) {
        encode(statusStore.snapshot(), reply: reply)
    }

    func runtimeEvidence(reply: @escaping (Data?, NSError?) -> Void) {
        encode(statusStore.evidenceSnapshot(), reply: reply)
    }

    func reapplyConfiguration(
        _ requestData: Data,
        reply: @escaping (Data?, NSError?) -> Void
    ) {
        encode(runtimeControlHandler.reapply(requestData), reply: reply)
    }

    func quiesceRuntime(
        _ requestData: Data,
        reply: @escaping (Data?, NSError?) -> Void
    ) {
        encode(runtimeControlHandler.quiesce(requestData), reply: reply)
    }

    func resumeRuntime(
        _ requestData: Data,
        reply: @escaping (Data?, NSError?) -> Void
    ) {
        encode(runtimeControlHandler.resume(requestData), reply: reply)
    }

    private func encode<Value: Encodable>(
        _ value: Value,
        reply: @escaping (Data?, NSError?) -> Void
    ) {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            reply(try encoder.encode(value), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }
}
