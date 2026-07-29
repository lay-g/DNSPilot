# Privacy

Last updated: 2026-07-29

This document describes the DNSPilot open-source application. Independently distributed builds may have different operators and policies.

## Project Services

Configuration and Rule data are stored locally for the current macOS user. Runtime network destinations are the user-selected DNS resolver and Apple-managed system services. The project operates no application service that receives analytics, telemetry, configuration, or DNS data.

## DNS Resolution

DNS queries are sent to the resolver selected in the active Profile. The resolver and network providers can observe query names, IP addresses, timing, and protocol metadata under their own terms and privacy policies.

## Location and SSID

macOS controls access to the current Wi-Fi SSID through Location authorization. DNSPilot requests authorization after an explicit user action and keeps the SSID in the Host process for local Rule evaluation.

## Logs and Diagnostics

Default logging minimizes DNS details. Debug logging can expose query names, addresses, resolver responses, SSIDs, endpoints, or tokens in system logs. Diagnostic export is an explicit user action and can include Profile, Rule, network, and runtime details. Review and redact exports before sharing them.

## System Extension

The DNS Proxy System Extension receives the active immutable resolver configuration, runtime logging mode, and DNS flows supplied by macOS. Profile catalogs, Rules, and SSID remain in the Host process.

## Retention and Deletion

DNSPilot keeps configuration in the user's Application Support container and short-lived recovery evidence with owner-only permissions during an active mutation. Resetting configuration removes product configuration through the supported app workflow. Removing the app does not necessarily disable an already enabled system-managed DNS Proxy; restore system DNS before removal.

## Third Parties

DNSPilot uses AdGuard DnsLibs/AGDnsProxy. See `THIRD-PARTY-NOTICES.md`. macOS, Apple signing services, the selected DNS resolver, and the source hosting provider operate under their own policies.
