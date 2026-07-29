import AGDnsProxy
import Foundation

enum AGDnsConfigurationAdapterError: LocalizedError {
    case defaultConfigurationUnavailable

    var errorDescription: String? {
        switch self {
        case .defaultConfigurationUnavailable:
            "AGDnsProxy did not provide a default configuration."
        }
    }
}

enum AGDnsConfigurationAdapter {
    static func makeUpstream(from upstream: DNSUpstream) throws -> AGDnsUpstream {
        let result = AGDnsUpstream()
        result.id = 1
        switch upstream {
        case let .plain(configuration):
            result.address = serverAddress(
                configuration.serverAddress,
                port: configuration.port
            )
            result.bootstrap = []
        case let .https(configuration):
            result.address = configuration.endpointURL.absoluteString
            result.bootstrap = configuration.bootstrapServers.map {
                serverAddress($0, port: 53)
            }
        }
        return result
    }

    private static func serverAddress(_ address: IPAddress, port: UInt16) -> String {
        if address.isIPv6 {
            "[\(address.stringValue)]:\(port)"
        } else {
            "\(address.stringValue):\(port)"
        }
    }

    static func makeProxyConfig(from configuration: ActiveProxyConfiguration) throws -> AGDnsProxyConfig {
        guard let result = AGDnsProxyConfig.getDefault() else {
            throw AGDnsConfigurationAdapterError.defaultConfigurationUnavailable
        }

        result.upstreams = [try makeUpstream(from: configuration.upstream)]
        result.fallbacks = []
        result.fallbackDomains = []
        result.filters = []
        result.listeners = []
        result.upstreamTimeoutMs = 5_000
        result.optimisticCache = false
        result.enableParallelUpstreamQueries = false
        result.enableFallbackOnUpstreamsFailure = false
        result.enableHttp3 = false
        return result
    }
}

extension DNSProxyReloadScope {
    var agDnsReapplyOptions: AGDnsProxyReapplyOptions {
        var options = AGDnsProxyReapplyOptions()
        if contains(.settings) {
            options.insert(.settings)
        }
        if contains(.filters) {
            options.insert(.filters)
        }
        return options
    }
}
