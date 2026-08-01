import Foundation
import NetworkExtension
import Testing
@testable import DNSPilot

struct DNSProxyManagerConfigurationTests {
    @Test func unitTestProcessCannotLoadLiveManager() async {
        let manager = NetworkExtensionDNSProxyManager()

        await #expect(throws: DNSProxyManagerClientError.unitTestProcess) {
            _ = try await manager.loadSnapshot()
        }
    }

    @Test func providerConfigurationUsesStableEncodedDataKey() throws {
        let configuration = try ActiveProxyConfiguration(
            generation: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            profileID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            upstream: .fixedCloudflare
        )

        let payload = try DNSProxyManagerConfiguration.providerConfiguration(for: configuration)

        #expect(Set(payload.keys) == [ActiveProxyConfiguration.providerConfigurationKey])
        let data = try #require(payload[ActiveProxyConfiguration.providerConfigurationKey])
        #expect(try ActiveProxyConfiguration.decodePropertyList(data) == configuration)
    }

    @Test func providerProtocolContainsBundleIdentifierAndPayload() throws {
        let configuration = try ActiveProxyConfiguration(
            generation: UUID(),
            profileID: UUID(),
            upstream: .fixedCloudflare
        )

        let result = try DNSProxyManagerConfiguration.makeProviderProtocol(
            configuration: configuration,
            providerBundleIdentifier: "com.example.DNSProxy"
        )

        #expect(result.providerBundleIdentifier == "com.example.DNSProxy")
        let data = try #require(
            result.providerConfiguration?[ActiveProxyConfiguration.providerConfigurationKey]
                as? Data
        )
        #expect(try ActiveProxyConfiguration.decodePropertyList(data) == configuration)
    }

    @Test func activeConfigurationReadsSavedProviderPayload() throws {
        let configuration = try ActiveProxyConfiguration(
            generation: UUID(),
            profileID: UUID(),
            upstream: .fixedCloudflare
        )
        let providerProtocol = try DNSProxyManagerConfiguration.makeProviderProtocol(
            configuration: configuration,
            providerBundleIdentifier: "com.example.DNSProxy"
        )

        #expect(
            try DNSProxyManagerConfiguration.activeConfiguration(from: providerProtocol)
                == configuration
        )
    }

    @Test func persistedConfigurationRetainsExactProviderPayloadBytes() throws {
        let configuration = try ActiveProxyConfiguration(
            generation: UUID(),
            profileID: UUID(),
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
        let providerProtocol = NEDNSProxyProviderProtocol()
        providerProtocol.providerConfiguration = [
            ActiveProxyConfiguration.providerConfigurationKey: xmlData,
        ]

        let loaded = try DNSProxyManagerConfiguration.persistedConfiguration(
            from: providerProtocol
        )
        let persisted = try #require(loaded)
        let snapshot = DNSProxyManagerSnapshot(
            isEnabled: true,
            persistedConfiguration: persisted
        )

        #expect(persisted.value == configuration)
        #expect(persisted.data == xmlData)
        #expect(persisted.fingerprint == ProxyConfigurationFingerprint(data: xmlData))
        #expect(snapshot.persistedConfiguration == persisted)
        #expect(snapshot.activeConfiguration == configuration)
    }

    @Test func persistedProviderProtocolUsesExactBytesWithoutReencoding() throws {
        let configuration = try ActiveProxyConfiguration(
            generation: UUID(),
            profileID: UUID(),
            upstream: .fixedCloudflare
        )
        let propertyList = try PropertyListSerialization.propertyList(
            from: configuration.propertyListData(),
            format: nil
        )
        let xmlData = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        let persisted = try PersistedProxyConfiguration(data: xmlData)

        let result = DNSProxyManagerConfiguration.makeProviderProtocol(
            persistedConfiguration: persisted,
            providerBundleIdentifier: "com.example.DNSProxy"
        )

        #expect(result.providerBundleIdentifier == "com.example.DNSProxy")
        #expect(
            result.providerConfiguration?[ActiveProxyConfiguration.providerConfigurationKey]
                as? Data == xmlData
        )
    }

    @Test func replacingPersistedPayloadPreservesUnknownProviderKeys() throws {
        let persisted = try PersistedProxyConfiguration(value: ActiveProxyConfiguration(
            generation: UUID(),
            profileID: UUID(),
            upstream: .fixedCloudflare
        ))
        let sentinel = Data([0x01, 0x02, 0x03])

        let result = DNSProxyManagerConfiguration.replacingActiveConfiguration(
            in: ["UnrelatedProviderKey": sentinel],
            with: persisted
        )

        #expect(result["UnrelatedProviderKey"] as? Data == sentinel)
        #expect(
            result[ActiveProxyConfiguration.providerConfigurationKey] as? Data
                == persisted.data
        )
    }

    @Test func activeConfigurationReturnsNilWithoutPayload() throws {
        #expect(
            try DNSProxyManagerConfiguration.activeConfiguration(from: nil)
                == nil
        )
    }

    #if DNSPILOT_DEBUG_LOCAL
    @Test func gateAOwnerNormalizesSnapshotOwnerIdentity() throws {
        let persisted = try PersistedProxyConfiguration(value: ActiveProxyConfiguration(
            generation: UUID(),
            profileID: UUID(),
            upstream: .fixedCloudflare
        ))
        let fingerprint = ProxyConfigurationFingerprint(data: Data("owner".utf8))
        let owner = DNSProxyManagerGateAOwner(
            snapshot: DNSProxyManagerSnapshot(
                isEnabled: true,
                persistedConfiguration: persisted
            ),
            providerBundleIdentifier: "com.example.DNSProxy",
            providerConfigurationFingerprint: fingerprint,
            localizedDescription: "DNSPilot"
        )

        #expect(owner.snapshot.ownerIdentity == DNSProxyManagerOwnerIdentity(
            providerBundleIdentifier: owner.providerBundleIdentifier,
            providerConfigurationFingerprint: owner.providerConfigurationFingerprint,
            localizedDescription: owner.localizedDescription
        ))
    }
    #endif
}
