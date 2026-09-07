# offload

Offload is an agent-agnostic, outcome-based delegation skill. The active contract is [SKILL.md](SKILL.md); [CONTEXT.md](CONTEXT.md) and ADR 0012 are the durable project sources of truth.

## Current boundaries

- Keep provider, model, reasoning, and command details runtime-dynamic. Do not add copied catalogs, exact model identifiers, role matrices, or integration interfaces to the workflow.
- Keep launch admission simple. A real launch is the usability check; unknown account, entitlement, billing, quota, capacity, or benchmark information must not block it.
- Keep implementation changes isolated until the orchestrator reviews the actual diff and relevant checks.
- Keep research bounded, source-backed, and explicit about inference and uncertainty.
- Retain only generic helpers that directly enforce scope, isolation, bounded snapshots, or safe cleanup.

## Editing and verification

- Preserve unrelated user changes in a dirty checkout.
- Use the native shell helper for the platform being changed.
- Run the contract tests for the affected platform and the full suite when practical.
- Treat superseded ADRs as historical context. Do not add active links to removed files.
