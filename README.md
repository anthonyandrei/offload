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
- uses benchmark-first routing for every automatic initial selection and quality escalation: after discovering plausible candidates, opens the actual task-matched benchmark URL and uses its latest result as primary quality evidence before adjudicating, prefers the most accurate capable model and effort, and skips it only for a clear price outlier among comparable capable candidates without a material quality advantage; use judgment to interpret the benchmark result against runtime facts, not to bypass it, and record any concrete departure reason;
- honors named vendors, models, and reasoning efforts, while applying benchmark-first routing to any remaining unpinned dimensions;
- returns infrastructure failures and unfinished work without automatic provider switching;
- allows exactly one quality-gate escalation, then finishes locally when safe or reports the usable partial result and precise blocker;
- reviews implementation diffs and research citations before acceptance;
- reports the assignment, selection, benchmark URL and access date, benchmark result or explicit evidence gap, usage evidence, result, verification, any departure reason, uncertainty or blockers, and cleanup status after removing and verifying every disposable workspace.

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
