# Claude adapter contract

The Claude adapter is one adapter for one bounded worker assignment. The
orchestrator owns assignment constraints, verification, lifecycle, and cleanup.
The adapter owns only Claude Code command syntax and response parsing.

## Assignment

An assignment is a JSON object with `schema_version: 1` and these fields:

- `assignment_id`, `prompt`, and `working_directory` are required.
- `owned_paths`, `frozen_paths`, `baseline`, and `gate_command` describe the
  execution scope and final gate. They are required for an execution run.
- `preference` is `fast`, `balanced`, or `deep`. It is an internal preference,
  not a Claude model name.
- `model` and `effort` are optional pinned choices selected by the
  orchestrator. The adapter never publishes a model ID or maps a family hint
  to a permission.
- `allowed_tools` and `disallowed_tools` are static assignment constraints.
  The adapter always adds Claude's child-assignment tools to the denied set.
- `timeout_seconds`, `resume_session_id`, `cancel_file`, and `ledger_path` are
  optional lifecycle and ownership data.

The working directory must contain an `.offload-execution-workspace` or
`.offload-research-workspace` marker. The adapter rejects the caller checkout,
an unmarked directory, unsafe permission mode, path escapes, arbitrary Claude
arguments, and attempts to pass `--model`, `--effort`, or permission flags from
the caller.

## Normalized result

The adapter writes a JSON result with `schema_version`, `assignment_id`,
`adapter`, `status`, `lifecycle`, `exit_code`, `response`, `structured_output`,
`session_id`, `capabilities`, `model_selection`, `resources`, `artifacts`, and
`verification`. A result reaches the caller as `completed` only after the
execution scope check and final gate both pass.

The adapter reports capability discovery from `claude --version` and
`claude --help`. A host-provided catalog may be supplied through
`CLAUDE_MODEL_CATALOG` or `model_catalog_path`; when neither exists, model
availability is `unknown`. A pinned model cannot run while availability is
unknown. This fails closed instead of guessing.

## Lifecycle and resources

The lifecycle is `created`, `started`, `running`, `completed`, `failed`,
`canceled`, `quota-handoff`, `retained`, or `cleaned`. Cancellation and timeout
terminate Claude, wait for process exit, and preserve stdout and stderr.

Before launch, the adapter registers the worktree, process placeholder, raw
output, raw error, normalized result, and verification artifacts in the
orchestrator-owned ledger. It updates the process identity and terminal state.
The adapter never deletes ledger resources. Cleanup and reconciliation remain
orchestrator responsibilities.

Claude Code features tested by the fake suite are print mode, JSON output,
model and permission flags, allowed and denied tools, resume IDs, process
termination, malformed JSON handling, and post-run scope/gate verification.
Native Windows Claude Code hosts need WSL, Git for Windows, or the supported
native binary. Any host that cannot provide a marked isolated runtime must be
rejected or run in a separately provisioned isolated environment.
