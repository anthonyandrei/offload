# Web research mode

Conducts cited online investigations and multi-angle technical research by dispatching parallel headless `agy` workers, synthesizing findings into a structured claim ledger, and validating every final citation with an independent auditor.

## Preconditions and sources

1. **Public-source default.** Research workers query public online sources by default.
2. **Explicit authorization for private sources.** Accessing private, internal, or authenticated sources requires explicit authorization from the user for that specific run. Never forward cookies, session tokens, browser profiles, or environment credentials implicitly.
3. **Helper family and environment requirements.** Select the helper family matching your host shell:
   - **POSIX shells (Bash 3.2+)**: Use `.sh` scripts in `scripts/`. Requires Git, `agy`, `jq`, and Python 3.
   - **PowerShell (PowerShell 7+)**: Use `.ps1` scripts in `scripts/`. Native Windows orchestrators require only PowerShell 7 (`pwsh`), Git, and `agy`. Windows workflows do not require Bash, WSL, Git Bash, Python, or `jq`.
4. **`agy` availability.** Workers are launched using the matching `run-agy-json` helper, which handles `AGY_BIN` precedence and output capture.
5. **Filesystem isolation.** Every research run operates in a disposable workspace outside the live repository.
6. **Model policy and preflight check.** Complete the shared preflight model availability check described in [`SKILL.md`](../SKILL.md) before dispatching workers. All roles route through `model-policy.json` (`gemini-3.8-flash-high` default). Do not pass `--model` or `--effort` directly.

## Worker isolation and mixed repositories

`--mode plan` is a version-sensitive behavioral hint, not a write barrier. The accepted `agy 1.1.25` probe blocked the tested direct write outside the permitted artifact area, but exposed tools and commands mean this is not a guarantee. Similarly, `--add-dir` grants directory access without confining worker writes. Safety and containment rely on strict filesystem isolation:

1. **Create workspace.** Initialize a temporary directory outside the live codebase using the matching workspace helper:

   #### Bash
   ```bash
   OFFLOAD_ROOT="<path to the installed _offload skill>"
   WORKSPACE=$("$OFFLOAD_ROOT/scripts/make-research-workspace.sh" --source-repo "$PWD" --path "<declared path>")
   ```

   #### PowerShell
   ```powershell
   $OffloadRoot = "<path to the installed _offload skill>"
   $Workspace = (& "$OffloadRoot/scripts/make-research-workspace.ps1" --source-repo (Get-Location).Path --path "<declared path>").Trim()
   ```

2. **Mixed repository handoff.** When research requires context from local files, declare the exact minimal paths required. The workspace helper writes the `.offload-research-workspace` marker and copies only those declared paths into `<workspace>/repo/`.
3. **No live repository paths.** Never pass the live repository path in worker prompts or `--add-dir` arguments. Point `--add-dir` at the snapshot directory (`<workspace>/repo`) when local context is needed.
4. **Local evidence verification.** The orchestrator independently checks all local codebase citations against the live repository using read-only commands.

## Profiles and triggers

Choose between two research profiles based on task complexity:

### Standard profile

Dispatches two or three researchers in parallel across distinct evidence angles, followed by one synthesizer, followed by one auditor. Use standard profile for general technical questions, documentation lookups, and library comparisons.

### Deep profile

Dispatches up to five researchers in total. Deep research starts from standard-profile findings and adds only the supplementary angles required to resolve specific uncertainty or conflicts. Do not rerun standard angles.

Deep profile activates upon explicit user request or when one of these named triggers is encountered:

- **Material source conflict**: High-trust primary sources directly contradict one another.
- **Costly or hard-to-reverse decision**: Architectural choices, infrastructure migrations, or licensing commitments.
- **Citation-sensitive output**: Formal specifications, security advisories, or compliance requirements.
- **Substantial counterevidence**: Initial findings challenge core architectural assumptions.

Record the specific deep trigger in the final report and in `provenance.json`. If no trigger applies, use standard profile.

## Worker roles and models

Workers are dispatched by role using `run-agy-json` with `--role <role>`. The launcher resolves models dynamically from `model-policy.json`. Do not pass `--model` or `--effort` directly. Refer to [`SKILL.md`](../SKILL.md) for the shared model routing, preflight, and recovery contract.

| Role | Stage | Default model | Effort | Alternative model | Mode | Job |
|---|---|---|---|---|---|---|
| researcher | 1 | `gemini-3.8-flash-high` | high | — | `plan` | Gathers structured claims and citations for an assigned evidence angle. |
| synthesizer | 2 | `gemini-3.8-flash-high` | high | — | `plan` | Builds claim ledger, resolves agreements/conflicts, and drafts synthesis. |
| auditor | 3 | `gemini-3.8-flash-high` | high | — | `plan` | Independently verifies every citation in the proposed final answer. |

A historical live smoke comparison against Gemini 3.7 retained Flash for every role. The proposed Pro synthesizer and auditor split did not complete its mandatory synthesis stage, while the all-Flash control completed synthesis and citation audit with four supported claims. See [`tests/live-smoke-comparison.md`](../tests/live-smoke-comparison.md) for the recorded judgment.

All workers run with a 20-minute timeout (`--print-timeout 20m`).

## Stage 1: Dispatch researchers

Divide the investigation into distinct evidence angles. Overlap between angles is permitted only to test conflicting claims or verify source independence. Example angles:
- Angle A: Official documentation, specifications, and vendor release notes.
- Angle B: Independent benchmarks, real-world case studies, and performance reports.
- Angle C: Known failure modes, security advisories, and counter-arguments.

### Researcher JSON schema

```json
{
  "type": "object",
  "properties": {
    "run_id": {"type": "string"},
    "angle_id": {"type": "string"},
    "status": {"type": "string", "enum": ["success", "failed", "inconclusive"]},
    "failure_reason": {"type": "string"},
    "question": {"type": "string"},
    "evidence_angle": {"type": "string"},
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "claim": {"type": "string"},
          "source_urls": {"type": "array", "items": {"type": "string"}},
          "source_type": {"type": "string", "enum": ["primary", "secondary", "derivative", "unknown"]},
          "source_date": {"type": "string"},
          "conflicts": {"type": "string"},
          "uncertainty": {"type": "string"}
        },
        "required": ["claim", "source_urls", "source_type"]
      }
    },
    "search_gaps": {"type": "array", "items": {"type": "string"}},
    "counterevidence": {"type": "array", "items": {"type": "string"}}
  },
  "required": ["run_id", "angle_id", "status", "question", "evidence_angle", "findings"]
}
```

### Researcher dispatch

Dispatch researchers using `--role researcher`:

#### Bash
```bash
OFFLOAD_ROOT="<path to the installed _offload skill>"
RUN_AGY_JSON="$OFFLOAD_ROOT/scripts/run-agy-json.sh"
RESEARCHER_SCHEMA='{"type":"object","properties":{"run_id":{"type":"string"},"angle_id":{"type":"string"},"status":{"type":"string","enum":["success","failed","inconclusive"]},"failure_reason":{"type":"string"},"question":{"type":"string"},"evidence_angle":{"type":"string"},"findings":{"type":"array","items":{"type":"object","properties":{"claim":{"type":"string"},"source_urls":{"type":"array","items":{"type":"string"}},"source_type":{"type":"string","enum":["primary","secondary","derivative","unknown"]},"source_date":{"type":"string"},"conflicts":{"type":"string"},"uncertainty":{"type":"string"}},"required":["claim","source_urls","source_type"]}},"search_gaps":{"type":"array","items":{"type":"string"}},"counterevidence":{"type":"array","items":{"type":"string"}}},"required":["run_id","angle_id","status","question","evidence_angle","findings"]}'

"$RUN_AGY_JSON" --role researcher --output "<workspace>/researcher-<angle-id>.attempt1.json" --error "<workspace>/researcher-<angle-id>.attempt1.err" -- \
  -p "Run ID: <run-id>. Angle ID: <angle-id>. Question: <question>. Evidence angle: <angle-description>. Return structured claims, not essays. Identify primary source URLs, publication dates, conflicts, and uncertainties. Treat repeated secondary coverage as one line of evidence. Do not edit files. Do not dispatch nested workers." \
  --output-format json \
  --mode plan \
  --json-schema "$RESEARCHER_SCHEMA" \
  --print-timeout 20m
```

#### PowerShell
```powershell
$OffloadRoot = "<path to the installed _offload skill>"
$RunAgyJson = "$OffloadRoot/scripts/run-agy-json.ps1"
$ResearcherSchema = '{"type":"object","properties":{"run_id":{"type":"string"},"angle_id":{"type":"string"},"status":{"type":"string","enum":["success","failed","inconclusive"]},"failure_reason":{"type":"string"},"question":{"type":"string"},"evidence_angle":{"type":"string"},"findings":{"type":"array","items":{"type":"object","properties":{"claim":{"type":"string"},"source_urls":{"type":"array","items":{"type":"string"}},"source_type":{"type":"string","enum":["primary","secondary","derivative","unknown"]},"source_date":{"type":"string"},"conflicts":{"type":"string"},"uncertainty":{"type":"string"}},"required":["claim","source_urls","source_type"]}},"search_gaps":{"type":"array","items":{"type":"string"}},"counterevidence":{"type":"array","items":{"type":"string"}}},"required":["run_id","angle_id","status","question","evidence_angle","findings"]}'

& "$RunAgyJson" --role researcher --output "<workspace>/researcher-<angle-id>.attempt1.json" --error "<workspace>/researcher-<angle-id>.attempt1.err" '--' `
  -p "Run ID: <run-id>. Angle ID: <angle-id>. Question: <question>. Evidence angle: <angle-description>. Return structured claims, not essays. Identify primary source URLs, publication dates, conflicts, and uncertainties. Treat repeated secondary coverage as one line of evidence. Do not edit files. Do not dispatch nested workers." `
  --output-format json `
  --mode plan `
  --json-schema $ResearcherSchema `
  --print-timeout 20m
```

Read `structured_output` from each researcher JSON response to extract validated findings for synthesis. Do not forward the top-level `response`, usage metadata, or the full JSON envelope.

If a researcher needs its one retry, preserve the same worker ID and dispatch to `<workspace>/researcher-<angle-id>.attempt2.json` and `<workspace>/researcher-<angle-id>.attempt2.err`. Record both attempts, set the worker's explicit `accepted_attempt`, and point its selected `output` field at that artifact after verification. Only selected researcher outputs may feed synthesis.

## Stage 2: Synthesize claim ledger

The synthesizer merges findings across the verified selected researcher outputs and constructs a claim ledger.

### Synthesis rules

1. **Claim ledger.** Map each finding to a discrete claim ID with citations, decision relevance, and status.
2. **Combine propositions.** Combine claims only when cited sources support the exact same proposition.
3. **Remove unsupported incidental claims.** Discard low-relevance claims that lack primary or verifiable support.
4. **Preserve decision-relevant uncertainty.** Retain unresolved or conflicting claims that affect the core question, clearly labeling the evidence gap.
5. **No voting.** Do not resolve disagreements by counting worker instances. Weigh primary and independent sources over derivative summaries.

### Synthesizer JSON schema

```json
{
  "type": "object",
  "properties": {
    "claim_ledger": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "claim_id": {"type": "string"},
          "claim": {"type": "string"},
          "citations": {"type": "array", "items": {"type": "string"}},
          "decision_relevance": {"type": "string", "enum": ["critical", "supporting", "incidental"]},
          "status": {"type": "string", "enum": ["supported", "conflicted", "unresolved"]},
          "inferences": {"type": "string"}
        },
        "required": ["claim_id", "claim", "citations", "decision_relevance", "status"]
      }
    },
    "proposed_answer": {"type": "string"},
    "omitted_unsupported_claims": {"type": "array", "items": {"type": "string"}},
    "unresolved_claims": {"type": "array", "items": {"type": "string"}},
    "profile_used": {"type": "string", "enum": ["standard", "deep"]},
    "deep_trigger": {"type": "string"}
  },
  "required": ["claim_ledger", "proposed_answer", "profile_used"]
}
```

### Synthesizer dispatch

Before dispatching, select the inputs from the verified worker records. `WORKER_RECORDS` is an explicit JSON file containing the worker records after routing and verification. The selector follows each researcher's `accepted_attempt`, checks that the matching versioned routing attempt completed with `verification_status: "passed"`, checks the selected artifact's successful researcher envelope, and returns the surviving paths and distinct `angle_id` values. It does not delete or hide omitted artifacts; failed and superseded attempts remain available in the routing record and workspace for diagnostics.

If fewer than two independent angles survive, take the documented partial-result fallback and do not dispatch a synthesizer. When the threshold is met, pass the returned paths as an explicit array to the extractor:

#### Bash selection gate
```bash
RESEARCH_SELECTION_JSON="$("$OFFLOAD_ROOT/scripts/select-research-outputs.sh" \
  --workers "$WORKER_RECORDS" \
  --base-dir "<workspace>")"
SURVIVING_ANGLE_COUNT="$(jq -r '.independent_angle_count' <<<"$RESEARCH_SELECTION_JSON")"
if [ "$SURVIVING_ANGLE_COUNT" -lt 2 ]; then
  printf 'Fewer than two verified independent research angles survived; use partial fallback.\n' >&2
else
  ACCEPTED_RESEARCH_OUTPUTS=()
  while IFS= read -r selected_file; do
    ACCEPTED_RESEARCH_OUTPUTS+=("$selected_file")
  done < <(jq -r '.selected_files[]' <<<"$RESEARCH_SELECTION_JSON" | tr -d '\r')
fi
```

#### PowerShell selection gate
```powershell
$ResearchSelectionJson = & "$OffloadRoot/scripts/select-research-outputs.ps1" `
  --workers $WorkerRecords `
  --base-dir "<workspace>"
$ResearchSelection = $ResearchSelectionJson | ConvertFrom-Json
$SurvivingAngleCount = [int]$ResearchSelection.independent_angle_count
if ($SurvivingAngleCount -lt 2) {
    [Console]::Error.WriteLine('Fewer than two verified independent research angles survived; use partial fallback.')
} else {
    $AcceptedResearcherFiles = @($ResearchSelection.selected_files)
}
```

When the selection gate reaches the synthesis branch, dispatch the synthesizer using `--role synthesizer`:

#### Bash
```bash
MERGED_RESEARCH_FINDINGS="$("$OFFLOAD_ROOT/scripts/extract-structured-output.sh" --array "${ACCEPTED_RESEARCH_OUTPUTS[@]}")"
SYNTH_SCHEMA='{"type":"object","properties":{"claim_ledger":{"type":"array","items":{"type":"object","properties":{"claim_id":{"type":"string"},"claim":{"type":"string"},"citations":{"type":"array","items":{"type":"string"}},"decision_relevance":{"type":"string","enum":["critical","supporting","incidental"]},"status":{"type":"string","enum":["supported","conflicted","unresolved"]},"inferences":{"type":"string"}},"required":["claim_id","claim","citations","decision_relevance","status"]}},"proposed_answer":{"type":"string"},"omitted_unsupported_claims":{"type":"array","items":{"type":"string"}},"unresolved_claims":{"type":"array","items":{"type":"string"}},"profile_used":{"type":"string","enum":["standard","deep"]},"deep_trigger":{"type":"string"}},"required":["claim_ledger","proposed_answer","profile_used"]}'

"$RUN_AGY_JSON" --role synthesizer --output "<workspace>/synthesizer.attempt1.json" --error "<workspace>/synthesizer.attempt1.err" -- \
  -p "Question: <question>. Profile: <standard|deep>. Deep trigger: <trigger-or-none>. Researcher findings: $MERGED_RESEARCH_FINDINGS. Build a claim ledger. Discard unsupported incidental claims. Keep decision-relevant gaps as unresolved. Draft a proposed answer referencing claim IDs. Do not edit files. Do not dispatch nested workers." \
  --output-format json \
  --mode plan \
  --json-schema "$SYNTH_SCHEMA" \
  --print-timeout 20m
```

#### PowerShell
```powershell
$MergedResearchFindings = & "$OffloadRoot/scripts/extract-structured-output.ps1" --array $AcceptedResearcherFiles
$SynthSchema = '{"type":"object","properties":{"claim_ledger":{"type":"array","items":{"type":"object","properties":{"claim_id":{"type":"string"},"claim":{"type":"string"},"citations":{"type":"array","items":{"type":"string"}},"decision_relevance":{"type":"string","enum":["critical","supporting","incidental"]},"status":{"type":"string","enum":["supported","conflicted","unresolved"]},"inferences":{"type":"string"}},"required":["claim_id","claim","citations","decision_relevance","status"]}},"proposed_answer":{"type":"string"},"omitted_unsupported_claims":{"type":"array","items":{"type":"string"}},"unresolved_claims":{"type":"array","items":{"type":"string"}},"profile_used":{"type":"string","enum":["standard","deep"]},"deep_trigger":{"type":"string"}},"required":["claim_ledger","proposed_answer","profile_used"]}'

& "$RunAgyJson" --role synthesizer --output "<workspace>/synthesizer.attempt1.json" --error "<workspace>/synthesizer.attempt1.err" '--' `
  -p "Question: <question>. Profile: <standard|deep>. Deep trigger: <trigger-or-none>. Researcher findings: $MergedResearchFindings. Build a claim ledger. Discard unsupported incidental claims. Keep decision-relevant gaps as unresolved. Draft a proposed answer referencing claim IDs. Do not edit files. Do not dispatch nested workers." `
  --output-format json `
  --mode plan `
  --json-schema $SynthSchema `
  --print-timeout 20m
```

Read `structured_output` from the synthesizer JSON response to extract `proposed_answer` and `claim_ledger` for the citation audit. Do not forward the synthesizer's top-level `response`.

If the audit requires a synthesizer revision, redispatch the same synthesizer worker with `--output "<workspace>/synthesizer.attempt2.json"` and `--error "<workspace>/synthesizer.attempt2.err"`. Set its `accepted_attempt` only after the revised output passes the final audit.

## Stage 3: Independent citation audit

The auditor is independent. It receives the proposed answer and claim ledger (not the synthesizer's chain-of-thought).

### Citation audit rules

The auditor opens each URL cited in the proposed answer and checks:
1. **Resolution.** The URL resolves to the expected source page.
2. **Support.** The source directly supports the associated claim, or supports it via a stated logical inference.
3. **Date fitness.** The publication or update date is appropriate for time-sensitive claims.
4. **Classification.** The source is categorized as primary, secondary, or derivative.
5. **Visibility.** Material conflicts and uncertainties remain visible in the answer.

### Auditor JSON schema

```json
{
  "type": "object",
  "properties": {
    "citation_audits": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "citation_url": {"type": "string"},
          "claim_id": {"type": "string"},
          "resolves": {"type": "boolean"},
          "support_verdict": {"type": "string", "enum": ["supports", "partially_supports", "refutes", "unsupported"]},
          "source_classification": {"type": "string", "enum": ["primary", "secondary", "derivative", "unknown"]},
          "independence_notes": {"type": "string"},
          "date_fitness": {"type": "string"},
          "notes": {"type": "string"}
        },
        "required": ["citation_url", "claim_id", "resolves", "support_verdict", "source_classification"]
      }
    },
    "final_status": {"type": "string", "enum": ["pass", "revise", "incomplete"]},
    "claims_to_remove": {"type": "array", "items": {"type": "string"}},
    "claims_to_narrow": {"type": "array", "items": {"type": "string"}},
    "claims_unresolved": {"type": "array", "items": {"type": "string"}}
  },
  "required": ["citation_audits", "final_status"]
}
```

### Auditor dispatch

Dispatch the auditor using `--role auditor`:

#### Bash
```bash
ACCEPTED_SYNTHESIZER_OUTPUT="<workspace>/synthesizer.attempt<accepted-attempt>.json"
PROPOSED_ANSWER="$(jq -r '.structured_output.proposed_answer' "$ACCEPTED_SYNTHESIZER_OUTPUT")"
CLAIM_LEDGER="$(jq -c '.structured_output.claim_ledger' "$ACCEPTED_SYNTHESIZER_OUTPUT")"
AUDITOR_SCHEMA='{"type":"object","properties":{"citation_audits":{"type":"array","items":{"type":"object","properties":{"citation_url":{"type":"string"},"claim_id":{"type":"string"},"resolves":{"type":"boolean"},"support_verdict":{"type":"string","enum":["supports","partially_supports","refutes","unsupported"]},"source_classification":{"type":"string","enum":["primary","secondary","derivative","unknown"]},"independence_notes":{"type":"string"},"date_fitness":{"type":"string"},"notes":{"type":"string"}},"required":["citation_url","claim_id","resolves","support_verdict","source_classification"]}},"final_status":{"type":"string","enum":["pass","revise","incomplete"]},"claims_to_remove":{"type":"array","items":{"type":"string"}},"claims_to_narrow":{"type":"array","items":{"type":"string"}},"claims_unresolved":{"type":"array","items":{"type":"string"}}},"required":["citation_audits","final_status"]}'

"$RUN_AGY_JSON" --role auditor --output "<workspace>/auditor.attempt1.json" --error "<workspace>/auditor.attempt1.err" -- \
  -p "Audit every citation in the proposed synthesis against live sources. Proposed answer: $PROPOSED_ANSWER. Claim ledger: $CLAIM_LEDGER. Verify each citation URL, check whether it directly supports the claim, classify primary vs derivative, and evaluate date fitness. Do not edit files. Do not dispatch nested workers." \
  --output-format json \
  --mode plan \
  --json-schema "$AUDITOR_SCHEMA" \
  --print-timeout 20m
```

#### PowerShell
```powershell
$AcceptedSynthesizerOutput = "<workspace>/synthesizer.attempt<accepted-attempt>.json"
$SynthJson = Get-Content $AcceptedSynthesizerOutput -Raw | ConvertFrom-Json
$ProposedAnswer = $SynthJson.structured_output.proposed_answer
$ClaimLedger = $SynthJson.structured_output.claim_ledger | ConvertTo-Json -Compress -Depth 10
$AuditorSchema = '{"type":"object","properties":{"citation_audits":{"type":"array","items":{"type":"object","properties":{"citation_url":{"type":"string"},"claim_id":{"type":"string"},"resolves":{"type":"boolean"},"support_verdict":{"type":"string","enum":["supports","partially_supports","refutes","unsupported"]},"source_classification":{"type":"string","enum":["primary","secondary","derivative","unknown"]},"independence_notes":{"type":"string"},"date_fitness":{"type":"string"},"notes":{"type":"string"}},"required":["citation_url","claim_id","resolves","support_verdict","source_classification"]}},"final_status":{"type":"string","enum":["pass","revise","incomplete"]},"claims_to_remove":{"type":"array","items":{"type":"string"}},"claims_to_narrow":{"type":"array","items":{"type":"string"}},"claims_unresolved":{"type":"array","items":{"type":"string"}}},"required":["citation_audits","final_status"]}'

& "$RunAgyJson" --role auditor --output "<workspace>/auditor.attempt1.json" --error "<workspace>/auditor.attempt1.err" '--' `
  -p "Audit every citation in the proposed synthesis against live sources. Proposed answer: $ProposedAnswer. Claim ledger: $ClaimLedger. Verify each citation URL, check whether it directly supports the claim, classify primary vs derivative, and evaluate date fitness. Do not edit files. Do not dispatch nested workers." `
  --output-format json `
  --mode plan `
  --json-schema $AuditorSchema `
  --print-timeout 20m
```

Read `structured_output` from the auditor JSON response to extract `citation_audits` and `final_status`.

If the auditor needs its one retry for the final audit, use `--output "<workspace>/auditor.attempt2.json"` and `--error "<workspace>/auditor.attempt2.err"` with the same auditor worker ID. Record that attempt separately, set the auditor's `accepted_attempt` after the final audit passes, and use its explicitly selected artifact for audit validation and the final report.

### Audit verification and acceptance rules

Before accepting the synthesis, mechanically validate audit coverage and verdict consistency:

#### Bash
```bash
ACCEPTED_AUDITOR_OUTPUT="<workspace>/auditor.attempt<accepted-attempt>.json"
"$OFFLOAD_ROOT/scripts/check-citation-audit.sh" \
  --ledger "$ACCEPTED_SYNTHESIZER_OUTPUT" \
  --auditor "$ACCEPTED_AUDITOR_OUTPUT"
AUDIT_STATUS=$?
```

#### PowerShell
```powershell
$AcceptedAuditorOutput = "<workspace>/auditor.attempt<accepted-attempt>.json"
& "$OffloadRoot/scripts/check-citation-audit.ps1" `
  --ledger $AcceptedSynthesizerOutput `
  --auditor $AcceptedAuditorOutput
$AuditStatus = $LASTEXITCODE
```

Audit validation enforces mechanical acceptance contracts across both shells:
1. **Required claim/citation pair coverage**: Every citation URL listed under each claim in the claim ledger forms a required `(claim_id, citation_url)` pair. Two citations for one claim require separate audit coverage.
2. **Exact coverage**: A nonempty required pair set rejects empty or partial `citation_audits` even when `final_status` is `pass`. Duplicate and unknown claim/citation pairs are rejected.
3. **Verdict consistency for automated acceptance**: Before automated acceptance (`exit 0`), every required pair must have `resolves: true` and `support_verdict: "supports"`. Failed entries (`resolves: false`, non-supporting verdicts `partially_supports`, `refutes`, `unsupported`) or unresolved entries (`claims_to_remove`, `claims_to_narrow`, `claims_unresolved`) cannot coexist with an accepted overall `pass`.
4. **Ledger with no auditable pairs**: By default, research assignments require citations. A ledger with no auditable pairs cannot bypass citations required by the research assignment; automated acceptance is rejected. If an explicit documented assignment branch permits citation-free findings, `--allow-empty` must be explicitly specified and requires empty `citation_audits`.
5. **Workflow branching**:
   - `exit 0` (`pass`): Valid complete coverage with supported verdicts. The synthesis is accepted. Label supported claims as `audited` in the final report.
   - `exit 1` (`revise`): Valid complete coverage where the auditor requested revision. The synthesizer may perform **one** revision pass to narrow or remove rejected claims (consuming the synthesizer's second attempt, attempt 2). The revised output undergoes one final audit (consuming the auditor's second attempt, attempt 2).
   - `exit 2` (`invalid`): Malformed response, partial coverage, duplicate/unknown pairs, contradictory verdicts, or zero pairs when citations required. Triggers one bounded retry of the failing worker using `--route default` (if attempt 1) or falls back to direct orchestrator review or `partial` status.

Do not enter open-ended revision loops. If the second audit fails or exhausts the retry budget, omit incidental unsupported claims or mark decision-relevant claims as unresolved and transition the run to `partial` status.

## Failure handling and partial results

Follow the shared recovery, retry accounting, and failure handling rules in [`SKILL.md`](../SKILL.md):

- **Stable worker IDs and retry ceiling.** Assign a stable `worker_id` to each assignment (researcher angle, synthesizer, auditor). Attempt 1 is initial dispatch; attempt 2 is its only permitted retry. Maximum two attempts total per assignment.
- **Outcome tracking.** Record each attempt and verification outcome in `routing-outcomes.json`.
- **Researcher failure.** If a researcher crashes, times out, or produces unparsable output, retry once with the error details using `--route default`. The selection gate admits only the verified accepted attempt for each assignment. If a retry fails, synthesis proceeds as long as at least two distinct `angle_id` values remain; otherwise use the partial-result fallback. The final report explicitly names any omitted angle.
- **Synthesis or audit failure.** Synthesis and citation audit are mandatory stages. The allowed synthesizer revision pass consumes the synthesizer's second attempt. The subsequent audit consumes the auditor's second attempt. If either stage crashes, times out, returns unparsable JSON, or fails to resolve citations after exhausting its 2-attempt budget, the run transitions to `partial` status.
- **Partial result contract.** A `partial` run returns audited claims and raw findings collected up to the point of failure, but strictly withholds a firm synthesis or recommendation. State the failed stage explicitly and retain all raw artifacts for debugging.
- **Quota exhaustion.** Explicit Gemini quota exhaustion triggers immediate quota handoff per [`SKILL.md`](../SKILL.md). Do not retry or switch models. Preserve completed artifacts and return unfinished work to the calling orchestrator.

## Provenance and cleanup

Browser, GUI, rendering, and other externally observable headless claims require a reality anchor: an explicit artifact type and path or artifact identifier, plus the claim or acceptance criterion it supports. Accept screenshots, DOM snapshots, network captures, console logs, rendered files, or equivalent regular files inside the disposable workspace or owned output; missing or out-of-scope anchors are unverified. Before publishing provenance, `final.md`, or a handoff/report, recursively redact credential-shaped values with stable `[REDACTED]` markers; leave raw scratch evidence unchanged.

At the conclusion of the research run:

1. **Assemble provenance.** Validate and generate `provenance.json` using the matching provenance helper. Each entry in the `workers` array may optionally include a `routing` container (`{schema_version: 1, attempts: [...]}`) retaining all attempts for that worker from `routing-outcomes.json` (canonical fixture: [`tests/fixtures/routing-worker.json`](../tests/fixtures/routing-worker.json)):

   ```json
   {
     "id": "researcher-web-1",
     "role": "researcher",
     "status": "completed",
     "output": "workspace/researcher-web-1.attempt2.json",
     "accepted_attempt": 2,
     "routing": {
       "schema_version": 1,
       "attempts": [
         {
           "worker_id": "researcher-web-1",
           "role": "researcher",
           "mode": "web-research",
           "attempt": 1,
           "policy_revision": "2026-09-03.1",
           "route": "default",
           "model": "gemini-3.8-flash-high",
           "effort": "high",
           "reason": "Initial default dispatch",
           "started_at": "2026-09-03T00:00:00Z",
           "ended_at": "2026-09-03T00:01:30Z",
           "duration_seconds": 90.0,
           "exit_code": 1,
           "state": "failed",
           "failure_class": "quality",
           "verification_status": "failed",
           "evidence_paths": [
             "workspace/researcher-web-1.attempt1.json",
             "workspace/researcher-web-1.attempt1.err"
           ],
           "usage": {
             "prompt_tokens": 1000,
             "candidates_tokens": 250,
             "unit": "tokens"
           }
         },
         {
           "worker_id": "researcher-web-1",
           "role": "researcher",
           "mode": "web-research",
           "attempt": 2,
           "policy_revision": "2026-09-03.1",
           "route": "default",
           "model": "gemini-3.8-flash-high",
           "effort": "high",
           "reason": "Retry authorized after quality gate failure on attempt 1",
           "started_at": "2026-09-03T00:02:00Z",
           "ended_at": "2026-09-03T00:03:30Z",
           "duration_seconds": 90.0,
           "exit_code": 0,
           "state": "completed",
           "failure_class": "none",
           "verification_status": "passed",
             "evidence_paths": [
               "workspace/researcher-web-1.attempt2.json",
               "workspace/researcher-web-1.attempt2.err"
           ],
           "usage": {
             "prompt_tokens": 1200,
             "candidates_tokens": 300,
             "unit": "tokens"
           }
         }
       ]
     }
   }
   ```


   #### Bash
   ```bash
   "$OFFLOAD_ROOT/scripts/collect-provenance.sh" \
     --run-id "<run-id>" \
     --request-summary "<request-summary>" \
     --selected-mode "web-research" \
     --profile "<standard|deep>" \
     --deep-trigger "<trigger-or-empty>" \
     --start-time "<iso8601-start>" \
     --end-time "<iso8601-end>" \
     --duration-seconds "<seconds>" \
     --scratch-path "<workspace>" \
     --workers '<workers-json-array>' \
     --final-citations '<citations-json-array>' \
     --audit-verdicts '<verdicts-json-array>' \
     --final-status "<success|partial>" \
     --incomplete-stage-reasons '<reasons-json-array>' \
     --output "<workspace>/provenance.json"
   ```

   #### PowerShell
   ```powershell
   & "$OffloadRoot/scripts/collect-provenance.ps1" `
     --run-id "<run-id>" `
     --request-summary "<request-summary>" `
     --selected-mode "web-research" `
     --profile "<standard|deep>" `
     --deep-trigger "<trigger-or-empty>" `
     --start-time "<iso8601-start>" `
     --end-time "<iso8601-end>" `
     --duration-seconds "<seconds>" `
     --scratch-path "<workspace>" `
     --workers '<workers-json-array>' `
     --final-citations '<citations-json-array>' `
     --audit-verdicts '<verdicts-json-array>' `
     --final-status "<success|partial>" `
     --incomplete-stage-reasons '<reasons-json-array>' `
     --output "<workspace>/provenance.json"
   ```

2. **Save final result.** Write `<workspace>/final.md` from the explicitly accepted synthesizer and auditor artifacts (and the selected researcher outputs they consumed), or from the retained partial findings. Never glob raw worker JSON when assembling the report.
3. **Run cleanup helper.** Execute the matching cleanup helper:

   #### Bash
   ```bash
   "$OFFLOAD_ROOT/scripts/cleanup-research-workspace.sh" --workspace "<workspace>" --status "<success|partial>"
   ```

   #### PowerShell
   ```powershell
   & "$OffloadRoot/scripts/cleanup-research-workspace.ps1" --workspace "<workspace>" --status "<success|partial>"
   ```

   - On `success`, the helper retains `final.md`, `provenance.json` when present, `routing-outcomes.json`, the workspace marker, and `evidence-disposition.json`. The disposition manifest records every evidence path from the routing record, its pre-cleanup existence, a SHA-256 hash for existing regular files, and a `retained`, `pruned`, `missing`, or safety-driven `uninspected` disposition. Raw intermediate worker JSON files and the temporary repository snapshot are still pruned by default.
   - On `partial` or failed status, the helper preserves all raw artifacts, worker logs, and repository snapshots for debugging.

## Research-then-implementation handoff

When research precedes code implementation (`modes/execution.md`):

1. Complete the full research workflow, synthesis, and citation audit.
2. Distill the verified research into a compact specification, audited claim ledger, and `provenance.json`.
3. Hand only the compact specification to `modes/execution.md`. Never feed raw multi-turn research transcripts to implementation workers.
4. If research concludes with a `partial` status, do not begin execution unless the user explicitly reviews and accepts the identified gaps.
