import Testing
@testable import DNSPilot

struct NetworkContextBuilderTests {
    @Test func mapsPathStatusAndActiveInterfaceTypes() {
        let interfaces = [
            NetworkPathInterfaceInput(name: "en0", type: .wifi, isUsed: true),
            NetworkPathInterfaceInput(name: "en1", type: .wiredEthernet, isUsed: true),
            NetworkPathInterfaceInput(name: "pdp_ip0", type: .cellular, isUsed: true),
            NetworkPathInterfaceInput(name: "lo0", type: .loopback, isUsed: false),
        ]

        let satisfied = build(path: NetworkPathInput(status: .satisfied, interfaces: interfaces))
        let required = build(path: NetworkPathInput(status: .requiresConnection, interfaces: []))
        let unsatisfied = build(path: NetworkPathInput(status: .unsatisfied, interfaces: []))

        #expect(satisfied.status == .satisfied)
        #expect(satisfied.activeInterfaceTypes == [.wifi, .wiredEthernet, .other])
        #expect(required.status == .requiresConnection)
        #expect(unsatisfied.status == .unsatisfied)
    }

    @Test func filtersUnusableUnsupportedInvalidAndMulticastAddresses() {
        let path = NetworkPathInput(
            status: .satisfied,
            interfaces: [NetworkPathInterfaceInput(name: "en0", type: .wifi, isUsed: true)]
        )
        let addresses = [
            address("192.0.2.1", isUp: false),
            address("192.0.2.2", isLoopback: true),
            address("192.0.2.3", interfaceName: "en9"),
            address("not-an-address"),
            address("192.0.2.4", family: .ipv6),
            address("192.0.2.5", family: .unsupported(1)),
            address("224.0.0.1"),
            address("ff02::1", family: .ipv6),
            address("192.0.2.6"),
        ]

        let context = build(path: path, addresses: addresses)

        #expect(context.addresses.map { $0.address.stringValue } == ["192.0.2.6"])
    }

    @Test func retainsIPv4AndIPv6LinkLocalAddresses() {
        let context = build(addresses: [
            address("169.254.10.20"),
            address("fe80::1234", family: .ipv6),
        ])

        #expect(context.addresses.map(\.address.stringValue) == ["169.254.10.20", "fe80::1234"])
    }

    @Test func rejectsAddressesWhenPathHasNoAvailableInterfaces() {
        let context = build(
            path: NetworkPathInput(status: .unsatisfied, interfaces: []),
            addresses: [address("192.0.2.1"), address("fe80::1%en0", family: .ipv6)]
        )

        #expect(context.addresses.isEmpty)
    }

    @Test func unusedInterfacesDoNotContributeAddresses() {
        let context = build(
            path: NetworkPathInput(
                status: .satisfied,
                interfaces: [
                    NetworkPathInterfaceInput(name: "en0", type: .wifi, isUsed: true),
                    NetworkPathInterfaceInput(name: "en1", type: .wiredEthernet, isUsed: false),
                ]
            ),
            addresses: [
                address("192.0.2.1"),
                address("198.51.100.1", interfaceName: "en1"),
            ]
        )

        #expect(context.addresses.map(\.address.stringValue) == ["192.0.2.1"])
    }

    @Test func ambiguousSameTypeInterfacesDoNotContributeAddresses() {
        let context = build(
            path: NetworkPathInput(
                status: .satisfied,
                interfaces: [
                    NetworkPathInterfaceInput(name: "en0", type: .wifi, isUsed: true),
                    NetworkPathInterfaceInput(name: "en1", type: .wifi, isUsed: true),
                ]
            ),
            addresses: [
                address("192.0.2.1"),
                address("198.51.100.1", interfaceName: "en1"),
            ]
        )

        #expect(context.activeInterfaceTypes == [.wifi])
        #expect(context.addresses.isEmpty)
    }

    @Test func duplicatePathEntriesForSameInterfaceRetainAddresses() {
        let context = build(
            path: NetworkPathInput(
                status: .satisfied,
                interfaces: [
                    NetworkPathInterfaceInput(name: "en0", type: .wifi, isUsed: true),
                    NetworkPathInterfaceInput(name: "en0", type: .wifi, isUsed: true)
                ]
            ),
            addresses: [address("192.0.2.1")]
        )

        #expect(context.addresses.map(\.address.stringValue) == ["192.0.2.1"])
    }

    @Test(arguments: [
        ("0.0.0.0", 0),
        ("255.255.255.0", 24),
        ("255.255.255.255", 32),
        ("::", 0),
        ("ffff:ffff:ffff:ffff::", 64),
        ("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", 128),
    ])
    func convertsContiguousNetmasks(mask: String, expectedPrefix: Int) throws {
        #expect(SystemNetworkAddressProvider.prefixLength(for: try IPAddress(mask)) == expectedPrefix)
    }

    @Test func rejectsNoncontiguousNetmasks() throws {
        #expect(SystemNetworkAddressProvider.prefixLength(
            for: try IPAddress("255.0.255.0")
        ) == nil)
        #expect(SystemNetworkAddressProvider.prefixLength(
            for: try IPAddress("ffff:0:ffff::")
        ) == nil)
    }

    @Test func stripsIPv6ZoneOnlyForParsingAndRetainsInterfaceName() {
        #expect(NetworkAddressLiteral.forParsing("fe80::1234%en0", family: .ipv6) == "fe80::1234")
        #expect(NetworkAddressLiteral.forParsing("192.0.2.1%en0", family: .ipv4) == "192.0.2.1%en0")

        let context = build(addresses: [address("fe80::1234%en0", family: .ipv6)])

        #expect(context.addresses.count == 1)
        #expect(context.addresses.first?.interfaceName == "en0")
        #expect(context.addresses.first?.address.stringValue == "fe80::1234")
    }

    @Test func orderingAndDeduplicationAreStable() {
        let inputs = [
            address("2001:db8::2", interfaceName: "en1", family: .ipv6),
            address("192.0.2.10", interfaceName: "en0"),
            address("192.0.2.2", interfaceName: "en0"),
            address("2001:db8::1", interfaceName: "en0", family: .ipv6),
            address("192.0.2.2", interfaceName: "en0"),
        ]

        let forward = build(path: path(names: ["en0", "en1"]), addresses: inputs)
        let reverse = build(path: path(names: ["en1", "en0"]), addresses: inputs.reversed())

        #expect(forward == reverse)
        #expect(forward.addresses.map { "\($0.interfaceName):\($0.address.stringValue)" } == [
            "en0:192.0.2.2",
            "en0:192.0.2.10",
            "en0:2001:db8::1",
            "en1:2001:db8::2",
        ])
    }

    @Test func carriesValidatedInterfacePrefixForSubnetRules() {
        let context = build(addresses: [
            address("192.0.2.42", prefixLength: 24),
            address("2001:db8::42", family: .ipv6, prefixLength: 64),
            address("198.51.100.1", prefixLength: 99),
        ])

        #expect(context.addresses.map(\.prefixLength) == [24, nil, 64])
    }

    @Test(arguments: [
        (SSIDInput(authorization: .authorized, ssid: "Office"), "Office", SSIDAvailability.available),
        (SSIDInput(authorization: .authorized, ssid: nil), nil, SSIDAvailability.temporarilyUnavailable),
        (SSIDInput(authorization: .notDetermined, ssid: "hidden"), nil, SSIDAvailability.permissionNotDetermined),
        (SSIDInput(authorization: .denied, ssid: "hidden"), nil, SSIDAvailability.permissionDenied),
    ])
    func mapsSSIDStates(input: SSIDInput, expectedSSID: String?, expectedAvailability: SSIDAvailability) {
        let context = build(ssid: input)

        #expect(context.ssid == expectedSSID)
        #expect(context.ssidAvailability == expectedAvailability)
    }

    @Test func reportsNotOnWiFiBeforeLocationState() {
        let context = build(
            path: NetworkPathInput(
                status: .satisfied,
                interfaces: [NetworkPathInterfaceInput(name: "en1", type: .wiredEthernet, isUsed: true)]
            ),
            ssid: SSIDInput(authorization: .denied, ssid: "stale")
        )

        #expect(context.ssid == nil)
        #expect(context.ssidAvailability == .notOnWiFi)
    }

    private func build(
        path: NetworkPathInput = NetworkPathInput(
            status: .satisfied,
            interfaces: [NetworkPathInterfaceInput(name: "en0", type: .wifi, isUsed: true)]
        ),
        addresses: [NetworkAddressInput] = [],
        ssid: SSIDInput = SSIDInput(authorization: .authorized, ssid: "Test")
    ) -> NetworkContext {
        NetworkContextBuilder.build(path: path, addresses: addresses, ssid: ssid)
    }

    private func path(names: [String]) -> NetworkPathInput {
        NetworkPathInput(
            status: .satisfied,
            interfaces: names.map {
                NetworkPathInterfaceInput(
                    name: $0,
                    type: $0 == "en0" ? .wifi : .wiredEthernet,
                    isUsed: true
                )
            }
        )
    }

    private func address(
        _ literal: String,
        interfaceName: String = "en0",
        family: NetworkAddressFamilyInput = .ipv4,
        prefixLength: Int? = nil,
        isUp: Bool = true,
        isLoopback: Bool = false
    ) -> NetworkAddressInput {
        NetworkAddressInput(
            interfaceName: interfaceName,
            family: family,
            literal: literal,
            prefixLength: prefixLength,
            isUp: isUp,
            isLoopback: isLoopback
        )
    }
}
