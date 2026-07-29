# Security Policy

## Supported Versions

DNSPilot is alpha software. Security fixes are applied to the current public development branch; no released version is currently covered by a long-term support commitment.

## Reporting a Vulnerability

Use the repository host's private Security Advisory channel. Do not open a public issue for a suspected vulnerability. If private advisories are unavailable, use the private contact method listed on the repository owner's public profile. A dedicated security contact must be configured before the repository is made public.

Include the affected revision, macOS version, build source, impact, and minimal reproduction. Do not send real DNS queries, SSIDs, IP addresses, endpoint tokens, certificates, provisioning profiles, signing credentials, raw packet captures, or unredacted diagnostic exports unless the maintainer explicitly provides a secure transfer method.

The initial response target is seven days. Confirmation, remediation, and disclosure timing depend on severity and the need to coordinate with Apple or an upstream dependency.

## Security Boundaries

Reports involving System Extension lifecycle, DNS restoration, XPC authentication, configuration/journal integrity, privacy-sensitive logging, or dependency integrity are in scope. Apple entitlement approval, third-party resolver operation, and unsupported local modifications are outside project control, but integration defects may still be valid reports.
