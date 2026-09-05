# Offload context

Offload delegates bounded work through compatible worker adapters while the calling agent remains responsible for scope, verification, and reporting. The repository includes a reference adapter, but selection is provider-neutral.

## Publication boundary

Published source skills remain vendor-neutral. `grill-with-docs` owns its
interview and documentation workflow and can run without offload. Offload is
an optional delegation layer, while adapters own vendor launch syntax, model
catalogs, capability probes, and output parsing. Consumers depend on stable
capabilities, model preferences, separate reasoning effort, and normalized
results, not vendor names or exact model IDs.

Capability support does not enforce security. The orchestrator remains
responsible for isolation, ownership, cleanup, execution scope checks, and
acceptance gates. The source repository is authoritative; generated and
installed copies are release outputs. See
`docs/contracts/publication-compatibility.md` and ADR 0007.

## Language

**Orchestrator**:
The calling agent that plans assignments, dispatches workers, and verifies their results.
_Avoid_: Controller, parent agent

**Worker**:
A process launched through a compatible adapter and assigned one bounded role. Its process environment is marked as worker context, so the dispatch, launcher, and execution-workspace lifecycle interfaces reject nested assignment, process, or worktree creation.
_Avoid_: Subagent, child agent

**Compatible worker adapter**:
An adapter that implements the worker contract and has verified support for the assignment's required capabilities. An installed agent CLI alone does not establish compatibility.
_Avoid_: Any installed CLI, universal worker support

**Worker selection**:
The orchestrator's choice of a configured, compatible worker provider before making an offload offer. Selection checks authenticated access, current entitlement, and usage limits against the assignment, verification, and one retry, accounting for workers sharing quota. Rank eligible workers by task capability and expected quality, with remaining capacity as the tie-breaker. Unknown usage excludes automatic selection but permits explicit user selection with disclosed uncertainty and otherwise established access. An explicit user provider choice takes precedence, subject to eligibility checks. The offer names the selected worker and explains the choice. The protocol-2 selector and capacity ledger implement this behavior. See ADR 0009.
_Avoid_: Always offer one provider, implicit provider switch

**Dispatch ledger**:
The orchestrator-owned `offload-dispatch-state-v1` record for admitted assignments. It records parentage, depth, child IDs, budgets, owned and frozen paths, lifecycle state, artifacts, and rejected nested-dispatch events.
_Avoid_: Worker tree, implicit scheduler state

**Helper family**:
A shell-native set of scripts that implements the same offload operations and command contracts for one supported shell.
_Avoid_: Port, rewrite

**Platform parity**:
Equivalent workflow behavior, safety checks, artifacts, and failure signals across supported helper families.
_Avoid_: Identical implementation

**Native workflow**:
An offload workflow that runs in a supported host shell without WSL, Git Bash, or another compatibility layer.
_Avoid_: Cross-platform workflow

**Launcher delimiter**:
The literal `--` argument that separates launcher options from worker arguments. PowerShell callers write `'--'` so the command parser passes the delimiter to the helper. Arguments after it retain their order and individual values.
_Avoid_: Optional separator, inferred worker boundary

**Execution scope check**:
The mechanical comparison of repository changes against a worker's owned and frozen paths.
_Avoid_: Diff check, ownership check

**Proactive offer contract**:
The host-independent rule that defines when an orchestrator offers offloading, how often it asks, and how it handles the answer.
_Avoid_: Hook, Claude hook

**Model routing**:
The policy and adapter process that selects an available model and independent reasoning effort for an offload worker assignment. It uses a role preference, task capabilities, live availability, static security rules, and quota state.
_Avoid_: Mode routing, unrestricted model selection

**Role default**:
The internal preference, reasoning effort, and required capabilities assigned to an offload role. The adapter resolves those requirements to a current model.
_Avoid_: Best model, permanent model assignment

**Model policy**:
The shared source of permitted model assignments and routing constraints, read and validated by both shell-native helper families for every offload mode.
_Avoid_: Per-mode model list, launcher default

**Model promotion**:
A change to an offload role default justified by repeated local runs on representative tasks with the same inputs and verification gates. ADR 0005 records a one-time exception for the initial 3.8 Flash baseline migration, which requires an integration smoke test.
_Avoid_: Version upgrade, benchmark ranking
