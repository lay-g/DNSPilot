import AGDnsProxy
import Foundation
import Testing
@testable import DNSPilot

struct AGDnsConfigurationAdapterTests {
    @Test func mapsPlainIPv4WithPort() throws {
        let upstream = DNSUpstream.plain(try PlainDNSConfiguration(
            serverAddress: IPAddress("192.0.2.1"),
            port: 5353
        ))

        let result = try AGDnsConfigurationAdapter.makeUpstream(from: upstream)

        #expect(result.id == 1)
        #expect(result.address == "192.0.2.1:5353")
        #expect(result.bootstrap.isEmpty)
    }

    @Test func mapsPlainIPv6WithBracketsAndPort() throws {
        let upstream = DNSUpstream.plain(try PlainDNSConfiguration(
            serverAddress: IPAddress("2001:0DB8:0:0:0:0:0:1"),
            port: 53
        ))

        let result = try AGDnsConfigurationAdapter.makeUpstream(from: upstream)

        #expect(result.id == 1)
        #expect(result.address == "[2001:db8::1]:53")
        #expect(result.bootstrap.isEmpty)
    }

    @Test func mapsDoHURLAndAddsBootstrapPortAtAdapterBoundary() throws {
        let endpoint = try #require(URL(string: "https://dns.example.test/dns-query?token=test"))
        let upstream = DNSUpstream.https(try DoHConfiguration(
            endpointURL: endpoint,
            bootstrapServers: [IPAddress("192.0.2.1"), IPAddress("2001:db8::1")]
        ))

        let result = try AGDnsConfigurationAdapter.makeUpstream(from: upstream)

        #expect(result.id == 1)
        #expect(result.address == "https://dns.example.test/dns-query?token=test")
        #expect(result.bootstrap == ["192.0.2.1:53", "[2001:db8::1]:53"])
    }

    @Test func mapsDoTHostsPortsAndBootstrapAtAdapterBoundary() throws {
        let hostname = DNSUpstream.tls(try DoTConfiguration(
            serverName: "dns.example.test",
            bootstrapServers: [IPAddress("192.0.2.1"), IPAddress("2001:db8::1")]
        ))
        let ipv6 = DNSUpstream.tls(try DoTConfiguration(
            serverName: "2001:db8::53",
            port: 8853,
            bootstrapServers: []
        ))

        let hostnameResult = try AGDnsConfigurationAdapter.makeUpstream(from: hostname)
        let ipv6Result = try AGDnsConfigurationAdapter.makeUpstream(from: ipv6)

        #expect(hostnameResult.address == "tls://dns.example.test")
        #expect(hostnameResult.bootstrap == ["192.0.2.1:53", "[2001:db8::1]:53"])
        #expect(ipv6Result.address == "tls://[2001:db8::53]:8853")
        #expect(ipv6Result.bootstrap.isEmpty)
    }

    @Test func mapsProfileHostsToOneInMemoryFilter() throws {
        let configuration = try ActiveProxyConfiguration(
            generation: UUID(),
            profileID: UUID(),
            upstream: .fixedCloudflare,
            hosts: [
                try DNSHostEntry(domain: "WWW.Example.Test.", address: IPAddress("2001:db8::10")),
                try DNSHostEntry(domain: "www.example.test", address: IPAddress("127.0.0.1")),
            ]
        )

        let result = try AGDnsConfigurationAdapter.makeProxyConfig(from: configuration)

        #expect(result.filters.count == 1)
        #expect(result.filters[0].id == 1)
        #expect(result.filters[0].inMemory)
        #expect(result.filters[0].data == "|www.example.test|$dnstype=A,dnsrewrite=NOERROR;A;127.0.0.1\n|www.example.test|$dnstype=AAAA,dnsrewrite=NOERROR;AAAA;2001:db8::10\n")
    }

    @Test func hostRuleGeneratorRejectsDuplicateAndOversizedInput() throws {
        let duplicate = try DNSHostEntry(domain: "example.test", address: IPAddress("192.0.2.10"))
        #expect(throws: ActiveProxyConfigurationError.duplicateHost(
            domain: "example.test",
            family: .ipv4
        )) {
            try AGDnsConfigurationAdapter.makeHostRules(from: [duplicate, duplicate])
        }

        let oversized = try (0..<DNSHostEntry.maximumCount + 1).map { index in
            try DNSHostEntry(
                domain: "host\(index).example.test",
                address: IPAddress("192.0.2.10")
            )
        }
        #expect(throws: ActiveProxyConfigurationError.tooManyHosts(257)) {
            try AGDnsConfigurationAdapter.makeHostRules(from: oversized)
        }
    }

    @Test func hostRuleGeneratorRejects256EntriesBeyondRuleByteLimit() throws {
        let hosts = try (0..<DNSHostEntry.maximumCount).map { index in
            let uniqueLabel = String(format: "%03d", index) + String(repeating: "z", count: 53)
            let domain = [String(repeating: "a", count: 63), uniqueLabel].joined(separator: ".")
            return try DNSHostEntry(domain: domain, address: IPAddress("192.0.2.10"))
        }
        _ = try PersistedProxyConfiguration(value: ActiveProxyConfiguration(
            generation: UUID(),
            profileID: UUID(),
            upstream: .fixedCloudflare,
            hosts: hosts
        ))

        do {
            _ = try AGDnsConfigurationAdapter.makeHostRules(from: hosts)
            Issue.record("Expected the host rule byte limit to reject 256 long entries")
        } catch let AGDnsConfigurationAdapterError.hostRulesTooLarge(bytes) {
            #expect(bytes > DNSProxyXPCContract.maximumConfigurationSize / 2)
        }
    }

    @Test func fixedDoHMappingDisablesFallbackAndExperimentalFeatures() throws {
        let configuration = try ActiveProxyConfiguration(
            generation: UUID(),
            profileID: UUID(),
            upstream: .fixedCloudflare
        )

        let result = try AGDnsConfigurationAdapter.makeProxyConfig(from: configuration)

        #expect(result.upstreams.count == 1)
        #expect(result.upstreams[0].address == "https://cloudflare-dns.com/dns-query")
        #expect(result.upstreams[0].bootstrap == ["1.1.1.1:53", "1.0.0.1:53"])
        #expect(result.fallbacks.isEmpty)
        #expect(result.fallbackDomains.isEmpty)
        #expect(result.filters.isEmpty)
        #expect(result.listeners.isEmpty)
        #expect(result.upstreamTimeoutMs == 5_000)
        #expect(result.dnsCacheSize == 1_000)
        #expect(result.optimisticCache == false)
        #expect(result.enableParallelUpstreamQueries == false)
        #expect(result.enableFallbackOnUpstreamsFailure == false)
        #expect(result.enableHttp3 == false)
    }

    @Test func mapsCustomAndDisabledCacheCapacityExactly() throws {
        let custom = try ActiveProxyConfiguration(
            generation: UUID(),
            profileID: UUID(),
            upstream: .fixedCloudflare,
            dnsCacheConfiguration: DNSCacheConfiguration(
                isEnabled: true,
                maximumEntries: 4_321
            )
        )
        let disabled = try ActiveProxyConfiguration(
            generation: UUID(),
            profileID: UUID(),
            upstream: .fixedCloudflare,
            dnsCacheConfiguration: DNSCacheConfiguration(
                isEnabled: false,
                maximumEntries: 4_321
            )
        )

        #expect(try AGDnsConfigurationAdapter.makeProxyConfig(from: custom).dnsCacheSize == 4_321)
        #expect(try AGDnsConfigurationAdapter.makeProxyConfig(from: disabled).dnsCacheSize == 0)
    }

    @Test func queryProxyUsesOneUpstreamWithoutListenersOrCache() throws {
        let result = try AGDnsConfigurationAdapter.makeQueryProxyConfig(from: .fixedCloudflare)

        #expect(result.upstreams.count == 1)
        #expect(result.upstreams[0].id == 1)
        #expect(result.fallbacks.isEmpty)
        #expect(result.listeners.isEmpty)
        #expect(result.filters.isEmpty)
        #expect(result.dnsCacheSize == 0)
        #expect(result.upstreamTimeoutMs == 5_000)
        #expect(result.enableParallelUpstreamQueries == false)
        #expect(result.enableFallbackOnUpstreamsFailure == false)
    }
}
