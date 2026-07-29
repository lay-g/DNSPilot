import Foundation
import NetworkExtension
import OSLog

struct DNSProxyManagerOwnerIdentity: Equatable, Sendable {
    let providerBundleIdentifier: String?
    let providerConfigurationFingerprint: ProxyConfigurationFingerprint
    let localizedDescription: String?
}

struct DNSProxyManagerSnapshot: Equatable, Sendable {
    let isEnabled: Bool
    let persistedConfiguration: PersistedProxyConfiguration?
    let ownerIdentity: DNSProxyManagerOwnerIdentity?

    var activeConfiguration: ActiveProxyConfiguration? {
        persistedConfiguration?.value
    }

    init(
        isEnabled: Bool,
        persistedConfiguration: PersistedProxyConfiguration?,
        ownerIdentity: DNSProxyManagerOwnerIdentity? = nil
    ) {
        self.isEnabled = isEnabled
        self.persistedConfiguration = persistedConfiguration
        self.ownerIdentity = ownerIdentity
    }

    init(
        isEnabled: Bool,
        activeConfiguration: ActiveProxyConfiguration?,
        ownerIdentity: DNSProxyManagerOwnerIdentity? = nil
    ) {
        self.isEnabled = isEnabled
        self.ownerIdentity = ownerIdentity
        if let activeConfiguration {
            persistedConfiguration = try? PersistedProxyConfiguration(value: activeConfiguration)
        } else {
            persistedConfiguration = nil
        }
    }
}

enum DNSProxyManagerEnableResult: Equatable, Sendable {
    case enabled
    case alreadyEnabled(DNSProxyManagerSnapshot)
}

enum DNSProxyManagerDisableResult: Equatable, Sendable {
    case disabled
    case alreadyDisabled
    case generationChanged(DNSProxyManagerSnapshot)
}

enum DNSProxyManagerReplaceResult: Equatable, Sendable {
    case replaced(DNSProxyManagerSnapshot)
    case configurationChanged(DNSProxyManagerSnapshot)
}

enum DNSProxyManagerClientError: LocalizedError, Sendable {
    case configurationStale
    case injectedDisableSaveFailure

    var errorDescription: String? {
        switch self {
        case .configurationStale:
            "The DNS Proxy manager configuration is stale."
        case .injectedDisableSaveFailure:
            "DebugLocal injected a DNS Proxy disable save failure."
        }
    }
}

#if DNSPILOT_DEBUG_LOCAL
enum DNSProxyManagerGateAError: LocalizedError, Sendable {
    case managerDisabled
    case missingConfiguration
    case exactOwnerChanged
    case saveVerificationFailed

    var errorDescription: String? {
        switch self {
        case .managerDisabled:
            "Gate A requires an enabled DNS Proxy manager."
        case .missingConfiguration:
            "Gate A could not read the DNS Proxy manager configuration."
        case .exactOwnerChanged:
            "Gate A refused to overwrite a manager configuration it does not own."
        case .saveVerificationFailed:
            "Gate A could not verify the exact saved manager configuration."
        }
    }
}

struct DNSProxyManagerGateAOwner: Equatable, Sendable {
    let snapshot: DNSProxyManagerSnapshot
    let providerBundleIdentifier: String?
    let providerConfigurationFingerprint: ProxyConfigurationFingerprint
    let localizedDescription: String?

    init(
        snapshot: DNSProxyManagerSnapshot,
        providerBundleIdentifier: String?,
        providerConfigurationFingerprint: ProxyConfigurationFingerprint,
        localizedDescription: String?
    ) {
        let ownerIdentity = DNSProxyManagerOwnerIdentity(
            providerBundleIdentifier: providerBundleIdentifier,
            providerConfigurationFingerprint: providerConfigurationFingerprint,
            localizedDescription: localizedDescription
        )
        self.snapshot = DNSProxyManagerSnapshot(
            isEnabled: snapshot.isEnabled,
            persistedConfiguration: snapshot.persistedConfiguration,
            ownerIdentity: ownerIdentity
        )
        self.providerBundleIdentifier = providerBundleIdentifier
        self.providerConfigurationFingerprint = providerConfigurationFingerprint
        self.localizedDescription = localizedDescription
    }

    func hasSameConfiguration(as other: Self) -> Bool {
        snapshot.persistedConfiguration == other.snapshot.persistedConfiguration
            && providerBundleIdentifier == other.providerBundleIdentifier
            && providerConfigurationFingerprint == other.providerConfigurationFingerprint
            && localizedDescription == other.localizedDescription
    }
}
#endif

enum DNSProxyManagerFailureInjection: Equatable, Sendable {
    case failNextDisableSave
    case delayNextDisableSave(Duration)
}

struct DNSProxyManagerFailureInjector: Sendable {
    static let argumentName = "--dnspilot-manager-failure-injection"

    private var pending: DNSProxyManagerFailureInjection?

    init(allowed: Bool, arguments: [String]) {
        guard
            allowed,
            let argumentIndex = arguments.firstIndex(of: Self.argumentName),
            arguments.indices.contains(argumentIndex + 1)
        else {
            pending = nil
            return
        }

        switch arguments[argumentIndex + 1] {
        case "fail-next-disable-save":
            pending = .failNextDisableSave
        case "delay-next-disable-save":
            pending = .delayNextDisableSave(.seconds(6))
        default:
            pending = nil
        }
    }

    mutating func consume() -> DNSProxyManagerFailureInjection? {
        defer { pending = nil }
        return pending
    }
}

protocol DNSProxyManagerManaging: Sendable {
    func loadSnapshot() async throws -> DNSProxyManagerSnapshot

    func saveEnabledConfigurationIfDisabled(
        _ configuration: ActiveProxyConfiguration,
        providerBundleIdentifier: String
    ) async throws -> DNSProxyManagerEnableResult

    func saveDisabled(
        ifGenerationMatches expectedGeneration: UUID?
    ) async throws -> DNSProxyManagerDisableResult

    func saveDisabled(
        ifCurrentMatches expected: DNSProxyManagerSnapshot
    ) async throws -> DNSProxyManagerDisableResult

    func replaceEnabledConfiguration(
        _ target: PersistedProxyConfiguration,
        ifCurrentMatches expected: DNSProxyManagerSnapshot
    ) async throws -> DNSProxyManagerReplaceResult
}

actor NetworkExtensionDNSProxyManager: DNSProxyManagerManaging {
    #if DNSPILOT_DEBUG_LOCAL
    private static let buildAllowsFailureInjection = true
    #else
    private static let buildAllowsFailureInjection = false
    #endif

    private let manager = NEDNSProxyManager.shared()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "DNSPilot",
        category: "DNSProxyManager"
    )
    private var failureInjector: DNSProxyManagerFailureInjector

    init(
        failureInjectionAllowed: Bool = NetworkExtensionDNSProxyManager
            .buildAllowsFailureInjection
            && Bundle.main.object(
                forInfoDictionaryKey: "DNSPilotManagerFailureInjectionAllowed"
            ) as? String == "YES",
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        failureInjector = DNSProxyManagerFailureInjector(
            allowed: failureInjectionAllowed,
            arguments: arguments
        )
    }

    func loadSnapshot() async throws -> DNSProxyManagerSnapshot {
        try await manager.loadFromPreferences()
        return snapshot()
    }

    func saveEnabledConfigurationIfDisabled(
        _ configuration: ActiveProxyConfiguration,
        providerBundleIdentifier: String
    ) async throws -> DNSProxyManagerEnableResult {
        guard !manager.isEnabled else {
            return .alreadyEnabled(snapshot())
        }

        manager.providerProtocol = try DNSProxyManagerConfiguration.makeProviderProtocol(
            configuration: configuration,
            providerBundleIdentifier: providerBundleIdentifier
        )
        manager.localizedDescription = "DNSPilot"
        manager.isEnabled = true
        logger.notice(
            "DNS manager enable save started: generation=\(configuration.generation.uuidString, privacy: .public)"
        )
        try await saveToPreferences()
        logger.notice(
            "DNS manager enable save completed: generation=\(configuration.generation.uuidString, privacy: .public)"
        )
        return .enabled
    }

    func saveDisabled(
        ifGenerationMatches expectedGeneration: UUID?
    ) async throws -> DNSProxyManagerDisableResult {
        guard manager.isEnabled else { return .alreadyDisabled }
        if let changed = generationChange(ifExpected: expectedGeneration) { return changed }

        if let injection = failureInjector.consume() {
            switch injection {
            case .failNextDisableSave:
                logger.error("Applying DebugLocal fail-next-disable-save injection")
                throw DNSProxyManagerClientError.injectedDisableSaveFailure
            case let .delayNextDisableSave(delay):
                logger.notice("Applying DebugLocal delay-next-disable-save injection")
                try await Task.sleep(for: delay)
            }
        }

        guard manager.isEnabled else { return .alreadyDisabled }
        if let changed = generationChange(ifExpected: expectedGeneration) { return changed }
        let currentGeneration = snapshot().activeConfiguration?.generation.uuidString ?? "none"
        let expectedGenerationDescription = expectedGeneration?.uuidString ?? "none"
        manager.isEnabled = false
        logger.notice(
            "DNS manager disable save started: expectedGeneration=\(expectedGenerationDescription, privacy: .public), currentGeneration=\(currentGeneration, privacy: .public)"
        )
        try await saveToPreferences()
        logger.notice(
            "DNS manager disable save completed: expectedGeneration=\(expectedGenerationDescription, privacy: .public), currentGeneration=\(currentGeneration, privacy: .public)"
        )
        return .disabled
    }

    func saveDisabled(
        ifCurrentMatches expected: DNSProxyManagerSnapshot
    ) async throws -> DNSProxyManagerDisableResult {
        try await manager.loadFromPreferences()
        let current = snapshot()
        if !current.isEnabled {
            guard
                current.persistedConfiguration == expected.persistedConfiguration,
                current.ownerIdentity == expected.ownerIdentity
            else {
                return .generationChanged(current)
            }
            return .alreadyDisabled
        }
        guard current == expected else {
            return .generationChanged(current)
        }

        if let injection = failureInjector.consume() {
            switch injection {
            case .failNextDisableSave:
                logger.error("Applying DebugLocal fail-next-disable-save injection")
                throw DNSProxyManagerClientError.injectedDisableSaveFailure
            case let .delayNextDisableSave(delay):
                logger.notice("Applying DebugLocal delay-next-disable-save injection")
                try await Task.sleep(for: delay)
            }
        }

        try await manager.loadFromPreferences()
        guard snapshot() == expected else {
            return .generationChanged(snapshot())
        }

        manager.isEnabled = false
        try await saveToPreferences()
        try await manager.loadFromPreferences()
        let confirmed = snapshot()
        guard
            !confirmed.isEnabled,
            confirmed.persistedConfiguration == expected.persistedConfiguration,
            confirmed.ownerIdentity == expected.ownerIdentity
        else {
            throw DNSProxyManagerClientError.configurationStale
        }
        return .disabled
    }

    func replaceEnabledConfiguration(
        _ target: PersistedProxyConfiguration,
        ifCurrentMatches expected: DNSProxyManagerSnapshot
    ) async throws -> DNSProxyManagerReplaceResult {
        try await manager.loadFromPreferences()
        let current = snapshot()
        guard current.isEnabled, current == expected else {
            return .configurationChanged(snapshot())
        }
        guard let providerProtocol = manager.providerProtocol else {
            return .configurationChanged(snapshot())
        }

        let targetProviderConfiguration = DNSProxyManagerConfiguration
            .replacingActiveConfiguration(
                in: providerProtocol.providerConfiguration,
                with: target
            )
        guard let targetOwnerIdentity = ownerIdentity(
            providerProtocol: providerProtocol,
            providerConfiguration: targetProviderConfiguration
        ) else {
            return .configurationChanged(snapshot())
        }
        let expectedSavedSnapshot = DNSProxyManagerSnapshot(
            isEnabled: true,
            persistedConfiguration: target,
            ownerIdentity: targetOwnerIdentity
        )

        providerProtocol.providerConfiguration = targetProviderConfiguration
        manager.providerProtocol = providerProtocol
        manager.isEnabled = true
        try await saveToPreferences()
        try await manager.loadFromPreferences()
        let confirmed = snapshot()
        guard confirmed == expectedSavedSnapshot else {
            throw DNSProxyManagerClientError.configurationStale
        }
        return .replaced(confirmed)
    }

    #if DNSPILOT_DEBUG_LOCAL
    func gateALoadOwner() async throws -> DNSProxyManagerGateAOwner {
        try await manager.loadFromPreferences()
        return try gateAOwner()
    }

    func gateAPreviewEnabledConfiguration(
        _ target: PersistedProxyConfiguration,
        replacing expected: DNSProxyManagerGateAOwner
    ) async throws -> DNSProxyManagerGateAOwner {
        try await manager.loadFromPreferences()
        let current = try gateAOwner()
        guard current == expected else {
            throw DNSProxyManagerGateAError.exactOwnerChanged
        }
        guard current.snapshot.isEnabled, let providerProtocol = manager.providerProtocol else {
            throw DNSProxyManagerGateAError.managerDisabled
        }
        let providerConfiguration = DNSProxyManagerConfiguration.replacingActiveConfiguration(
            in: providerProtocol.providerConfiguration,
            with: target
        )
        return try makeGateAOwner(
            snapshot: DNSProxyManagerSnapshot(
                isEnabled: true,
                persistedConfiguration: target
            ),
            providerProtocol: providerProtocol,
            providerConfiguration: providerConfiguration
        )
    }

    func gateAReplaceEnabledConfiguration(
        _ target: PersistedProxyConfiguration,
        replacing expected: DNSProxyManagerGateAOwner
    ) async throws -> DNSProxyManagerGateAOwner {
        try await manager.loadFromPreferences()
        let current = try gateAOwner()
        guard current.snapshot.isEnabled else {
            throw DNSProxyManagerGateAError.managerDisabled
        }
        guard current.snapshot.persistedConfiguration != nil else {
            throw DNSProxyManagerGateAError.missingConfiguration
        }
        guard current == expected else {
            throw DNSProxyManagerGateAError.exactOwnerChanged
        }
        guard let providerProtocol = manager.providerProtocol else {
            throw DNSProxyManagerGateAError.missingConfiguration
        }

        providerProtocol.providerConfiguration = DNSProxyManagerConfiguration
            .replacingActiveConfiguration(
                in: providerProtocol.providerConfiguration,
                with: target
            )
        manager.providerProtocol = providerProtocol
        manager.isEnabled = true
        logger.notice(
            "Gate A enabled save started: oldGeneration=\(expected.snapshot.activeConfiguration?.generation.uuidString ?? "none", privacy: .public), targetGeneration=\(target.value.generation.uuidString, privacy: .public)"
        )
        try await saveToPreferences()
        try await manager.loadFromPreferences()
        let confirmed = try gateAOwner()
        guard
            confirmed.snapshot.isEnabled,
            confirmed.snapshot.persistedConfiguration == target
        else {
            throw DNSProxyManagerGateAError.saveVerificationFailed
        }
        logger.notice(
            "Gate A enabled save confirmed: targetGeneration=\(target.value.generation.uuidString, privacy: .public)"
        )
        return confirmed
    }

    func gateADisableForRecovery(
        ifOwnerMatches expected: DNSProxyManagerGateAOwner
    ) async throws -> DNSProxyManagerGateAOwner {
        try await manager.loadFromPreferences()
        let current = try gateAOwner()
        guard current == expected else {
            throw DNSProxyManagerGateAError.exactOwnerChanged
        }
        guard current.snapshot.isEnabled else { return current }

        manager.isEnabled = false
        logger.notice(
            "Gate A recovery disable started: generation=\(expected.snapshot.activeConfiguration?.generation.uuidString ?? "none", privacy: .public)"
        )
        try await saveToPreferences()
        try await manager.loadFromPreferences()
        let confirmed = try gateAOwner()
        guard
            !confirmed.snapshot.isEnabled,
            confirmed.hasSameConfiguration(as: expected)
        else {
            throw DNSProxyManagerGateAError.saveVerificationFailed
        }
        return confirmed
    }

    private func gateAOwner() throws -> DNSProxyManagerGateAOwner {
        guard let providerProtocol = manager.providerProtocol else {
            throw DNSProxyManagerGateAError.missingConfiguration
        }
        return try makeGateAOwner(
            snapshot: snapshot(),
            providerProtocol: providerProtocol,
            providerConfiguration: providerProtocol.providerConfiguration ?? [:]
        )
    }

    private func makeGateAOwner(
        snapshot: DNSProxyManagerSnapshot,
        providerProtocol: NEDNSProxyProviderProtocol,
        providerConfiguration: [String: Any]
    ) throws -> DNSProxyManagerGateAOwner {
        guard PropertyListSerialization.propertyList(
            providerConfiguration,
            isValidFor: .binary
        ) else {
            throw DNSProxyManagerGateAError.missingConfiguration
        }
        let providerConfigurationData = try PropertyListSerialization.data(
            fromPropertyList: providerConfiguration,
            format: .binary,
            options: 0
        )
        return DNSProxyManagerGateAOwner(
            snapshot: snapshot,
            providerBundleIdentifier: providerProtocol.providerBundleIdentifier,
            providerConfigurationFingerprint: ProxyConfigurationFingerprint(
                data: providerConfigurationData
            ),
            localizedDescription: manager.localizedDescription
        )
    }
    #endif

    private func snapshot() -> DNSProxyManagerSnapshot {
        DNSProxyManagerSnapshot(
            isEnabled: manager.isEnabled,
            persistedConfiguration: try? DNSProxyManagerConfiguration.persistedConfiguration(
                from: manager.providerProtocol
            ),
            ownerIdentity: ownerIdentity(
                providerProtocol: manager.providerProtocol,
                providerConfiguration: manager.providerProtocol?.providerConfiguration
            )
        )
    }

    private func ownerIdentity(
        providerProtocol: NEDNSProxyProviderProtocol?,
        providerConfiguration: [String: Any]?
    ) -> DNSProxyManagerOwnerIdentity? {
        guard
            let providerProtocol,
            let providerConfiguration,
            PropertyListSerialization.propertyList(
                providerConfiguration,
                isValidFor: .binary
            ),
            let data = try? PropertyListSerialization.data(
                fromPropertyList: providerConfiguration,
                format: .binary,
                options: 0
            )
        else {
            return nil
        }
        return DNSProxyManagerOwnerIdentity(
            providerBundleIdentifier: providerProtocol.providerBundleIdentifier,
            providerConfigurationFingerprint: ProxyConfigurationFingerprint(data: data),
            localizedDescription: manager.localizedDescription
        )
    }

    private func generationChange(
        ifExpected expectedGeneration: UUID?
    ) -> DNSProxyManagerDisableResult? {
        guard
            let expectedGeneration,
            snapshot().activeConfiguration?.generation != expectedGeneration
        else {
            return nil
        }
        return .generationChanged(snapshot())
    }

    private func saveToPreferences() async throws {
        do {
            try await manager.saveToPreferences()
        } catch let error as NSError where
            error.domain == NEDNSProxyErrorDomain
                && error.code == NEDNSProxyManagerError.configurationStale.rawValue {
            throw DNSProxyManagerClientError.configurationStale
        }
    }
}
