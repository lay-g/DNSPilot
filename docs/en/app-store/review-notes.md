# App Review Notes

[中文](../../zh/app-store/review-notes.md)

Replace the bracketed build version before submission. The text below is intended for the App Review Information notes field.

## Copy-Ready Notes

DNSPilot `[VERSION] ([BUILD])` is a menu-bar macOS DNS configuration utility. It uses an embedded DNS Proxy System Extension implemented with Apple's NetworkExtension and SystemExtensions frameworks. There is no account, purchase, subscription, advertising, analytics, telemetry, or developer-operated backend.

The System Extension and DNS Proxy are installed and enabled only after separate explicit user actions during onboarding. macOS may require approval in System Settings. The app never asks for root credentials and does not install a separate application or updater.

Suggested review flow on macOS 15 or later:

1. Launch DNSPilot and continue to Profile setup.
2. Choose a built-in resolver or Custom, then use "Test and Continue." The test performs a DNS lookup through that resolver.
3. Continue without Location access, or allow it to test Wi-Fi-name Rules. Location is used only to read the current Wi-Fi SSID. Interface and subnet Rules work without it.
4. Select "Install" for the System Extension. If macOS shows approval-required state, approve DNSPilot in System Settings and return to the app.
5. Select "Enable DNS Proxy." Completion appears only after the extension confirms the active runtime configuration.
6. Use Profiles and Rules in the management window, or Automatic/Manual switching in the menu-bar menu.
7. Use "Restore System DNS" before removing or deactivating the extension. Choosing Quit from the menu also attempts confirmed System DNS restoration.

DNS traffic is sent directly to the resolver selected in the active Profile. App configuration and Rules remain local to the current macOS user. Debug Logging is off by default and displays a warning before it can be enabled. Diagnostic export is optional, requires confirmation, and writes only to a location selected by the user.

The app's Network Extension entitlement value for Mac App Store distribution is `dns-proxy`. The Host owns user configuration and `NEDNSProxyManager` writes; the System Extension owns DNS flow handling and one in-process AGDnsProxy runtime.

No review account or external hardware is required. Internet access is required to test public DNS resolvers. If System Extension approval does not appear or activation remains pending, please contact `[APP REVIEW CONTACT]` through the contact details supplied with this submission.

## Submission Checks

- Replace `[VERSION]`, `[BUILD]`, and `[APP REVIEW CONTACT]`.
- Verify the instructions against the exact uploaded build.
- Keep public DNS resolver services reachable during review.
- Attach supporting entitlement documentation only if App Review requests it.
- Do not mention development-only acceptance controls or unavailable features.
