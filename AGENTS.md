# offload

Offload is an agent-agnostic, outcome-based delegation skill. The active contract is [SKILL.md](SKILL.md); [CONTEXT.md](CONTEXT.md), ADR 0012, and ADR 0013 are the durable project sources of truth.

## Current boundaries

- Keep provider, model, reasoning, and command details runtime-dynamic. Do not add copied catalogs, exact model identifiers, role matrices, or integration interfaces to the workflow.
- Offer Offload immediately before native multi-agent delegation for two or more independent, bounded implementation or research assignments; file count alone is not a trigger.
- Require consent before Offload dispatch. Explicit requests, named providers, and accepted offers bypass the proactive threshold; a decline lets native delegation continue and settles the offer for the session.
- Keep launch admission simple. A real launch is the usability check; unknown account, entitlement, billing, quota, capacity, or benchmark information must not block it.
- Keep implementation changes isolated until the orchestrator reviews the actual diff and relevant checks.
- Keep research bounded, source-backed, and explicit about inference and uncertainty.
- Retain only generic helpers that directly enforce scope, isolation, bounded snapshots, or safe cleanup.

## Editing and verification

- Preserve unrelated user changes in a dirty checkout.
- Use the native shell helper for the platform being changed.
- Run the contract tests for the affected platform and the full suite when practical.
- Treat superseded ADRs as historical context. Do not add active links to removed files.
