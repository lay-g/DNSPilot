# Toolchain And Concurrency Baseline

[中文](../../zh/design/toolchain.md)

This document is the canonical compiler, deployment, and concurrency baseline.

## Versions

| Item | Baseline |
| --- | --- |
| Xcode | 26.4 |
| Xcode build | 17E192 |
| Apple Swift compiler | 6.3 |
| Swift language mode | Swift 6 |
| `SWIFT_VERSION` | `6.0` |
| Strict concurrency | `complete` |
| Default actor isolation | `nonisolated` |
| macOS deployment target | `15.0` |
| Architectures | `arm64`, `x86_64` where dependencies support both |

Compiler version, language mode, and deployment target are separate concepts. Xcode 26.4 does not imply a macOS 26 deployment target, and the upstream `swift-5` artifact label does not require Swift 5 language mode.

All first-party targets inherit the baseline from `Configurations/Base.xcconfig`. Project or target settings must not override it.

## Isolation And Ownership

- SwiftUI-facing types and UI command coordinators use explicit `@MainActor`.
- Shared mutable services such as `DNSProxyController` and `ProfileMutationCoordinator` use actors.
- Rule, CIDR, configuration mapping, and payload models are `Sendable` values and pure functions.
- Shared Contracts compile in both Host and Extension and must not gain target-wide actor isolation.
- Tests use local `@MainActor` only where they access UI-isolated APIs.

`nonisolated` does not promise background execution. Blocking `AGDnsUtils.testUpstream` work runs on the owned serial blocking executor and returns through a checked continuation.

## Objective-C Dependency Boundary

`AGDnsProxy`, flow managers, and mutable callbacks remain inside the Provider lifecycle owner. They do not cross actors or XPC. DnsLibs callbacks are copied into immutable, identity-tagged events before entering application state.

Do not suppress diagnostics with module-wide `@preconcurrency import` or broad `@unchecked Sendable`. Any escape hatch must be the smallest adapter-level wrapper and document ownership and test invariants.

## Tool Selection

Local commands use:

```bash
export DEVELOPER_DIR="/Applications/Xcode-26.4.0.app/Contents/Developer"
scripts/check-toolchain.sh
```

CI may install Xcode elsewhere but must select it explicitly and verify the same Xcode build and compiler. Never rely on ambient `xcode-select` state.

## Upgrade Rule

Changing Xcode, compiler, language mode, strict-concurrency level, default isolation, deployment target, or architectures requires one reviewed change that updates this document, `Configurations/Base.xcconfig`, toolchain checks, CI pins, architecture constraints, and relevant tests. Host and Extension must both compile the shared Contracts and DnsLibs adapter before the upgrade is accepted.
