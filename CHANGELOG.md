# Changelog

All notable changes to DNSPilot are documented in this file. The format follows Keep a Changelog, and releases use semantic versioning once the first public version is tagged.

## Unreleased

### Added

- Apache-2.0 open-source packaging and public project policies.
- Release-optimized `DNSPilot Community` build configuration with local identity injection.

### Changed

- Profile creation, duplication, editing, and deletion are available in every build.
- Build identities are supplied outside Git and derived consistently for Host, System Extension, App Group, Mach service, and XPC authentication.

### Security

- Public examples and tests use synthetic Team and Bundle identifiers.

### Compliance

- AGDnsProxy attribution and artifact provenance are documented; application binary redistribution requires completion of the artifact-level transitive notice inventory.
