# ADR 0012: Keep offload outcome-based and runtime-dynamic

- Status: accepted
- Date: 2026-09-07
- Supersedes: [ADR 0001](0001-maintain-shell-native-helper-families.md), [ADR 0005](0005-bound-model-routing-to-gemini-and-explicit-rules.md), [ADR 0007](0007-cross-library-publication-boundaries.md), [ADR 0008](0008-runtime-model-selection-through-adapters.md), and [ADR 0011](0011-launch-first-admission-and-orchestrator-fallback.md)

## Context

Offload began as a way to orchestrate AGY workers, then expanded into an agent-agnostic orchestration framework. The expansion introduced adapter contracts, normalized catalogs, model policies, provider admission checks, routing records, retries, parallel shell command families, and prescribed command sequences.

That machinery attempted to make every orchestrator reason and route identically. It also depended on provider facts that were unavailable or unknowable before launch. In practice, admission could reject a usable worker because entitlement, billing, or quota remained unknown.

The durable value of offload is narrower. It should preserve the quality and safety obligations around delegation while allowing the runtime model to decide how to satisfy them from its current tools and evidence.

## Decision

Offload is an outcome-based workflow, not a vendor orchestration framework or step-by-step command guide.

The skill records no vendor command syntax, copied help text, model matrix, adapter interface, normalized model catalog, quota protocol, routing algorithm, provider-specific retry policy, or persistent worker-performance ledger. The orchestrator discovers installed worker tools, current models, capabilities, and command syntax at runtime when that information is useful. It may inspect native help and model-listing facilities directly.

The orchestrator chooses whether to delegate and selects the vendor, model, and reasoning effort using the assignment, current availability, cost, relevant benchmark references, and its own judgment. Benchmark references are advisory evidence. They do not prove availability, entitlement, remaining usage, subscription cost, or performance in the actual worker harness. Missing, stale, unavailable, or mismatched benchmark evidence never blocks delegation.

A real launch is the definitive usability check. Offload does not attempt to prove usable capacity in advance. It does not silently switch providers or run an offload-level retry engine. When a worker fails, unfinished work returns to the orchestrator automatically.

Offload standardizes only the assurances surrounding delegation:

- A worker receives one bounded assignment in an appropriately isolated workspace.
- The orchestrator treats the worker as a fallible collaborator.
- Worker-authored implementation is reviewed and subjected to relevant verification before acceptance.
- Research is grounded in credible sources, citations are checked, and inference is identified.
- The orchestrator completes or safely reports unfinished work after worker failure.
- Temporary workspaces are removed after accepted integration.
- The final report states what was delegated, what was verified, and what remains uncertain.

These are procedural assurances. They do not claim that worker output or orchestrator review is infallible.

## Consequences

- Different orchestrators may make different routing and execution decisions while satisfying the same acceptance obligations.
- Provider CLI and model changes do not require an offload release merely to update stored commands or catalogs.
- External benchmarks ground judgment without becoming mandatory runtime dependencies.
- AGY remains a valid worker option without being a special architectural boundary.
- Runtime model quality and judgment affect outcomes more than prescriptive workflow mechanics.
- The existing command-heavy skill, adapters, routing policy, ledgers, and duplicated helper families do not implement this decision and require a separate simplification change.

## Decision references

The initial advisory shortlist is recorded in [the benchmark research note](../research/2026-09-07-benchmark-references-for-runtime-routing.md). It may evolve independently because references support judgment rather than define protocol behavior.
