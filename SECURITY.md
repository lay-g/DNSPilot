# Security Policy

## Supported Versions

Security fixes are applied to the current public development branch.

## Reporting a Vulnerability

Use the repository host's private Security Advisory channel or email [security@lay-g.com](mailto:security@lay-g.com). Do not open a public issue for a suspected vulnerability.

Include the affected revision, macOS version, build source, impact, and minimal reproduction. Do not send real DNS queries, SSIDs, IP addresses, endpoint tokens, certificates, provisioning profiles, signing credentials, raw packet captures, or unredacted diagnostic exports unless the maintainer explicitly provides a secure transfer method.

The initial response target is seven days. Confirmation, remediation, and disclosure timing depend on severity and the need to coordinate with Apple or an upstream dependency.

## Security Boundaries

Reports involving System Extension lifecycle, DNS restoration, XPC authentication, configuration/journal integrity, privacy-sensitive logging, dependency integrity, and DNSPilot's third-party integrations are in scope. Apple manages entitlement approval, and resolver operators remain responsible for their services.
