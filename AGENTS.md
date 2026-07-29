# Agent Instructions

## Documentation

- Read the relevant English design document under `docs/en/design/` before changing behavior, architecture, build settings, security boundaries, UI contracts, or tests.
- Keep `docs/en/` and `docs/zh/` structurally mirrored and update both languages in the same change.
- Documentation describes enduring contracts. Do not add project progress, dated execution records, test-round status, machine-specific paths, local identities, or transient validation logs.

## Swift And Toolchain

- Before changing Swift source, Xcode targets or build settings, `.xcconfig` files, build scripts, or CI, read [`docs/en/design/toolchain.md`](docs/en/design/toolchain.md).
- The canonical baseline is Xcode 26.4 build 17E192, Apple Swift 6.3, Swift 6 language mode (`SWIFT_VERSION = 6.0`), complete strict concurrency, default nonisolated targets, and macOS 15.0 deployment.
- All first-party targets inherit the baseline from `Configurations/Base.xcconfig`. Do not introduce project- or target-level overrides that weaken or replace it.
- Do not change Xcode, Swift, language mode, strict concurrency, default actor isolation, deployment target, or supported architectures without synchronizing the toolchain document, build settings, toolchain checks, CI pins, architecture contracts, and tests.

## Architecture Boundaries

- The Host is the only owner of user configuration, Rule decisions, System Extension management, and `NEDNSProxyManager` writes.
- The System Extension owns one in-process AGDnsProxy runtime, flow handling, authenticated runtime control, and actual runtime evidence.
- Keep ordinary Profile switching on the authenticated single-engine reapply path. Do not reintroduce manager stop/start switching, dual-engine prepare/commit, shared-file IPC, or an independent DNS transport.
- Preserve exact-byte runtime identity, XPC Team-and-Bundle authentication, mutation-journal recovery, external-manager ownership checks, and confirmed System DNS restoration.

## UI And System-State Testing

- Do not perform UI operations or UI automation, including launching and operating the app, clicking, typing, dragging, handling authorization dialogs, or using XCUITest, Playwright, or browser-style automation, unless the user explicitly authorizes it for the current task.
- Do not infer authorization from an earlier task or session.
- By default, run builds, static checks, and non-UI unit tests only.
- Do not activate or deactivate the System Extension, enable or disable system DNS, mutate authorization state, or install signed candidates without explicit current-task authorization.
- When UI or signed runtime validation is not performed, state that clearly and list the remaining manual checks.

## Verification

- Keep changes focused and run the smallest relevant checks first.
- For Swift or build-system changes, run `scripts/ci/all.sh` when feasible.
- Never weaken type checking, concurrency checking, security requirements, signing checks, recovery behavior, or tests to make validation pass.
- Never commit certificates, provisioning profiles, signing identities, Team IDs, private Bundle IDs, credentials, real SSIDs, DNS query data, endpoint tokens, or raw diagnostic exports.
