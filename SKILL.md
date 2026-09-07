---
name: offload
description: Use when the user explicitly asks to offload work to another worker, names a worker provider, or accepts an offload offer. Offer proactively for large, independently gated implementation or research work when the host instructions permit it.
---

# offload

Offload is an optional delegation workflow. The calling agent remains the orchestrator: it owns the assignment, reviews the result, finishes unfinished work, and gives the final report.

Use this skill when the user explicitly asks to offload or run work on another worker, names a worker provider, or accepts a proactive offer. Keep narrow factual answers, explanations, single-source lookups, and focused code reviews local. A worker must not dispatch another worker.

## Before delegation

- Describe one bounded assignment. Include the objective, in-scope paths or questions, acceptance criteria, deliverables, and the boundary of the worker's authority.
- If the user named a provider, honor that choice. Otherwise inspect the worker tools currently available to the host. When the choice matters, use each tool's current native help or model-listing facility rather than relying on copied instructions.
- Choose the worker, model, and reasoning effort from the task, required capabilities, current availability, cost, relevant benchmark references, and judgment. The benchmark note is advisory evidence, not a routing table.
- Unknown entitlement, billing, quota, capacity, or benchmark information never blocks an attempted launch. The real launch is the definitive usability check.
- Start one worker per bounded assignment by default. Split work only when the pieces are genuinely independent and each has its own acceptance criteria.

Do not encode provider command syntax, copied help text, exact model identifiers, a universal catalog, or a role matrix in this workflow. Those details belong to the worker tool and the current runtime.

## Implementation work

- Place implementation work in an appropriately isolated disposable worktree or project copy. The worker must not write directly to the orchestrator's live checkout before review.
- Give the worker its assignment and acceptance criteria. Do not give it authority to widen its paths, change the assignment, dispatch nested workers, or alter orchestrator state.
- After launch, inspect the actual files and diff. Check scope, intent, and the relevant project checks. A success message from the worker is evidence to inspect, not an acceptance decision.
- Accept or integrate changes only when the criteria and relevant verification pass. Reject out-of-scope or unverified changes, then finish the assignment yourself or report the remaining blocker.
- Remove the disposable workspace after accepted integration. If partial output must be preserved, name it in the report and clean it when the orchestrator has recovered what it needs.

## Research work

- Define bounded questions and evidence responsibilities. Use separate disposable snapshots when repository context or concurrent work makes isolation useful.
- Prefer credible primary sources and claim-level support. Reject broken citations or claims not supported by their cited sources. Mark inference, uncertainty, disagreement, missing evidence, and stale evidence plainly.
- A worker's research synthesis is not accepted solely because it contains citations or reports success. The orchestrator reviews the sources and the claims they support.
- Do not require a universal result envelope or provider-specific research record. Keep only the evidence needed to support the final answer.

## Launch failure and fallback

- A failed launch or failed run returns the unfinished assignment and any usable partial output to the orchestrator automatically.
- Do not hide a failed launch with an Offload-managed second automatic attempt or a silent provider switch. The orchestrator may make a new, explicit decision after reporting what failed.
- The orchestrator completes the remaining work when it can do so safely. Otherwise it reports a resumable partial result, the failure, and the precise blocker.

## Proactive offer

Host instructions may offer Offload without an explicit request only when all of the following are true:

- implementation has at least three independently gated assignments and the Git repository is clean, or
- a read-only audit or research task has at least two distinct evidence tracks.

Ask for consent before dispatching. A refusal settles the offer for the rest of the session. Do not offer it for narrow work. The host keeps the final result and remains responsible for verification.

## Final report

State the bounded assignment, worker choice when relevant, actual result, files or sources inspected, verification performed, remaining uncertainty, and any failure or fallback. Say whether disposable workspaces were removed. Do not claim a worker ran until its launch succeeded.

## Repository references

- [CONTEXT.md](CONTEXT.md) defines the project's terms and durable contract.
- [ADR 0012](docs/adr/0012-keep-offload-outcome-based-and-runtime-dynamic.md) records why the workflow stays outcome-based and runtime-dynamic.
- [Benchmark references](docs/research/2026-09-07-benchmark-references-for-runtime-routing.md) records optional decision evidence.
- The generic [execution scope checker](scripts/check-execution-scope.sh) and [execution workspace helper](scripts/execution-workspace.sh) enforce the retained implementation safety outcomes.
