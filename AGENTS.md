# offload

Agent-agnostic skill that delegates plan execution and research to headless `agy` workers.

## Key decisions and architecture

- **Orchestrator-agnostic, adapter-backed workers**: Any agent capable of reading `SKILL.md` and running shell commands can orchestrate, including Claude Code, Codex CLI, and similar agents. Worker execution runs through the adapter contract, with `agy` as the reference adapter. The self-guard stops a dispatched worker that loads this skill. Every assignment instructs workers not to dispatch nested workers, but the skill cannot enforce that prohibition if a worker ignores it.
- **Modular mode architecture**: Root `SKILL.md` is a lightweight router under 500 lines owning shared preconditions, mode inference, explicit overrides, mode loading, and the shared report contract. Workflows are isolated into dedicated mode documents: `modes/execution.md` (code and file mutations), `modes/repo-research.md` (bounded local investigations and audits), and `modes/web-research.md` (online research, synthesis, and citation auditing).
- **Routing hierarchy**: Once invoked, the router resolves mode in this order:
  1. Honor explicit mode override.
  2. Route research-backed mutations to `web-research` first and `execution` second.
  3. Route direct file or code mutations to `execution`.
  4. Route local read-only questions to `repo-research`.
  5. Route external read-only questions to `web-research`.
  6. Route mixed local and external questions to `web-research` with a scoped snapshot.
  Single factual lookups stay local with the orchestrator.
- **Shell-native helper families with platform parity**: Offload maintains two shell-native helper families: Bash 3.2+ for POSIX shells and PowerShell 7+ for PowerShell orchestrators. Orchestrators select the helper family for their current shell. Native workflows on Windows require only PowerShell 7+, Git, and `agy` without WSL, Git Bash, Python, or `jq`. Platform parity ensures equivalent workflow behavior, workspace isolation, provenance artifacts, and safety checks across supported shells.
- **Worker roles, preferences, and modes**:
  - Worker routing is governed centrally by `model-policy.json` and a vendor adapter. The policy stores each role's internal preference, independent effort, and required capabilities. The adapter provides the live catalog and translates the selected model into worker arguments.
  - Selection is deterministic after filtering for availability, quota, effort, capabilities, and static security constraints. Family hints are descriptive only.
- **Model routing policy and recovery accounting**:
  - Preflight model availability check against the resolved `agy` installation before first dispatch.
  - Launchers take `--role <role>` and optional `--route default|quality-retry`, resolving models dynamically and rejecting caller `--model` or `--effort` arguments.
  - Stable assignment identity across attempts with a strict ceiling of at most one retry (maximum two attempts per worker).
  - Operational failures (crashes, timeouts, unparsable output) trigger at most one retry of the pinned selection (`--route default`). Quality failures (gate failures, scope violations, audit rejections) retry the pinned selection or require an explicit fallback or handoff when the pin is unavailable.
  - Explicit quota exhaustion triggers immediate handoff of unfinished work to the calling orchestrator without blocking on sibling workers.
  - The orchestrator records all attempts and verification verdicts in `routing-outcomes.json` in the scratch workspace. Web research provenance optionally records routing attempt records in `provenance.json`.
- **Corrected worker guarantees**: `--mode plan` is a version-sensitive behavioral hint, not a write barrier. The accepted `agy 1.1.25` probe blocked the tested direct write outside the permitted artifact area, but plan mode is not a sole safety control. `--add-dir` grants access without confining writes. Security and containment rely on filesystem isolation (disposable workspaces with scoped file snapshots for research) and mechanical verification (clean git working trees, execution scope checks, frozen path diffs, and test gates for execution).
- **Verification over claims**: Worker JSON status (`SUCCESS`/`ERROR`) is not trusted alone. Implementers are verified via mechanical execution scope checks (`check-execution-scope.sh` or `check-execution-scope.ps1`), frozen paths, and gate commands. Reviewers are verified against the recorded artifact digest and verbatim quote matching. Research findings are verified against the live repository with read-only orchestrator commands after scope validation, with direct checks on high-priority claims and sampling on lower-priority claims.
- **Preconditions**: Writing workflows require a clean git repository. Research workflows operate in isolated disposable workspaces.
- **Proactive offer contract**: For implementation splits of 3+ gated tasks or multi-angle audit fan-outs, the orchestrator offers offloading once per session; a negative response settles the decision for that session. Offload uses a host-independent, model-readable proactive offer contract in context files (`AGENTS.md` or `CLAUDE.md`) rather than vendor-specific lifecycle hooks.
- **Installation**: Tracked public repo (`github.com/anthonyandrei/offload`), installed via `skillshare install anthonyandrei/offload --track` as `_offload`. Manual installation copies the entire skill directory.
