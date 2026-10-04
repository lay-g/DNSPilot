# Changelog

All notable changes to DNSPilot are documented in this file. The format follows Keep a Changelog, and releases use semantic versioning once the first public version is tagged.

## [1.6] - 2026-10-04

### Changed

- The Dock icon now appears while the management or Settings window is open and hides after the last window closes. Minimizing a window keeps the Dock icon available, and closing windows leaves the menu-bar controls and DNS Proxy running.
- Background and login launches start without a running Dock icon until a window is opened.

## [1.5] - 2026-10-03

### Changed

- Redesigned the management window with grouped layouts. Overview shows a status header and inline recovery notices, the sidebar keeps a persistent DNS Proxy status summary, Profiles show transport, Active, and Default markers with Upstream, Hosts, and Usage details, and Rules mark the Rule that matches the current network. Floating list controls use Liquid Glass on macOS 26 and a system material on earlier releases.
- Building now accepts Xcode 26.4 or later with Apple Swift 6.3 or later instead of requiring an exact Xcode build.

### Fixed

- Restoring DNS Proxy at launch after a safe Quit, including after a System Extension update, no longer waits for an upstream connectivity test. Configuration validation and exact runtime confirmation remain required.

## [1.4] - 2026-09-02

### Changed

- Automatic and Manual Profile switching now applies the selected configuration without waiting for an upstream connectivity test. Configuration validation and exact runtime confirmation remain required.

### Fixed

- Profile switching now tolerates short-lived DNS Proxy Extension runtime-status response delays before failing.

## [1.3] - 2026-08-28

### Added

- Leftmost wildcard (`*.`) Profile hosts entries covering the base domain and every subdomain, with IPv4 and IPv6 addresses.

### Changed

- Same-family Profile hosts entries whose coverage overlaps a wildcard entry are now rejected to keep overrides unambiguous.

## [1.2] - 2026-08-21

### Added

- Profile hosts overrides for exact domain-to-address mappings, including IPv4 and IPv6 entries.

### Changed

- Profile hosts are validated, stored, and applied consistently during active DNS runtime changes and Profile testing without requiring a separate DNS transport.


### Added

- Configurable DNS response caching with an enable switch and capacity control in General Settings.
- A dedicated DNS Test workspace for querying Profiles or temporary Plain DNS, DNS over TLS, and DNS over HTTPS servers across common record types.

### Changed

- Profile tests now show clearer localized success and failure results beside the initiating action.
- Compatible System Extension upgrades preserve the confirmed DNS Proxy intent through a safe restore and resume flow.
- The DNS Proxy System Extension now carries the DNSPilot app icon.

### Fixed

- DNS Test uses a draggable, compressible split layout that preserves the divider position across query states and compact window sizes.
- Release-configured unit tests are isolated from production preferences, configuration, Launch at Login registration, and Network Extension state.

## [1.0] - 2026-08-01

### Added

- Native macOS DNS Proxy management for Plain DNS, DNS over TLS, and DNS over HTTPS Profiles.
- Manual Profile selection and ordered automatic Rules based on Wi-Fi SSID, interface type, and subnet.
- Management window, Settings window, menu-bar controls, Profile testing, and diagnostic export.
- Apache-2.0 open-source packaging and public project policies.
- Release-optimized `DNSPilot Community` build configuration with local identity injection.

### Changed

- Profile creation, duplication, editing, and deletion are available in every build.
- Build identities are supplied outside Git and derived consistently for Host, System Extension, App Group, Mach service, and XPC authentication.
- Normal Quit restores System DNS, while a confirmed active DNS Proxy can be safely restored on the next launch.

### Security

- Public examples and tests use synthetic Team and Bundle identifiers.

### Compliance

- AGDnsProxy attribution and artifact provenance are documented; application binary redistribution requires completion of the artifact-level transitive notice inventory.
