import Foundation

struct ProfileDisplayIdentity: Equatable, Sendable {
    let profileID: DNSProfile.ID
    let name: String
    let summary: String
    let disambiguationSuffix: String?

    var displaySummary: String {
        guard let disambiguationSuffix else { return summary }
        return "\(summary) · \(disambiguationSuffix)"
    }

    static func identities(for profiles: [DNSProfile]) -> [DNSProfile.ID: ProfileDisplayIdentity] {
        let baseValues = profiles.map { profile in
            (profile: profile, summary: summary(for: profile.upstream))
        }
        let collisionGroups = Dictionary(
            grouping: baseValues,
            by: { "\($0.profile.name)\u{0}\($0.summary)" }
        )

        return Dictionary(uniqueKeysWithValues: baseValues.map { value in
            let collisionKey = "\(value.profile.name)\u{0}\(value.summary)"
            let group = collisionGroups[collisionKey, default: []]
            let suffix = group.count == 1 ? nil : uniqueUUIDPrefix(
                for: value.profile.id,
                among: group.map(\.profile.id)
            )
            return (
                value.profile.id,
                ProfileDisplayIdentity(
                    profileID: value.profile.id,
                    name: value.profile.name,
                    summary: value.summary,
                    disambiguationSuffix: suffix
                )
            )
        })
    }

    static func displayNames(for profiles: [DNSProfile]) -> [DNSProfile.ID: String] {
        let identities = identities(for: profiles)
        let duplicateNames = Dictionary(grouping: profiles, by: \.name)
        return Dictionary(uniqueKeysWithValues: profiles.map { profile in
            let identity = identities[profile.id]!
            let value = duplicateNames[profile.name, default: []].count > 1
                ? "\(identity.name) · \(identity.displaySummary)"
                : identity.name
            return (profile.id, value)
        })
    }

    private static func uniqueUUIDPrefix(for id: UUID, among ids: [UUID]) -> String {
        let value = compactUUID(id)
        let candidates = ids.map(compactUUID)
        for length in 4...value.count {
            let prefix = value.prefix(length)
            if candidates.lazy.filter({ $0.hasPrefix(prefix) }).count == 1 {
                return String(prefix)
            }
        }
        return value
    }

    private static func compactUUID(_ id: UUID) -> String {
        id.uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func summary(for upstream: DNSUpstream) -> String {
        switch upstream {
        case let .plain(configuration):
            let address = configuration.serverAddress.isIPv6
                ? "[\(configuration.serverAddress.stringValue)]"
                : configuration.serverAddress.stringValue
            return "Plain DNS · \(address):\(configuration.port)"
        case let .tls(configuration):
            let serverName = (try? IPAddress(configuration.serverName))?.isIPv6 == true
                ? "[\(configuration.serverName)]"
                : configuration.serverName
            let serverIdentity = configuration.port == DoTConfiguration.defaultPort
                ? serverName
                : "\(serverName):\(configuration.port)"
            return "DNS over TLS · \(serverIdentity)"
        case let .https(configuration):
            guard let components = URLComponents(
                url: configuration.endpointURL,
                resolvingAgainstBaseURL: false
            ), let host = components.host else {
                preconditionFailure("Validated DoH endpoints must have a host")
            }
            let serverIdentity: String
            if let port = components.port, port != 443 {
                serverIdentity = "\(host):\(port)"
            } else {
                serverIdentity = host
            }
            return "DNS over HTTPS · \(serverIdentity)"
        }
    }
}
