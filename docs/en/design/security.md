# Security And IPC Design

[中文](../../zh/design/security.md)

## Build Identity

Team and Bundle identity enter through ignored local configuration or protected CI values. Public defaults are synthetic. Host, System Extension, App Group, Mach service, and XPC peer requirements derive from the same inputs.

Both peers install code-signing requirements before activating XPC connections. Requirements bind the expected Apple signing anchor, Team ID, and environment-specific Bundle identifier. The Extension also requires the effective user ID to match the active console user. PID is diagnostic only.

## Mach XPC Contract

The Mach service name is versioned by the build and lives under the App Group namespace. The service offers read-only status/evidence plus bounded runtime commands for reapply, quiesce, and resume.

Selectors accept only `Data` and return `Data` plus `NSError`. Write messages are strict binary property lists with exact keys. Unknown fields require a protocol revision.

- Maximum write envelope: 64 KiB.
- Maximum embedded runtime configuration: 48 KiB.
- At most one runtime mutation in flight.
- Process-local token bucket: 8 requests/second, burst 16.
- Terminal replay cache: at most 32 operations, scoped to lifecycle epoch.

Admission is charged before decoding, single-flight checks, or replay lookup. Malformed, oversized, replayed, and conflicting requests consume the same budget.

## Compare-And-Swap Identity

Provider instance, lifecycle epoch, base generation, base fingerprint, target fingerprint, operation ID, and exact request bytes form the mutation boundary.

Repeating one operation ID with identical bytes returns the cached terminal response. Reusing it with different bytes is rejected. A stale or structurally invalid request cannot authorize rollback, manager disable, runtime adoption, or Profile publication.

The Host validates response protocol, operation identity, Provider instance, disposition-specific fields, target or preserved-base identity, exact preserved bytes, and forbidden fields. A malformed response is an uncertain control outcome.

## Data Minimization

XPC never accepts Profile catalogs, Rules, SSIDs, file paths, arbitrary command strings, shell commands, or DNS query data. Runtime status is process-local evidence, not a durable configuration channel.

Configuration and recovery files use private directories and restrictive permissions. DNS names, SSIDs, addresses, subnets, answers, endpoint paths, tokens, bootstrap addresses, and raw runtime payloads are private data.

Default logs avoid those values. Debug Logging requires explicit warning and may expose them. Diagnostic summary copying is reduced; explicit export is treated as sensitive and requires confirmation.

Underlying operational errors are logged as private by default and are not rendered directly in user-facing error text. User-facing failures may expose reviewed, stable error categories and non-sensitive codes, but never raw descriptions that can contain private configuration or implementation details. An unstructured dependency failure remains explicitly unclassified. Debug Logging and confirmed diagnostic export may contain detailed failures under their existing sensitive-data warnings.

## Failure Policy

Authentication, ownership, schema, replay, rate-limit, or identity uncertainty fails closed. External manager changes are observed but never overwritten automatically. Legacy read-only runtime-control capability permits status inspection but blocks active Profile switching until a compatible Extension is installed.
