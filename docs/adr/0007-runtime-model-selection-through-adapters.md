# ADR 0007: Select models at runtime through worker adapters

- Status: accepted
- Date: 2026-09-04
- Supersedes: [ADR 0005](0005-bound-model-routing-to-gemini-and-explicit-rules.md)

## Decision

Worker policy publishes only the internal preferences `fast`, `balanced`, and `deep`, a separate reasoning effort, and required capabilities. The launcher asks a vendor-neutral worker adapter for a live catalog, filters it using static policy and task requirements, and deterministically selects a current candidate. The adapter translates the selected vendor and exact model ID into its own CLI or API syntax. AGY remains the reference adapter.

Every selection is recorded with the adapter, vendor, exact model ID, family hint, preference, effort, catalog and adapter revisions, selection reason, and each attempt. Retries and resumes use the recorded selection as a pin. A missing pinned model causes an explicit fallback or handoff; it never causes an implicit provider or model switch.

## Consequences

Workflows survive vendor catalog changes without publishing vendor-specific IDs. Catalog availability and quota can be evaluated at launch time. Exact model IDs still exist in operational evidence, where they are needed for reproducibility, but they are not a permission boundary or a quality guarantee. Historical ADR 0005 remains available as the record of the superseded decision.
