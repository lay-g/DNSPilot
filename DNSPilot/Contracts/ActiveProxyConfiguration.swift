import Foundation

enum ActiveProxyConfigurationError: LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case unsupportedLegacyUpstreamKind(String)
    case unsupportedLegacyDoHConfiguration
    case invalidLegacyBootstrapServer(String)
    case invalidPlainDNSPort(Int)
    case invalidDoHEndpoint
    case missingBootstrapServers
    case invalidPropertyListStructure

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Unsupported proxy configuration schema version: \(version)."
        case let .unsupportedLegacyUpstreamKind(kind):
            "Unsupported legacy DNS upstream kind: \(kind)."
        case .unsupportedLegacyDoHConfiguration:
            "The DNS-over-HTTPS configuration cannot be represented by schema version 1."
        case let .invalidLegacyBootstrapServer(address):
            "Invalid legacy bootstrap server address: \(address)."
        case let .invalidPlainDNSPort(port):
            "The plain DNS port must be between 1 and 65535, got \(port)."
        case .invalidDoHEndpoint:
            "The DNS-over-HTTPS endpoint must be an HTTPS URL with a host and no user info or fragment."
        case .missingBootstrapServers:
            "A DNS-over-HTTPS hostname endpoint requires at least one bootstrap server."
        case .invalidPropertyListStructure:
            "The proxy configuration property list has an invalid structure."
        }
    }
}

struct PlainDNSConfiguration: Codable, Hashable, Sendable {
    let serverAddress: IPAddress
    let port: UInt16

    init(serverAddress: IPAddress, port: Int = 53) throws {
        guard (1...65_535).contains(port) else {
            throw ActiveProxyConfigurationError.invalidPlainDNSPort(port)
        }
        self.serverAddress = serverAddress
        self.port = UInt16(port)
    }

    private enum CodingKeys: String, CodingKey {
        case serverAddress
        case port
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            serverAddress: container.decode(IPAddress.self, forKey: .serverAddress),
            port: container.decode(Int.self, forKey: .port)
        )
    }
}

struct DoHConfiguration: Codable, Hashable, Sendable {
    let endpointURL: URL
    let bootstrapServers: [IPAddress]

    init(endpointURL: URL, bootstrapServers: [IPAddress]) throws {
        guard
            let components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.fragment == nil
        else {
            throw ActiveProxyConfigurationError.invalidDoHEndpoint
        }

        let unbracketedHost: String
        if host.hasPrefix("[") && host.hasSuffix("]") {
            unbracketedHost = String(host.dropFirst().dropLast())
        } else {
            unbracketedHost = host
        }
        if (try? IPAddress(unbracketedHost)) == nil, bootstrapServers.isEmpty {
            throw ActiveProxyConfigurationError.missingBootstrapServers
        }

        self.endpointURL = endpointURL
        self.bootstrapServers = bootstrapServers
    }

    private enum CodingKeys: String, CodingKey {
        case endpointURL
        case bootstrapServers
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let endpointValue = try container.decode(String.self, forKey: .endpointURL)
        try self.init(
            endpointURL: requireURL(endpointValue),
            bootstrapServers: container.decode([IPAddress].self, forKey: .bootstrapServers)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpointURL.absoluteString, forKey: .endpointURL)
        try container.encode(bootstrapServers, forKey: .bootstrapServers)
    }
}

enum DNSUpstream: Codable, Hashable, Sendable {
    case plain(PlainDNSConfiguration)
    case https(DoHConfiguration)

    private enum CodingKeys: String, CodingKey {
        case kind
        case configuration
    }

    private enum Kind: String, Codable {
        case plain
        case https
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .plain:
            self = .plain(try container.decode(PlainDNSConfiguration.self, forKey: .configuration))
        case .https:
            self = .https(try container.decode(DoHConfiguration.self, forKey: .configuration))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .plain(configuration):
            try container.encode(Kind.plain, forKey: .kind)
            try container.encode(configuration, forKey: .configuration)
        case let .https(configuration):
            try container.encode(Kind.https, forKey: .kind)
            try container.encode(configuration, forKey: .configuration)
        }
    }

    static let fixedCloudflare = builtInDoH(
        endpoint: "https://cloudflare-dns.com/dns-query",
        bootstrapServers: ["1.1.1.1", "1.0.0.1"]
    )

    #if DNSPILOT_DEBUG_LOCAL
    private static let debugLocalAliDNS = builtInDoH(
        endpoint: "https://dns.alidns.com/dns-query",
        bootstrapServers: ["223.5.5.5", "223.6.6.6"]
    )
    #endif

    static var fixedForCurrentBuild: DNSUpstream {
        #if DNSPILOT_DEBUG_LOCAL
        debugLocalAliDNS
        #else
        fixedCloudflare
        #endif
    }

    private static func builtInDoH(endpoint: String, bootstrapServers: [String]) -> DNSUpstream {
        do {
            let endpointURL = try requireURL(endpoint)
            let addresses = try bootstrapServers.map(IPAddress.init)
            return .https(try DoHConfiguration(
                endpointURL: endpointURL,
                bootstrapServers: addresses
            ))
        } catch {
            preconditionFailure("Invalid built-in DNS upstream: \(error)")
        }
    }
}

private func requireURL(_ value: String) throws -> URL {
    guard let url = URL(string: value) else {
        throw ActiveProxyConfigurationError.invalidDoHEndpoint
    }
    return url
}

enum ProxyLoggingMode: String, Codable, Sendable {
    case `default`
    case debug
}

struct ActiveProxyConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    static let providerConfigurationKey = "DNSPilotActiveProxyConfiguration"
    static let vendorDataOptionKey = "VendorData"

    let schemaVersion: Int
    let generation: UUID
    let profileID: UUID
    let upstream: DNSUpstream
    let loggingMode: ProxyLoggingMode

    init(
        generation: UUID,
        profileID: UUID,
        upstream: DNSUpstream,
        loggingMode: ProxyLoggingMode = .default,
        schemaVersion: Int = Self.currentSchemaVersion
    ) throws {
        guard schemaVersion == 1 || schemaVersion == Self.currentSchemaVersion else {
            throw ActiveProxyConfigurationError.unsupportedSchemaVersion(schemaVersion)
        }
        if schemaVersion == 1 {
            guard case let .https(configuration) = upstream else {
                throw ActiveProxyConfigurationError.unsupportedLegacyUpstreamKind("plain")
            }
            guard
                configuration.endpointURL.scheme == "https",
                !configuration.bootstrapServers.isEmpty
            else {
                throw ActiveProxyConfigurationError.unsupportedLegacyDoHConfiguration
            }
        }
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.profileID = profileID
        self.upstream = upstream
        self.loggingMode = loggingMode
    }

    func propertyListData() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    static func decodePropertyList(_ data: Data) throws -> Self {
        let payload = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        try validatePropertyListStructure(payload)
        return try PropertyListDecoder().decode(Self.self, from: data)
    }

    private static let propertyListKeys: Set<String> = [
        "schemaVersion",
        "generation",
        "profileID",
        "upstream",
        "loggingMode",
    ]
    private static let legacyUpstreamKeys: Set<String> = [
        "kind",
        "address",
        "bootstrapServerAddresses",
    ]
    private static let currentUpstreamKeys: Set<String> = [
        "kind",
        "configuration",
    ]
    private static let plainConfigurationKeys: Set<String> = [
        "serverAddress",
        "port",
    ]
    private static let doHConfigurationKeys: Set<String> = [
        "endpointURL",
        "bootstrapServers",
    ]

    private static func validatePropertyListStructure(_ payload: Any) throws {
        guard
            let configuration = payload as? [String: Any],
            let schemaVersion = configuration["schemaVersion"] as? Int
        else {
            throw ActiveProxyConfigurationError.invalidPropertyListStructure
        }
        guard schemaVersion == 1 || schemaVersion == currentSchemaVersion else {
            throw ActiveProxyConfigurationError.unsupportedSchemaVersion(schemaVersion)
        }
        try requireExactKeys(propertyListKeys, in: configuration)
        guard let upstream = configuration["upstream"] as? [String: Any] else {
            throw ActiveProxyConfigurationError.invalidPropertyListStructure
        }

        if schemaVersion == 1 {
            try requireExactKeys(legacyUpstreamKeys, in: upstream)
            return
        }

        try requireExactKeys(currentUpstreamKeys, in: upstream)
        guard
            let kind = upstream["kind"] as? String,
            let nestedConfiguration = upstream["configuration"] as? [String: Any]
        else {
            throw ActiveProxyConfigurationError.invalidPropertyListStructure
        }
        switch kind {
        case "plain":
            try requireExactKeys(plainConfigurationKeys, in: nestedConfiguration)
        case "https":
            try requireExactKeys(doHConfigurationKeys, in: nestedConfiguration)
        default:
            throw ActiveProxyConfigurationError.invalidPropertyListStructure
        }
    }

    private static func requireExactKeys(
        _ expectedKeys: Set<String>,
        in dictionary: [String: Any]
    ) throws {
        guard Set(dictionary.keys) == expectedKeys else {
            throw ActiveProxyConfigurationError.invalidPropertyListStructure
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generation
        case profileID
        case upstream
        case loggingMode
    }

    private struct LegacyDNSUpstream: Codable {
        let kind: String
        let address: String
        let bootstrapServerAddresses: [String]
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decode(Int.self, forKey: .schemaVersion)

        guard decodedSchemaVersion == 1 || decodedSchemaVersion == Self.currentSchemaVersion else {
            throw ActiveProxyConfigurationError.unsupportedSchemaVersion(decodedSchemaVersion)
        }

        generation = try container.decode(UUID.self, forKey: .generation)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        loggingMode = try container.decode(ProxyLoggingMode.self, forKey: .loggingMode)

        switch decodedSchemaVersion {
        case 1:
            upstream = try Self.migrateLegacyUpstream(
                container.decode(LegacyDNSUpstream.self, forKey: .upstream)
            )
            schemaVersion = 1
        case Self.currentSchemaVersion:
            upstream = try container.decode(DNSUpstream.self, forKey: .upstream)
            schemaVersion = Self.currentSchemaVersion
        default:
            preconditionFailure("Schema version was validated before payload decoding")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generation, forKey: .generation)
        try container.encode(profileID, forKey: .profileID)
        switch schemaVersion {
        case 1:
            guard case let .https(configuration) = upstream else {
                throw ActiveProxyConfigurationError.unsupportedLegacyUpstreamKind("plain")
            }
            try container.encode(
                LegacyDNSUpstream(
                    kind: "dnsOverHTTPS",
                    address: configuration.endpointURL.absoluteString,
                    bootstrapServerAddresses: configuration.bootstrapServers.map {
                        legacyServerAddress($0, port: 53)
                    }
                ),
                forKey: .upstream
            )
        case Self.currentSchemaVersion:
            try container.encode(upstream, forKey: .upstream)
        default:
            throw ActiveProxyConfigurationError.unsupportedSchemaVersion(schemaVersion)
        }
        try container.encode(loggingMode, forKey: .loggingMode)
    }

    private static func migrateLegacyUpstream(_ legacy: LegacyDNSUpstream) throws -> DNSUpstream {
        guard legacy.kind == "dnsOverHTTPS" else {
            throw ActiveProxyConfigurationError.unsupportedLegacyUpstreamKind(legacy.kind)
        }
        let bootstrapServers = try legacy.bootstrapServerAddresses.map(parseLegacyBootstrapServer)
        return .https(try DoHConfiguration(
            endpointURL: requireURL(legacy.address),
            bootstrapServers: bootstrapServers
        ))
    }

    private static func parseLegacyBootstrapServer(_ address: String) throws -> IPAddress {
        let literal: String
        if address.hasPrefix("[") {
            guard address.hasSuffix("]:53") else {
                throw ActiveProxyConfigurationError.invalidLegacyBootstrapServer(address)
            }
            literal = String(address.dropFirst().dropLast(4))
        } else {
            guard address.hasSuffix(":53") else {
                throw ActiveProxyConfigurationError.invalidLegacyBootstrapServer(address)
            }
            literal = String(address.dropLast(3))
        }

        do {
            return try IPAddress(literal)
        } catch {
            throw ActiveProxyConfigurationError.invalidLegacyBootstrapServer(address)
        }
    }

    private func legacyServerAddress(_ address: IPAddress, port: UInt16) -> String {
        if address.isIPv6 {
            "[\(address.stringValue)]:\(port)"
        } else {
            "\(address.stringValue):\(port)"
        }
    }
}
