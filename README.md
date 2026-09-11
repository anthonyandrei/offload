# Offload

Offload outsources one bounded implementation or research assignment to an external vendor. The orchestrator defines the work, routes it from what is available at runtime, reviews the result, and owns the finish.

## Contract

The orchestrator:

- activates Offload when the user asks to outsource, names an external vendor or model, or approves outsourcing after a bounded assignment is defined;
- uses external vendors only. Native subagents and native multi-agent calls stay outside this contract;
- defines the objective, scope, acceptance criteria, deliverables, and authority boundary before launch;
- discovers vendors, models, tools, and current capabilities at runtime without copying catalogs, commands, model matrices, adapters, or routing ledgers into the skill;
- consults relevant advisory benchmarks and native usage signals. Exact current evidence is preferred, but missing or stale evidence does not block a real launch;
- selects the lightest model and lowest reasoning effort that appear capable of meeting the acceptance criteria;
- honors named vendors and exact models;
- returns launch, timeout, quota, and tool failures without automatic provider switching; the assignment remains unfinished;
- allows exactly one quality-gate escalation after refreshed benchmark and usage checks. Generic approval can switch vendors; named vendor and exact model constraints still apply;
- stops after a failed escalation, finishing locally when safe or reporting the usable partial result and precise blocker;
- reviews implementation diffs and verification, audits research citations, cleans disposable workspaces, and reports what happened.

## Implementation assignments

Implementation runs in a disposable isolated worktree or project copy. The orchestrator checks the final diff for scope and intent, runs the relevant project checks, and accepts or integrates the result only when the acceptance criteria pass.

## Research assignments

Research starts with bounded questions and evidence responsibilities. The worker uses credible sources, and the orchestrator checks that every material citation resolves and supports its claim. Inference, uncertainty, disagreement, missing evidence, and stale evidence stay visible in the final synthesis.

## Repository layout

- [SKILL.md](SKILL.md) is the active delegation contract and contains the advisory benchmark sources.
- [Execution scope](scripts/check-execution-scope.sh) and [execution workspace](scripts/execution-workspace.sh) helpers retain generic implementation safety.
- [Research workspace](scripts/make-research-workspace.sh) and [research cleanup](scripts/cleanup-research-workspace.sh) helpers retain bounded disposable snapshots.
- The tests under [tests](tests) check the contract, isolation, scope, cleanup, failure fallback, and repository consistency.

## Installation

Install the repository directory as a skill. `SKILL.md` is the contract and `scripts/` contains its generic safety helpers.

## Verification

The contract suite runs in Bash and PowerShell. It checks the active documentation, helper behavior, disposable workspace safety, bounded research snapshots, failed-launch fallback, and references to removed workflow machinery.
