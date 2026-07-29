import Foundation

enum DNSProfileError: LocalizedError, Equatable, Sendable {
    case emptyName

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "A DNS profile name cannot be empty."
        }
    }
}

struct DNSProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let upstream: DNSUpstream

    init(id: UUID = UUID(), name: String, upstream: DNSUpstream) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw DNSProfileError.emptyName
        }
        self.id = id
        self.name = trimmedName
        self.upstream = upstream
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case upstream
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            upstream: container.decode(DNSUpstream.self, forKey: .upstream)
        )
    }
}
