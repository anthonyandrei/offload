# offload

Agent-agnostic skill that delegates plan execution to headless `agy` subagent workers.

## Key Decisions & Architecture

- **Orchestrator-agnostic, worker-fixed**: Any agent that can read `SKILL.md` and run shell commands can orchestrate, including Claude Code, Codex CLI, and similar agents. `agy` is reserved for the worker role. The self-guard stops an `agy` process that loads this skill. Every assignment also instructs workers not to dispatch nested workers, but the skill cannot enforce that prohibition if a worker ignores it.
- **Worker Roles, Models & Modes**: Dispatches `scout` (`gemini-3.7-flash-low`, `--mode plan`), `gate-author` (`gemini-3.7-flash-high`, `accept-edits`), `implementer` (`gemini-3.7-flash-high`, `accept-edits`), `reviewer` (`gemini-3.7-flash-high`, `--mode plan`), and `researcher` (`gemini-3.7-flash-high`, `--mode plan`).
- **Preconditions**: Only all-plan research/audit runs waive Git and clean-tree preconditions. Every gate-author or implementer run retains them.
- **Lanes and Gates**: Writing tasks use either a Machine gate (authored test with red check and read) or a Diff gate (adversarial reviewer with diff quote verification). Read-only tasks use a bounded research/audit lane declaring exactly one bounded question, allowed scope, evidence expectations, and an explicit non-mutation rule. Open-ended research is out of scope.
- **Structured Outputs**: Uses `--json-schema` with `--output-format json` across scouts, reviewers, and researchers (`structured_output`). The research schema captures a stable lane ID, lane kind, bounded question, findings, overall status, and uncertainty.
- **Verification over Claims**: Worker JSON `status` (`SUCCESS`/`ERROR`) is not trusted alone. Implementers are verified via git ownership diffs, frozen paths, and gate commands. Reviewers are verified via diff quote matching. Research evidence must stay within the declared scope, and worker-supplied commands are inspected before use. The orchestrator confirms priority, checks every high-priority claim, samples lower-priority claims, leaves unsupported claims unverified, and records per-finding provenance.
- **Offer, not Gate**: The skill description carries shapes the agent reaches on its own (an implementation split of 3+ gated tasks; a read-only audit fan-out). `Preconditions` says to offer once per session and take a no as settled. Nothing enforces this.
- **Optional Hook (Claude Code only)**: `hooks/offload-ask.sh` is a Claude Code `PreToolUse` hook on `ExitPlanMode` that denies the first exit call per session to force the same question. Deterministic alternative to the offer; not installed by default; has no equivalent for other orchestrators yet.
- **Installation**: Tracked public repo (`github.com/anthonyandrei/offload`), installed via `skillshare install anthonyandrei/offload --track` as `_offload`.
