# Offload context

Offload delegates bounded work to `agy` processes while the calling agent remains responsible for scope, verification, and reporting.

## Language

**Orchestrator**:
The calling agent that plans assignments, dispatches workers, and verifies their results.
_Avoid_: Controller, parent agent

**Worker**:
An `agy` process assigned one bounded role and prohibited from dispatching more workers.
_Avoid_: Subagent, child agent

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
