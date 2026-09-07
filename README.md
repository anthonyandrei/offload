# Offload

Offload is a small, agent-agnostic delegation contract. It lets an orchestrator hand a bounded implementation or research assignment to a worker while keeping responsibility for review, unfinished work, and the final report.

## Contract

The orchestrator:

- uses Offload only for an explicit request, a named worker provider, an accepted offer, or a host-approved proactive offer;
- describes the assignment, paths or questions, acceptance criteria, deliverables, and authority boundary;
- discovers current worker tools, model choices, and reasoning options at runtime;
- makes a task-based choice using capabilities, availability, cost, judgment, and advisory benchmark evidence;
- treats a real launch as the usability check. Unknown account, entitlement, billing, quota, capacity, or benchmark information does not block launch;
- keeps the worker bounded and forbids nested delegation;
- reviews the actual result and relevant verification before accepting it;
- finishes unfinished work itself or reports the precise blocker.

The workflow does not carry provider commands, copied help, exact model identifiers, a universal catalog, a role matrix, or a hidden selection protocol. A named provider choice is honored. A failed launch returns the unfinished assignment to the orchestrator without a silent switch or automatic second attempt.

## Implementation assignments

Implementation runs in a disposable isolated worktree or project copy. The orchestrator checks the final diff for scope and intent, runs the relevant project checks, and accepts or integrates the result only when the acceptance criteria pass. The disposable workspace is removed after recovery or acceptance.

## Research assignments

Research starts with bounded questions and evidence responsibilities. The worker uses credible sources, and the orchestrator checks that every material citation resolves and supports its claim. Inference, uncertainty, disagreement, missing evidence, and stale evidence stay visible in the final synthesis.

## Proactive offers

The host may offer Offload for implementation with at least three independently gated assignments when the repository is clean, or for a read-only audit or research task with at least two independent evidence tracks. The user must consent before dispatch. A refusal settles the offer for the session.

## Repository layout

- [SKILL.md](SKILL.md) is the active delegation contract.
- [CONTEXT.md](CONTEXT.md) and [ADR 0012](docs/adr/0012-keep-offload-outcome-based-and-runtime-dynamic.md) define the current vocabulary and decisions.
- [Benchmark references](docs/research/2026-09-07-benchmark-references-for-runtime-routing.md) are advisory evidence for runtime choices.
- [Execution scope](scripts/check-execution-scope.sh) and [execution workspace](scripts/execution-workspace.sh) helpers retain generic implementation safety.
- [Research workspace](scripts/make-research-workspace.sh) and [research cleanup](scripts/cleanup-research-workspace.sh) helpers retain bounded disposable snapshots.
- The tests under [tests](tests) check the contract, isolation, scope, cleanup, failure fallback, and repository consistency.

## Installation

Install the complete repository directory as a skill. The repository is the source of truth for the contract and its generic safety helpers.

## Verification

The contract suite runs natively in Bash and PowerShell. It checks the active documentation, helper behavior, disposable workspace safety, bounded research snapshots, failed-launch fallback, and references to removed workflow machinery.
