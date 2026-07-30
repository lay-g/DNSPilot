# Data Model And Rules

[中文](../../zh/design/data-model.md)

## DNS Profiles

```swift
struct DNSProfile {
    let id: UUID
    let name: String
    let upstream: DNSUpstream
}

enum DNSUpstream {
    case plain(PlainDNSConfiguration)
    case tls(DoTConfiguration)
    case https(DoHConfiguration)
}
```

Profile UUID is identity; names may repeat. Names are trimmed and non-empty. Plain DNS accepts an IPv4 or IPv6 literal and port `1...65535`. DoT accepts a hostname or IP address and port `1...65535`, defaulting to 853; a hostname requires at least one literal bootstrap address. DoH requires HTTPS, a host, no user information or fragment, and at least one literal bootstrap address when the endpoint uses a hostname.

Display identity uses the name plus a privacy-safe protocol/server summary. DoT summaries exclude bootstrap addresses. DoH summaries exclude paths, queries, tokens, and bootstrap addresses. Business logic always uses UUIDs.

The Default Profile is a role assigned to a user-owned Profile. Provider templates create ordinary Profiles that remain editable by the user.

## Rules

```swift
struct DNSRule {
    let id: UUID
    let name: String
    let isEnabled: Bool
    let conditions: RuleConditions
    let profileID: DNSProfile.ID
}
```

A Rule has at least one condition. Configured condition groups use AND semantics; values within one group use OR semantics. SSIDs match exactly and case-sensitively. Interface matching uses active interface types. Subnet matching uses binary IPv4/IPv6 CIDR containment. Disabled Rules are skipped and the first enabled match wins.

Automatic mode uses the ordered Rules and falls back to the Default Profile. Manual mode persists its selected Profile and ignores network-driven selection until the user returns to Automatic.

## Network Context

`NetworkContext` records path status, SSID and its availability reason, active interface types, and all relevant active IPv4/IPv6 interface addresses.

SSID denial disables only SSID conditions. Interface and subnet Rules continue to work. Network changes are content-deduplicated and debounced for one second. While a switch is running, only the latest decision remains pending.

## Configuration Storage

Profiles, Rules, Default Profile, and operating mode live in one versioned `AppConfiguration` document. An empty document starts in Automatic mode and cannot enable the DNS Proxy until a valid Profile and Default Profile exist.

Loading validates schema support, duplicate identities, and every reference. Persisted schema 1 is migrated canonically to schema 2 in memory and changes the official file only through the normal atomic commit path. A newer schema enters read-only recovery and is never overwritten. Corrupt input is preserved before reset is offered.

Configuration is canonicalized, fingerprinted, and committed with compare-and-swap semantics using a private Application Support directory, restrictive permissions, durable temporary-file writes, and atomic replacement. `UserDefaults` is limited to UI preferences.

## Referential Integrity

Deleting a referenced Profile requires an explicit replacement for Rules, Default Profile, Manual target, and Active runtime. A pending Target that differs from Active must first be reconciled, cancelled, or followed by Restore System DNS. No operation may leave a dangling Profile reference.

## Mutation Journal

Profile mutations are serialized. Inactive changes need one atomic configuration commit. A change affecting the Active runtime uses a compensating transaction with:

- operation and runtime transaction identity;
- old and draft configuration fingerprints;
- old and draft runtime identity;
- journal phase and authenticated checksums;
- a short-lived private payload containing exact bytes required for compensation.

Startup processes mutation evidence before ordinary runtime reconciliation. It may complete the draft, restore the old state, or clean a verified terminal transaction. Unknown, conflicting, incomplete, or corrupt evidence enters recovery-required state. Recovery artifacts are deleted only after a verified terminal state.
