# Changelog

All notable changes to DNSPilot are documented in this file. The format follows Keep a Changelog, and releases use semantic versioning once the first public version is tagged.

## Unreleased

### Added

- Apache-2.0 open-source packaging and public project policies.
- Release-optimized `DNSPilot Community` build configuration with local identity injection.

### Changed

- Profile creation, duplication, editing, and deletion no longer use entitlement or purchase state.
- Build identities are supplied outside Git and derived consistently for Host, System Extension, App Group, Mach service, and XPC authentication.

### Removed

- Unshipped StoreKit product setting, Profile quota, entitlement revision, and Free-plan messaging.

### Security

- Public examples and tests use synthetic Team and Bundle identifiers.

### Known Limitations

- AGDnsProxy's artifact-level transitive license inventory remains incomplete, so application binary redistribution is blocked pending review.
