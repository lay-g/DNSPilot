import Foundation

enum AppNavigationSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case overview
    case profiles
    case rules

    var id: Self { self }
}

enum ProfileTransport: String, CaseIterable, Codable, Identifiable, Sendable {
    case plain
    case https

    var id: Self { self }
}

enum ProfileDraftError: LocalizedError, Equatable, Sendable {
    case emptyName
    case invalidServerAddress(String)
    case invalidPort(Int)
    case invalidEndpoint(String)
    case invalidBootstrapServer(String)
    case missingBootstrapServers

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a Profile name."
        case let .invalidServerAddress(value):
            "Enter a valid IP address for the DNS server: \(value)."
        case let .invalidPort(value):
            "The DNS port must be between 1 and 65535, got \(value)."
        case let .invalidEndpoint(value):
            "Enter a valid HTTPS endpoint: \(value)."
        case let .invalidBootstrapServer(value):
            "Enter a valid bootstrap IP address: \(value)."
        case .missingBootstrapServers:
            "A hostname endpoint requires at least one bootstrap server."
        }
    }
}

struct ProfileDraft: Identifiable, Equatable, Sendable {
    var id: DNSProfile.ID
    var name: String
    var transport: ProfileTransport
    var plainServerAddress: String
    var plainPort: Int
    var endpointURL: String
    var bootstrapServers: [String]

    init(
        id: DNSProfile.ID = UUID(),
        name: String = "",
        transport: ProfileTransport = .https,
        plainServerAddress: String = "",
        plainPort: Int = 53,
        endpointURL: String = "",
        bootstrapServers: [String] = []
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.plainServerAddress = plainServerAddress
        self.plainPort = plainPort
        self.endpointURL = endpointURL
        self.bootstrapServers = bootstrapServers
    }

    init(profile: DNSProfile) {
        id = profile.id
        name = profile.name
        switch profile.upstream {
        case let .plain(configuration):
            transport = .plain
            plainServerAddress = configuration.serverAddress.stringValue
            plainPort = Int(configuration.port)
            endpointURL = ""
            bootstrapServers = []
        case let .https(configuration):
            transport = .https
            plainServerAddress = ""
            plainPort = 53
            endpointURL = configuration.endpointURL.absoluteString
            bootstrapServers = configuration.bootstrapServers.map(\.stringValue)
        }
    }

    func profile() throws -> DNSProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ProfileDraftError.emptyName }

        let upstream: DNSUpstream
        switch transport {
        case .plain:
            let addressValue = plainServerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let address = try? IPAddress(addressValue) else {
                throw ProfileDraftError.invalidServerAddress(plainServerAddress)
            }
            guard (1...65_535).contains(plainPort) else {
                throw ProfileDraftError.invalidPort(plainPort)
            }
            upstream = .plain(try PlainDNSConfiguration(
                serverAddress: address,
                port: plainPort
            ))
        case .https:
            let endpointValue = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let endpoint = URL(string: endpointValue) else {
                throw ProfileDraftError.invalidEndpoint(endpointURL)
            }
            let bootstrap = try bootstrapServers.map { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let address = try? IPAddress(trimmed) else {
                    throw ProfileDraftError.invalidBootstrapServer(value)
                }
                return address
            }
            do {
                upstream = .https(try DoHConfiguration(
                    endpointURL: endpoint,
                    bootstrapServers: bootstrap
                ))
            } catch ActiveProxyConfigurationError.missingBootstrapServers {
                throw ProfileDraftError.missingBootstrapServers
            } catch {
                throw ProfileDraftError.invalidEndpoint(endpointURL)
            }
        }
        return try DNSProfile(id: id, name: trimmedName, upstream: upstream)
    }
}

enum RuleDraftError: LocalizedError, Equatable, Sendable {
    case emptyName
    case missingConditions
    case missingProfile
    case invalidSubnet(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a Rule name."
        case .missingConditions:
            "Add at least one Rule condition."
        case .missingProfile:
            "Choose a Profile for this Rule."
        case let .invalidSubnet(value):
            "Enter a valid IP subnet: \(value)."
        }
    }
}

struct RuleDraft: Identifiable, Equatable, Sendable {
    var id: DNSRule.ID
    var name: String
    var isEnabled: Bool
    var ssids: [String]
    var interfaceTypes: Set<NetworkInterfaceType>
    var subnets: [String]
    var profileID: DNSProfile.ID?

    init(
        id: DNSRule.ID = UUID(),
        name: String = "",
        isEnabled: Bool = true,
        ssids: [String] = [],
        interfaceTypes: Set<NetworkInterfaceType> = [],
        subnets: [String] = [],
        profileID: DNSProfile.ID? = nil
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.ssids = ssids
        self.interfaceTypes = interfaceTypes
        self.subnets = subnets
        self.profileID = profileID
    }

    init(rule: DNSRule) {
        id = rule.id
        name = rule.name
        isEnabled = rule.isEnabled
        ssids = rule.conditions.ssids
        interfaceTypes = rule.conditions.interfaceTypes
        subnets = rule.conditions.subnets.map(\.stringValue)
        profileID = rule.profileID
    }

    func rule() throws -> DNSRule {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw RuleDraftError.emptyName }
        guard let profileID else { throw RuleDraftError.missingProfile }

        let normalizedSSIDs = ssids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedSubnets = try subnets.compactMap { value -> IPNetwork? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let subnet = try? IPNetwork(trimmed) else {
                throw RuleDraftError.invalidSubnet(value)
            }
            return subnet
        }
        let conditions = RuleConditions(
            ssids: normalizedSSIDs,
            interfaceTypes: interfaceTypes,
            subnets: normalizedSubnets
        )
        guard !conditions.isEmpty else { throw RuleDraftError.missingConditions }
        return try DNSRule(
            id: id,
            name: trimmedName,
            isEnabled: isEnabled,
            conditions: conditions,
            profileID: profileID
        )
    }
}

enum OnboardingStep: String, CaseIterable, Codable, Sendable {
    case introduction
    case profile
    case customProfile
    case location
    case systemExtension
    case dnsProxy
    case complete
}

struct OnboardingProgress: Codable, Equatable, Sendable {
    var setupProfileID: DNSProfile.ID
    var introductionCompleted: Bool
    var locationStepCompleted: Bool

    init(
        setupProfileID: DNSProfile.ID = UUID(),
        introductionCompleted: Bool = false,
        locationStepCompleted: Bool = false
    ) {
        self.setupProfileID = setupProfileID
        self.introductionCompleted = introductionCompleted
        self.locationStepCompleted = locationStepCompleted
    }

    func currentStep(
        isSetupProfileConfigured: Bool,
        isSystemExtensionInstalled: Bool,
        isDNSProxyActive: Bool
    ) -> OnboardingStep {
        if !introductionCompleted { return .introduction }
        if !isSetupProfileConfigured { return .profile }
        if !locationStepCompleted { return .location }
        if !isSystemExtensionInstalled { return .systemExtension }
        if !isDNSProxyActive { return .dnsProxy }
        return .complete
    }
}

enum MenuBarProxyCommand: Equatable, Sendable {
    case turnOn
    case restoreSystemDNS
    case unavailable
}

struct MenuBarPresentation: Equatable, Sendable {
    let statusText: String
    let profileLines: [String]
    let networkText: String
    let symbolName: String
    let proxyCommand: MenuBarProxyCommand

    static func make(
        configuration: AppConfiguration,
        proxy: ProxyControllerSnapshot,
        network: NetworkContext?
    ) -> Self {
        let names = profileNames(configuration.profiles)
        let activeName = proxy.activeProfileID.flatMap { names[$0] } ?? "System DNS"
        let targetName = proxy.targetProfileID.flatMap { names[$0] }
        let mode = switch configuration.operatingMode {
        case .automatic: "Automatic"
        case .manual: "Manual"
        }

        switch proxy.state {
        case .disabled:
            return Self(
                statusText: "DNS Proxy Off",
                profileLines: ["System DNS · \(mode)"],
                networkText: networkSummary(network),
                symbolName: "network.slash",
                proxyCommand: .turnOn
            )
        case .preparing:
            return switching(
                status: "Preparing \(targetName ?? "Profile")",
                target: targetName,
                active: activeName,
                network: network,
                symbol: "arrow.triangle.2.circlepath"
            )
        case .applying:
            return switching(
                status: "Applying \(targetName ?? "Profile")",
                target: targetName,
                active: activeName,
                network: network,
                symbol: "arrow.triangle.2.circlepath"
            )
        case .repairing:
            return switching(
                status: "Repairing DNS Proxy",
                target: targetName,
                active: activeName,
                network: network,
                symbol: "wrench.and.screwdriver"
            )
        case .active:
            return Self(
                statusText: "DNS Proxy On",
                profileLines: ["\(activeName) · \(mode)"],
                networkText: networkSummary(network),
                symbolName: "network",
                proxyCommand: .restoreSystemDNS
            )
        case .stopping:
            return switching(
                status: "Restoring System DNS",
                target: nil,
                active: activeName,
                network: network,
                symbol: "arrow.triangle.2.circlepath"
            )
        case .recoveryRequired:
            return error(
                status: "DNS Proxy Recovery Required",
                target: targetName,
                active: activeName,
                network: network,
                proxyCommand: .restoreSystemDNS
            )
        case .failed:
            return error(
                status: "DNS Proxy Error",
                target: targetName,
                active: activeName,
                network: network,
                proxyCommand: .restoreSystemDNS
            )
        case .degraded:
            return error(
                status: "DNS Proxy Error",
                target: targetName,
                active: activeName,
                network: network,
                proxyCommand: .unavailable
            )
        }
    }

    private static func switching(
        status: String,
        target: String?,
        active: String,
        network: NetworkContext?,
        symbol: String
    ) -> Self {
        var lines: [String] = []
        if let target { lines.append("Target: \(target)") }
        lines.append("Active: \(active)")
        return Self(
            statusText: status,
            profileLines: lines,
            networkText: networkSummary(network),
            symbolName: symbol,
            proxyCommand: .unavailable
        )
    }

    private static func error(
        status: String,
        target: String?,
        active: String,
        network: NetworkContext?,
        proxyCommand: MenuBarProxyCommand
    ) -> Self {
        var presentation = switching(
            status: status,
            target: target,
            active: active,
            network: network,
            symbol: "network.badge.shield.half.filled"
        )
        presentation = Self(
            statusText: presentation.statusText,
            profileLines: presentation.profileLines,
            networkText: presentation.networkText,
            symbolName: presentation.symbolName,
            proxyCommand: proxyCommand
        )
        return presentation
    }

    private static func profileNames(_ profiles: [DNSProfile]) -> [DNSProfile.ID: String] {
        ProfileDisplayIdentity.displayNames(for: profiles)
    }

    private static func networkSummary(_ network: NetworkContext?) -> String {
        guard let network else { return "Network: Checking" }
        if let ssid = network.ssid { return "Network: \(ssid) - Wi-Fi" }
        let interfaces = network.activeInterfaceTypes
            .map { type in
                switch type {
                case .wifi: "Wi-Fi"
                case .wiredEthernet: "Ethernet"
                case .other: "Other"
                }
            }
            .sorted()
        if !interfaces.isEmpty { return "Network: \(interfaces.joined(separator: ", "))" }
        return switch network.status {
        case .satisfied: "Network: Available"
        case .requiresConnection: "Network: Connection Required"
        case .unsatisfied: "Network: Unavailable"
        }
    }
}
