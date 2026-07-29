# Product Design

[中文](../../zh/design/product.md)

## Purpose

DNSPilot is a menu-bar-first macOS utility that forwards system DNS traffic through a DNS Proxy System Extension. It lets users create DNS Profiles and select them manually or automatically from the current network context.

## Supported Behavior

- Plain DNS over UDP with TCP fallback and native TCP DNS flow support.
- DNS over HTTPS using DNS wire format.
- Ordered automatic Rules based on Wi-Fi SSID, active interface type, and IPv4 or IPv6 subnet.
- First matching enabled Rule wins; a user-selected Default Profile is the fallback.
- Manual selection persists until the user explicitly returns to Automatic mode.
- Closing the management window keeps the app and DNS Proxy running.
- Normal Quit attempts to disable the DNS Proxy and restore System DNS.
- The UI distinguishes Target Profile, confirmed Active Profile, operating mode, network context, System Extension state, and DNS Proxy state.

Official and source-built distributions expose the same capabilities and configuration format. DNSPilot has no subscription, in-app purchase, account, receipt check, license key, Profile quota, or paid feature gate.

## Platform Boundary

DNSPilot requires macOS 15 or later. Signed installation requires an Apple Developer Team authorized for the `dns-proxy` Network Extension entitlement. Source licensing does not provide certificates, provisioning profiles, entitlements, official identifiers, or App Store distribution rights.

The product does not claim to intercept DNS already controlled by a VPN, another DNS Proxy, Fake-IP service, or scoped resolver. It does not detect or repair VPN DNS precedence.

## Excluded Scope

- DNS over TLS, DNSCrypt, DNS over QUIC, or custom DNS JSON APIs.
- Query history, statistics, cache controls, filtering, or DNSSEC controls.
- Multi-upstream failover, load balancing, domain routing, or app routing.
- VPN control, captive-portal automation, hosts, routes, or system proxy editing.
- Accounts, cloud synchronization, configuration import/export, or an independent updater.
- A hidden fallback resolver or silent substitution after an upstream failure.

## Distribution Principles

The source is Apache-2.0 licensed. Official builds may use protected names, icons, signing assets, identifiers, and store metadata, but those assets do not change product capability. A signed artifact necessarily exposes its signing Team and Bundle identifiers.

Application binary distribution remains subject to the complete third-party notice and release requirements in [Releasing](../releasing.md) and the [AGDnsProxy inventory](../compliance/agdnproxy-v2.8.45.md).
