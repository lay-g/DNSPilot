import Foundation

enum DNSRuleError: LocalizedError, Equatable, Sendable {
    case missingConditions

    var errorDescription: String? {
        switch self {
        case .missingConditions:
            "A DNS rule must have at least one condition."
        }
    }
}

enum NetworkInterfaceType: String, Codable, CaseIterable, Sendable {
    case wifi
    case wiredEthernet
    case other
}

struct RuleConditions: Codable, Equatable, Sendable {
    let ssids: [String]
    let interfaceTypes: Set<NetworkInterfaceType>
    let subnets: [IPNetwork]

    init(
        ssids: [String] = [],
        interfaceTypes: Set<NetworkInterfaceType> = [],
        subnets: [IPNetwork] = []
    ) {
        self.ssids = ssids
        self.interfaceTypes = interfaceTypes
        self.subnets = subnets
    }

    var isEmpty: Bool {
        ssids.isEmpty && interfaceTypes.isEmpty && subnets.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case ssids
        case interfaceTypes
        case subnets
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ssids = try container.decode([String].self, forKey: .ssids)
        interfaceTypes = Set(try container.decode([NetworkInterfaceType].self, forKey: .interfaceTypes))
        subnets = try container.decode([IPNetwork].self, forKey: .subnets)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ssids, forKey: .ssids)
        try container.encode(interfaceTypes.sorted { $0.rawValue < $1.rawValue }, forKey: .interfaceTypes)
        try container.encode(subnets, forKey: .subnets)
    }
}

struct DNSRule: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let isEnabled: Bool
    let conditions: RuleConditions
    let profileID: DNSProfile.ID

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        conditions: RuleConditions,
        profileID: DNSProfile.ID
    ) throws {
        guard !conditions.isEmpty else {
            throw DNSRuleError.missingConditions
        }
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.conditions = conditions
        self.profileID = profileID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isEnabled
        case conditions
        case profileID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            isEnabled: container.decode(Bool.self, forKey: .isEnabled),
            conditions: container.decode(RuleConditions.self, forKey: .conditions),
            profileID: container.decode(DNSProfile.ID.self, forKey: .profileID)
        )
    }
}
