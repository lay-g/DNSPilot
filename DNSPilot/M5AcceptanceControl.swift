#if DNSPILOT_DEBUG_LOCAL
import AppKit
import Foundation

struct M5AcceptanceSnapshot: Equatable {
    var profileCount = 0
    var ruleSummary = "None"
    var defaultProfile = "None"
    var operatingMode = "Automatic"
    var ssidAvailability = "Awaiting context"
    var interfaceSummary = "None"
    var hasIPv4 = false
    var hasIPv6 = false
    var lastAction = "Ready"

    var addressSummary: String {
        "IPv4 \(hasIPv4 ? "yes" : "no") | IPv6 \(hasIPv6 ? "yes" : "no")"
    }
}

enum M5AcceptanceReport {
    static func text(
        snapshot: M5AcceptanceSnapshot,
        buildVersion: String,
        extensionState: String,
        proxyState: String
    ) -> String {
        [
            "DNSPilot M5 Acceptance",
            "Build: \(buildVersion)",
            "System Extension: \(extensionState)",
            "Proxy: \(proxyState)",
            "Profiles: \(snapshot.profileCount)",
            "Rules: \(snapshot.ruleSummary)",
            "Default: \(snapshot.defaultProfile)",
            "Mode: \(snapshot.operatingMode)",
            "SSID: \(snapshot.ssidAvailability)",
            "Interfaces: \(snapshot.interfaceSummary)",
            "Addresses: \(snapshot.addressSummary)",
            "Result: \(snapshot.lastAction)"
        ].joined(separator: "\n")
    }

    @MainActor
    static func copy(
        appModel: DNSPilotAppModel,
        systemExtension: SystemExtensionController
    ) {
        let report = text(
            snapshot: appModel.m5Acceptance,
            buildVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "Unknown",
            extensionState: systemExtension.state.description,
            proxyState: appModel.proxyState.description
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}

enum M5AcceptanceRoutingState {
    case applied
    case persisted
    case failed
}

enum M5AcceptanceFixture {
    static let dohProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let plainProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let ssidRuleID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let secondSSIDRuleID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
    static let interfaceRuleID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    static let subnetRuleID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
    static let ipv6SubnetRuleID = UUID(uuidString: "10000000-0000-0000-0000-000000000005")!
    static let profileIDs: Set<DNSProfile.ID> = [dohProfileID, plainProfileID]

    @MainActor static func profiles() throws -> [DNSProfile] {
        [
            try DNSProfile(
                id: dohProfileID,
                name: "M5 DoH",
                upstream: DNSPilotAppModel.diagnosticDoHTarget.upstream
            ),
            try DNSProfile(
                id: plainProfileID,
                name: "M5 Plain",
                upstream: DNSPilotAppModel.diagnosticPlainTarget.upstream
            )
        ]
    }

    static func rules(for context: NetworkContext) throws -> [DNSRule] {
        var rules: [DNSRule] = []
        if let ssid = context.ssid, context.ssidAvailability == .available {
            rules.append(try DNSRule(
                id: ssidRuleID,
                name: "SSID",
                conditions: RuleConditions(ssids: [ssid]),
                profileID: plainProfileID
            ))
            rules.append(try DNSRule(
                id: secondSSIDRuleID,
                name: "SSID Second",
                conditions: RuleConditions(ssids: [ssid]),
                profileID: dohProfileID
            ))
        }
        if !context.activeInterfaceTypes.isEmpty {
            rules.append(try DNSRule(
                id: interfaceRuleID,
                name: "Interface",
                conditions: RuleConditions(interfaceTypes: context.activeInterfaceTypes),
                profileID: dohProfileID
            ))
        }
        if let ipv4 = context.addresses.first(where: {
            $0.address.family == .ipv4 && $0.prefixLength != nil
        }), let prefixLength = ipv4.prefixLength {
            rules.append(try DNSRule(
                id: subnetRuleID,
                name: "IPv4 Subnet",
                conditions: RuleConditions(subnets: [
                    try IPNetwork(address: ipv4.address, prefixLength: prefixLength)
                ]),
                profileID: plainProfileID
            ))
        }
        if let ipv6 = context.addresses.first(where: {
            $0.address.family == .ipv6 && $0.prefixLength != nil
        }), let prefixLength = ipv6.prefixLength {
            rules.append(try DNSRule(
                id: ipv6SubnetRuleID,
                name: "IPv6 Subnet",
                conditions: RuleConditions(subnets: [
                    try IPNetwork(address: ipv6.address, prefixLength: prefixLength)
                ]),
                profileID: dohProfileID
            ))
        }
        return rules
    }

    static func profileName(_ id: DNSProfile.ID?) -> String {
        switch id {
        case dohProfileID: "M5 DoH"
        case plainProfileID: "M5 Plain"
        default: "None"
        }
    }

    static func owns(_ configuration: AppConfiguration) -> Bool {
        Set(configuration.profiles.map(\.id)) == profileIDs
    }

    static func ruleSummary(_ rules: [DNSRule]) -> String {
        guard !rules.isEmpty else { return "None" }
        var summaries: [String] = []
        for rule in rules {
            guard let name = ruleName(rule.id) else {
                return "Non-fixture (\(rules.count))"
            }
            summaries.append("\(name)\(rule.isEnabled ? "" : " (off)")")
        }
        return summaries.joined(separator: " > ")
    }

    private static func ruleName(_ id: DNSRule.ID) -> String? {
        switch id {
        case ssidRuleID: "SSID"
        case secondSSIDRuleID: "SSID Second"
        case interfaceRuleID: "Interface"
        case subnetRuleID: "IPv4 Subnet"
        case ipv6SubnetRuleID: "IPv6 Subnet"
        default: nil
        }
    }
}
#endif
