# Runtime Design

[中文](../../zh/design/runtime.md)

## Runtime Identity

Each desired runtime is represented by one decoded `ActiveProxyConfiguration`, its exact binary property-list bytes, and the SHA-256 fingerprint of those bytes. The configuration contains schema version, generation UUID, Profile UUID, upstream, and logging mode.

Encoding occurs once per generation. Manager persistence, XPC mutation, runtime application, rollback, and final verification use the same bytes. Generation and fingerprint are independent identity dimensions.

A runtime is confirmed only when Provider instance, generation, fingerprint, `.ready` phase, compatible control protocol, and final manager ownership reload all agree.

Active Proxy schema capability is transport-specific: DoH requires schema 1, Plain DNS requires schema 2, and DoT requires schema 3. The Host discovers authenticated Provider capability before encoding transports newer than schema 1 and never sends an unsupported upstream discriminator. Capability mismatch fails before preflight or manager mutation.

## Single-Engine Lifecycle

The Provider process owns exactly one `AGDnsProxy` and one `AGDnsAppProxyFlowManager`.

- Startup decodes and validates exact manager bytes, publishes `.starting`, creates the engine, then publishes exact `.ready` identity.
- UDP and TCP flows pass directly to the flow manager in redirect mode.
- The Provider-wide active local-flow limit is 256.
- Flow admission, start, reapply, quiesce, resume, and stop are linearized by one lifecycle ownership boundary.
- Teardown stops the flow manager before the proxy, clears event routing, and is idempotent.
- Quiescence retains the exact stopped generation and configuration for lifecycle resume.
- Resume is valid only from exact quiescence and recreates the engine from retained exact bytes.

Late callbacks from an old generation, lifecycle epoch, or Provider instance cannot update current status.

## Ordinary Profile Switching

An ordinary switch keeps `NEDNSProxyManager` enabled:

1. Confirm manager ownership, exact desired bytes, Active Profile, Provider instance, runtime identity, `.ready` phase, and runtime-control compatibility.
2. Preflight the target upstream.
3. Create a fresh generation and operation ID; encode the target once.
4. Compare-and-save exact target bytes into the enabled manager.
5. Reload and verify enabled state, owner, bytes, generation, and fingerprint.
6. Start the five-second runtime-application deadline.
7. If exact old runtime remains ready, send one identity-scoped reapply request. Any unexplained state becomes recovery-required.
8. The Provider blocks new flow admission, validates the base identity, and synchronously reapplies the target to the existing engine.
9. Publish target identity only after successful reapply.
10. The Host waits for exact target `.ready`, reloads manager ownership, and only then publishes the new Active Profile.

Only the latest distinct pending target is retained. Preference-save completion or a DnsLibs return value alone never proves success.

## Failure Semantics

- `applied`: target runtime identity was published. Host final verification is still required.
- `rejectedPreservingBase`: mutation was refused before change or exact old-configuration rollback succeeded. The response carries verified old bytes and identity.
- `unrecoverable`: target and rollback failed; the Provider synchronously stopped the runtime and published failure.
- `rejected`: pre-mutation refusal for malformed input, stale identity, unsupported protocol, rate limit, conflict, or unavailable runtime.

A DnsLibs reapply failure is treated as potentially mutating. Rollback uses the last confirmed exact configuration while flow admission remains blocked. Unknown state is never presented as old Active, target Active, degraded service, or restored System DNS.

## Timeout And Reconciliation

| Operation | Limit |
| --- | --- |
| Upstream preflight | 5 seconds |
| Runtime application after manager reload | 5 seconds |
| Failure reconciliation and repair | 8 seconds |
| Runtime polling | 200 milliseconds |
| Network-context debounce | 1 second |
| DnsLibs upstream exchange | 5 seconds |
| Keyboard Quit confirmation | 2 seconds |
| Confirmed safe Quit decision | 5 seconds |

`AGDnsProxy.reapplySettings` is synchronous and non-cancellable. Host cancellation ends only the Host wait. After timeout, reply loss, or XPC interruption, the Host reads authenticated actual status and may replay only identical request bytes with the same operation ID.

## Restore System DNS And Quit

Lifecycle shutdown fences new switching intent, waits for unavoidable in-flight mutation, captures exact ownership, quiesces the runtime, compare-and-saves manager disabled, and reloads disabled state. Disabled is reported only after exact quiescence and manager proof.

If disable explicitly fails while the exact manager remains enabled, exact runtime resume may be attempted. If manager save outcome is unknown, resume and further manager mutation are forbidden until the operation settles and preferences are reloaded.

Normal Quit leaves the System Extension installed. After Force Quit, crash, or power loss, the system-managed DNS Proxy may remain enabled until the next launch reconciles persisted desired state and actual runtime or the user restores System DNS. Manager stop/start is used for initial enablement, explicit restore, Quit, Extension replacement, and bounded lifecycle repair; ordinary Profile switching uses the enabled single-engine reapply path.
