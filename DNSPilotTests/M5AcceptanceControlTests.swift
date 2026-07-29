#if DNSPILOT_DEBUG_LOCAL
import Foundation
import Testing
@testable import DNSPilot

struct M5AcceptanceControlTests {
    @MainActor
    @Test func fixtureUsesTwoStableProfiles() throws {
        let profiles = try M5AcceptanceFixture.profiles()

        #expect(profiles.count == 2)
        #expect(profiles.map(\.id) == [
            M5AcceptanceFixture.dohProfileID,
            M5AcceptanceFixture.plainProfileID
        ])
    }

    @Test func capturedRuleSummaryDoesNotExposeNetworkValues() throws {
        let privateSSID = "private-network-name"
        let privateAddress = try IPAddress("192.0.2.42")
        let privateIPv6Address = try IPAddress("2001:db8::42")
        let context = NetworkContext(
            status: .satisfied,
            ssid: privateSSID,
            ssidAvailability: .available,
            activeInterfaceTypes: [.wifi],
            addresses: [
                InterfaceAddress(
                    interfaceName: "en0",
                    address: privateAddress,
                    prefixLength: 24
                ),
                InterfaceAddress(
                    interfaceName: "en0",
                    address: privateIPv6Address,
                    prefixLength: 64
                )
            ]
        )

        let rules = try M5AcceptanceFixture.rules(for: context)
        let summary = M5AcceptanceFixture.ruleSummary(rules)

        #expect(rules.map(\.id) == [
            M5AcceptanceFixture.ssidRuleID,
            M5AcceptanceFixture.secondSSIDRuleID,
            M5AcceptanceFixture.interfaceRuleID,
            M5AcceptanceFixture.subnetRuleID,
            M5AcceptanceFixture.ipv6SubnetRuleID
        ])
        #expect(!summary.contains(privateSSID))
        #expect(!summary.contains(privateAddress.stringValue))
        #expect(!summary.contains(privateIPv6Address.stringValue))
        #expect(summary == "SSID > SSID Second > Interface > IPv4 Subnet > IPv6 Subnet")
    }

    @MainActor
    @Test func fixtureOwnershipRejectsUnrelatedOrPartialConfigurations() throws {
        let profiles = try M5AcceptanceFixture.profiles()
        let unrelated = try DNSProfile(name: "Unrelated", upstream: .fixedCloudflare)

        #expect(M5AcceptanceFixture.owns(try AppConfiguration(profiles: profiles)))
        #expect(!M5AcceptanceFixture.owns(try AppConfiguration(profiles: [profiles[0]])))
        #expect(!M5AcceptanceFixture.owns(try AppConfiguration(profiles: profiles + [unrelated])))
    }

    @Test func clipboardReportContainsEverySanitizedResult() {
        let report = M5AcceptanceReport.text(
            snapshot: M5AcceptanceSnapshot(
                profileCount: 2,
                ruleSummary: "SSID > Interface",
                defaultProfile: "M5 DoH",
                operatingMode: "Automatic",
                ssidAvailability: "available",
                interfaceSummary: "wifi",
                hasIPv4: true,
                hasIPv6: false,
                lastAction: "Current rules captured: applied"
            ),
            buildVersion: "7",
            extensionState: "Active",
            proxyState: "Active"
        )

        #expect(report == """
        DNSPilot M5 Acceptance
        Build: 7
        System Extension: Active
        Proxy: Active
        Profiles: 2
        Rules: SSID > Interface
        Default: M5 DoH
        Mode: Automatic
        SSID: available
        Interfaces: wifi
        Addresses: IPv4 yes | IPv6 no
        Result: Current rules captured: applied
        """)
    }

    @Test func unknownRuleNamesAreNotExposed() throws {
        let privateRuleName = "private-rule-name"
        let rule = try DNSRule(
            name: privateRuleName,
            conditions: RuleConditions(interfaceTypes: [.wifi]),
            profileID: M5AcceptanceFixture.dohProfileID
        )

        let summary = M5AcceptanceFixture.ruleSummary([rule])

        #expect(summary == "Non-fixture (1)")
        #expect(!summary.contains(privateRuleName))
    }
}
#endif
