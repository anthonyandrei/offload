# Worker adapter contract

This document defines the boundary between the `orchestrator` and a vendor
`adapter`. An adapter runs one bounded `worker` assignment. It does not decide
the assignment, verify the result, or own cleanup outside the resources it
reports.

The contract is versioned independently from a vendor command line. Vendor
syntax, output parsing, process handles, capability catalogs, and model
catalogs stay inside the adapter. The orchestrator only consumes the records
defined here and runs the `execution scope check` and other existing gates.

## Assignment

The orchestrator gives the adapter an immutable JSON assignment:

```json
{
  "contract_version": 1,
  "assignment_id": "task-17",
  "request": { "prompt": "..." },
  "constraints": {
    "tools": ["read", "write"],
    "permissions": ["repo.read", "repo.write"],
    "owned_paths": ["src"],
    "frozen_paths": ["tests"],
    "worktree": { "id": "worktree-17", "path": "..." },
    "artifact_root": "...",
    "cleanup_resource_ids": ["process:17", "worktree:17"]
  }
}
```

`assignment_id` must be stable across retries. `owned_paths` and
`frozen_paths` are repository-relative paths. The adapter may use fewer tools,
permissions, or paths than the assignment grants, but it cannot widen them.
The worktree and artifact root are exact identities. A result that reports a
different worktree, artifact root, or cleanup resource is rejected.

The adapter must treat `constraints` as read-only input. It must not turn a
missing permission into an allowed permission, reinterpret a path as a parent
directory, or transfer cleanup to the orchestrator for an unreported resource.

## Adapter operations

Every adapter exposes these operations, whether as functions, a command
protocol, or a host-language object:

| Operation | Required behavior |
| --- | --- |
| `discover-capabilities` | Return the adapter's available tools and permissions, without changing the assignment. |
| `discover-models` | Return model identifiers and capabilities known by this vendor. The adapter owns catalog syntax and authentication. |
| `launch` | Start exactly one worker for the assignment and return a process/job identity plus the worktree and artifact-root identities. |
| `wait` | Wait for completion up to the requested timeout and return a lifecycle state. |
| `cancel` | Request cancellation for the reported process/job identity and return its final lifecycle state. |
| `exit-status` | Return the process exit code or signal, including a still-running state when no exit exists. |
| `capture-result` | Parse the worker output into the normalized result below. Raw vendor output never crosses this boundary. |
| `ownership` | Return the process/job, worktree, and artifact resources the adapter created and can identify. |

`launch` may not widen the static assignment. `wait`, `cancel`, and
`exit-status` may only address the identity returned by `launch`. The adapter
reports ownership; the orchestrator decides whether cleanup is safe. This
prevents an adapter from deleting a resource outside its ownership record.

## Normalized result

`capture-result` returns this shape:

```json
{
  "contract_version": 1,
  "assignment_id": "task-17",
  "status": "succeeded",
  "artifacts": [
    { "path": "...", "kind": "worker-output", "sha256": "...", "verified": false }
  ],
  "resources": [
    { "type": "process", "id": "process:17" },
    { "type": "worktree", "id": "worktree:17", "path": "..." }
  ],
  "ownership": { "resource_ids": ["process:17", "worktree:17"] },
  "constraint_snapshot": {
    "tools": ["read"],
    "permissions": ["repo.read"],
    "owned_paths": ["src"],
    "frozen_paths": ["tests"],
    "worktree": { "id": "worktree-17", "path": "..." },
    "artifact_root": "...",
    "cleanup_resource_ids": ["process:17", "worktree:17"]
  },
  "model_selection": {
    "provider": "vendor-name",
    "model_id": "vendor-model-id",
    "selection_reason": "matched required capability"
  },
  "exit": { "code": 0, "signal": null },
  "publication": { "status": "unpublished" }
}
```

`status` is one of `succeeded`, `failed`, `cancelled`, or `malformed`.
`malformed` describes a worker response that the adapter could classify. An
unparseable adapter result is a contract failure instead.

The adapter must keep every artifact below `artifact_root`, report every
resource in `ownership.resource_ids`, and set `verified` to `false`.
`publication.status` must be `unpublished`. Verification, publication, and
the final `accepted_attempt` belong to the orchestrator after the
`execution scope check` and gate commands pass.

The normalized result always carries model-selection metadata. The
`provider`, model identifier, and selection reason are opaque to the
orchestrator. The orchestrator may compare them with its own policy, but it
does not parse vendor model catalogs.

## Reference adapter

The current AGY path is the reference adapter. On PowerShell it launches
through [`scripts/run-agy-json.ps1`](../scripts/run-agy-json.ps1); on POSIX
hosts it uses [`scripts/run-agy-json.sh`](../scripts/run-agy-json.sh). Those
files contain AGY argument syntax and model routing. A future adapter keeps
its own command syntax and catalog parsing in its own directory, then emits
the same assignment and normalized-result records.

`grill-with-docs` and other host skills should depend only on this contract.
They must not contain adapter names, vendor commands, or vendor model names.
