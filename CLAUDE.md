# offload

Claude Code skill that delegates plan execution to headless `agy` subagent workers.

## Key Decisions & Architecture

- **Worker Model & CLI**: Uses `agy` directly with `--model gemini-3.7-flash-high`. Modes: `accept-edits` for implementers and test authors, `plan` for read-only scouts and reviewers.
- **Verification over Claims**: Worker JSON `status` (`SUCCESS`/`ERROR`) is not trusted alone; orchestrator verifies edits via `git diff`, frozen test suites, and exit codes.
- **Hook Gating**: `PreToolUse` on `ExitPlanMode` denies the first exit call per session to prompt the user for offloading consent before execution.
- **Installation**: Tracked public repo (`github.com/anthonyandrei/offload`), installed via `skillshare install anthonyandrei/offload --track` as `_offload`.
