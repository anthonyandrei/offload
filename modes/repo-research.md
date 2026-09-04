# Repository research mode

Conducts bounded local repository investigations, audits, and invariant checks using isolated workspaces and read-only orchestrator verification.

## Preconditions and helper selection

Select the helper family matching your current host shell:

- **POSIX shells (Bash 3.2+)**: Use `scripts/make-research-workspace.sh`, `scripts/run-agy-json.sh`, and `scripts/cleanup-research-workspace.sh`. Requires Git, `agy`, `jq`, and Python 3.
- **PowerShell (PowerShell 7+)**: Use `scripts/make-research-workspace.ps1`, `scripts/run-agy-json.ps1`, and `scripts/cleanup-research-workspace.ps1`. Native Windows orchestrators require only PowerShell 7 (`pwsh`), Git, and `agy`. Windows workflows do not require Bash, WSL, Git Bash, Python, or `jq`.

Complete the shared preflight model availability check described in [`SKILL.md`](../SKILL.md) before dispatching workers. Researchers route through `model-policy.json` (`gemini-3.8-flash-high` default). Do not pass `--model` or `--effort` directly.

## Assignment requirements

Every repository research assignment must define four fields:

1. **One bounded question.** A specific inquiry answerable from code (for example, "Which API endpoints omit session authentication?").
2. **Allowed scope.** Explicit list of files, directories, or modules the worker is permitted to inspect.
3. **Evidence expectations.** Concrete citations required for each finding (file paths with line numbers or ranges, and reproducible commands).
4. **Explicit non-mutation rule.** A clear instruction: investigate only, make no file modifications or creations, and dispatch no nested workers.

Open-ended research without a bounded question, defined scope, and evidence expectations is out of scope.

## Filesystem isolation and workspace creation

Do not point workers directly at the live repository. `--mode plan` is a version-sensitive behavioral hint, not a write barrier; the `agy 1.1.25` probe is an observation, not a guarantee. Similarly, `--add-dir` grants directory access without confining worker writes. Filesystem isolation and disposable workspaces are the containment boundary.

Isolate every research run in a disposable workspace:

#### Bash
```bash
OFFLOAD_ROOT="<path to installed _offload skill>"
WORKSPACE=$("$OFFLOAD_ROOT/scripts/make-research-workspace.sh" --source-repo "$PWD" --path "<scope path 1>" --path "<scope path 2>")
```

#### PowerShell
```powershell
$OffloadRoot = "<path to installed _offload skill>"
$Workspace = (& "$OffloadRoot/scripts/make-research-workspace.ps1" --source-repo (Get-Location).Path --path "<scope path 1>" --path "<scope path 2>").Trim()
```

The workspace helper creates a unique temporary directory, writes the `.offload-research-workspace` marker, and copies only declared scope paths into `<workspace>/repo/`. Launch the worker with its working directory set to the workspace and `--add-dir` pointing at `<workspace>/repo`. The live repository remains untouched by worker processes.

## Worker dispatch

Dispatch researchers in parallel using role `researcher` with a structured schema and the matching launcher helper. The launcher resolves `gemini-3.8-flash-high` from `model-policy.json`:

#### Bash
```bash
RESEARCH_SCHEMA='{"type":"object","properties":{"lane_id":{"type":"string"},"lane_kind":{"type":"string","enum":["research","audit"]},"question":{"type":"string"},"overall_status":{"type":"string","enum":["complete","inconclusive","blocked"]},"uncertainty":{"type":"string"},"findings":{"type":"array","items":{"type":"object","properties":{"finding":{"type":"string"},"priority":{"type":"string","enum":["high","medium","low"]},"status":{"type":"string","enum":["confirmed","refuted","inconclusive"]},"evidence_locations":{"type":"array","items":{"type":"string"}},"evidence_commands":{"type":"array","items":{"type":"string"}}},"required":["finding","priority","status","evidence_locations"]}}},"required":["lane_id","lane_kind","question","overall_status","uncertainty","findings"]}'

"$OFFLOAD_ROOT/scripts/run-agy-json.sh" \
  --role researcher \
  --output "$WORKSPACE/<slug>.attempt1.research.json" \
  --error "$WORKSPACE/<slug>.attempt1.research.err" \
  -- \
  -p "Lane ID: <slug>. Lane kind: <research or audit>. Question: <bounded question>. Allowed scope: <scope>. Evidence expectations: <expectations>. Non-mutation rule: investigate only, do not create or edit files, do not dispatch nested workers." \
  --output-format json \
  --mode plan \
  --json-schema "$RESEARCH_SCHEMA" \
  --add-dir "$WORKSPACE/repo" \
  --print-timeout 20m
```

#### PowerShell
```powershell
$ResearchSchema = '{"type":"object","properties":{"lane_id":{"type":"string"},"lane_kind":{"type":"string","enum":["research","audit"]},"question":{"type":"string"},"overall_status":{"type":"string","enum":["complete","inconclusive","blocked"]},"uncertainty":{"type":"string"},"findings":{"type":"array","items":{"type":"object","properties":{"finding":{"type":"string"},"priority":{"type":"string","enum":["high","medium","low"]},"status":{"type":"string","enum":["confirmed","refuted","inconclusive"]},"evidence_locations":{"type":"array","items":{"type":"string"}},"evidence_commands":{"type":"array","items":{"type":"string"}}},"required":["finding","priority","status","evidence_locations"]}}},"required":["lane_id","lane_kind","question","overall_status","uncertainty","findings"]}'

& "$OffloadRoot/scripts/run-agy-json.ps1" `
  --role researcher `
  --output "$Workspace/<slug>.attempt1.research.json" `
  --error "$Workspace/<slug>.attempt1.research.err" `
  '--' `
  -p "Lane ID: <slug>. Lane kind: <research or audit>. Question: <bounded question>. Allowed scope: <scope>. Evidence expectations: <expectations>. Non-mutation rule: investigate only, do not create or edit files, do not dispatch nested workers." `
  --output-format json `
  --mode plan `
  --json-schema $ResearchSchema `
  --add-dir "$Workspace/repo" `
  --print-timeout 20m
```

Read `structured_output` from the JSON response to extract validated findings.

If a lane needs its one permitted retry, keep the same `lane_id` and use new paths. Set `ATTEMPT=2` in Bash or `$Attempt = 2` in PowerShell, then dispatch to `<slug>.attempt2.research.json` and `<slug>.attempt2.research.err`. Record both paths in the corresponding attempt's `evidence_paths`, and set an explicit `accepted_attempt` after verification. Any report or later consumer must read only the selected attempt, never a wildcard that could include both attempts.

## Verification protocol

Never accept a worker's research findings on trust alone. Run this verification protocol against the live repository using read-only orchestrator commands:

1. **Scope validation.** Confirm all cited `evidence_locations` and `evidence_commands` stay inside the declared scope. Treat out-of-scope citations as invalid.
2. **Priority assessment.** Independently evaluate finding severity. Correct worker-assigned priority when needed so critical findings cannot bypass thorough review.
3. **Direct check of high-priority findings.** Inspect the exact cited file paths and line ranges in the live repository. Before running any `evidence_command`, inspect it to ensure it is read-only, non-interactive, and safe. Confirm the evidence directly proves the finding. Record provenance as `orchestrator+checked`.
4. **Sampling lower-priority findings.** Spot-check a representative sample of medium- and low-priority findings against the live codebase. Record provenance as `orchestrator+sampled`.
5. **Mark unsupported claims as unverified.** If a finding lacks concrete evidence, cites out-of-scope files, references unsafe commands, or fails manual checking, classify it as `UNVERIFIED` (provenance `agy+unverified`).
6. **Record sample counts and provenance.** Note priority adjustments, the exact sample verified, and individual finding provenance in the final report.

## Retry, recovery, and fallback

Follow the shared recovery, retry accounting, and failure handling rules in [`SKILL.md`](../SKILL.md):

- **Stable worker IDs and retry ceiling.** Assign a stable `worker_id` to each investigation lane. Attempt 1 is initial dispatch; attempt 2 is its only permitted retry. Maximum two attempts total per assignment.
- **Outcome tracking.** Record each attempt and verification outcome in `routing-outcomes.json`.
- **Operational failure.** If a worker crashes, times out, or produces unparsable output, redispatch once using `--route default`. No model escalation for operational failure.
- **Orchestrator fallback.** If the second attempt fails or findings remain inconclusive, complete the investigation directly as the orchestrator (`orchestrator (fallback)`).
- **Quota exhaustion.** Explicit Gemini quota exhaustion triggers immediate quota handoff per [`SKILL.md`](../SKILL.md). Do not retry or switch models. Preserve completed artifacts and return unfinished work to the calling orchestrator.

## Cleanup

After verification completes, clean the temporary workspace and snapshot directory using the matching cleanup helper. On success, it retains `final.md`, `provenance.json` when present, `routing-outcomes.json`, the workspace marker, and an `evidence-disposition.json` manifest. The manifest records every evidence path from the routing record, its pre-cleanup existence, a SHA-256 hash for existing regular files, and whether the path was retained, pruned, missing, or left uninspected for safety. Raw worker artifacts remain the default success-pruning policy. A partial or failed run retains all artifacts.

#### Bash
```bash
"$OFFLOAD_ROOT/scripts/cleanup-research-workspace.sh" --workspace "$WORKSPACE" --status success
```

#### PowerShell
```powershell
& "$OffloadRoot/scripts/cleanup-research-workspace.ps1" --workspace "$Workspace" --status success
```
