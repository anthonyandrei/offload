# Worker adapter catalog contract

Status: accepted. Catalog protocol version 2.

The launcher owns policy, selection, retry identity, capacity admission, and
filesystem scope. An adapter owns vendor syntax, authenticated discovery, and
the live catalog. The public workflow names a worker role, an internal
preference (`fast`, `balanced`, or `deep`), a reasoning effort, and required
capabilities. It does not name a vendor or exact model ID unless the user
explicitly chooses one.

## Operations

The launcher invokes an adapter with one of these operations:

```text
adapter --operation catalog --request REQUEST.json
adapter --operation launch --request SELECTION.json --output OUTPUT --error ERROR -- WORKER_ARGS...
```

`REQUEST.json` contains the role, preference, effort, required capabilities,
policy revision, route, and protocol version. The catalog operation writes one
JSON object to stdout. A catalog must report the adapter revision, vendor,
catalog revision, model entries, and a normalized preflight record for each
candidate:

```json
{
  "protocol_version": 2,
  "adapter": "configured-adapter",
  "adapter_revision": "adapter-2",
  "vendor": "provider-name",
  "catalog_revision": "provider-current",
  "models": [{
    "id": "provider-exact-model-id",
    "supported_efforts": ["low", "high"],
    "capabilities": ["structured-output"],
    "scores": {"fast": 1, "balanced": 2, "deep": 3},
    "preflight": {
      "access": {"state": "verified", "reason": "authenticated", "account_ref": "nonsecret-account-ref"},
      "entitlement": {"state": "active", "reason": "subscription", "billing_route": "included"},
      "usage": {
        "state": "known",
        "observed_at": "2026-09-05T00:00:00Z",
        "source": "provider-usage",
        "scopes": [{"scope_id": "account-window", "remaining_units": 8, "reserved_units": 0, "reset_at": "2026-09-05T01:00:00Z"}]
      }
    }
  }]
}
```

Access, entitlement, billing, and usage observations must be current, scoped,
and explainable. Missing, malformed, stale, unsupported, or optimistic
observations never become available capacity. The selector requires known
fresh usage for automatic selection. An explicit provider may proceed with
unknown usage only after access, capability, entitlement, and billing checks
pass, with the uncertainty recorded in the selection.

The selector rejects expired entitlements, paid-fallback routes, explicit
ineligibility, and candidates that cannot cover the assignment, verification,
and one allowed retry. It ranks eligible candidates by the role preference and
capabilities first, remaining capacity second, and stable provider/model
identity last. Family labels and installed CLIs do not establish quality or
access.

The selection record includes the normalized preflight evidence, a capacity
estimate, and reservation scopes. The launcher reserves those scopes before a
managed launch, then records completion, cancellation, failure, or recovery.
Competing admissions use an atomic ledger. Reservation and usage evidence
must not contain credentials, tokens, or private account data.

## Pinning and retries

The launcher writes the complete selection record when `--selection-output` is
supplied. The orchestrator copies it into every `routing-outcomes.json` attempt
together with the attempt number and verification result. A retry or resume
supplies the same record with `--pin`. The launcher checks the pinned adapter,
provider, account or billing route, exact model ID, effort, and current
eligibility. A missing pinned model fails explicitly and requires a recorded
fallback or handoff. No retry silently changes provider, model, effort, or
billing route. At most one retry is allowed for an assignment.

Adapters keep discovery, quota, cancellation, wait, and exit-code details
behind this protocol. They must not widen the permissions, tools, path scope,
or resource ownership granted by the orchestrator.
