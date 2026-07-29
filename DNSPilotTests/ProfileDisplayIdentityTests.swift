import Foundation
import Testing
@testable import DNSPilot

struct ProfileDisplayIdentityTests {
    @Test func trimsProfileNamesAndRejectsEmptyNames() throws {
        let profile = try DNSProfile(
            name: "  Office DNS\n",
            upstream: .plain(try PlainDNSConfiguration(serverAddress: IPAddress("192.0.2.1")))
        )

        #expect(profile.name == "Office DNS")
        #expect(throws: DNSProfileError.emptyName) {
            try DNSProfile(name: " \n\t ", upstream: .fixedCloudflare)
        }
    }

    @Test func dohIdentityNeverRevealsPathQueryTokenOrBootstrap() throws {
        let profile = try DNSProfile(
            name: "Private",
            upstream: .https(try DoHConfiguration(
                endpointURL: #require(URL(string: "https://dns.example.test:8443/private/path?token=secret")),
                bootstrapServers: [IPAddress("192.0.2.99")]
            ))
        )

        let identity = try #require(ProfileDisplayIdentity.identities(for: [profile])[profile.id])

        #expect(identity.summary == "DNS over HTTPS · dns.example.test:8443")
        #expect(!identity.displaySummary.contains("private"))
        #expect(!identity.displaySummary.contains("token"))
        #expect(!identity.displaySummary.contains("secret"))
        #expect(!identity.displaySummary.contains("192.0.2.99"))
        #expect(identity.disambiguationSuffix == nil)
    }

    @Test func suffixAppearsOnlyForDuplicateNameAndSummaryCollisions() throws {
        let firstID = UUID(uuidString: "7F2A0000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "7F2AB000-0000-0000-0000-000000000002")!
        let distinctID = UUID(uuidString: "9C4D0000-0000-0000-0000-000000000003")!
        let first = try dohProfile(
            id: firstID,
            endpoint: "https://dns.example.test/one?token=first"
        )
        let second = try dohProfile(
            id: secondID,
            endpoint: "https://dns.example.test/two?token=second"
        )
        let distinct = try dohProfile(id: distinctID, endpoint: "https://other.example.test/dns-query")

        let identities = ProfileDisplayIdentity.identities(for: [first, second, distinct])

        #expect(identities[firstID]?.disambiguationSuffix == "7F2A0")
        #expect(identities[secondID]?.disambiguationSuffix == "7F2AB")
        #expect(identities[distinctID]?.disambiguationSuffix == nil)
        #expect(identities[firstID]?.summary == identities[secondID]?.summary)
    }

    @Test func plainIdentityUsesOnlyAddressAndPort() throws {
        let profile = try DNSProfile(
            name: "Local",
            upstream: .plain(try PlainDNSConfiguration(
                serverAddress: IPAddress("2001:db8::53"),
                port: 5353
            ))
        )

        let identity = try #require(ProfileDisplayIdentity.identities(for: [profile])[profile.id])
        #expect(identity.summary == "Plain DNS · [2001:db8::53]:5353")
    }

    private func dohProfile(id: UUID, endpoint: String) throws -> DNSProfile {
        try DNSProfile(
            id: id,
            name: "Duplicate",
            upstream: .https(try DoHConfiguration(
                endpointURL: #require(URL(string: endpoint)),
                bootstrapServers: [IPAddress("192.0.2.1")]
            ))
        )
    }
}
