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
        #expect(result.optimisticCache == false)
        #expect(result.enableParallelUpstreamQueries == false)
        #expect(result.enableFallbackOnUpstreamsFailure == false)
        #expect(result.enableHttp3 == false)
    }
}
