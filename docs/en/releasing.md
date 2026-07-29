# Releasing DNSPilot

[中文](../zh/releasing.md)

## Source Release

1. Confirm the public tree contains no private Team, Bundle, certificate, account-path, credential, or diagnostic literals.
2. Run repository checks, Gitleaks over the current tree and reachable history, non-UI tests, analysis, and universal Community builds.
3. Verify the source tag, dependency revision, checksums, changelog, licenses, notices, privacy statements, and known limitations.
4. Create a signed source tag and publish source archives and checksums from the canonical public repository.

Source publication does not imply that an application binary is ready for redistribution.

## Binary Release Gate

Before publishing an app, archive, installer, or store build:

1. Complete the [AGDnsProxy transitive inventory](compliance/agdnproxy-v2.8.45.md) and bundle every required license and NOTICE text.
2. Build from a clean public-source checkout using protected signing inputs.
3. Verify Host, System Extension, nested frameworks, entitlements, provisioning, designated requirements, versions, and both architectures.
4. Strip and inspect the distributed archive, dSYMs, Info.plists, entitlements, and binaries for private development paths or identities.
5. Complete signed clean-machine validation for installation, approval, XPC, DNS, switching, sleep/wake, recovery, update, and normal Quit.
6. Verify privacy manifests and encryption/export declarations.
7. Ensure the artifact maps exactly to the public source commit and publish checksums, notices, limitations, and rollback guidance.

Pull-request CI and fork builds never receive official signing or store credentials. Official release credentials are used only in a protected manual environment.

## Failure And Rollback

Do not hide an unresolved gate with a waiver in release copy. If artifact identity, signing, dependency provenance, notice completeness, runtime restoration, or source traceability cannot be proved, do not distribute the binary.

For a faulty published build, withdraw the artifact where possible, preserve the source tag and checksums for traceability, document affected versions, and direct users to a verified prior version or System DNS restoration procedure.
