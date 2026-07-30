import Foundation
import Testing
@testable import DNSPilot

struct AppConfigurationTests {
    private let profileID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    private let ruleID = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!

    @Test func schemaTwoRoundTripPreservesModelsAndStableSetEncoding() throws {
        let profile = try makeProfile()
        let rule = try DNSRule(
            id: ruleID,
            name: "Network",
            conditions: RuleConditions(interfaceTypes: [.wiredEthernet, .other, .wifi]),
            profileID: profile.id
        )
        let configuration = try AppConfiguration(
            profiles: [profile],
            rules: [rule],
            defaultProfileID: profile.id,
            operatingMode: .manual(profileID: profile.id)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(configuration)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rules = try #require(json["rules"] as? [[String: Any]])
        let conditions = try #require(rules.first?["conditions"] as? [String: Any])

        #expect(decoded == configuration)
        #expect(conditions["interfaceTypes"] as? [String] == ["other", "wifi", "wiredEthernet"])
    }

    @Test func emptyInitialConfigurationIsValid() throws {
        let configuration = try AppConfiguration()

        #expect(configuration.schemaVersion == 2)
        #expect(configuration.profiles.isEmpty)
        #expect(configuration.defaultProfileID == nil)
        #expect(configuration.operatingMode == .automatic)
    }

    @Test func rejectsUnsupportedSchemaAndDuplicateIDs() throws {
        let profile = try makeProfile()
        let rule = try DNSRule(
            id: ruleID,
            name: "Wi-Fi",
            conditions: RuleConditions(interfaceTypes: [.wifi]),
            profileID: profile.id
        )

        #expect(throws: AppConfigurationError.unsupportedSchemaVersion(3)) {
            try AppConfiguration(schemaVersion: 3)
        }
        #expect(throws: AppConfigurationError.duplicateProfileID(profile.id)) {
            try AppConfiguration(profiles: [profile, profile])
        }
        #expect(throws: AppConfigurationError.duplicateRuleID(rule.id)) {
            try AppConfiguration(profiles: [profile], rules: [rule, rule])
        }
    }

    @Test func migratesSchemaOneToCurrentSchema() throws {
        let current = try AppConfiguration(profiles: [makeProfile()])
        var payload = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
        )
        payload["schemaVersion"] = 1

        let migrated = try JSONDecoder().decode(
            AppConfiguration.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )

        #expect(migrated.schemaVersion == AppConfiguration.currentSchemaVersion)
        #expect(migrated.profiles == current.profiles)
    }

    @Test func rejectsMissingDefaultManualAndRuleReferences() throws {
        let missingID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let profile = try makeProfile()
        let missingRule = try DNSRule(
            id: ruleID,
            name: "Missing",
            conditions: RuleConditions(interfaceTypes: [.wifi]),
            profileID: missingID
        )

        #expect(throws: AppConfigurationError.missingDefaultProfile(missingID)) {
            try AppConfiguration(profiles: [profile], defaultProfileID: missingID)
        }
        #expect(throws: AppConfigurationError.missingManualProfile(missingID)) {
            try AppConfiguration(profiles: [profile], operatingMode: .manual(profileID: missingID))
        }
        #expect(throws: AppConfigurationError.missingRuleProfile(
            ruleID: missingRule.id,
            profileID: missingID
        )) {
            try AppConfiguration(profiles: [profile], rules: [missingRule])
        }
    }

    @Test func decodingRevalidatesTrimmedProfileNamesAndReferences() throws {
        let profile = try makeProfile()
        let configuration = try AppConfiguration(profiles: [profile])
        let data = try JSONEncoder().encode(configuration)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var profiles = try #require(json["profiles"] as? [[String: Any]])
        profiles[0]["name"] = "   "
        json["profiles"] = profiles
        let invalidData = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: DNSProfileError.emptyName) {
            try JSONDecoder().decode(AppConfiguration.self, from: invalidData)
        }
    }

    private func makeProfile() throws -> DNSProfile {
        try DNSProfile(
            id: profileID,
            name: "Primary",
            upstream: .plain(try PlainDNSConfiguration(serverAddress: IPAddress("192.0.2.53")))
        )
    }
}
