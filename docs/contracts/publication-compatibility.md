# Publication compatibility contract

This contract keeps a published source skill independent from worker vendors.
It applies to `grill-with-docs` and to any other skill that may use offload.

## Ownership boundary

`grill-with-docs` owns the interview workflow and the documentation workflow. It
must run with no offload, AGY, Codex, Claude, or vendor-model installation. Its
published instructions may describe an optional offload integration, but they
must not require that integration to run the interview.

`offload` owns optional worker delegation, the orchestrator lifecycle, artifact
verification, and the execution scope check. An adapter owns one vendor's
launch syntax, output parsing, model catalog, capability probe, cancellation,
and resource identity details. The adapter receives the assignment's static
constraints. It cannot widen tool permissions, path scope, worktree scope, or
cleanup obligations.

Capability support is not security enforcement. An adapter can report that a
worker supports structured output or cancellation. The orchestrator still
enforces filesystem isolation, frozen paths, execution scope checks, cleanup
ownership, and acceptance gates. A vendor's permission feature is never a
substitute for those checks.

## Stable consumer contract

Published skills depend on these stable concepts:

- `orchestrator`, `worker`, and `adapter` roles.
- Assignment requirements and static security constraints.
- Internal model preferences: `fast`, `balanced`, and `deep`.
- Reasoning effort as a separate setting.
- Adapter-reported capabilities and a normalized result.
- Artifact, process, worktree, and resource ownership records.

They must not depend on a vendor name, a vendor family label, an exact model
ID, or a vendor-specific feature. Exact model IDs and family hints may appear
in adapter-owned runtime records. They are metadata, not a cross-library
contract or a quality guarantee.

## Manifest and catalog versions

A published skill carries `publication.json` beside `SKILL.md`:

```json
{
  "schema_version": 1,
  "publication_contract_version": 1,
  "skill": "grill-with-docs",
  "contract": "vendor-neutral",
  "imports": [],
  "optional_adapters": [
    { "name": "offload", "min_version": "1.0.0" }
  ],
  "required_capabilities": [],
  "vendor_features": []
}
```

`imports` are required adapters. The compatibility check fails when an import
is absent or older than `min_version`. `optional_adapters` may be absent. A
missing optional adapter produces a warning and does not stop the source skill
from running. `required_capabilities` names a capability supplied by a named
adapter. `vendor_features` must stay empty in a published source skill.

An adapter catalog records the available adapter contract and its capabilities:

```json
{
  "schema_version": 1,
  "adapter_contract_version": 1,
  "adapters": [
    {
      "name": "offload",
      "version": "1.2.0",
      "capabilities": ["worker-delegation", "structured-results"],
      "vendor_features": ["adapter-owned-feature"]
    }
  ]
}
```

The contract version changes for incompatible manifest, adapter, helper-family,
or normalized-result changes. A minor version adds optional fields or
capabilities without changing existing meaning. A patch version fixes behavior
without changing the contract. Consumers pin the contract major and set a
minimum adapter version. Adapters may release vendor model changes within that
adapter version line. The orchestrator records the selected adapter, model
metadata, catalog revision, and every attempt for retry and resume.

## Helper-family compatibility

The Bash and PowerShell helper families implement equivalent observable
contracts. Each family must preserve argument order, structured-result capture,
output and error separation, ownership records, cleanup rules, and failure
classification. Their implementations may differ.

There is no universal launcher. Select the helper family from the host shell.
Vendor command syntax stays in the adapter package. A published source skill
may link to the helper-family contract, but it must not copy a vendor command or
assume that one shell is installed.

Run the compatibility check against a published skill and the adapter catalog:

```bash
scripts/check-publication-compatibility.sh \
  --skill-root /path/to/published-skill \
  --catalog /path/to/adapter-catalog.json
```

```powershell
& scripts/check-publication-compatibility.ps1 `
  --skill-root C:\path\to\published-skill `
  --catalog C:\path\to\adapter-catalog.json
```

The check fails for a missing required adapter, an incompatible version, a
missing capability, a vendor feature declaration, or a vendor-specific name in
published Markdown. CI runs both helper-family checks. The check does not prove
that a worker is safe. Runtime verification remains the orchestrator's job.

## Release and migration guidance

The source repository is the source of truth. Edit the source skill,
`publication.json`, adapter contract, and helper-family documents there. Do not
edit generated release archives, installed skill copies, or copied adapter
catalogs directly. Regenerate or reinstall them, then run the compatibility
checks and the full contract suite before publishing.

Release an adapter when its vendor command syntax, model catalog, or capability
probe changes. Release the source skill only when its interview or
documentation workflow changes. A vendor model release therefore updates one
adapter and its catalog record. It does not require a pull request to every
consumer skill.

Existing AGY-only consumers migrate by removing vendor model IDs and command
examples from their source skill, adding `publication.json`, and declaring the
offload adapter as optional unless delegation is required for the workflow.
Replace vendor-specific settings with a model preference, separate effort,
required capabilities, and the normalized result fields. Keep the old AGY
adapter installed during the migration, run the compatibility checker, and
move any vendor-specific routing or security text into the adapter package.
