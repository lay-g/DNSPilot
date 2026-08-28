import Foundation

enum DNSProfileError: LocalizedError, Equatable, Sendable {
    case emptyName
    case tooManyHosts(Int)
    case duplicateHost(domain: String, family: IPAddress.Family)
    case overlappingWildcardHost(domain: String, family: IPAddress.Family)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "A DNS profile name cannot be empty."
        case let .tooManyHosts(count):
            return "A DNS profile cannot contain more than \(DNSHostEntry.maximumCount) hosts; got \(count)."
        case let .duplicateHost(domain, family):
            let familyName = switch family {
            case .ipv4: "IPv4"
            case .ipv6: "IPv6"
            }
            return "DNS profile host \(domain) has more than one \(familyName) address."
        case let .overlappingWildcardHost(domain, family):
            let familyName = switch family {
            case .ipv4: "IPv4"
            case .ipv6: "IPv6"
            }
            return "DNS profile host \(domain) overlaps an existing wildcard hosts entry for \(familyName)."
        }
    }
}

struct DNSProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let upstream: DNSUpstream
    let hosts: [DNSHostEntry]

    init(
        id: UUID = UUID(),
        name: String,
        upstream: DNSUpstream,
        hosts: [DNSHostEntry] = []
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw DNSProfileError.emptyName
        }

        guard hosts.count <= DNSHostEntry.maximumCount else {
            throw DNSProfileError.tooManyHosts(hosts.count)
        }

        let sortedHosts = hosts.sorted { lhs, rhs in
            if lhs.domain != rhs.domain { return lhs.domain < rhs.domain }
            if lhs.address.family != rhs.address.family {
                return lhs.address.family == .ipv4
            }
            return lhs.address.stringValue < rhs.address.stringValue
        }
        var identities = Set<HostIdentity>()
        for host in sortedHosts {
            guard identities.insert(HostIdentity(domain: host.domain, family: host.address.family)).inserted else {
                throw DNSProfileError.duplicateHost(
                    domain: host.domain,
                    family: host.address.family
                )
            }
        }
        for i in 0..<sortedHosts.count {
            for j in (i + 1)..<sortedHosts.count where DNSHostEntry.overlaps(sortedHosts[i], sortedHosts[j]) {
                throw DNSProfileError.overlappingWildcardHost(
                    domain: sortedHosts[j].domain,
                    family: sortedHosts[j].address.family
                )
            }
        }

        self.id = id
        self.name = trimmedName
        self.upstream = upstream
        self.hosts = sortedHosts
    }

    private struct HostIdentity: Hashable {
        let domain: String
        let family: IPAddress.Family
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case upstream
        case hosts
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            upstream: container.decode(DNSUpstream.self, forKey: .upstream),
            hosts: container.decodeIfPresent([DNSHostEntry].self, forKey: .hosts) ?? []
        )
    }
}
