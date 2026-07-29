# DNSPilot

English | [简体中文](README.zh-CN.md)

DNSPilot is a native macOS DNS Proxy utility for managing Plain DNS and DNS-over-HTTPS Profiles. Profiles can be selected manually or automatically through ordered Wi-Fi SSID, interface-type, and subnet Rules.

## Features

- Plain DNS over UDP with TCP fallback and native TCP flow support.
- DNS over HTTPS with explicit bootstrap addresses.
- Automatic Profile selection from ordered network Rules.
- Persistent Manual mode and a user-selected Default Profile.
- Native management window, Settings window, and menu-bar controls.
- Exact runtime identity, authenticated Host/Extension IPC, and bounded DNS restoration.
- No accounts, subscriptions, in-app purchases, receipt checks, license keys, or Profile limits.

Official and source-built distributions provide the same product capabilities and configuration format.

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
- [Release requirements](docs/en/releasing.md)

## Privacy

DNSPilot has no project-operated account, analytics, or telemetry service. DNS queries are sent to the resolver selected by the user. Location permission is used only to obtain the current Wi-Fi name for SSID Rules. Debug Logging and explicit diagnostic exports can contain sensitive DNS and network details. Read [PRIVACY.md](PRIVACY.md) before sharing logs.

## Limitations

- DNSPilot does not detect, control, or repair VPN DNS precedence.
- A VPN, another DNS Proxy, Fake-IP service, or scoped resolver can prevent DNSPilot from observing all DNS traffic.
- Normal Quit attempts to restore System DNS; crash or Force Quit cannot guarantee cleanup.
- AGDnsProxy is a pinned prebuilt dependency governed by [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
- Application binary redistribution is blocked until the [AGDnsProxy transitive inventory](docs/en/compliance/agdnproxy-v2.8.45.md) is complete.

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
