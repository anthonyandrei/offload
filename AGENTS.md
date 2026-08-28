# offload

Claude Code skill that delegates plan execution to headless `agy` subagent workers.

## Key Decisions & Architecture

- **Worker Model & CLI**: Uses `agy` directly with `--model gemini-3.7-flash-high`. Modes: `accept-edits` for implementers and test authors, `plan` for read-only scouts and reviewers.
- **Verification over Claims**: Worker JSON `status` (`SUCCESS`/`ERROR`) is not trusted alone; orchestrator verifies edits via `git diff`, frozen test suites, and exit codes.
- **Offer, not Gate**: the skill description carries two shapes the agent reaches on its own (an implementation split of 3+ gated tasks; a read-only audit fan-out). `Preconditions` says to offer once per session and take a no as settled. Nothing enforces this.
- **Optional Hook**: `hooks/offload-ask.sh` is a `PreToolUse` hook on `ExitPlanMode` that denies the first exit call per session to force the same question. Deterministic alternative to the offer; not installed by default.
- **Installation**: Tracked public repo (`github.com/anthonyandrei/offload`), installed via `skillshare install anthonyandrei/offload --track` as `_offload`.
