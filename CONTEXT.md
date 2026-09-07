# Offload context

Offload is a lean, agent-agnostic workflow for delegating bounded implementation and research work. The orchestrator chooses how to execute the workflow from the tools and evidence available at runtime. See [ADR 0012](docs/adr/0012-keep-offload-outcome-based-and-runtime-dynamic.md).

## Core contract

- Treat workers as fallible collaborators, not authoritative executors or hostile processes.
- Discover available worker CLIs, models, and current command syntax at runtime when useful.
- Choose whether and where to delegate using the task, current benchmark references, cost, and orchestrator judgment.
- Do not make delegation depend on quota, entitlement, billing, benchmark, or other speculative pre-checks. A real launch settles whether a chosen worker is usable.
- Review every worker-authored implementation and run relevant verification before acceptance.
- Ground research in credible sources, audit citations, and distinguish sourced findings from inference, uncertainty, disagreement, and stale evidence.
- Return unfinished work to the orchestrator automatically when a worker fails.
- Isolate delegated work appropriately and remove temporary workspaces after accepted integration.

These are procedural assurances, not a promise that worker output is infallible.

## Language

**Orchestrator**:
The calling agent that decides whether and how to delegate, reviews worker output, and owns the final result.

**Worker**:
A fallible collaborator assigned one bounded piece of work. Its output is never accepted solely because the worker reports success.

**Runtime discovery**:
The orchestrator's inspection of currently available CLIs, models, capabilities, and command help. Offload does not store vendor command syntax or normalize provider catalogs.

**Decision reference**:
Current external evidence, such as a relevant benchmark, that grounds routing judgment without determining it. Missing, stale, or mismatched benchmark data never blocks delegation.

**Implementation assurance**:
The requirement that the orchestrator reviews worker-authored changes and performs verification relevant to the assignment before accepting them.

**Research assurance**:
The requirement that the orchestrator checks source quality, claim support, and citations before accepting a research synthesis.

**Orchestrator fallback**:
The automatic return of unfinished work to the orchestrator after worker failure. Offload does not retry through a routing engine or silently switch providers.

**Workspace isolation**:
Separation appropriate to the risk of the delegated work, such as a disposable worktree for implementation or a disposable project copy for research. The workflow specifies the outcome, not shell-specific commands.
