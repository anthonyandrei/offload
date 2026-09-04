---
status: accepted
---

# Keep published skills vendor-neutral

Decision date: 2026-09-04.

`grill-with-docs` and `offload` have different responsibilities. The source
skill owns its interview and documentation workflow. Offload is an optional
delegation layer. Adapters contain vendor launch syntax, output parsing, model
catalog handling, and capability probes. This boundary prevents a published
source skill from importing one worker vendor's assumptions.

Published consumers use the versioned vendor-neutral publication contract and
capability names. They do not require exact model IDs, family names, or vendor
features. The orchestrator records adapter and model metadata internally so
retries and resume can pin the same choice. That metadata does not become a
consumer dependency.

The Bash and PowerShell helper families keep equivalent observable contracts,
with separate native implementations. The compatibility checker validates a
published skill's manifest against an adapter catalog and rejects unavailable
required adapters, incompatible versions, missing capabilities, vendor-feature
declarations, and vendor names in published Markdown.

Capability support is descriptive. Security enforcement remains with the
orchestrator and its filesystem, ownership, cleanup, execution scope, and gate
checks. A worker or adapter cannot widen those constraints.

The repository is the source of truth. Generated archives, installed copies,
and copied catalogs are release outputs and must not be edited directly. A
source skill release changes the workflow contract. An adapter release handles
vendor model or command changes without requiring a source skill release.

See [`publication-compatibility.md`](../contracts/publication-compatibility.md)
for the manifest, version rules, release steps, and AGY-only migration note.
