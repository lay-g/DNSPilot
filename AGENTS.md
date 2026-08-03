# Agent Instructions

## Sources Of Truth

- Before changing behavior, architecture, security, UI contracts, tests, Swift, build settings, scripts, or CI, read the relevant document under [`docs/en/design/`](docs/en/design/). Treat the design documents and repository configuration as authoritative; do not duplicate versioned facts here.
- Keep `docs/en/` and `docs/zh/` structurally and semantically synchronized. Documentation records enduring contracts, not progress logs, local details, or validation history.

## Non-Negotiable Boundaries

- Preserve the ownership and source-of-truth boundaries in [`architecture.md`](docs/en/design/architecture.md), [`runtime.md`](docs/en/design/runtime.md), and [`security.md`](docs/en/design/security.md).
- Ordinary Profile switching must remain on the authenticated single-engine reapply path. Do not introduce manager stop/start switching, dual-engine switching, shared-file IPC, or a separate DNS transport.
- Do not weaken exact-byte runtime identity, XPC peer authentication, mutation-journal recovery, external-manager ownership checks, or confirmed System DNS restoration.
- Follow [`toolchain.md`](docs/en/design/toolchain.md) for compiler, deployment, concurrency, dependency, and upgrade constraints.

## Authorization And Verification

- Without explicit authorization for the current task, do not operate or automate the UI, activate or deactivate the System Extension, change system DNS or authorization state, or install signed builds.
- Run the smallest relevant checks first. For documentation-only changes, run `scripts/ci/check-repository.sh`; for code or build changes, run `scripts/ci/all.sh` when feasible. Report omitted checks and remaining signed-runtime or manual UI validation.
- Never weaken type, concurrency, security, signing, recovery, or test checks to make validation pass.
- Never commit signing material, private identifiers, credentials, real network identifiers or DNS data, endpoint tokens, private logs, or raw diagnostics.

## UI Layout

- In compact macOS forms, do not show a nested control label when the surrounding `LabeledContent` already describes the field. Hide only the redundant visual label while preserving an accessible name, and verify that minimum window width and long localized text do not introduce wrapping or overlap.
- In an `HSplitView` nested inside the management `NavigationSplitView`, do not assign positive hard `minWidth` values to sibling panes unless their combined minima, the navigation sidebar, and every divider are proven to fit within the `760 pt` minimum window width. Prefer a zero minimum with `idealWidth` and `maxWidth` so panes can compress with the window. Keep each pane's direct child structurally stable across empty, loading, failure, and result states so intrinsic-content changes do not move a user-positioned divider. Verify the minimum window size, state transitions, and long localized content without horizontal overflow or divider jumps.
