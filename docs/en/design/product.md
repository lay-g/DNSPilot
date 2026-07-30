# Product Design

[中文](../../zh/design/product.md)

## Purpose

DNSPilot is a menu-bar-first macOS utility that forwards system DNS traffic through a DNS Proxy System Extension. It lets users create DNS Profiles and select them manually or automatically from the current network context.

## Supported Behavior

- Plain DNS over UDP with TCP fallback and native TCP DNS flow support.
- DNS over TLS with certificate validation and bootstrap resolution owned by DnsLibs.
- DNS over HTTPS using DNS wire format.
- Ordered automatic Rules based on Wi-Fi SSID, active interface type, and IPv4 or IPv6 subnet.
- First matching enabled Rule wins; a user-selected Default Profile is the fallback.
- Manual selection persists until the user explicitly returns to Automatic mode.
- Closing the management window keeps the app running and preserves the current DNS Proxy state.
- Normal Quit attempts to disable the DNS Proxy and restore System DNS.
- The UI distinguishes Target Profile, confirmed Active Profile, operating mode, network context, System Extension state, and DNS Proxy state.

## Platform Boundary

DNSPilot requires macOS 15 or later. Signed installation requires an Apple Developer Team authorized for the `dns-proxy` Network Extension entitlement. Source licensing does not provide certificates, provisioning profiles, entitlements, official identifiers, or App Store distribution rights.

## License And Build Identity

The source is Apache-2.0 licensed. Build identity is supplied outside Git and consistently derives the Host, System Extension, App Group, Mach service, and XPC peer requirements. A signed artifact exposes its signing Team and Bundle identifiers.
