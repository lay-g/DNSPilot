# User Interface Design

[中文](../../zh/design/user-interface.md)

## Product Shape

DNSPilot is a quiet, native macOS utility with one management window, one standard Settings window, and a persistent menu-bar menu. Closing the window leaves the app running and preserves the current DNS Proxy state.

The management window uses a two-column navigation split view with Overview, Profiles, and Rules. Settings contains General, Privacy, Diagnostics, and About. Use native lists, forms, sheets, alerts, menus, segmented controls, toggles, system typography, semantic colors, and SF Symbols. Color never carries status alone.

## State Language

The UI presents observable runtime states: `DNS Proxy On`, `DNS Proxy Off`, `Preparing`, `Applying`, `Restoring System DNS`, `Recovery Required`, and `Error`.

System Extension installation and DNS Proxy enablement are separate states. Stable state shows one Active Profile. Switching or failure may show both Target and confirmed Active Profile. Unknown ownership or runtime identity is always recovery-required.

## Overview

Overview presents DNS Proxy state and control, Automatic/Manual mode, Target and Active Profiles, selection source, current network, Profile testing, diagnostics access, and recovery actions.

After safe Quit, startup resume may show `Waiting for System Extension`, `Waiting for Network`, or `Restoring DNS Proxy`. The menu continues to report `DNS Proxy Off` until exact Active proof exists. A failed or blocked attempt offers `Retry` and `Keep System DNS`; it never retries continuously in the background.

Selecting Manual persists the requested Profile while preserving the current Proxy On/Off state. A failed switch preserves Target and confirmed Active, with Retry and `Use Active Profile (Manual)` actions. Returning to Automatic immediately evaluates the latest valid network context.

## Profiles And Rules

Profile and Rule editors use staged drafts. Only Save commits domain configuration. Validation focuses the first invalid field. Editing an Active Profile uses the journaled runtime/configuration transaction and publishes the draft as Active after exact verification.

Profiles expose create, edit, duplicate, test, make-default, replacement, and delete workflows. Custom Profile editors support Plain DNS, DNS over TLS, and DNS over HTTPS. DoT input contains server name or address, port, and bootstrap addresses. List identity uses privacy-safe DoT and DoH server summaries.

Rules show enabled state, priority, condition summary, and target Profile. Reordering saves once and reevaluates once. Dragging has Move Up/Move Down keyboard alternatives. The Default Profile selector remains visible and cannot be empty while the Proxy is usable.

## Onboarding

Setup is a dedicated workflow:

1. Explain DNS takeover and restoration behavior.
2. Create a Profile from an explicit template choice or custom input and require successful preflight.
3. Explain optional Location access for SSID Rules.
4. Install the System Extension after an explicit command.
5. Enable the DNS Proxy after another explicit command.
6. Show completion only after exact Active runtime confirmation.

Permission denial affects only SSID Rules. Approval-required state offers System Settings and recheck actions. Interrupted setup preserves committed configuration, and completion requires exact Active runtime confirmation.

## Menu Bar And Commands

The menu bar shows Proxy state, Active or Target Profile, mode, and network summary. It offers Automatic, Manual Profile selection, Open DNSPilot, Settings, Turn On or Restore System DNS, and Quit. Commands call shared application intents rather than implementing separate logic.

Standard shortcuts include `Command-1/2/3` for main sections, `Command-,` for Settings, `Command-N` for a Profile, `Shift-Command-N` for a Rule, and `Command-W` to close a window.

## Quit

Keyboard Quit requires two independent `Command-Q` presses within two seconds. Auto-repeat is ignored and a key-up is required between presses. The first press only displays a non-activating visual prompt and VoiceOver announcement. Timeout, Escape, or lost keyboard context disarms it.

An explicit menu click starts safe Quit immediately. Unsaved drafts require a separate discard confirmation. Confirmed Quit fences changes, restores System DNS within a bounded decision window, and exits only after proof. Failure offers Retry, Cancel Quit, and Quit Anyway with a warning that DNS Proxy may remain enabled.

If DNSPilot cannot durably prepare the next-launch resume record, Quit leaves the current runtime unchanged and offers Retry, Quit Without Auto-Restore, and Cancel Quit. Choosing the opt-out path discards the incomplete resume intent before using the normal safe System DNS restoration path.

## Privacy And Diagnostics

Location is requested contextually for Wi-Fi SSID. Debug Logging displays a persistent sensitive-data warning. Diagnostic export requires confirmation. About shows version, build, license, source, privacy, support, third-party notices, and build origin.

Operational failures identify the attempted action, the most specific stable failure category available, the confirmed resulting state, and a relevant recovery action. Generic titles such as `Operation Failed` are not used. If a dependency exposes only an unstructured error, the UI states which dependency stage failed and that the cause is unclassified instead of guessing a more specific cause. Alerts, status labels, tooltips, and reduced diagnostic summaries never expose raw underlying error chains; full details are recorded through the logging boundary. Field-level validation remains specific so users can correct input.

## Accessibility And Layout

Core workflows must support keyboard-only operation and VoiceOver. Icon-only controls need labels and tooltips. Lists expose coherent accessibility values. Primary commands must not truncate. Long names, IPv6 addresses, URLs, and error codes may wrap or use middle truncation while copy preserves full values.

Reduced Motion, Increased Contrast, Reduced Transparency, long localization, and the minimum `760 x 520 pt` management window must preserve hierarchy, focus, and operability without overlap.
