# App Store Metadata

[中文](../../zh/app-store/metadata.md)

This document contains copy-ready metadata for the first Mac App Store release. Replace every bracketed value before submission.

## App Information

- Name: `DNSPilot`
- Subtitle: `DNS Profiles for Every Network`
- Primary category: `Utilities`
- Secondary category: `Developer Tools`
- Content rights: DNSPilot contains third-party content and has the necessary rights to use it. Confirm this answer only after the binary-release compliance gate is closed.
- Custom license agreement: None. Use Apple's standard Licensed Application End User License Agreement.
- Copyright: `[YEAR] [LEGAL NAME]`

## URLs

- Support URL: `https://github.com/lay-g/DNSPilot/blob/main/SUPPORT.md`
- Privacy Policy URL: `https://github.com/lay-g/DNSPilot/blob/main/PRIVACY.md`
- Marketing URL: `https://github.com/lay-g/DNSPilot`

Keep the repository public and verify these URLs without authentication before submission.

## Promotional Text

Switch between plain DNS and DNS over HTTPS Profiles from the menu bar, or let DNSPilot select one automatically for the network you are using.

## Description

DNSPilot is a native macOS utility for managing the DNS resolver used by your Mac.

Create Profiles for plain DNS or DNS over HTTPS, test them before use, and switch between them from the app or menu bar. Automatic mode can select a Profile using ordered Rules based on the current Wi-Fi name, active interface type, or IPv4 and IPv6 subnet. Manual mode keeps your chosen Profile active until you return to Automatic.

DNSPilot keeps its configuration on your Mac and does not require an account. Location access is optional and is used only to read the current Wi-Fi name for SSID Rules. Interface and subnet Rules continue to work without Location access.

Features:

- Plain DNS over UDP with TCP fallback
- DNS over HTTPS using DNS wire format
- Ordered Rules with a Default Profile fallback
- Automatic and Manual operating modes
- Menu bar controls and clear active-state reporting
- Profile preflight testing
- Explicit System DNS restoration and diagnostics

DNS queries are sent to the resolver selected in the active Profile. Resolver operators and network providers process that traffic under their own terms and privacy policies.

Requires macOS 15 or later.

## Keywords

`DoH,resolver,encrypted DNS,network,Wi-Fi,SSID,privacy,menu bar,automatic,profile`

## First-Release Summary

Initial release of DNSPilot with plain DNS and DNS over HTTPS Profiles, network-based automatic Rules, menu bar controls, Profile testing, diagnostics, and confirmed System DNS restoration.

App Store Connect does not provide the What's New field for an app's first version. Reuse this summary only where a first-release summary is requested; do not try to enter it as What's New for version 1.0.

## App Privacy Draft

Provisional App Store Connect answer: `Data Not Collected` by the developer.

Confirm this answer against the final signed binary and Apple's current definitions immediately before submission. In particular, confirm that the selected resolver is not treated as a developer-controlled third-party partner. DNSPilot itself has no account system, analytics, advertising, telemetry, crash-reporting SDK, or developer-operated backend. DNS traffic is necessarily transmitted to the resolver selected by the user, and optional diagnostic export remains under explicit user control.

## Submission Checklist

- Replace `[YEAR] [LEGAL NAME]` with the App Store Connect seller's legal copyright holder.
- Confirm that the Support URL exposes a general support email, legal address, or telephone number where required by local law. The public issue tracker alone may not satisfy every storefront.
- Confirm final pricing and availability.
- Confirm the third-party content-rights answer after license review.
- Recheck the App Privacy answer against the archived binary.
- Complete export-compliance answers for the final binary's encryption use.
- Upload screenshots showing the actual app in use; do not use placeholders or development-only acceptance controls.
