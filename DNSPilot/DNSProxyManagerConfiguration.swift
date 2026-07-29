import Foundation
import NetworkExtension

enum DNSProxyManagerConfiguration {
    static func persistedConfiguration(
        from providerProtocol: NEDNSProxyProviderProtocol?
    ) throws -> PersistedProxyConfiguration? {
        guard
            let providerProtocol,
            let data = providerProtocol.providerConfiguration?[
                ActiveProxyConfiguration.providerConfigurationKey
            ] as? Data
        else {
            return nil
        }
        return try PersistedProxyConfiguration(data: data)
    }

    static func activeConfiguration(
        from providerProtocol: NEDNSProxyProviderProtocol?
    ) throws -> ActiveProxyConfiguration? {
        try persistedConfiguration(from: providerProtocol)?.value
    }

    static func providerConfiguration(
        for configuration: ActiveProxyConfiguration
    ) throws -> [String: Data] {
        [ActiveProxyConfiguration.providerConfigurationKey: try configuration.propertyListData()]
    }

    static func providerConfiguration(
        for configuration: PersistedProxyConfiguration
    ) -> [String: Data] {
        [ActiveProxyConfiguration.providerConfigurationKey: configuration.data]
    }

    static func replacingActiveConfiguration(
        in providerConfiguration: [String: Any]?,
        with configuration: PersistedProxyConfiguration
    ) -> [String: Any] {
        var result = providerConfiguration ?? [:]
        result[ActiveProxyConfiguration.providerConfigurationKey] = configuration.data
        return result
    }

    static func makeProviderProtocol(
        configuration: ActiveProxyConfiguration,
        providerBundleIdentifier: String
    ) throws -> NEDNSProxyProviderProtocol {
        let providerProtocol = NEDNSProxyProviderProtocol()
        providerProtocol.providerBundleIdentifier = providerBundleIdentifier
        providerProtocol.providerConfiguration = try providerConfiguration(for: configuration)
        return providerProtocol
    }

    static func makeProviderProtocol(
        persistedConfiguration: PersistedProxyConfiguration,
        providerBundleIdentifier: String
    ) -> NEDNSProxyProviderProtocol {
        let providerProtocol = NEDNSProxyProviderProtocol()
        providerProtocol.providerBundleIdentifier = providerBundleIdentifier
        providerProtocol.providerConfiguration = providerConfiguration(
            for: persistedConfiguration
        )
        return providerProtocol
    }
}
