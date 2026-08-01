# Building DNSPilot

[中文](../zh/building.md)

## Requirements

- macOS 15 or later.
- Xcode 26.4 build 17E192 with Apple Swift 6.3.
- For signed runtime use, an Apple Developer Team authorized for `dns-proxy`.

Read the [toolchain baseline](design/toolchain.md) before changing Swift, Xcode settings, build scripts, or CI.

## Identity Configuration

Create the ignored local file:

```bash
cp Configurations/Identity.local.xcconfig.example \
   Configurations/Identity.local.xcconfig
```

Set values owned by your Apple Developer Team:

```xcconfig
IDENTITY_TEAM_IDENTIFIER = ABCDE12345
IDENTITY_BUNDLE_ID_PREFIX = org.example
```

The build derives Host and System Extension Bundle IDs, App Group, versioned Mach service, test identifiers, and both XPC peer requirements. Do not commit this file.

| Configuration | Host suffix | Extension suffix | Purpose |
| --- | --- | --- | --- |
| DebugLocal | `.DNSPilot.dev` | `.DNSPilot.dev.DNSProxy` | Local diagnostics and failure controls |
| Community | `.DNSPilot` | `.DNSPilot.DNSPilot-NE` | Source builds and public CI |
| Sandbox | `.DNSPilot` | `.DNSPilot.DNSPilot-NE` | Store sandbox validation |
| Release | `.DNSPilot` | `.DNSPilot.DNSPilot-NE` | Distribution candidate |

Certificates remain in Keychain or protected CI. Provisioning profiles and store credentials are never committed.

## Versioning

`Configurations/Version.xcconfig` is the single source of truth for `MARKETING_VERSION` and the repository-default `CURRENT_PROJECT_VERSION`. All first-party targets and configurations inherit these values through `Configurations/Base.xcconfig`; do not add target-level overrides in the Xcode project. Release automation may override `CURRENT_PROJECT_VERSION` on the `xcodebuild` command line with a monotonically increasing build number.

## Community Validation

```bash
export DEVELOPER_DIR="/Applications/Xcode-26.4.0.app/Contents/Developer"
scripts/check-toolchain.sh
scripts/ci/all.sh
```

The CI entry point runs repository policy checks, serial non-UI tests, static analysis, and an unsigned universal Community build.

To inspect derived identity without signing:

```bash
xcodebuild -project DNSPilot.xcodeproj \
  -scheme "DNSPilot Community" \
  -configuration Community \
  -showBuildSettings \
  IDENTITY_TEAM_IDENTIFIER=ABCDE12345 \
  IDENTITY_BUNDLE_ID_PREFIX=org.example \
  CODE_SIGNING_ALLOWED=NO
```

Command-line build settings override xcconfig values and are suitable for CI secrets. A signed build additionally requires matching Host, Extension, App Group, and `dns-proxy` provisioning.

## Signed Builds

Use the same scheme without disabling signing only after provisioning is complete. Before changing system state, inspect Host, embedded Extension, both AGDnsProxy copies, entitlements, designated requirements, Bundle IDs, build numbers, and architectures. Install runtime acceptance candidates from `/Applications`.

Unsigned builds and tests do not prove installation, XPC authentication, authorization, or DNS behavior.
