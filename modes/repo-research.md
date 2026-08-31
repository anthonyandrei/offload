# Repository research mode

Conducts bounded local repository investigations, audits, and invariant checks using isolated workspaces and read-only orchestrator verification.

## Assignment requirements

Every repository research assignment must define four fields:

1. **One bounded question.** A specific inquiry answerable from code (for example, "Which API endpoints omit session authentication?").
2. **Allowed scope.** Explicit list of files, directories, or modules the worker is permitted to inspect.
3. **Evidence expectations.** Concrete citations required for each finding (file paths with line numbers or ranges, and reproducible commands).
4. **Explicit non-mutation rule.** A clear instruction: investigate only, make no file modifications or creations, and dispatch no nested workers.

Open-ended research without a bounded question, defined scope, and evidence expectations is out of scope.

## Filesystem isolation

Do not point workers directly at the live repository. `--mode plan` is a behavioral hint, not a write barrier. Direct testing demonstrated that plan-mode workers can write files.

Isolate every research run:

1. Create a disposable workspace outside the repository.
2. Copy only the declared scope paths into a snapshot directory in the workspace (for example, `workspace/snapshot/`).
3. Launch the worker with its working directory set to the workspace and `--add-dir` pointing at the snapshot directory.
4. The live repository remains untouched by worker processes.

## Worker dispatch

Dispatch researchers in parallel using `gemini-3.7-flash-high` with a structured schema:

```bash
AGY=$(command -v agy || echo "$HOME/.local/bin/agy")
RESEARCH_SCHEMA='{"type":"object","properties":{"lane_id":{"type":"string"},"lane_kind":{"type":"string","enum":["research","audit"]},"question":{"type":"string"},"overall_status":{"type":"string","enum":["complete","inconclusive","blocked"]},"uncertainty":{"type":"string"},"findings":{"type":"array","items":{"type":"object","properties":{"finding":{"type":"string"},"priority":{"type":"string","enum":["high","medium","low"]},"status":{"type":"string","enum":["confirmed","refuted","inconclusive"]},"evidence_locations":{"type":"array","items":{"type":"string"}},"evidence_commands":{"type":"array","items":{"type":"string"}}},"required":["finding","priority","status","evidence_locations"]}}},"required":["lane_id","lane_kind","question","overall_status","uncertainty","findings"]}'

"$AGY" -p "Lane ID: <slug>. Lane kind: <research or audit>. Question: <bounded question>. Allowed scope: <scope>. Evidence expectations: <expectations>. Non-mutation rule: investigate only, do not create or edit files, do not dispatch nested workers." \
  --model gemini-3.7-flash-high \
  --output-format json \
  --mode plan \
  --json-schema "$RESEARCH_SCHEMA" \
  --add-dir "<snapshot dir>" \
  --print-timeout 20m \
  > "<workspace>/<slug>.research.json" 2> "<workspace>/<slug>.research.err"
```

Read `structured_output` from the JSON response to extract validated findings.

## Verification protocol

Never accept a worker's research findings on trust alone. Run this verification protocol against the live repository using read-only orchestrator commands:

1. **Scope validation.** Confirm all cited `evidence_locations` and `evidence_commands` stay inside the declared scope. Treat out-of-scope citations as invalid.
2. **Priority assessment.** Independently evaluate finding severity. Correct worker-assigned priority when needed so critical findings cannot bypass thorough review.
3. **Direct check of high-priority findings.** Inspect the exact cited file paths and line ranges in the live repository. Before running any `evidence_command`, inspect it to ensure it is read-only, non-interactive, and safe. Confirm the evidence directly proves the finding. Record provenance as `orchestrator+checked`.
4. **Sampling lower-priority findings.** Spot-check a representative sample of medium- and low-priority findings against the live codebase. Record provenance as `orchestrator+sampled`.
5. **Mark unsupported claims as unverified.** If a finding lacks concrete evidence, cites out-of-scope files, references unsafe commands, or fails manual checking, classify it as `UNVERIFIED` (provenance `agy+unverified`).
6. **Record sample counts and provenance.** Note priority adjustments, the exact sample verified, and individual finding provenance in the final report.

## Retry and fallback

- **Worker failure.** If a worker crashes, times out, or produces unparsable output, redispatch once with the concrete error.
- **Orchestrator fallback.** If the second attempt fails or findings remain inconclusive, complete the investigation directly as the orchestrator (`orchestrator (fallback)`).

## Cleanup

After verification completes, delete the temporary workspace and snapshot directory.
