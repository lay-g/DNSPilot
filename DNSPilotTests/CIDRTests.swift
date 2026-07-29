import Foundation
import Testing
@testable import DNSPilot

struct CIDRTests {
    @Test(arguments: [
        ("192.0.2.129/24", "192.0.2.0/24"),
        ("2001:0DB8:12:34::BEEF/64", "2001:db8:12:34::/64"),
        ("203.0.113.9/0", "0.0.0.0/0"),
        ("2001:db8::1/0", "::/0"),
        ("192.0.2.129/32", "192.0.2.129/32"),
        ("2001:db8::1/128", "2001:db8::1/128"),
    ])
    func normalizesCanonicalNetwork(cidr: String, canonical: String) throws {
        let network = try IPNetwork(cidr)

        #expect(network.stringValue == canonical)
        #expect(try JSONDecoder().decode(
            IPNetwork.self,
            from: JSONEncoder().encode(network)
        ) == network)
    }

    @Test func containsIPv4OnlyWithinPrefixAndFamily() throws {
        let network = try IPNetwork("192.0.2.129/24")

        #expect(network.contains(try IPAddress("192.0.2.0")))
        #expect(network.contains(try IPAddress("192.0.2.255")))
        #expect(!network.contains(try IPAddress("192.0.3.0")))
        #expect(!network.contains(try IPAddress("::ffff:192.0.2.1")))
    }

    @Test func containsIPv6OnlyWithinPrefix() throws {
        let network = try IPNetwork("2001:db8:abcd:12::1234/64")

        #expect(network.contains(try IPAddress("2001:db8:abcd:12::")))
        #expect(network.contains(try IPAddress("2001:db8:abcd:12:ffff::1")))
        #expect(!network.contains(try IPAddress("2001:db8:abcd:13::")))
    }

    @Test func zeroAndHostPrefixesHaveBoundarySemantics() throws {
        #expect(try IPNetwork("0.0.0.0/0").contains(IPAddress("255.255.255.255")))
        #expect(try IPNetwork("::/0").contains(IPAddress("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")))

        let ipv4Host = try IPNetwork("192.0.2.7/32")
        #expect(ipv4Host.contains(try IPAddress("192.0.2.7")))
        #expect(!ipv4Host.contains(try IPAddress("192.0.2.6")))

        let ipv6Host = try IPNetwork("2001:db8::7/128")
        #expect(ipv6Host.contains(try IPAddress("2001:db8::7")))
        #expect(!ipv6Host.contains(try IPAddress("2001:db8::6")))
    }

    @Test func structuredInitializerMasksWithoutStringAssembly() throws {
        let ipv4 = try IPNetwork(address: IPAddress("192.0.2.129"), prefixLength: 24)
        let ipv6 = try IPNetwork(address: IPAddress("2001:db8:1::beef"), prefixLength: 64)

        #expect(ipv4.stringValue == "192.0.2.0/24")
        #expect(ipv6.stringValue == "2001:db8:1::/64")
    }

    @Test func ipAddressExposesCanonicalFixedBytesWithoutChangingWireFormat() throws {
        let ipv4 = try IPAddress("192.0.2.1")
        let ipv6 = try IPAddress("2001:db8::1")

        #expect(ipv4.bytes == [192, 0, 2, 1])
        #expect(ipv6.bytes.count == 16)
        #expect(String(decoding: try JSONEncoder().encode(ipv4), as: UTF8.self) == "\"192.0.2.1\"")
    }

    @Test(arguments: [
        "192.0.2.1",
        "192.0.2.1/",
        "/24",
        "192.0.2.1/-1",
        "192.0.2.1/33",
        "2001:db8::1/129",
        "2001:db8::1/64/1",
    ])
    func rejectsInvalidCIDR(cidr: String) {
        #expect(throws: (any Error).self) {
            try IPNetwork(cidr)
        }
    }
}
