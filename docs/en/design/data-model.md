# Data Model And Rules

[中文](../../zh/design/data-model.md)

## DNS Profiles

```swift
struct DNSProfile {
    let id: UUID
    let name: String
    let upstream: DNSUpstream
    let hosts: [DNSHostEntry]
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

## Profile Hosts

A Profile may contain up to 256 typed `DNSHostEntry` values. Each entry is an exact, canonicalized ASCII domain plus one IPv4 or IPv6 address. Domains are lowercased, one trailing dot is removed, wildcards are not accepted, and each domain may have at most one address per family. Hosts are sorted canonically before persistence.

Hosts are Profile-owned and are not `DNSRule` conditions. They affect only A or AAAA queries for the exact domain. Other record types continue to the Profile upstream. The runtime adapter generates `$dnsrewrite` plus `$dnstype` rules in one in-memory DnsLibs filter; raw filter text and file paths are not part of the model or XPC contract.

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

Profiles, Rules, Default Profile, operating mode, per-Profile hosts, and the global DNS cache configuration live in one versioned `AppConfiguration` document. The cache is enabled by default with a maximum of 1,000 responses. An enabled capacity is restricted to `1...10,000`; disabling the cache retains the last valid capacity for later reuse. An empty document starts in Automatic mode and cannot enable the DNS Proxy until a valid Profile and Default Profile exist.

Loading validates schema support, duplicate identities, every reference, hosts bounds, and cache bounds. Persisted schemas 1 and 2 are migrated in memory to schema 3 with the standard cache configuration; schema 3 and later inputs are canonicalized to the current schema 4, with absent Profile hosts represented by an empty array. The official file changes only through the normal atomic commit path. A newer schema enters read-only recovery and is never overwritten. Corrupt input is preserved before reset is offered.

Configuration is canonicalized, fingerprinted, and committed with compare-and-swap semantics using a private Application Support directory, restrictive permissions, durable temporary-file writes, and atomic replacement. `UserDefaults` is limited to UI preferences.

## Referential Integrity

Deleting a referenced Profile requires an explicit replacement for Rules, Default Profile, Manual target, and Active runtime. A pending Target that differs from Active must first be reconciled, cancelled, or followed by Restore System DNS. No operation may leave a dangling Profile reference.

## Mutation Journal

Configuration mutations are serialized. Inactive changes need one atomic configuration commit. A Profile or cache change affecting the Active runtime uses a compensating transaction with:

- operation and runtime transaction identity;
- old and draft configuration fingerprints;
- old and draft runtime identity;
- journal phase and authenticated checksums;
- a short-lived private payload containing exact bytes required for compensation.

Startup processes mutation evidence before ordinary runtime reconciliation. It may complete the draft, restore the old state, or clean a verified terminal transaction. Unknown, conflicting, incomplete, or corrupt evidence enters recovery-required state. Recovery artifacts are deleted only after a verified terminal state.

## Lifecycle Resume Journal

Safe Quit uses a separate versioned lifecycle journal in the same private Application Support directory. It stores an operation identity, phase, application-configuration fingerprint, expected manager owner and localized-description fingerprints, Active generation, Active configuration fingerprint, and Profile identity. It never stores raw runtime bytes, upstream configuration, network context, or DNS traffic.

Schema 2 adds an optional Extension upgrade subrecord containing its operation ID, source and target short/build versions, pre-update owner fingerprint, replacement attempt ID, and `prepared`, `replacementSubmitted`, or `replacementConfirmed` phase. Schema 1 records remain readable and preserve their original resume eligibility; entering an upgrade transaction rewrites them as schema 2 with newly verified manager evidence. Resume claim is forbidden while an upgrade is prepared or submitted.

Base phases cover prepared Quit, confirmed disable, claimed launch, and failed attempt. All base and upgrade phase changes use canonical encoding, checksums, durable atomic replacement, and operation-scoped compare-and-swap. Corrupt and newer-schema records are preserved and never authorize automatic enablement. The journal is consumed once and is not part of `AppConfiguration`; `UserDefaults` remains limited to UI preferences.
