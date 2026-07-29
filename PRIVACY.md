# Privacy

Last updated: 2026-07-29

This document describes the DNSPilot open-source application. Independently distributed builds may have different operators and policies.

## Project Services

DNSPilot does not require an account and does not send analytics or telemetry to a DNSPilot-operated server. Configuration and rule data are stored locally for the current macOS user.

## DNS Resolution

DNS queries are sent to the resolver selected in the active Profile. The resolver and network providers can observe query names, IP addresses, timing, and protocol metadata under their own terms and privacy policies. DNSPilot does not operate or endorse third-party resolvers merely because they appear as built-in examples.

## Location and SSID

macOS controls access to the current Wi-Fi SSID through Location authorization. DNSPilot requests authorization only after an explicit user action. SSID is used locally to evaluate rules and is not sent to a DNSPilot-operated service.

## Logs and Diagnostics

Default logging minimizes DNS details. Debug logging can expose query names, addresses, resolver responses, SSIDs, endpoints, or tokens in system logs. Diagnostic export is an explicit user action and can include Profile, Rule, network, and runtime details. Review and redact exports before sharing them.

## System Extension

The DNS Proxy System Extension receives the active immutable resolver configuration and DNS flows supplied by macOS. It does not receive the Profile catalog, rules, SSID, account data, or store receipts.

## Retention and Deletion

DNSPilot keeps configuration in the user's Application Support container and short-lived recovery evidence with owner-only permissions during an active mutation. Resetting configuration removes product configuration through the supported app workflow. Removing the app does not necessarily disable an already enabled system-managed DNS Proxy; restore system DNS before removal.

## Third Parties

DNSPilot uses AdGuard DnsLibs/AGDnsProxy. See `THIRD-PARTY-NOTICES.md`. macOS, Apple signing services, the selected DNS resolver, and the source hosting provider operate under their own policies.

Privacy manifest and encryption/export declarations are release gates and must be re-audited against every shipped binary and dependency revision.
