# App Store Metadata

[中文](../../zh/app-store/metadata.md)

This document contains copy-ready metadata for Mac App Store releases. Replace every bracketed value before submission.

## App Information

- Name: `DNSPilot`
- Subtitle: `DNS Profiles for Every Network`
- Primary category: `Utilities`
- Secondary category: `Developer Tools`
- Content rights: `No`. DNSPilot does not contain, show, or access third-party content. Open-source software dependencies remain subject to the separate binary-release license-compliance gate.
- Custom license agreement: None. Use Apple's standard Licensed Application End User License Agreement.
- Copyright: `[YEAR] [LEGAL NAME]`

## URLs

- Support URL: `https://github.com/lay-g/DNSPilot/blob/main/SUPPORT.md`
- Privacy Policy URL: `https://github.com/lay-g/DNSPilot/blob/main/PRIVACY.md`
- Marketing URL: `https://github.com/lay-g/DNSPilot`

Keep the repository public and verify these URLs without authentication before submission.

## Promotional Text

Create and test Plain DNS, DNS over TLS, and DNS over HTTPS Profiles, then switch from the menu bar or let network Rules choose automatically.

## Description

DNSPilot is a native macOS utility for managing the DNS resolver used by your Mac.

Create, duplicate, edit, and test Profiles for Plain DNS, DNS over TLS, or DNS over HTTPS, then switch between them from the app or menu bar. Automatic mode can select a Profile using ordered Rules based on the current Wi-Fi name, active interface type, or IPv4 and IPv6 subnet. Manual mode keeps your chosen Profile active until you return to Automatic.

DNSPilot keeps its configuration on your Mac and does not require an account. Location access is optional and is used only to read the current Wi-Fi name for SSID Rules. Interface and subnet Rules continue to work without Location access.

Features:

- Plain DNS over UDP with TCP fallback
- DNS over TLS with certificate validation
- DNS over HTTPS using DNS wire format
- Ordered Rules with a Default Profile fallback
- Automatic and Manual operating modes
- Menu bar controls and clear active-state reporting
- Profile preflight testing
- Explicit System DNS restoration and diagnostics

DNS queries are sent to the resolver selected in the active Profile. Resolver operators and network providers process that traffic under their own terms and privacy policies.

Requires macOS 15 or later.

## Keywords

`DoH,DoT,resolver,encrypted DNS,network,Wi-Fi,SSID,privacy,menu bar,automatic,profile`

## First-Release Summary

Initial release of DNSPilot with Plain DNS, DNS over TLS, and DNS over HTTPS Profiles, network-based automatic Rules, menu bar controls, Profile testing, diagnostics, and confirmed System DNS restoration.

App Store Connect does not provide the What's New field for an app's first version. Reuse this summary only where a first-release summary is requested; do not try to enter it as What's New for version 1.0.

## Version 1.1 What's New

Adds configurable DNS caching and a dedicated DNS query tester for Profiles and temporary Plain DNS, DNS over TLS, and DNS over HTTPS servers. Improves Profile test feedback, compatible System Extension upgrades, and compact-window layouts.

## App Privacy Draft

Provisional App Store Connect answer: `Data Not Collected` by the developer.

Confirm this answer against the final signed binary and Apple's current definitions immediately before submission. In particular, confirm that the selected resolver is not treated as a developer-controlled third-party partner. DNSPilot itself has no account system, analytics, advertising, telemetry, crash-reporting SDK, or developer-operated backend. DNS traffic is necessarily transmitted to the resolver selected by the user, and optional diagnostic export remains under explicit user control.

## Submission Checklist

- Replace `[YEAR] [LEGAL NAME]` with the App Store Connect seller's legal copyright holder.
- Confirm that the Support URL exposes a general support email, legal address, or telephone number where required by local law. The public issue tracker alone may not satisfy every storefront.
- Confirm final pricing and availability.
- Complete the open-source binary license and notice review before distribution.
- Recheck the App Privacy answer against the archived binary.
- Complete export-compliance answers for the final binary's encryption use.
- Upload screenshots showing the actual app in use; do not use placeholders or development-only acceptance controls.
