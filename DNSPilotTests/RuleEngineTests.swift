import Foundation
import Testing
@testable import DNSPilot

struct RuleEngineTests {
    private let defaultProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let firstProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let secondProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    @Test func returnsFirstEnabledMatchInRuleOrder() throws {
        let disabledID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let firstID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let secondID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let conditions = RuleConditions(interfaceTypes: [.wifi])
        let rules = [
            try DNSRule(
                id: disabledID,
                name: "Disabled",
                isEnabled: false,
                conditions: conditions,
                profileID: defaultProfileID
            ),
            try DNSRule(id: firstID, name: "First", conditions: conditions, profileID: firstProfileID),
            try DNSRule(id: secondID, name: "Second", conditions: conditions, profileID: secondProfileID),
        ]

        let result = RuleEngine.resolveProfile(
            context: context(interfaceTypes: [.wifi]),
            rules: rules,
            defaultProfileID: defaultProfileID
        )

        #expect(result == RuleMatchResult(profileID: firstProfileID, source: .rule(firstID)))
    }

    @Test func fieldsUseANDWhileValuesWithinEachFieldUseOR() throws {
        let ruleID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let rule = try DNSRule(
            id: ruleID,
            name: "Office",
            conditions: RuleConditions(
                ssids: ["Office", "Lab"],
                interfaceTypes: [.wifi, .wiredEthernet],
                subnets: [try IPNetwork("192.0.2.0/24"), try IPNetwork("2001:db8::/32")]
            ),
            profileID: firstProfileID
        )
        let matching = context(
            ssid: "Lab",
            interfaceTypes: [.wifi],
            addresses: [try IPAddress("2001:db8:1::7")]
        )
        let wrongInterface = context(
            ssid: "Lab",
            interfaceTypes: [.other],
            addresses: [try IPAddress("2001:db8:1::7")]
        )

        #expect(RuleEngine.resolveProfile(
            context: matching,
            rules: [rule],
            defaultProfileID: defaultProfileID
        ).source == .rule(ruleID))
        #expect(RuleEngine.resolveProfile(
            context: wrongInterface,
            rules: [rule],
            defaultProfileID: defaultProfileID
        ).source == .default)
    }

    @Test func subnetMatchesAnyActiveAddressAcrossIPv4AndIPv6() throws {
        let ruleID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let rule = try DNSRule(
            id: ruleID,
            name: "Subnet",
            conditions: RuleConditions(subnets: [try IPNetwork("10.0.0.0/8")]),
            profileID: firstProfileID
        )
        let network = context(addresses: [
            try IPAddress("2001:db8::1"),
            try IPAddress("10.20.30.40"),
        ])

        #expect(RuleEngine.resolveProfile(
            context: network,
            rules: [rule],
            defaultProfileID: defaultProfileID
        ).source == .rule(ruleID))
    }

    @Test func ssidIsCaseSensitiveAndUnavailableSSIDRulesDoNotMatch() throws {
        let rule = try DNSRule(
            name: "SSID",
            conditions: RuleConditions(ssids: ["OfficeWiFi"]),
            profileID: firstProfileID
        )

        #expect(RuleEngine.resolveProfile(
            context: context(ssid: "officewifi"),
            rules: [rule],
            defaultProfileID: defaultProfileID
        ).source == .default)
        #expect(RuleEngine.resolveProfile(
            context: context(ssid: "OfficeWiFi", ssidAvailability: .permissionDenied),
            rules: [rule],
            defaultProfileID: defaultProfileID
        ).source == .default)
        #expect(RuleEngine.resolveProfile(
            context: context(ssid: "OfficeWiFi"),
            rules: [rule],
            defaultProfileID: defaultProfileID
        ).source == .rule(rule.id))
    }

    @Test func fallsBackToDefaultProfile() {
        let result = RuleEngine.resolveProfile(
            context: context(interfaceTypes: [.wiredEthernet]),
            rules: [],
            defaultProfileID: defaultProfileID
        )

        #expect(result == RuleMatchResult(profileID: defaultProfileID, source: .default))
    }

    private func context(
        ssid: String? = nil,
        ssidAvailability: SSIDAvailability = .available,
        interfaceTypes: Set<NetworkInterfaceType> = [],
        addresses: [IPAddress] = []
    ) -> NetworkContext {
        NetworkContext(
            status: .satisfied,
            ssid: ssid,
            ssidAvailability: ssidAvailability,
            activeInterfaceTypes: interfaceTypes,
            addresses: addresses.enumerated().map {
                InterfaceAddress(interfaceName: "en\($0.offset)", address: $0.element)
            }
        )
    }
}
