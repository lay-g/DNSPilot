# Runtime Design

[中文](../../zh/design/runtime.md)

## Runtime Identity

Each desired runtime is represented by one decoded `ActiveProxyConfiguration`, its exact binary property-list bytes, and the SHA-256 fingerprint of those bytes. The configuration contains schema version, generation UUID, Profile UUID, upstream, logging mode, and DNS cache settings.

Encoding occurs once per generation. Manager persistence, XPC mutation, runtime application, rollback, and final verification use the same bytes. Generation and fingerprint are independent identity dimensions.

A runtime is confirmed only when Provider instance, generation, fingerprint, `.ready` phase, compatible control protocol, and final manager ownership reload all agree.

Active Proxy schema capability is transport-specific: DoH requires schema 1, Plain DNS requires schema 2, and DoT requires schema 3. Schema 1 through 3 imply the standard DNS cache configuration; custom capacity or disabled cache requires schema 4. The Host discovers authenticated Provider capability before encoding a transport or cache setting that needs a newer schema and never silently drops a requested setting. Capability mismatch fails before preflight or manager mutation.

## DNS Cache Changes

The ordinary DNS response cache is global. It defaults to 1,000 responses, accepts an enabled capacity of `1...10,000`, and is disabled by passing a capacity of zero to DnsLibs. Optimistic cache remains disabled and is not user-configurable.

Saving while the Proxy is off commits the application configuration and takes effect on the next enable. Saving while an exact Active runtime exists uses the same manager-enabled, authenticated single-engine mutation and compensation path as an Active Profile edit, but does not repeat upstream preflight when the upstream is unchanged. A cache settings reapply discards old cache entries. Success is published only after exact target runtime and final manager verification; uncertain outcomes enter recovery-required state.

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

When exact Active state is confirmed, safe Quit durably prepares a one-shot resume record before quiescence and marks the exact disable as confirmed after the final manager reload. A crash between those phases is reconciled from the record and the current exact manager state. A record is claimed durably before any startup enable and is automatically attempted at most once per launch.

Startup processes configuration mutation recovery before safe-Quit resume evidence. An exact enabled manager is reconciled and adopted without stop/start. An exact disabled manager may be enabled only when owner identity, retained configuration generation and fingerprint, application-configuration identity, and Extension readiness agree with the record. Manual mode uses its persisted Profile. Automatic mode waits for a fresh network context from the current active desktop session and reevaluates Rules. Missing, corrupt, claimed, foreign, changed, or uncertain evidence never authorizes an automatic manager write.

If a safe-Quit resume is pending while the bundled System Extension is newer, startup first proves the disabled manager exactly matches the resume record and durably records the source build, target build, pre-replacement owner identity, and replacement attempt. Replacement is submitted at most once per target per launch. Resume remains forbidden until macOS reports the exact target build active and the Host reloads the manager. Post-replacement reconciliation accepts only unchanged identity or changes limited to the provider-configuration and localized-description fingerprints; disabled state, provider Bundle identifier, retained Active bytes, generation, Active fingerprint, and Profile identity must remain exact. The accepted owner evidence is rebound durably before the existing claim, fenced enable, Provider readiness, and final manager proof path runs.

A crash after upgrade preparation, replacement submission, or replacement confirmation resumes from the durable phase and current Extension and manager state. An unconfirmed upgrade cannot claim the resume record or enable the manager. A different target build, unavailable identity, real configuration change, or uncertain durable transition stops automatic recovery and leaves System DNS active.

Normal Quit leaves the System Extension installed. After Force Quit, crash, or power loss, the system-managed DNS Proxy may remain enabled until the next launch reconciles persisted state and actual runtime or the user restores System DNS. Manager stop/start is used for initial enablement, safe-Quit resume, explicit restore, Quit, Extension replacement, and bounded lifecycle repair; ordinary Profile switching uses the enabled single-engine reapply path.
