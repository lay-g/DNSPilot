import AGDnsProxy
import Foundation

enum AGDnsConfigurationAdapterError: LocalizedError, Equatable, Sendable {
    case defaultConfigurationUnavailable
    case hostRulesTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .defaultConfigurationUnavailable:
            "AGDnsProxy did not provide a default configuration."
        case let .hostRulesTooLarge(bytes):
            "The Profile hosts rules exceed the supported size: \(bytes) bytes."
        }
    }
}

enum AGDnsConfigurationAdapter {
    private static let hostFilterID: Int = 1
    private static let maximumHostRulesBytes = DNSProxyXPCContract.maximumConfigurationSize / 2

    static func makeHostRules(from hosts: [DNSHostEntry]) throws -> String {
        try DNSHostEntry.validate(hosts)
        let sortedHosts = hosts.sorted { lhs, rhs in
            if lhs.domain != rhs.domain { return lhs.domain < rhs.domain }
            if lhs.address.family != rhs.address.family {
                return lhs.address.family == .ipv4
            }
            return lhs.address.stringValue < rhs.address.stringValue
        }
        let rules = sortedHosts.map { host in
            let type = host.address.isIPv6 ? "AAAA" : "A"
            return "|\(host.domain)|$dnstype=\(type),dnsrewrite=NOERROR;\(type);\(host.address.stringValue)"
        }
        let result = rules.isEmpty ? "" : rules.joined(separator: "\n") + "\n"
        guard result.utf8.count <= maximumHostRulesBytes else {
            throw AGDnsConfigurationAdapterError.hostRulesTooLarge(result.utf8.count)
        }
        return result
    }

    private static func makeFilters(from hosts: [DNSHostEntry]) throws -> [AGDnsFilterParams] {
        guard !hosts.isEmpty else { return [] }
        let filter = AGDnsFilterParams()
        filter.id = hostFilterID
        filter.data = try makeHostRules(from: hosts)
        filter.inMemory = true
        return [filter]
    }

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
        case let .tls(configuration):
            var components = URLComponents()
            components.scheme = "tls"
            components.host = (try? IPAddress(configuration.serverName))?.isIPv6 == true
                ? "[\(configuration.serverName)]"
                : configuration.serverName
            if configuration.port != DoTConfiguration.defaultPort {
                components.port = Int(configuration.port)
            }
            guard let address = components.string else {
                preconditionFailure("Validated DoT configuration must produce an upstream URL")
            }
            result.address = address
            result.bootstrap = configuration.bootstrapServers.map {
                serverAddress($0, port: 53)
            }
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
        result.filters = try makeFilters(from: configuration.hosts)
        result.listeners = []
        result.upstreamTimeoutMs = 5_000
        result.dnsCacheSize = configuration.dnsCacheConfiguration.isEnabled
            ? UInt(configuration.dnsCacheConfiguration.maximumEntries)
            : 0
        result.optimisticCache = false
        result.enableParallelUpstreamQueries = false
        result.enableFallbackOnUpstreamsFailure = false
        result.enableHttp3 = false
        return result
    }

    static func makeQueryProxyConfig(
        from upstream: DNSUpstream,
        hosts: [DNSHostEntry] = []
    ) throws -> AGDnsProxyConfig {
        guard let result = AGDnsProxyConfig.getDefault() else {
            throw AGDnsConfigurationAdapterError.defaultConfigurationUnavailable
        }
        result.upstreams = [try makeUpstream(from: upstream)]
        result.fallbacks = []
        result.fallbackDomains = []
        result.filters = try makeFilters(from: hosts)
        result.listeners = []
        result.upstreamTimeoutMs = 5_000
        result.dnsCacheSize = 0
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
