# Offload

Offload is a small, agent-agnostic delegation contract. It lets an orchestrator hand a bounded implementation or research assignment to another worker provider, with implicit pre-delegation offers, runtime model and effort selection, and orchestrator verification.

## Contract

The orchestrator:

- uses Offload when the user explicitly asks to offload, names a worker provider, accepts an offload offer, or implicitly at the offer gate before native multi-agent delegation for two or more independent bounded assignments;
- describes the assignment, paths or questions, acceptance criteria, deliverables, and authority boundary;
- discovers current worker tools, model choices, and reasoning options at runtime;
- chooses the worker, model, and reasoning effort dynamically using task demands, capabilities, availability, cost, judgment, and advisory benchmark references when cost or quality materially matters;
- treats a real launch as the usability check. Unknown account, entitlement, billing, quota, capacity, or benchmark information does not block launch;
- keeps the worker bounded and forbids nested delegation;
- reviews the actual result and relevant verification before accepting it;
- finishes unfinished work itself or reports the precise blocker.

The workflow does not carry provider commands, copied help, exact model identifiers, a universal catalog, a role matrix, or a hidden selection protocol. A named provider choice is honored. A failed launch returns the unfinished assignment to the orchestrator without a silent switch or automatic second attempt.

## Implementation assignments

Implementation runs in a disposable isolated worktree or project copy. The orchestrator checks the final diff for scope and intent, runs the relevant project checks, and accepts or integrates the result only when the acceptance criteria pass. The disposable workspace is removed after recovery or acceptance.

## Research assignments

Research starts with bounded questions and evidence responsibilities. The worker uses credible sources, and the orchestrator checks that every material citation resolves and supports its claim. Inference, uncertainty, disagreement, missing evidence, and stale evidence stay visible in the final synthesis.

## Proactive offer gate

Offload activates implicitly immediately before an orchestrator begins a native multi-agent workflow for two or more independent, bounded assignments (delegation lanes) in implementation or research. The orchestrator asks once, before native worker dispatch, whether the user prefers another available worker provider. File count alone does not trigger an offer. Explicit requests, named providers, and accepted offers bypass the two-lane threshold. The user must consent before dispatch; a refusal settles the offer for the session and allows native multi-agent delegation to proceed.

## Repository layout

- [SKILL.md](SKILL.md) is the active delegation contract and contains the advisory benchmark sources.
- [Execution scope](scripts/check-execution-scope.sh) and [execution workspace](scripts/execution-workspace.sh) helpers retain generic implementation safety.
- [Research workspace](scripts/make-research-workspace.sh) and [research cleanup](scripts/cleanup-research-workspace.sh) helpers retain bounded disposable snapshots.
- The tests under [tests](tests) check the contract, isolation, scope, cleanup, failure fallback, and repository consistency.

## Installation

Install the repository directory as a skill. `SKILL.md` is the contract and `scripts/` contains its generic safety helpers.

## Verification

The contract suite runs natively in Bash and PowerShell. It checks the active documentation, helper behavior, disposable workspace safety, bounded research snapshots, failed-launch fallback, and references to removed workflow machinery.
