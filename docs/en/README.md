# DNSPilot Documentation

[中文文档](../zh/README.md)

These documents describe the implemented product and its enduring engineering contracts.

## Design

- [Product](design/product.md): supported behavior, platform requirements, license, and build identity.
- [System Architecture](design/architecture.md): process boundaries, ownership, and sources of truth.
- [Data Model](design/data-model.md): Profiles, Rules, network context, storage, and mutation recovery.
- [Runtime](design/runtime.md): DNS engine lifecycle, switching, restoration, and failure semantics.
- [Security and IPC](design/security.md): signing identity, Mach XPC, payload, replay, and privacy boundaries.
- [User Interface](design/user-interface.md): windows, menu bar, onboarding, state language, Quit, and accessibility.
- [Toolchain](design/toolchain.md): canonical Xcode, Swift, deployment, and concurrency baseline.
- [Testing](design/testing.md): automated, integration, signed-runtime, and manual verification boundaries.

## Development And Compliance

- [Building](building.md)
- [AGDnsProxy 2.8.45 compliance inventory](compliance/agdnproxy-v2.8.45.md)
- [App Store metadata](app-store/metadata.md)
- [App Review notes](app-store/review-notes.md)
- [Support](../../SUPPORT.md)
- [Privacy Policy](../../PRIVACY.md)

When documents conflict, the narrower design contract takes precedence. Build settings in `Configurations/Base.xcconfig` must remain consistent with the toolchain document.
