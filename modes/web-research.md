# Web research mode

Conducts cited online investigations and multi-angle technical research by dispatching parallel headless `agy` workers, synthesizing findings into a structured claim ledger, and validating every final citation with an independent auditor.

## Preconditions and sources

1. **Public-source default.** Research workers query public online sources by default.
2. **Explicit authorization for private sources.** Accessing private, internal, or authenticated sources requires explicit authorization from the user for that specific run. Never forward cookies, session tokens, browser profiles, or environment credentials implicitly.
3. **`agy` availability.** Verify `agy` on `PATH` or at `~/.local/bin/agy`.
4. **Filesystem isolation.** Every research run operates in a disposable workspace outside the live repository.

## Worker isolation and mixed repositories

`--mode plan` provides a behavioral hint, not a write barrier. Direct testing demonstrated that plan-mode workers can write files. Similarly, `--add-dir` grants directory access without confining worker writes. Safety and containment rely on strict filesystem isolation:

1. **Create workspace.** Use `scripts/make-research-workspace.sh` to initialize a temporary directory outside the live codebase.
2. **Mixed repository handoff.** When research requires context from local files, declare the exact minimal paths required. The workspace helper copies only those declared paths into `<workspace>/repo/`.
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

| Role | Stage | Default model | Alternative model | Mode | Job |
|---|---|---|---|---|---|
| researcher | 1 | `gemini-3.7-flash-high` | — | `plan` | Gathers structured claims and citations for an assigned evidence angle. |
| synthesizer | 2 | `gemini-3.7-flash-high` | — | `plan` | Builds claim ledger, resolves agreements/conflicts, and drafts synthesis. |
| auditor | 3 | `gemini-3.7-flash-high` | — | `plan` | Independently verifies every citation in the proposed final answer. |

The live smoke comparison retained Flash for every role. The proposed Pro synthesizer and auditor
split did not complete its mandatory synthesis stage, while the all-Flash control completed
synthesis and citation audit with four supported claims. See
[`tests/live-smoke-comparison.md`](../tests/live-smoke-comparison.md) for the recorded judgment.

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

```bash
AGY=$(command -v agy || echo "$HOME/.local/bin/agy")
RESEARCHER_SCHEMA='{"type":"object","properties":{"run_id":{"type":"string"},"angle_id":{"type":"string"},"status":{"type":"string","enum":["success","failed","inconclusive"]},"failure_reason":{"type":"string"},"question":{"type":"string"},"evidence_angle":{"type":"string"},"findings":{"type":"array","items":{"type":"object","properties":{"claim":{"type":"string"},"source_urls":{"type":"array","items":{"type":"string"}},"source_type":{"type":"string","enum":["primary","secondary","derivative","unknown"]},"source_date":{"type":"string"},"conflicts":{"type":"string"},"uncertainty":{"type":"string"}},"required":["claim","source_urls","source_type"]}},"search_gaps":{"type":"array","items":{"type":"string"}},"counterevidence":{"type":"array","items":{"type":"string"}}},"required":["run_id","angle_id","status","question","evidence_angle","findings"]}'

"$AGY" -p "Run ID: <run-id>. Angle ID: <angle-id>. Question: <question>. Evidence angle: <angle-description>. Return structured claims, not essays. Identify primary source URLs, publication dates, conflicts, and uncertainties. Treat repeated secondary coverage as one line of evidence. Do not edit files. Do not dispatch nested workers." \
  --model gemini-3.7-flash-high \
  --output-format json \
  --mode plan \
  --json-schema "$RESEARCHER_SCHEMA" \
  --print-timeout 20m \
  > "<workspace>/researcher-<angle-id>.json" 2> "<workspace>/researcher-<angle-id>.err"
```

## Stage 2: Synthesize claim ledger

The synthesizer merges findings across all researcher outputs and constructs a claim ledger.

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

```bash
SYNTH_SCHEMA='{"type":"object","properties":{"claim_ledger":{"type":"array","items":{"type":"object","properties":{"claim_id":{"type":"string"},"claim":{"type":"string"},"citations":{"type":"array","items":{"type":"string"}},"decision_relevance":{"type":"string","enum":["critical","supporting","incidental"]},"status":{"type":"string","enum":["supported","conflicted","unresolved"]},"inferences":{"type":"string"}},"required":["claim_id","claim","citations","decision_relevance","status"]}},"proposed_answer":{"type":"string"},"omitted_unsupported_claims":{"type":"array","items":{"type":"string"}},"unresolved_claims":{"type":"array","items":{"type":"string"}},"profile_used":{"type":"string","enum":["standard","deep"]},"deep_trigger":{"type":"string"}},"required":["claim_ledger","proposed_answer","profile_used"]}'

"$AGY" -p "Question: <question>. Profile: <standard|deep>. Deep trigger: <trigger-or-none>. Researcher findings: <merged-researcher-findings>. Build a claim ledger. Discard unsupported incidental claims. Keep decision-relevant gaps as unresolved. Draft a proposed answer referencing claim IDs. Do not edit files. Do not dispatch nested workers." \
  --model gemini-3.7-flash-high \
  --output-format json \
  --mode plan \
  --json-schema "$SYNTH_SCHEMA" \
  --print-timeout 20m \
  > "<workspace>/synthesizer.json" 2> "<workspace>/synthesizer.err"
```

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

```bash
AUDITOR_SCHEMA='{"type":"object","properties":{"citation_audits":{"type":"array","items":{"type":"object","properties":{"citation_url":{"type":"string"},"claim_id":{"type":"string"},"resolves":{"type":"boolean"},"support_verdict":{"type":"string","enum":["supports","partially_supports","refutes","unsupported"]},"source_classification":{"type":"string","enum":["primary","secondary","derivative","unknown"]},"independence_notes":{"type":"string"},"date_fitness":{"type":"string"},"notes":{"type":"string"}},"required":["citation_url","claim_id","resolves","support_verdict","source_classification"]}},"final_status":{"type":"string","enum":["pass","revise","incomplete"]},"claims_to_remove":{"type":"array","items":{"type":"string"}},"claims_to_narrow":{"type":"array","items":{"type":"string"}},"claims_unresolved":{"type":"array","items":{"type":"string"}}},"required":["citation_audits","final_status"]}'

"$AGY" -p "Audit every citation in the proposed synthesis against live sources. Proposed answer: <proposed-answer>. Claim ledger: <claim-ledger>. Verify each citation URL, check whether it directly supports the claim, classify primary vs derivative, and evaluate date fitness. Do not edit files. Do not dispatch nested workers." \
  --model gemini-3.7-flash-high \
  --output-format json \
  --mode plan \
  --json-schema "$AUDITOR_SCHEMA" \
  --print-timeout 20m \
  > "<workspace>/auditor.json" 2> "<workspace>/auditor.err"
```

### Audit revision loop

- If the auditor returns `pass`, the synthesis is accepted. Label supported claims as `audited` in the final report.
- If the auditor returns `revise`, the synthesizer may perform **one** revision pass to narrow or remove rejected claims. The revised output undergoes one final audit.
- If the second audit fails, omit incidental unsupported claims or mark decision-relevant claims as unresolved. Do not enter open-ended revision loops.

## Failure handling and partial results

1. **Researcher failure.** If a researcher crashes, times out, or produces unparsable output, retry once with the error details. If the retry fails, synthesis proceeds as long as at least two independent evidence angles remain. The final report explicitly names any omitted angle.
2. **Synthesis or audit failure.** Synthesis and citation audit are mandatory stages. If either stage crashes, times out, returns unparsable JSON, or fails to resolve citations, the run transitions to `partial` status.
3. **Partial result contract.** A `partial` run returns audited claims and raw findings collected up to the point of failure, but strictly withholds a firm synthesis or recommendation. State the failed stage explicitly and retain all raw artifacts.

## Provenance and cleanup

At the conclusion of the research run:

1. **Assemble provenance.** Validate and generate `provenance.json` using `scripts/collect-provenance.sh`:

   ```bash
   ./scripts/collect-provenance.sh \
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

2. **Save final result.** Write the Markdown synthesis or partial findings to `<workspace>/final.md`.
3. **Run cleanup helper.** Execute `scripts/cleanup-research-workspace.sh`:

   ```bash
   ./scripts/cleanup-research-workspace.sh --workspace "<workspace>" --status "<success|partial>"
   ```

   - On `success`, the helper retains `final.md` and `provenance.json`, while deleting raw intermediate worker JSON files and the temporary repository snapshot.
   - On `partial` or failed status, the helper preserves all raw artifacts, worker logs, and repository snapshots for debugging.

## Research-then-implementation handoff

When research precedes code implementation (`modes/execution.md`):

1. Complete the full research workflow, synthesis, and citation audit.
2. Distill the verified research into a compact specification, audited claim ledger, and `provenance.json`.
3. Hand only the compact specification to `modes/execution.md`. Never feed raw multi-turn research transcripts to implementation workers.
4. If research concludes with a `partial` status, do not begin execution unless the user explicitly reviews and accepts the identified gaps.
