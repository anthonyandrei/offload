# Claude adapter contract

The Claude adapter is a vendor-neutral worker boundary for hosts that provide the
Claude Code CLI (`claude`). It conforms to the worker adapter contract
(`docs/adapter-contract.md`) and has PowerShell and Bash entry points:

```text
scripts/run-claude-json.ps1 --operation catalog --request <request.json>
scripts/run-claude-json.ps1 --operation launch --request <selection.json> --output <output.json> --error <error.log> -- <worker_args...>

bash scripts/run-claude-json.sh --operation catalog --request <request.json>
bash scripts/run-claude-json.sh --operation launch --request <selection.json> --output <output.json> --error <error.log> -- <worker_args...>
```

The orchestrator owns assignment constraints, execution-scope verification,
final acceptance gates, resource ledgers, and lifecycle management. The adapter
owns Claude Code command syntax and response normalization.

## Operations

### Catalog discovery

`--operation catalog --request <request.json>` verifies that the Claude CLI is
available and advertises structured output support via `claude --help`. It reads
model metadata from `CLAUDE_MODEL_CATALOG` or `OFFLOAD_ADAPTER_CATALOG` (or
host-provided model list) and outputs a protocol version 1 catalog JSON document
to standard output:

```json
{
  "protocol_version": 1,
  "adapter": "claude",
  "adapter_revision": "claude-1",
  "vendor": "anthropic",
  "catalog_revision": "catalog-revision-id",
  "models": [
    {
      "id": "claude-3-5-sonnet-20241022",
      "family_hint": "sonnet",
      "available": true,
      "quota_available": true,
      "supported_efforts": ["low", "medium", "high"],
      "capabilities": ["structured-output"],
      "scores": { "fast": 2, "balanced": 1, "deep": 2 }
    }
  ]
}
```

If the CLI or catalog is unavailable, the adapter fails closed and exits
nonzero.

### Worker launch

`--operation launch --request <selection.json> --output <output.json> --error <error.log> -- <worker_args...>`
launches Claude Code with the exact model selected by the orchestrator. The
adapter parses worker arguments following the `--` delimiter (such as
`--prompt`, `--cd`, `--cancel-file`, `--timeout-seconds`, `--allowedTools`, and
`--disallowedTools`), preserving argument and path boundaries when values
contain spaces.

The adapter enforces isolated execution:
- The working directory must contain an `.offload-execution-workspace` or
  `.offload-research-workspace` marker. Unmarked workspaces fail closed.
- Nested dispatch tools `Task` and `Agent` are automatically added to
  `--disallowedTools`.
- `--permission-mode` defaults to `acceptEdits`; `bypassPermissions` is rejected.
- Structured JSON output is requested via `-p <prompt> --output-format json`.

The normalized output written to `<output.json>` follows the launcher result
contract:

```json
{
  "status": "success",
  "response": "ok",
  "session_id": "s1",
  "structured_output": { ... },
  "model_id": "claude-3-5-sonnet-20241022"
}
```

## Security and responsibility boundary

The orchestrator owns assignment verification, execution scope checks, final
gates, and resource ledgers. The adapter does not run adapter-owned scope checks
or acceptance gates, nor does it generate competing private ledger schemas.

Cancellation (signal or cancel file) terminates the process and exits with code
130. Timeout terminates the process and exits with code 124. Quota exhaustion
exits with code 75 for caller handoff. Malformed output exits with code 1,
preserving the raw output for diagnosis.
