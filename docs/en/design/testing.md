# Testing Strategy

[中文](../../zh/design/testing.md)

DNSPilot uses deterministic automated checks, controlled network fixtures, signed runtime validation, and manual UI review.

## Automated Unit Tests

Unit and contract tests cover:

- Profile, upstream, Rule, IP, CIDR, and reference validation.
- DNS Test query-name and type encoding, isolated adapter configuration, immutable DnsLibs event snapshots, AppState cancellation, and stale-result fencing.
- Plain DNS, DoT, and DoH model validation, adapter wire mapping, bootstrap conversion, and transport-specific schema capability gating.
- Rule ordering, AND/OR semantics, SSID availability, and Default fallback.
- Configuration schema, canonical encoding, fingerprints, atomic commit, corruption preservation, and compare-and-swap conflicts.
- DNS cache defaults, bounds, disablement, schema migration, adapter mapping, capability gating, cache-hit behavior, settings reapply, and rollback.
- Automatic/Manual persistence, target coalescing, stale decisions, and session fencing.
- Mutation journal authentication, compensation, crash recovery, and cleanup.
- Safe-Quit resume journal encoding, schema 1 compatibility, Extension upgrade prepare/submit/confirm fencing, corruption preservation, one-shot claims, and crash windows before and after manager disable or replacement.
- Runtime payload validation, exact identity, replay, rate limits, rollback, quiescence, resume, and recovery classification.
- Manual and Automatic startup resume, fresh-session network selection, Extension readiness gates, field-level disabled-manager mismatch, prepare-before-replace and confirm-before-resume ordering, duplicate publisher fencing, and explicit Keep System DNS behavior.
- Quit key-up, repeat rejection, timeout, cancellation, draft handling, and exactly-once dispatch.
- Privacy-safe display identity and diagnostic redaction.

Run the non-UI suite serially because several tests exercise process-global Network Extension or DnsLibs resources.

## Unit-Test Host Isolation

Every scheme Test action and `scripts/ci/test.sh` marks the launched App Host with `DNSPILOT_UNIT_TEST_HOST=1`. A marked or XCTest-loaded Host must not start the product runtime, open the live `ConfigurationStore`, submit System Extension requests, inspect or change the real Launch at Login registration, or use production `UserDefaults`. These runtime guards apply even if a developer accidentally runs tests with a Release configuration or Production Bundle identity. Repository policy checks require the marker on every shared scheme and the CI entry point; unit tests prove live-store rejection and preference-suite separation.

Temporary stores and injected manager, runtime, network, login-item, and System Extension fakes are the only mutable boundaries permitted in unit tests. Signed runtime validation is a separate, explicitly authorized workflow and never runs through the unit-test target.

## Static And Build Validation

Every code or build-system change should run repository policy checks, the pinned toolchain check, non-UI tests, static analysis, and an unsigned universal Community build. Inspect expanded build settings for Swift, deployment, concurrency, signing-derived identifiers, logging mode, and architectures.

Build-only success cannot prove code signing, entitlement authorization, System Extension activation, or DNS interception.

## Integration Validation

Controlled DNS and DoH fixtures validate real DnsLibs behavior: UDP/TCP fallback, HTTP connection reuse, bootstrap, cache hits and bypass, cancellation, resource limits, repeated lifecycle operations, rollback, and stop. Fixtures use reserved addresses and synthetic domains.

## Signed Runtime Validation

A properly provisioned machine is required to validate:

- Host, Extension, and nested framework signatures and entitlements.
- System Extension install, approval, replacement, and deactivation.
- DNS Proxy enablement and actual system DNS interception.
- XPC peer authentication and wrong-signer rejection.
- Plain DNS, DoT, DoH, switching, retry behavior, sleep/wake, and restoration.
- Network and active-user-session changes.
- Conflicts with other DNS or VPN products.
- Crash recovery and normal Quit restoration.
- Same-build relaunch and signed build N to N+1 safe-Quit replacement, including approval, restart, replacement failure, Host crashes at each durable phase, external manager mutation, delayed Provider readiness, and final manager mismatch.

Signed validation must use explicit user authorization when it changes UI or system state.

## Manual UI Validation

Manual review covers window behavior, menu consistency, keyboard-only operation, VoiceOver, long localization, DNS Test Profile/custom switching and long answer layout, permission dialogs, contrast, transparency, motion, and Quit alerts. UI and authorization checks run on an explicitly authorized test machine.
