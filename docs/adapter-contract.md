# Worker adapter contract

Status: accepted. Protocol version 1.

The launcher owns policy, selection, retry identity, and filesystem scope. An adapter owns vendor syntax and the live model catalog. The public workflow contract names a worker role, an internal preference (`fast`, `balanced`, or `deep`), and a reasoning effort. It does not name a vendor or an exact model ID.

## Operations

The launcher invokes an adapter with one of these operations:

```text
adapter --operation catalog --request REQUEST.json
adapter --operation launch --request SELECTION.json --output OUTPUT --error ERROR -- WORKER_ARGS...
```

`REQUEST.json` contains the role, preference, effort, required capabilities, policy revision, and a protocol version. The catalog operation writes one JSON object to stdout. A catalog contains an adapter revision, vendor, catalog revision, capabilities, and model entries:

```json
{
  "protocol_version": 1,
  "adapter": "agy",
  "adapter_revision": "1",
  "vendor": "provider",
  "catalog_revision": "provider-current",
  "models": [
    {
      "id": "provider-exact-model-id",
      "family_hint": "flash",
      "available": true,
      "quota_available": true,
      "supported_efforts": ["low", "high"],
      "capabilities": ["structured-output"],
      "scores": {"fast": 1, "balanced": 2, "deep": 3}
    }
  ]
}
```

The launcher filters unavailable, quota-exhausted, effort-incompatible, and capability-incompatible candidates. It then sorts the remaining candidates by the requested preference score and stable `(vendor, id)` tie-breakers. `family_hint` is descriptive metadata only. It cannot grant permissions, widen filesystem access, or make a cross-vendor quality claim.

The launch operation receives the selected exact ID and effort in the selection JSON. It translates those values into vendor-specific arguments, captures worker stdout and stderr at the supplied paths, and exits with the worker's exit code. Adapter failures are operational failures, not permission to select another provider.

## Pinning and retries

The launcher writes the complete selection record when `--selection-output` is supplied. The orchestrator copies that record into every `routing-outcomes.json` attempt together with the attempt number and verification result. A retry or resume supplies the same record with `--pin`. The launcher checks the pinned adapter, vendor, exact model ID, and effort against the current catalog. A changed catalog is acceptable when the pinned model is still available; a missing pinned model fails explicitly and requires a recorded fallback or handoff. No retry silently changes provider, model, or effort.

Adapters must keep their own discovery, quota, cancellation, wait, and exit-code details behind this protocol. They must not widen the permissions, tools, path scope, or resource ownership granted by the orchestrator.
