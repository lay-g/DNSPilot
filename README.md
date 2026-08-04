# DNSPilot

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

English | [简体中文](README.zh-CN.md)

[Official website](https://dnspilot.lay-g.com) | [Download DNSPilot on the App Store](https://apps.apple.com/us/app/dnspilot/id6793036211)

DNSPilot is a native macOS DNS Proxy utility for managing Plain DNS and DNS-over-HTTPS Profiles. Profiles can be selected manually or automatically through ordered Wi-Fi SSID, interface-type, and subnet Rules.

## Features

- Plain DNS over UDP with TCP fallback and native TCP flow support.
- DNS over HTTPS with explicit bootstrap addresses.
- Automatic Profile selection from ordered network Rules.
- Persistent Manual mode and a user-selected Default Profile.
- Native management window, Settings window, and menu-bar controls.
- Exact runtime identity, authenticated Host/Extension IPC, and bounded DNS restoration.

## Requirements

- macOS 15 or later.
- Xcode 26.4 build 17E192 with Apple Swift 6.3.
- For signed installation, an Apple Developer Team authorized for the `dns-proxy` Network Extension entitlement.
- Team-owned Host, System Extension, and App Group identifiers.

Apple controls entitlement approval. The Apache-2.0 license does not grant signing credentials, provisioning profiles, entitlements, official branding, or store distribution rights.

## Community Build

```bash
cp Configurations/Identity.local.xcconfig.example \
   Configurations/Identity.local.xcconfig
```

Set `IDENTITY_TEAM_IDENTIFIER` and `IDENTITY_BUNDLE_ID_PREFIX` to values owned by your Team, configure matching Apple identifiers and provisioning, then use the `DNSPilot Community` scheme.

The local identity file is ignored by Git. Unsigned builds can compile and run non-UI tests but cannot prove System Extension installation, XPC authentication, authorization, or DNS behavior.

See [Building](docs/en/building.md) for commands and identity derivation.

## Documentation

- [English documentation](docs/en/README.md)
- [中文文档](docs/zh/README.md)
- [Product design](docs/en/design/product.md)
- [System architecture](docs/en/design/architecture.md)
- [Runtime design](docs/en/design/runtime.md)
- [Toolchain baseline](docs/en/design/toolchain.md)
- [Testing strategy](docs/en/design/testing.md)

## Privacy

Configuration and Rule data remain on the Mac. DNS queries are sent to the resolver selected by the user. Location permission provides the current Wi-Fi name for SSID Rules. Debug Logging and explicit diagnostic exports can contain sensitive DNS and network details. Read [PRIVACY.md](PRIVACY.md) before sharing logs.

## Runtime And Dependencies

DNSPilot processes the DNS flows supplied by the macOS DNS Proxy subsystem. Normal Quit attempts to restore System DNS. After an interrupted exit, the system-managed DNS Proxy may remain enabled until the next launch reconciles persisted state or the user restores System DNS. DNS transport uses the pinned AGDnsProxy dependency documented in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Its artifact-level transitive notice inventory is currently incomplete, so application binary redistribution requires completion of the [compliance inventory](docs/en/compliance/agdnproxy-v2.8.45.md).

## Development

```bash
export DEVELOPER_DIR="/Applications/Xcode-26.4.0.app/Contents/Developer"
scripts/ci/all.sh
```

This runs repository checks, serial non-UI tests, static analysis, and an unsigned universal Community build. UI or signed system-state testing requires explicit authorization and suitable provisioning.

## Policies

- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [Privacy](PRIVACY.md)
- [Support](SUPPORT.md)
- [Branding](BRANDING.md)
- [Third-party notices](THIRD-PARTY-NOTICES.md)
- [Changelog](CHANGELOG.md)

DNSPilot source code is licensed under Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
