import Foundation

enum RuleMatchSource: Equatable, Sendable {
    case rule(DNSRule.ID)
    case `default`
}

struct RuleMatchResult: Equatable, Sendable {
    let profileID: DNSProfile.ID
    let source: RuleMatchSource
}

enum RuleEngine {
    static func resolveProfile(
        context: NetworkContext,
        rules: [DNSRule],
        defaultProfileID: DNSProfile.ID
    ) -> RuleMatchResult {
        for rule in rules where rule.isEnabled && matches(rule.conditions, context: context) {
            return RuleMatchResult(profileID: rule.profileID, source: .rule(rule.id))
        }
        return RuleMatchResult(profileID: defaultProfileID, source: .default)
    }

    private static func matches(_ conditions: RuleConditions, context: NetworkContext) -> Bool {
        let matchesSSID = conditions.ssids.isEmpty || (
            context.ssidAvailability == .available
                && context.ssid.map(conditions.ssids.contains) == true
        )
        let matchesInterface = conditions.interfaceTypes.isEmpty
            || !conditions.interfaceTypes.isDisjoint(with: context.activeInterfaceTypes)
        let matchesSubnet = conditions.subnets.isEmpty || conditions.subnets.contains { subnet in
            context.addresses.contains { subnet.contains($0.address) }
        }
        return matchesSSID && matchesInterface && matchesSubnet
    }
}
