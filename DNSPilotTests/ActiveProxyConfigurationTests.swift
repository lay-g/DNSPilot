import Foundation
import Testing
@testable import DNSPilot

struct ActiveProxyConfigurationTests {
    private let generation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let profileID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test func fingerprintHashesExactRawBytes() throws {
        #expect(
            ProxyConfigurationFingerprint(data: Data()).rawValue
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )

        let configuration = try ActiveProxyConfiguration(
            generation: generation,
            profileID: profileID,
            upstream: .fixedCloudflare
        )
        let binaryData = try configuration.propertyListData()
        let propertyList = try PropertyListSerialization.propertyList(
            from: binaryData,
            format: nil
        )
        let xmlData = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        let binary = try PersistedProxyConfiguration(data: binaryData)
        let xml = try PersistedProxyConfiguration(data: xmlData)

        #expect(binary.value == xml.value)
        #expect(binary.data == binaryData)
        #expect(xml.data == xmlData)
        #expect(binary.fingerprint != xml.fingerprint)
    }

    @Test func fingerprintUsesValidatedSingleStringWireValue() throws {
        struct Envelope: Codable, Equatable {
            let fingerprint: ProxyConfigurationFingerprint
        }
        let fingerprint = ProxyConfigurationFingerprint(data: Data("DNSPilot".utf8))
        let envelope = Envelope(fingerprint: fingerprint)
        let data = try PropertyListEncoder().encode(envelope)
        let propertyList = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(propertyList["fingerprint"] as? String == fingerprint.rawValue)
        #expect(try PropertyListDecoder().decode(
            Envelope.self,
            from: data
        ) == envelope)
        #expect(ProxyConfigurationFingerprint(rawValue: fingerprint.rawValue.uppercased()) == nil)
    }

    @Test func schemaTwoPlainRoundTripPreservesConfigurationAndDiscriminator() throws {
        let upstream = DNSUpstream.plain(try PlainDNSConfiguration(
            serverAddress: IPAddress("2001:0DB8:0:0:0:0:0:1"),
            port: 5353
        ))
        let configuration = try ActiveProxyConfiguration(
            generation: generation,
            profileID: profileID,
            upstream: upstream
        )

        let data = try configuration.propertyListData()
        let decoded = try ActiveProxyConfiguration.decodePropertyList(data)
        let payload = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let encodedUpstream = try #require(payload["upstream"] as? [String: Any])

        #expect(decoded == configuration)
        #expect(payload["schemaVersion"] as? Int == 2)
        #expect(encodedUpstream["kind"] as? String == "plain")
        #expect(encodedUpstream["configuration"] != nil)
    }

    @Test func schemaTwoDoHRoundTripPreservesConfiguration() throws {
        let configuration = try ActiveProxyConfiguration(
            generation: generation,
            profileID: profileID,
            upstream: .fixedCloudflare,
            loggingMode: .debug
        )

        let decoded = try ActiveProxyConfiguration.decodePropertyList(configuration.propertyListData())
        let payload = try #require(
            PropertyListSerialization.propertyList(
                from: configuration.propertyListData(),
                format: nil
            ) as? [String: Any]
        )
        let upstream = try #require(payload["upstream"] as? [String: Any])
        let encodedDoH = try #require(upstream["configuration"] as? [String: Any])

        #expect(decoded == configuration)
        #expect(decoded.schemaVersion == 2)
        #expect(encodedDoH["endpointURL"] as? String == "https://cloudflare-dns.com/dns-query")
    }

    @Test func migratesSchemaOneFixedDoHAndRemovesBootstrapPortsFromModel() throws {
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "generation": generation.uuidString,
            "profileID": profileID.uuidString,
            "upstream": [
                "kind": "dnsOverHTTPS",
                "address": "https://cloudflare-dns.com/dns-query",
                "bootstrapServerAddresses": ["1.1.1.1:53", "[2001:4860:4860::8888]:53"],
            ],
            "loggingMode": ProxyLoggingMode.default.rawValue,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)

        let decoded = try ActiveProxyConfiguration.decodePropertyList(data)

        #expect(decoded.schemaVersion == 1)
        guard case let .https(configuration) = decoded.upstream else {
            Issue.record("Expected migrated HTTPS upstream")
            return
        }
        #expect(configuration.endpointURL.absoluteString == "https://cloudflare-dns.com/dns-query")
        #expect(configuration.bootstrapServers.map(\.stringValue) == [
            "1.1.1.1",
            "2001:4860:4860::8888",
        ])
    }

    @Test func migratedSchemaOneReencodesAsSchemaOneForRollbackCompatibility() throws {
        let legacyData = try legacyData()

        let migrated = try ActiveProxyConfiguration.decodePropertyList(legacyData)
        let reencoded = try PropertyListSerialization.propertyList(
            from: migrated.propertyListData(),
            format: nil
        ) as? [String: Any]

        #expect(reencoded?["schemaVersion"] as? Int == 1)
        let upstream = try #require(reencoded?["upstream"] as? [String: Any])
        #expect(upstream["kind"] as? String == "dnsOverHTTPS")
        #expect(upstream["bootstrapServerAddresses"] as? [String] == [
            "1.1.1.1:53",
            "1.0.0.1:53",
        ])
    }

    @Test func freshSchemaOneDoHConfigurationUsesLegacyWireShape() throws {
        let configuration = try ActiveProxyConfiguration(
            generation: generation,
            profileID: profileID,
            upstream: .fixedCloudflare,
            schemaVersion: 1
        )

        let payload = try #require(
            PropertyListSerialization.propertyList(
                from: configuration.propertyListData(),
                format: nil
            ) as? [String: Any]
        )
        let upstream = try #require(payload["upstream"] as? [String: Any])

        #expect(payload["schemaVersion"] as? Int == 1)
        #expect(upstream["kind"] as? String == "dnsOverHTTPS")
        #expect(upstream["address"] as? String == "https://cloudflare-dns.com/dns-query")
    }

    @Test func schemaOneRejectsPlainDNS() throws {
        let upstream = DNSUpstream.plain(try PlainDNSConfiguration(
            serverAddress: IPAddress("192.0.2.1")
        ))

        #expect(throws: ActiveProxyConfigurationError.unsupportedLegacyUpstreamKind("plain")) {
            try ActiveProxyConfiguration(
                generation: generation,
                profileID: profileID,
                upstream: upstream,
                schemaVersion: 1
            )
        }
    }

    @Test func schemaOneRejectsDoHSemanticsUnsupportedByLegacyExtension() throws {
        let uppercaseScheme = try #require(URL(string: "HTTPS://dns.example.test/dns-query"))
        let ipEndpoint = try #require(URL(string: "https://192.0.2.1/dns-query"))

        #expect(throws: ActiveProxyConfigurationError.unsupportedLegacyDoHConfiguration) {
            try ActiveProxyConfiguration(
                generation: generation,
                profileID: profileID,
                upstream: .https(try DoHConfiguration(
                    endpointURL: uppercaseScheme,
                    bootstrapServers: [IPAddress("192.0.2.1")]
                )),
                schemaVersion: 1
            )
        }
        #expect(throws: ActiveProxyConfigurationError.unsupportedLegacyDoHConfiguration) {
            try ActiveProxyConfiguration(
                generation: generation,
                profileID: profileID,
                upstream: .https(try DoHConfiguration(
                    endpointURL: ipEndpoint,
                    bootstrapServers: []
                )),
                schemaVersion: 1
            )
        }
    }

    @Test func rejectsUnknownSchemaBeforeUsingPayload() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["schemaVersion": 99],
            format: .binary,
            options: 0
        )

        #expect(throws: ActiveProxyConfigurationError.unsupportedSchemaVersion(99)) {
            try ActiveProxyConfiguration.decodePropertyList(data)
        }
    }

    @Test(arguments: [
        ("192.0.2.1", "192.0.2.1", false),
        ("2001:0DB8:0:0:0:0:0:1", "2001:db8::1", true),
        ("::FFFF:192.0.2.128", "::ffff:192.0.2.128", true),
    ])
    func canonicalizesIPAddress(literal: String, canonical: String, isIPv6: Bool) throws {
        let address = try IPAddress(literal)

        #expect(address.stringValue == canonical)
        #expect(address.isIPv6 == isIPv6)
        #expect(try JSONDecoder().decode(
            IPAddress.self,
            from: JSONEncoder().encode(address)
        ) == address)
    }

    @Test(arguments: [
        "",
        "example.com",
        "192.0.2.1:53",
        "[2001:db8::1]",
        "[2001:db8::1]:53",
        "fe80::1%en0",
        "192.0.2",
        "999.0.0.1",
    ])
    func rejectsInvalidIPAddressLiteral(literal: String) {
        #expect(throws: IPAddressError.invalidLiteral(literal)) {
            try IPAddress(literal)
        }
    }

    @Test func validatesPlainDNSPortRange() throws {
        let address = try IPAddress("192.0.2.1")

        #expect(try PlainDNSConfiguration(serverAddress: address, port: 1).port == 1)
        #expect(try PlainDNSConfiguration(serverAddress: address, port: 65_535).port == 65_535)
        #expect(throws: ActiveProxyConfigurationError.invalidPlainDNSPort(0)) {
            try PlainDNSConfiguration(serverAddress: address, port: 0)
        }
        #expect(throws: ActiveProxyConfigurationError.invalidPlainDNSPort(65_536)) {
            try PlainDNSConfiguration(serverAddress: address, port: 65_536)
        }
    }

    @Test func hostnameDoHRequiresBootstrapButIPDoHDoesNot() throws {
        let hostnameURL = try #require(URL(string: "https://dns.example.test/dns-query"))
        let ipv4URL = try #require(URL(string: "https://192.0.2.1/dns-query"))
        let ipv6URL = try #require(URL(string: "https://[2001:db8::1]/dns-query"))

        #expect(throws: ActiveProxyConfigurationError.missingBootstrapServers) {
            try DoHConfiguration(endpointURL: hostnameURL, bootstrapServers: [])
        }
        #expect(try DoHConfiguration(endpointURL: ipv4URL, bootstrapServers: []).bootstrapServers.isEmpty)
        #expect(try DoHConfiguration(endpointURL: ipv6URL, bootstrapServers: []).bootstrapServers.isEmpty)
    }

    @Test(arguments: [
        "http://dns.example.test/dns-query",
        "https:///dns-query",
        "https://user@dns.example.test/dns-query",
        "https://user:password@dns.example.test/dns-query",
        "https://dns.example.test/dns-query#fragment",
    ])
    func rejectsInvalidDoHEndpoint(value: String) throws {
        let endpoint = try #require(URL(string: value))

        #expect(throws: ActiveProxyConfigurationError.invalidDoHEndpoint) {
            try DoHConfiguration(
                endpointURL: endpoint,
                bootstrapServers: [IPAddress("192.0.2.1")]
            )
        }
    }

    #if DNSPILOT_DEBUG_LOCAL
    @Test func debugLocalBuildUsesAliDNS() {
        guard case let .https(configuration) = DNSUpstream.fixedForCurrentBuild else {
            Issue.record("Expected fixed HTTPS upstream")
            return
        }
        #expect(configuration.endpointURL.absoluteString == "https://dns.alidns.com/dns-query")
        #expect(configuration.bootstrapServers.map(\.stringValue) == ["223.5.5.5", "223.6.6.6"])
    }
    #endif

    private func legacyData() throws -> Data {
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "generation": generation.uuidString,
            "profileID": profileID.uuidString,
            "upstream": [
                "kind": "dnsOverHTTPS",
                "address": "https://cloudflare-dns.com/dns-query",
                "bootstrapServerAddresses": ["1.1.1.1:53", "1.0.0.1:53"],
            ],
            "loggingMode": ProxyLoggingMode.default.rawValue,
        ]
        return try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
    }
}
