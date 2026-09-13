# Offload

Offload outsources one bounded assignment that benefits from independent execution to an external vendor. Eligible work includes bounded repository reconnaissance, analysis, test investigation, implementation, research, transformations, artifact-producing work, and independently executable long-running work. Open-ended or tightly interactive work stays local. Native subagents remain outside the contract.

## Contract

The orchestrator:

- activates Offload after an explicit outsourcing request, a named vendor or model, or user approval of a defined bounded assignment;
- defines every assignment with the same shape: objective, scope, acceptance criteria, deliverables, and authority;
- keeps phases with shared authority and acceptance criteria together, and gives genuinely independent work separate boundaries;
- discovers current vendor, model, and tool details at runtime;
- uses version-matched official documentation for capability, installed version and native help for invocation details, and a real launch as the definitive admission check;
- keeps the launch record transient to the run and excludes credentials, tokens, and secrets;
- uses the task's best-matched advisory benchmark and available pricing to prefer the most accurate capable model and effort, while skipping a clear price outlier without a material quality advantage;
- honors named vendors and exact models;
- returns infrastructure failures and unfinished work without automatic provider switching;
- allows exactly one quality-gate escalation, then finishes locally when safe or reports the usable partial result and precise blocker;
- reviews implementation diffs and research citations before acceptance;
- reports the assignment, selection, benchmark and usage evidence, result, verification, uncertainty or blockers, and cleanup status after removing and verifying every disposable workspace.

## Work types

Implementation uses an isolated disposable worktree or project copy. Repository reconnaissance can use a complete disposable workspace, and temporary notes remain disposable. Research uses bounded questions, credible sources, citation checks, and visible inference or uncertainty. Transformations and artifact-producing work define their source, output, format, and acceptance checks.

## Repository layout

- [SKILL.md](SKILL.md) is the active delegation contract and contains the advisory benchmark sources.
- [Execution scope](scripts/check-execution-scope.sh) and [execution workspace](scripts/execution-workspace.sh) helpers retain generic implementation safety.
- [Research workspace](scripts/make-research-workspace.sh) and [research cleanup](scripts/cleanup-research-workspace.sh) helpers retain bounded disposable snapshots.
- The tests under [tests](tests) check the contract, isolation, scope, cleanup, failure fallback, and repository consistency.

## Installation

Install the repository directory as a skill. `SKILL.md` is the contract and `scripts/` contains the generic safety helpers.

## Verification

The contract suite runs in Bash and PowerShell. It checks the active documentation, helper behavior, disposable workspace safety, bounded research snapshots, failed-launch fallback, and references to removed workflow machinery.
