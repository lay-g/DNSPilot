# Changelog

All notable changes to DNSPilot are documented in this file. The format follows Keep a Changelog, and releases use semantic versioning once the first public version is tagged.

## Unreleased

## [1.1] - 2026-08-03

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
