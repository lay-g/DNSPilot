# Contributing to DNSPilot

DNSPilot develops in public. Use issues for reproducible bugs and focused proposals, and send changes through pull requests.

## Development Baseline

Read `AGENTS.md` and `docs/en/design/toolchain.md` before changing Swift, Xcode settings, build scripts, or CI. DNSPilot uses macOS 15, Swift 6 language mode, complete strict concurrency, default nonisolated targets, and Xcode 26.4 build 17E192.

Use the `DNSPilot Community` scheme and a local ignored identity file. Never commit certificates, provisioning profiles, App Store credentials, Team IDs, personal Bundle IDs, SSIDs, DNS query names, endpoint tokens, raw diagnostic exports, or private logs.

## Pull Requests

- Keep changes focused and preserve existing ownership boundaries.
- Add tests proportional to behavior and risk.
- Run `scripts/ci/all.sh` for code or build changes.
- Update `CHANGELOG.md` for user-visible changes.
- Document manual or signed validation that was not performed.
- Keep `docs/en/` and `docs/zh/` synchronized when a documented contract changes.
- Do not weaken XPC Team+Bundle requirements, journal recovery, DNS restoration, or strict concurrency to make a check pass.

UI and system authorization work requires explicit human operation on an appropriate signed test machine. Public CI must not activate a System Extension, change system DNS, open authorization dialogs, or collect real network identifiers.

## Contribution License

Unless explicitly marked otherwise, contributions submitted for inclusion are provided under Apache License 2.0 under Section 5 of that license. DNSPilot does not currently require a separate contributor license agreement.

Participation is governed by `CODE_OF_CONDUCT.md`.
