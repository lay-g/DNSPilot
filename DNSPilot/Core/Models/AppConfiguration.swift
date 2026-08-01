import Foundation

enum OperatingMode: Codable, Equatable, Sendable {
    case automatic
    case manual(profileID: DNSProfile.ID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case profileID
    }

    private enum Kind: String, Codable {
        case automatic
        case manual
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .automatic:
            self = .automatic
        case .manual:
            self = .manual(profileID: try container.decode(DNSProfile.ID.self, forKey: .profileID))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode(Kind.automatic, forKey: .kind)
        case let .manual(profileID):
            try container.encode(Kind.manual, forKey: .kind)
            try container.encode(profileID, forKey: .profileID)
        }
    }
}

enum AppConfigurationError: LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case duplicateProfileID(DNSProfile.ID)
    case duplicateRuleID(DNSRule.ID)
    case missingDefaultProfile(DNSProfile.ID)
    case missingManualProfile(DNSProfile.ID)
    case missingRuleProfile(ruleID: DNSRule.ID, profileID: DNSProfile.ID)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Unsupported app configuration schema version: \(version)."
        case let .duplicateProfileID(id):
            "Duplicate DNS profile ID: \(id)."
        case let .duplicateRuleID(id):
            "Duplicate DNS rule ID: \(id)."
        case let .missingDefaultProfile(id):
            "Default DNS profile does not exist: \(id)."
        case let .missingManualProfile(id):
            "Manual DNS profile does not exist: \(id)."
        case let .missingRuleProfile(ruleID, profileID):
            "DNS rule \(ruleID) references missing profile \(profileID)."
        }
    }
}

struct AppConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let profiles: [DNSProfile]
    let rules: [DNSRule]
    let defaultProfileID: DNSProfile.ID?
    let operatingMode: OperatingMode
    let dnsCacheConfiguration: DNSCacheConfiguration

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        profiles: [DNSProfile] = [],
        rules: [DNSRule] = [],
        defaultProfileID: DNSProfile.ID? = nil,
        operatingMode: OperatingMode = .automatic,
        dnsCacheConfiguration: DNSCacheConfiguration = .standard
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AppConfigurationError.unsupportedSchemaVersion(schemaVersion)
        }

        var profileIDs = Set<DNSProfile.ID>()
        for profile in profiles where !profileIDs.insert(profile.id).inserted {
            throw AppConfigurationError.duplicateProfileID(profile.id)
        }

        var ruleIDs = Set<DNSRule.ID>()
        for rule in rules where !ruleIDs.insert(rule.id).inserted {
            throw AppConfigurationError.duplicateRuleID(rule.id)
        }

        if let defaultProfileID, !profileIDs.contains(defaultProfileID) {
            throw AppConfigurationError.missingDefaultProfile(defaultProfileID)
        }
        if case let .manual(profileID) = operatingMode, !profileIDs.contains(profileID) {
            throw AppConfigurationError.missingManualProfile(profileID)
        }
        for rule in rules where !profileIDs.contains(rule.profileID) {
            throw AppConfigurationError.missingRuleProfile(ruleID: rule.id, profileID: rule.profileID)
        }

        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.rules = rules
        self.defaultProfileID = defaultProfileID
        self.operatingMode = operatingMode
        self.dnsCacheConfiguration = dnsCacheConfiguration
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case profiles
        case rules
        case defaultProfileID
        case operatingMode
        case dnsCacheConfiguration
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.currentSchemaVersion).contains(decodedSchemaVersion) else {
            throw AppConfigurationError.unsupportedSchemaVersion(decodedSchemaVersion)
        }
        try self.init(
            profiles: container.decode([DNSProfile].self, forKey: .profiles),
            rules: container.decode([DNSRule].self, forKey: .rules),
            defaultProfileID: container.decodeIfPresent(DNSProfile.ID.self, forKey: .defaultProfileID),
            operatingMode: container.decode(OperatingMode.self, forKey: .operatingMode),
            dnsCacheConfiguration: decodedSchemaVersion == Self.currentSchemaVersion
                ? container.decode(DNSCacheConfiguration.self, forKey: .dnsCacheConfiguration)
                : .standard
        )
    }
}
