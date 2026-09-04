# Codex adapter

The Codex adapter is a vendor-neutral worker boundary for hosts that provide the
Codex CLI. It has PowerShell and Bash entry points:

```text
scripts/run-codex-json.ps1 capabilities --output <capabilities.json>
scripts/run-codex-json.ps1 run --assignment <assignment.json> --output <result.json> --error <error.log>

bash scripts/run-codex-json.sh capabilities --output <capabilities.json>
bash scripts/run-codex-json.sh run --assignment <assignment.json> --output <result.json> --error <error.log>
```

The Bash entry point requires Bash 3.2 or newer and `jq`; the PowerShell entry
point requires PowerShell 7 or newer.

The adapter accepts an assignment document with `schema_version: 1`,
`assignment_id`, `prompt`, `worktree`, `preference`, `effort`, `timeout_seconds`,
`scope_check`, and `final_gate`. The optional
`parent_assignment_id`, `depth`, `attempt`, `resume_session_id`, `model_id`, and
`resource_ledger` fields carry lifecycle and ownership state from the caller.

## Capability discovery

`capabilities` probes the installed Codex CLI for the structured execution flags
used by the adapter: `--json`, `--output-schema`, and `--output-last-message`. It also reads the
host-provided `CODEX_MODEL_CATALOG` environment variable. The variable may contain a JSON
document or a path to one:

```json
{
  "revision": "host-catalog-1",
  "models": [
    {
      "id": "host-selected-model",
      "preference": "balanced",
      "efforts": ["low", "medium", "high"]
    }
  ]
}
```

The catalog is deliberately supplied by the host. The adapter does not publish
or embed model IDs. `fast`, `balanced`, and `deep` are the stable internal preferences; the adapter
selects a matching available model deterministically. If the CLI flags or
catalog are unavailable, the adapter writes a normalized unsupported result and
exits nonzero.

## Security and lifecycle boundary

The adapter owns the native Codex invocation and always supplies these fixed
constraints:

- `exec --json --ephemeral`
- `--cd <assignment worktree>`
- `--sandbox workspace-write`
- `--ask-for-approval never`
- `--output-schema <adapter schema>`
- `--output-last-message <artifact>`

Callers cannot inject native worker flags through the assignment. A worker
response containing a child-assignment request is recorded under
`orchestrator_requests`; the adapter never dispatches it. Assignment depth
and attempt values are validated before launch.

Every worktree, process, and adapter artifact is appended to the JSONL resource
ledger with the assignment ID and an ownership marker. The normalized result
records process identity, selected model, artifacts, cancellation, timeout,
quota handoff, malformed output, scope-check, and final-gate outcomes.
Cancellation and timeout stop the native process. Retry, quota handoff, and
resume scheduling remain decisions of the shared lifecycle coordinator, which
passes the next attempt or resume session back to this adapter.

The adapter only returns `completed` after both the declared scope check and
final gate pass. Scope failure and gate failure are caller-visible failures and
do not expose the worker's structured result as a successful result.

## Tested and unavailable features

The deterministic PowerShell acceptance test covers capability discovery,
successful structured output, malformed output, cancellation, scope failure,
quota handoff, and fail-closed capability discovery. The Bash entry point is
syntax-checked in CI and uses the same assignment and result contract.

The Codex CLI does not provide a portable model-catalog command for this
adapter, so hosts must provide `CODEX_MODEL_CATALOG`. The adapter does not
offer concurrency, nested dispatch, or independent worktree cleanup. Those
operations belong to the shared lifecycle and resource-ledger services. A
missing service or unsupported host capability is reported as an explicit
failure instead of being inferred or silently widened.
