# Testing Strategy

[中文](../../zh/design/testing.md)

DNSPilot uses deterministic automated checks, controlled network fixtures, signed runtime validation, and manual UI review.

## Automated Unit Tests

Unit and contract tests cover:

- Profile, upstream, Rule, IP, CIDR, and reference validation.
- Rule ordering, AND/OR semantics, SSID availability, and Default fallback.
- Configuration schema, canonical encoding, fingerprints, atomic commit, corruption preservation, and compare-and-swap conflicts.
- Automatic/Manual persistence, target coalescing, stale decisions, and session fencing.
- Mutation journal authentication, compensation, crash recovery, and cleanup.
- Runtime payload validation, exact identity, replay, rate limits, rollback, quiescence, resume, and recovery classification.
- Quit key-up, repeat rejection, timeout, cancellation, draft handling, and exactly-once dispatch.
- Privacy-safe display identity and diagnostic redaction.

Run the non-UI suite serially because several tests exercise process-global Network Extension or DnsLibs resources.

## Static And Build Validation

Every code or build-system change should run repository policy checks, the pinned toolchain check, non-UI tests, static analysis, and an unsigned universal Community build. Inspect expanded build settings for Swift, deployment, concurrency, signing-derived identifiers, logging mode, and architectures.

Build-only success cannot prove code signing, entitlement authorization, System Extension activation, or DNS interception.

## Integration Validation

Controlled DNS and DoH fixtures validate real DnsLibs behavior: UDP/TCP fallback, HTTP connection reuse, bootstrap, cancellation, resource limits, repeated lifecycle operations, rollback, and stop. Fixtures use reserved addresses and synthetic domains.

## Signed Runtime Validation

A properly provisioned machine is required to validate:

- Host, Extension, and nested framework signatures and entitlements.
- System Extension install, approval, replacement, and deactivation.
- DNS Proxy enablement and actual system DNS interception.
- XPC peer authentication and wrong-signer rejection.
- Plain DNS, DoH, switching, retry behavior, sleep/wake, and restoration.
- Network and active-user-session changes.
- Conflicts with other DNS or VPN products.
- Crash recovery and normal Quit restoration.

Signed validation must use explicit user authorization when it changes UI or system state.

## Manual UI Validation

Manual review covers window behavior, menu consistency, keyboard-only operation, VoiceOver, long localization, permission dialogs, contrast, transparency, motion, and Quit alerts. UI and authorization checks run on an explicitly authorized test machine.
