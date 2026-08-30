# offload

Agent-agnostic skill that delegates plan execution to headless `agy` subagent workers.

## Key Decisions & Architecture

- **Orchestrator-agnostic, worker-fixed**: Any agent that can read `SKILL.md` and run shell commands can orchestrate, including Claude Code, Codex CLI, and similar agents. `agy` is reserved for the worker role. The self-guard at the top of `SKILL.md` blocks `agy` both as a dispatched worker and as a top-level session.
- **Worker Model & CLI**: Uses `agy` directly with `--model gemini-3.7-flash-high`. Modes: `accept-edits` for implementers and test authors, `plan` for read-only scouts and reviewers.
- **Verification over Claims**: Worker JSON `status` (`SUCCESS`/`ERROR`) is not trusted alone; orchestrator verifies edits via `git diff`, frozen test suites, and exit codes.
- **Offer, not Gate**: the skill description carries two shapes the agent reaches on its own (an implementation split of 3+ gated tasks; a read-only audit fan-out). `Preconditions` says to offer once per session and take a no as settled. Nothing enforces this.
- **Optional Hook (Claude Code only)**: `hooks/offload-ask.sh` is a Claude Code `PreToolUse` hook on `ExitPlanMode` that denies the first exit call per session to force the same question. Deterministic alternative to the offer; not installed by default; has no equivalent for other orchestrators yet.
- **Installation**: Tracked public repo (`github.com/anthonyandrei/offload`), installed via `skillshare install anthonyandrei/offload --track` as `_offload`.
