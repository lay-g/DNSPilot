# System Architecture

[中文](../../zh/design/architecture.md)

## Executable Units

DNSPilot has two executable units:

```text
DNSPilot.app
  SwiftUI and MenuBarExtra
  ConfigurationStore and RuleEngine
  NetworkMonitor
  SystemExtensionController
  DNSProxyController and DNSProxyManagerClient
  MachXPCClient and UpstreamValidator

DNSPilot DNS Proxy System Extension
  NEDNSProxyProvider
  MachXPCServer
  ProxyLifecycleController
  DNSProxyEngine
  AGDnsProxy and AGDnsAppProxyFlowManager
  RuntimeStatusStore
```

The Host owns user configuration, Location permission, network observation, Profile selection, System Extension management, every `NEDNSProxyManager` write, and user-visible state. The System Extension owns DNS flow handling, one in-process DNS runtime, authenticated runtime control, and actual runtime evidence.

## Ownership Layers

The system lifecycle layer is Host-owned. It performs initial enablement, Restore System DNS, normal Quit, Extension replacement, and bounded repair. Only this layer may write `NEDNSProxyManager`. Runtime quiesce and resume are lifecycle operations, not ordinary Profile switches.

The runtime switching layer is Extension-owned and reached through authenticated Mach XPC. It applies already-persisted desired bytes to the current Provider instance, performs single-engine rollback, controls flow admission during mutation, and publishes exact runtime identity.

## Sources Of Truth

| Fact | Owner | Persistence |
| --- | --- | --- |
| Profiles, Rules, Default Profile, mode | Host `AppConfiguration` | Durable |
| Desired runtime configuration | `NEDNSProxyManager.providerConfiguration` | Durable |
| Actual runtime and last confirmed bytes | `ProxyLifecycleController` | Process-local |
| Runtime phase and evidence | `RuntimeStatusStore` | Process-local |
| Profile mutation compensation | Host mutation journal | Durable, recovery-only |
| Extension installation and approval | macOS | System-owned |

No layer may silently copy, replace, or infer another layer's source of truth.

## Communication Boundary

The Host and Extension use a build-identity-derived Mach service as their sole communication channel. The App Group entitlement authorizes only the Mach service namespace. Host configuration remains in private Application Support storage, and runtime status remains process-local in the Extension.

The Extension receives one immutable `ActiveProxyConfiguration` containing schema version, generation and Profile identity, upstream configuration, and runtime logging mode.

## Dependency Boundary

`AGDnsProxy` is the only DNS transport engine. DNSPilot maps configuration, passes Network Extension flows to `AGDnsAppProxyFlowManager`, bridges events and logs, and manages runtime identity. DNS wire parsing, request IDs, UDP/TCP exchange, truncation fallback, DoH, bootstrap, TLS, HTTP connection reuse, cancellation, and transport cleanup remain inside DnsLibs.

The Host uses the same pure upstream mapping through `AGDnsUtils.testUpstream` for preflight. Runtime and preflight DNS transport are both implemented through DnsLibs.

## Session Boundary

Only the active desktop login session may initiate automatic switching. When its GUI session resigns active, the Host stops network-driven decisions. On reactivation it obtains a fresh network context before resuming Automatic mode.
