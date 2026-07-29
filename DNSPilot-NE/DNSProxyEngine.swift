import AGDnsProxy
import Foundation
import NetworkExtension
import os
import Synchronization

enum DNSProxyEngineError: LocalizedError {
    case alreadyRunning
    case initializationFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "The DNS proxy engine is already running."
        case let .initializationFailed(message):
            "AGDnsProxy initialization failed: \(message)"
        }
    }
}

final class DNSProxyEngine: DNSProxyServicing, Sendable {
    private struct State {
        var generation: UUID?
        var proxy: AGDnsProxy?
        var flowManager: AGDnsAppProxyFlowManager?
        var events: AGDnsProxyEvents?
    }

    private final class RequestEventRouter: Sendable {
        private let statusStore: RuntimeStatusStore
        private let generation = Mutex<UUID?>(nil)

        init(statusStore: RuntimeStatusStore) {
            self.statusStore = statusStore
        }

        func setGeneration(_ value: UUID?) {
            generation.withLock { $0 = value }
        }

        func recordRequest() {
            guard let current = generation.withLock({ $0 }) else { return }
            statusStore.recordRequest(generation: current)
        }
    }

    // DnsLibs and NetworkExtension objects are not Sendable; this lock is their sole owner.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let statusStore: RuntimeStatusStore
    private let requestEventRouter: RequestEventRouter

    init(statusStore: RuntimeStatusStore = .shared) {
        self.statusStore = statusStore
        requestEventRouter = RequestEventRouter(statusStore: statusStore)
    }

    deinit {
        stop()
    }

    func start(configuration: PersistedProxyConfiguration) throws {
        try state.withLockUnchecked { state in
            guard state.proxy == nil, state.flowManager == nil else {
                throw DNSProxyEngineError.alreadyRunning
            }
            let value = configuration.value

            DNSLogBridge.configure(
                process: "SystemExtension",
                mode: value.loggingMode
            )
            let proxyConfig = try AGDnsConfigurationAdapter.makeProxyConfig(from: value)
            let events = AGDnsProxyEvents()
            events.onRequestProcessed = { [requestEventRouter] _ in
                requestEventRouter.recordRequest()
            }
            var initializationIssue: NSError?
            guard let proxy = AGDnsProxy(
                config: proxyConfig,
                handler: events,
                error: &initializationIssue
            ) else {
                throw DNSProxyEngineError.initializationFailed(
                    initializationIssue?.localizedDescription ?? "Unknown error"
                )
            }
            if let initializationIssue {
                proxy.stop()
                throw DNSProxyEngineError.initializationFailed(
                    initializationIssue.localizedDescription
                )
            }

            state.generation = value.generation
            state.events = events
            state.proxy = proxy
            state.flowManager = AGDnsAppProxyFlowManager(
                dnsProxy: proxy,
                maxLocalFlowCount: 256
            )
            requestEventRouter.setGeneration(value.generation)
        }
    }

    func reapply(_ plan: DNSProxyReloadPlan) throws {
        let proxyConfig: AGDnsProxyConfig?
        do {
            proxyConfig = plan.scope.isEmpty
                ? nil
                : try AGDnsConfigurationAdapter.makeProxyConfig(from: plan.target.value)
        } catch {
            throw DNSProxyServiceReapplyError.unchanged(String(describing: error))
        }

        try state.withLockUnchecked { state in
            guard let proxy = state.proxy, state.flowManager != nil else {
                throw DNSProxyServiceReapplyError.unchanged(
                    "The DNS proxy engine is not running."
                )
            }

            if let proxyConfig {
                var reapplyIssue: NSError?
                let applied = proxy.reapplySettings(
                    proxyConfig,
                    options: plan.scope.agDnsReapplyOptions,
                    error: &reapplyIssue
                )
                guard applied else {
                    throw DNSProxyServiceReapplyError.engineMayHaveMutated(
                        reapplyIssue?.localizedDescription
                            ?? "AGDnsProxy reapply failed without an error."
                    )
                }
            }

            if plan.loggingModeChanged {
                DNSLogBridge.configure(
                    process: "SystemExtension",
                    mode: plan.target.value.loggingMode
                )
            }
            state.generation = plan.target.value.generation
            requestEventRouter.setGeneration(plan.target.value.generation)
        }
    }

    func handle(_ flow: NEAppProxyFlow) -> Bool {
        state.withLockUnchecked { state in
            guard
                let generation = state.generation,
                let flowManager = state.flowManager
            else { return false }
            let accepted = flowManager.handle(flow, mode: .redirect)
            let kind: RuntimeFlowKind
            if flow is NEAppProxyUDPFlow {
                kind = .udp
            } else if flow is NEAppProxyTCPFlow {
                kind = .tcp
            } else {
                kind = .other
            }
            statusStore.recordFlow(
                generation: generation,
                kind: kind,
                accepted: accepted
            )
            return accepted
        }
    }

    func stop() {
        state.withLockUnchecked { state in
            guard state.proxy != nil || state.flowManager != nil else { return }
            requestEventRouter.setGeneration(nil)
            state.generation = nil
            state.flowManager?.stop()
            state.flowManager = nil
            state.proxy?.stop()
            state.proxy = nil
            state.events = nil
        }
    }
}
