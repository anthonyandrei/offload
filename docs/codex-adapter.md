# Codex adapter

The Codex adapter is a vendor-neutral worker boundary for hosts that provide the
Codex CLI. It conforms to the worker adapter contract (`docs/adapter-contract.md`)
and has PowerShell and Bash entry points:

```text
scripts/run-codex-json.ps1 --operation catalog --request <request.json>
scripts/run-codex-json.ps1 --operation launch --request <selection.json> --output <output.json> --error <error.log> -- <worker_args...>

bash scripts/run-codex-json.sh --operation catalog --request <request.json>
bash scripts/run-codex-json.sh --operation launch --request <selection.json> --output <output.json> --error <error.log> -- <worker_args...>
```

The Bash entry point requires Bash 3.2 or newer and `jq`; the PowerShell entry
point requires PowerShell 7 or newer.

## Operations

### Catalog discovery

`--operation catalog --request <request.json>` probes the installed Codex CLI for
the structured execution flags used by the adapter: `--json`, `--output-schema`,
and `--output-last-message`. It also reads the host-provided `CODEX_MODEL_CATALOG`
(or `OFFLOAD_ADAPTER_CATALOG`) environment variable. The variable may contain a
JSON document or a path to one:

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

The adapter emits a protocol version 2 catalog document to standard output:

```json
{
  "protocol_version": 2,
  "adapter": "codex",
  "adapter_revision": "codex-2",
  "vendor": "codex",
  "catalog_revision": "host-catalog-1",
  "models": [
    {
      "id": "host-selected-model",
      "family_hint": "unknown",
      "available": true,
      "quota_available": true,
      "supported_efforts": ["low", "medium", "high"],
      "capabilities": ["structured-output"],
      "scores": { "fast": 2, "balanced": 1, "deep": 2 },
      "preflight": {
        "access": { "state": "verified", "account_ref": "account-ref" },
        "entitlement": { "state": "active", "billing_route": "subscription" },
        "usage": {
          "state": "known",
          "source": "codex-usage",
          "observed_at": "2026-09-05T00:00:00Z",
          "scopes": [
            { "scope_id": "account-window", "remaining_units": 12, "reserved_units": 0 }
          ]
        }
      }
    }
  ]
}
```

The catalog is supplied by the host; the adapter does not hardcode vendor model
IDs. Access, entitlement, billing, and usage are independent preflight facts.
Missing or stale facts remain unknown and cannot be selected as compatible. If
the CLI flags or catalog are unavailable, the adapter fails closed and exits
nonzero.

### Worker launch

`--operation launch --request <selection.json> --output <output.json> --error <error.log> -- <worker_args...>`
launches Codex with the exact model selected by the orchestrator. The adapter
parses worker arguments following the `--` delimiter (such as `--prompt`, `--cd`,
`--cancel-file`, and `--timeout-seconds`), preserving argument and path
boundaries when values contain spaces.

The adapter owns the native Codex invocation syntax, supplying fixed
constraints:

- `exec --json --ephemeral`
- `--cd <worktree>`
- `--sandbox workspace-write`
- `--ask-for-approval never`
- `--output-schema <adapter schema>`
- `--output-last-message <artifact>`
- `--model <model_id>`
- `-- <prompt>`

The adapter captures process standard output and standard error, writing the
normalized result to the designated output path:

```json
{
  "status": "success",
  "structured_output": { ... },
  "model_id": "host-selected-model"
}
```

## Security and responsibility boundary

The orchestrator owns assignment constraints, execution-scope verification,
final acceptance gates, resource ledgers, and cleanup. The adapter does not run
adapter-owned scope checks or acceptance gates, nor does it maintain a competing
private ledger schema.

Cancellation (signal or cancel file) terminates the process and exits with code
130. Timeout terminates the process and exits with code 124. Quota exhaustion
exits with code 75 for caller handoff. Malformed output exits with code 1,
preserving the raw output for diagnosis.
