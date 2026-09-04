# Execution mode

Dispatches `agy` workers to implement file and code changes across independent gated tasks through isolated workspaces.

## Preconditions and helper selection

Select the helper family matching your current host shell:

- **POSIX shells (Bash 3.2+)**: Use `scripts/dispatch-worker.sh`, `scripts/run-agy-json.sh`, `scripts/check-execution-scope.sh`, `scripts/execute-gate.sh`, and `scripts/execution-workspace.sh`. Requires Git, `agy`, `jq`, and Python 3.
- **PowerShell (PowerShell 7+)**: Use `scripts/dispatch-worker.ps1`, `scripts/run-agy-json.ps1`, `scripts/check-execution-scope.ps1`, `scripts/execute-gate.ps1`, and `scripts/execution-workspace.ps1`. Native Windows orchestrators require only PowerShell 7 (`pwsh`), Git, and `agy`. Windows workflows do not require Bash, WSL, Git Bash, Python, or `jq`.

Check these before dispatching writing tasks:

1. **`agy` is available.** Verify `agy` via `run-agy-json` or ensure `agy` is on `PATH`, user-local bin, or `AGY_BIN`.
2. **Target is a git repository.** Run `git rev-parse --is-inside-work-tree`.
3. **Working tree is clean.** Run `git status --porcelain`. A clean tree is required to track edits, isolate changes, and roll back failed tasks.
4. **Record baseline revision.** Record the caller repository baseline before creating workspaces:
   - Bash: `BASELINE=$(git rev-parse HEAD)`
   - PowerShell: `$Baseline = (git rev-parse HEAD).Trim()`
5. **Model policy and preflight check.** Complete the shared preflight model availability check described in [`SKILL.md`](../SKILL.md) before dispatching the first worker. All workers route through `model-policy.json`.
6. **Workspace isolation principle.** Writing workers are never dispatched directly into the caller's main checkout (`<repo root>`). All candidate mutations occur in isolated candidate worktrees created at the recorded baseline revision via `execution-workspace create`.
7. **Orchestrator-owned admission.** Route every worker launch through `dispatch-worker` with a dispatch ledger and explicit `--max-depth`, `--max-width`, `--max-timeout-seconds`, and `--max-resource-units` on the root assignment. The dispatcher creates the worktree and invokes the launcher. A worker's structured request for more work remains data until the orchestrator deliberately admits it as a new bounded assignment.

Every execution dispatch supplies the shared lifecycle metadata to `run-agy-json`: `--assignment-id`, `--attempt`, `--mode execution`, `--verification-baseline`, `--resource-ledger`, and a distinct `--lifecycle` path. The launcher records the common state machine, waits for the worker to exit before cleanup, and records the exit result. Timeout and cancellation terminate the worker before cleanup; quota exhaustion hands off unfinished work immediately. Retries and resume read the resource ledger and preserve the pinned assignment, model, effort, verification baseline, and attempt limit.

## Roles and models

Workers are admitted by role using `dispatch-worker` with `--role <role>` and a bounded budget. The dispatcher invokes `run-agy-json`, which resolves models dynamically from `model-policy.json`. Do not pass `--model` or `--effort` directly. Refer to [`SKILL.md`](../SKILL.md) for the shared model routing, preflight, and recovery contract.

The command examples below show the `agy` arguments passed after the dispatcher's `--` delimiter. In a real run, put the state path, assignment identity, parent identity when applicable, source revision, owned and frozen paths, output and error paths, workspace path, budget, and root limits on the `dispatch-worker` invocation. Do not invoke `run-agy-json` directly for an execution assignment.

The examples use one assignment per ledger. For a parallel wave, share the ledger and set its root child-width and total resource limits to cover the whole wave.

| Role | Wave | Default model | Effort | Mode | Job |
|---|---|---|---|---|---|
| scout | 1 | `gemini-3.8-flash-low` | low | `plan` | Report repository-relative file paths a task touches. |
| gate-author | 2 | `gemini-3.8-flash-high` | high | `accept-edits` | Author an executable test file from acceptance criteria. |
| implementer | 3 | `gemini-3.8-flash-high` | high | `accept-edits` | Implement the task within owned files in candidate workspace. |
| reviewer | 4 | `gemini-3.8-flash-high` | high | `plan` | Evaluate the recorded review artifact against criteria for diff-gated tasks. |

`--mode plan` is a version-sensitive behavioral hint, not a write barrier. On `agy 1.1.25`, the compatibility probe blocked the tested direct write outside the permitted artifact area, but this is not a guarantee. `--add-dir` grants access without confining writes. Protection relies on isolated candidate worktrees, mechanical execution scope checks with explicit baselines, frozen path checks, and test gates.

Acceptance is distinct from process completion: exit 0, a top-level success status, or prose is insufficient. Require a parsed envelope, valid substantive structured output, execution-scope and gate evidence, and an explicit accepted attempt. A gate exit 126 or 127 is classified as `unrunnable` with `verification: not_performed`; preserve the command, exit code, and diagnostic evidence, and do not schedule a quality retry.

Worker processes run through the vendor-neutral adapter boundary in
[`docs/worker-adapter-contract.md`](../docs/worker-adapter-contract.md).
Validate its normalized result with `scripts/check-worker-adapter.sh` or
`scripts/check-worker-adapter.ps1`, using the helper matching the host, before
accepting artifacts. The adapter reports process, worktree, and artifact
ownership. The orchestrator alone decides whether verification, publication,
or cleanup is allowed.

## Step 1: Split and scout

### Provisional split

Break work into provisional tasks with a slug and a concise description of goals.

### Choose gates

Assign each task exactly one gate:

- **Machine gate.** An executable test command executed through `execute-gate.sh` or `execute-gate.ps1`. A gate-author creates the test in Step 2; you run a red check and read the test before freezing it. The shared gate helper normalizes exit 0 to passed (`failure_class: none`), exit 126/127 to unrunnable (`verification: not_performed`, no quality retry), and other nonzero exits to quality failure (`verification: failed`). Record whether the task is behavior-preserving (waives the red check failure requirement).
- **Diff gate.** Plain-text criteria for tasks without automated tests (documentation, configuration, refactoring). A reviewer worker evaluates the diff against these criteria in Step 5.

### Scout

For provisional writing tasks, dispatch scouts in parallel through `dispatch-worker` with `--role scout`. Scouts run in an isolated worktree at the recorded baseline:

#### Bash
```bash
OFFLOAD_ROOT="<path to installed _offload skill>"
DISPATCH_STATE="<scratch dir>/offload/dispatch.json"
SCOUT_WORKSPACE="<scratch dir>/offload/scout"
SCOUT_SCHEMA='{"type":"object","properties":{"files":{"type":"array","items":{"type":"string"}}},"required":["files"]}'
"$OFFLOAD_ROOT/scripts/dispatch-worker.sh" \
  --state "$DISPATCH_STATE" \
  --assignment-id "scout-<slug>" \
  --role scout \
  --source-repo "<repo root>" \
  --baseline "$BASELINE" \
  --owned "README.md" \
  --workspace-dir "$SCOUT_WORKSPACE" \
  --max-depth 0 \
  --max-width 1 \
  --max-timeout-seconds 1200 \
  --max-resource-units 1 \
  --timeout-seconds 1200 \
  --resource-units 1 \
  --output "<scratch dir>/offload/<slug>.attempt1.scout.json" \
  --error "<scratch dir>/offload/<slug>.attempt1.scout.err" \
  -- \
  -p "<task description>. List every repo-relative file path this task would need to read or change. Do not edit anything. Do not dispatch nested workers." \
  --output-format json \
  --mode plan \
  --json-schema "$SCOUT_SCHEMA" \
  --add-dir "$SCOUT_WORKSPACE" \
  --print-timeout 20m
```

#### PowerShell
```powershell
$OffloadRoot = "<path to installed _offload skill>"
$DispatchState = "<scratch dir>/offload/dispatch.json"
$ScoutWorkspace = "<scratch dir>/offload/scout"
$ScoutSchema = '{"type":"object","properties":{"files":{"type":"array","items":{"type":"string"}}},"required":["files"]}'
& "$OffloadRoot/scripts/dispatch-worker.ps1" `
  --state $DispatchState `
  --assignment-id "scout-<slug>" `
  --role scout `
  --source-repo "<repo root>" `
  --baseline $Baseline `
  --owned "README.md" `
  --workspace-dir $ScoutWorkspace `
  --max-depth 0 `
  --max-width 1 `
  --max-timeout-seconds 1200 `
  --max-resource-units 1 `
  --timeout-seconds 1200 `
  --resource-units 1 `
  --output "<scratch dir>/offload/<slug>.attempt1.scout.json" `
  --error "<scratch dir>/offload/<slug>.attempt1.scout.err" `
  '--' `
  -p "<task description>. List every repo-relative file path this task would need to read or change. Do not edit anything. Do not dispatch nested workers." `
  --output-format json `
  --mode plan `
  --json-schema $ScoutSchema `
  --add-dir $ScoutWorkspace `
  --print-timeout 20m
```

Read `structured_output` from the JSON response to extract the file list.

### Finalize split

Reconcile scout findings:

- If two writing tasks touch overlapping files, serialize them rather than running in parallel.
- If a scout returned unexpected paths, adjust task boundaries before proceeding.
- Write final acceptance criteria for each task and assign each one a unique, stable `criterion_id` (for example, `C1`, `C2`). Save the resulting array as a JSON file in the run scratch directory so the reviewer and verifier consume the same set.

## Step 2: Author gates

Machine-gated tasks only. Skip for diff-gated tasks.

For each machine-gated task, create an isolated candidate worktree at the recorded `$BASELINE`, owning only the gate file and freezing source files. Then dispatch one gate-author per machine-gated task in parallel using `--role gate-author`:

#### Bash
```bash
GATE_WORKSPACE="<scratch dir>/offload/gate-<slug>"
"$OFFLOAD_ROOT/scripts/dispatch-worker.sh" \
  --state "<scratch dir>/offload/dispatch.json" \
  --assignment-id "gate-<slug>" \
  --source-repo "<repo root>" \
  --baseline "$BASELINE" \
  --owned "<exact gate path>" \
  --frozen "<source path 1>" \
  --frozen "<source path 2>" \
  --workspace-dir "$GATE_WORKSPACE" \
  --max-depth 0 \
  --max-width 1 \
  --max-timeout-seconds 1200 \
  --max-resource-units 1 \
  --timeout-seconds 1200 \
  --resource-units 1 \
  --role gate-author \
  --output "<scratch dir>/offload/<slug>.attempt1.gate.json" \
  --error "<scratch dir>/offload/<slug>.attempt1.gate.err" \
  -- \
  -p "<criteria>. Write this test at <exact gate path>. Do not touch any other file. Do not dispatch nested workers." \
  --output-format json \
  --add-dir "$GATE_WORKSPACE" \
  --mode accept-edits \
  --print-timeout 20m
```

#### PowerShell
```powershell
$GateWorkspace = "<scratch dir>/offload/gate-<slug>"
& "$OffloadRoot/scripts/dispatch-worker.ps1" `
  --state "<scratch dir>/offload/dispatch.json" `
  --assignment-id "gate-<slug>" `
  --source-repo "<repo root>" `
  --baseline $Baseline `
  --owned "<exact gate path>" `
  --frozen "<source path 1>" `
  --frozen "<source path 2>" `
  --workspace-dir $GateWorkspace `
  --max-depth 0 `
  --max-width 1 `
  --max-timeout-seconds 1200 `
  --max-resource-units 1 `
  --timeout-seconds 1200 `
  --resource-units 1 `
  --role gate-author `
  --output "<scratch dir>/offload/<slug>.attempt1.gate.json" `
  --error "<scratch dir>/offload/<slug>.attempt1.gate.err" `
  '--' `
  -p "<criteria>. Write this test at <exact gate path>. Do not touch any other file. Do not dispatch nested workers." `
  --output-format json `
  --add-dir $GateWorkspace `
  --mode accept-edits `
  --print-timeout 20m
```

Verify each created gate:

1. **Scope verification and patch export.** Run `execution-workspace verify-export --manifest "<scratch dir>/offload/gate-<slug>.manifest.json"`. The helper executes `check-execution-scope` against `--baseline "$BASELINE" --owned "<exact gate path>" --frozen "<source paths>"`. If the gate-author modified unowned source files or violated scope, it is rejected immediately before its output can become an implementation baseline.
2. **File existence.** Confirm the test file exists at `<exact gate path>` in the candidate workspace (`[ -f "$GATE_WORKSPACE/<exact gate path>" ]` in Bash or `Test-Path "$GateWorkspace/<exact gate path>"` in PowerShell).
3. **Red check.** Run the gate command against the untouched baseline revision in the candidate workspace (`<gate cmd>` in Bash or `& <gate cmd>` in PowerShell). Require a non-zero exit code, unless the task is marked behavior-preserving where 0 is expected.
4. **Read the test.** Read the test source to confirm assertions match the requirements.
5. **Integrate and freeze.** Integrate verified gate patch into the repository integration baseline:
   - Bash:
     ```bash
     "$OFFLOAD_ROOT/scripts/execution-workspace.sh" integrate \
       --manifest "<scratch dir>/offload/gate-<slug>.manifest.json"
     git commit -m "offload: freeze gates"
     GATE_BASELINE=$(git rev-parse HEAD)
     ```
   - PowerShell:
     ```powershell
     & "$OffloadRoot/scripts/execution-workspace.ps1" integrate `
       --manifest "<scratch dir>/offload/gate-<slug>.manifest.json"
     git commit -m "offload: freeze gates"
     $GateBaseline = (git rev-parse HEAD).Trim()
     ```

## Step 3: Dispatch implementers

For each task, create an isolated candidate worktree from the approved `$GATE_BASELINE` (or initial `$BASELINE` for diff-gated tasks). Assign owned paths and designate approved gates as frozen paths. Dispatch implementers in parallel using `--role implementer`:

#### Bash
```bash
TASK_WORKSPACE="<scratch dir>/offload/<slug>"
"$OFFLOAD_ROOT/scripts/dispatch-worker.sh" \
  --state "<scratch dir>/offload/dispatch.json" \
  --assignment-id "<slug>" \
  --source-repo "<repo root>" \
  --baseline "$GATE_BASELINE" \
  --owned "<owned path 1>" \
  --owned "<owned path 2>" \
  --frozen "<exact gate path>" \
  --workspace-dir "$TASK_WORKSPACE" \
  --max-depth 0 \
  --max-width 1 \
  --max-timeout-seconds 1200 \
  --max-resource-units 1 \
  --timeout-seconds 1200 \
  --resource-units 1 \
  --role implementer \
  --output "<scratch dir>/offload/<slug>.attempt1.json" \
  --error "<scratch dir>/offload/<slug>.attempt1.err" \
  -- \
  -p "<task prompt>. Owned files: <owned paths>. Frozen paths: <frozen paths>. Gate command: <gate cmd>. Do not touch any other file. Do not dispatch nested workers." \
  --output-format json \
  --add-dir "$TASK_WORKSPACE" \
  --mode accept-edits \
  --print-timeout 20m
```

#### PowerShell
```powershell
$TaskWorkspace = "<scratch dir>/offload/<slug>"
& "$OffloadRoot/scripts/dispatch-worker.ps1" `
  --state "<scratch dir>/offload/dispatch.json" `
  --assignment-id "<slug>" `
  --source-repo "<repo root>" `
  --baseline $GateBaseline `
  --owned "<owned path 1>" `
  --owned "<owned path 2>" `
  --frozen "<exact gate path>" `
  --workspace-dir $TaskWorkspace `
  --max-depth 0 `
  --max-width 1 `
  --max-timeout-seconds 1200 `
  --max-resource-units 1 `
  --timeout-seconds 1200 `
  --resource-units 1 `
  --role implementer `
  --output "<scratch dir>/offload/<slug>.attempt1.json" `
  --error "<scratch dir>/offload/<slug>.attempt1.err" `
  '--' `
  -p "<task prompt>. Owned files: <owned paths>. Frozen paths: <frozen paths>. Gate command: <gate cmd>. Do not touch any other file. Do not dispatch nested workers." `
  --output-format json `
  --add-dir $TaskWorkspace `
  --mode accept-edits `
  --print-timeout 20m
```

The prompt must specify owned files, frozen paths (including approved frozen gates), the gate command, and prohibitions against touching unassigned files or dispatching nested workers.

When an attempt fails verification, keep its evidence paths in the outcome record and redispatch the same `worker_id` with attempt 2 paths. Set `ATTEMPT=2` in Bash or `$Attempt = 2` in PowerShell, then use `<scratch dir>/offload/<slug>.attempt2.json` (or `<slug>.attempt2.<role>.json` for the role-suffixed scout, gate-author, and reviewer artifacts) for `--output`, with the matching `.err` path for `--error`. Record the verified attempt as `accepted_attempt` in the orchestrator's run state and use only that attempt's patch or review output for integration.

## Step 4: Collect

Read worker JSON responses and record outcomes in `routing-outcomes.json`:

- `status: SUCCESS`: Worker completed execution. Proceed to verification in Step 5.
- Non-zero exit code or unparsable output: Worker crashed or encountered an operational failure. Record the attempt and follow Step 6.
- Timeout (no output written before 20m timeout): Operational failure. Record the timeout and follow Step 6.
- **Immediate quota handoff**: If explicit Gemini quota exhaustion is detected on any worker, record still-running candidates and all existing artifacts in `routing-outcomes.json` immediately without waiting for sibling completion, and hand off unfinished work directly to the calling orchestrator.

## Step 5: Verify and integrate

Verify every worker reporting `SUCCESS`:

1. **Mechanical execution scope check and patch export.**
   Run `execution-workspace verify-export --manifest "<scratch dir>/offload/<slug>.manifest.json"` before dispatching a reviewer.

   #### Bash
   ```bash
   if ! REVIEW_ARTIFACT="$("$OFFLOAD_ROOT/scripts/execution-workspace.sh" verify-export --manifest "<manifest path>")"; then
     echo "review artifact export failed" >&2
     exit 1
   fi
   ```

   #### PowerShell
   ```powershell
   $ReviewArtifact = & "$OffloadRoot/scripts/execution-workspace.ps1" `
     verify-export `
     --manifest "<manifest path>"
   if ($LASTEXITCODE -ne 0) {
     throw "review artifact export failed"
   }
   ```

   `verify-export` stages all candidate changes, including committed, staged, unstaged, deleted, renamed, untracked, and binary changes. It executes `check-execution-scope` against the recorded baseline and owned/frozen paths, then writes one binary-capable patch outside the candidate and records its `patch_file`, `patch_digest`, and `touched_paths` in the manifest. Any scope, Git, artifact, or digest failure rejects the review.

   Direct manual invocation of `check-execution-scope` always requires `--baseline`:
   #### Bash
   ```bash
   "$OFFLOAD_ROOT/scripts/check-execution-scope.sh" \
     --baseline "$GATE_BASELINE" \
     --owned "<owned path 1>" \
     --owned "<owned path 2>" \
     --frozen "<frozen path 1>" \
     --frozen "<frozen path 2>"
   ```

   #### PowerShell
   ```powershell
   & "$OffloadRoot/scripts/check-execution-scope.ps1" `
     --baseline $GateBaseline `
     --owned "<owned path 1>" `
     --owned "<owned path 2>" `
     --frozen "<frozen path 1>" `
     --frozen "<frozen path 2>"
   ```

   Any violation printed by the helper represents an unowned modification or a frozen path violation. The helper exits nonzero when violations exist. Report violations regardless of gate results.

2. **Candidate gate execution.**
   - Machine gate: Run the frozen gate command in the candidate workspace through the shell-native gate execution helper (`execute-gate.sh` or `execute-gate.ps1`), which captures diagnostic stdout/stderr to an artifact file and normalizes gate exit codes:

     #### Bash
     ```bash
     GATE_REPORT="$("$OFFLOAD_ROOT/scripts/execute-gate.sh" --command "<gate cmd>" --workspace "$TASK_WORKSPACE")"
     ```

     #### PowerShell
     ```powershell
     $GateReport = & "$OffloadRoot/scripts/execute-gate.ps1" --command "<gate cmd>" --workspace $TaskWorkspace | ConvertFrom-Json
     ```

     Consume the normalized classification from the gate execution helper rather than requiring the process to exit 0 directly:
     - `verification_status: "passed"` (`failure_class: "none"`, exit 0): The gate passed cleanly.
     - `failure_class: "unrunnable"` (`verification_status: "not_performed"`, `allow_retry: false`, exit 126 or 127): The gate command could not be executed (command not found or permission denied). Retain the command, exit code, and `diagnostic_artifact_path` evidence in `routing-outcomes.json`. Exits 126 and 127 are not quality retries; do not schedule a quality retry.
     - `failure_class: "quality"` (`verification_status: "failed"`, `allow_retry: true`, other non-zero exit codes): The test assertions failed. Record the diagnostic artifact path and schedule a quality retry if attempt budget remains.
   - Diff gate: Dispatch an adversarial reviewer worker to inspect the recorded artifact using `--role reviewer`:

      #### Bash
      ```bash
      REVIEW_SCHEMA='{"type":"object","properties":{"criteria":{"type":"array","items":{"type":"object","properties":{"criterion_id":{"type":"string"},"verdict":{"type":"string","enum":["pass","fail","hedge"]},"quote":{"type":"string"}},"required":["criterion_id","verdict","quote"]}}},"required":["criteria"]}'
      REVIEW_WORKSPACE="<scratch dir>/offload/<slug>-reviewer"
      "$OFFLOAD_ROOT/scripts/dispatch-worker.sh" \
        --state "<scratch dir>/offload/dispatch.json" \
        --assignment-id "<slug>-reviewer" \
        --role reviewer \
        --source-repo "<repo root>" \
        --baseline "$GATE_BASELINE" \
        --owned "README.md" \
        --workspace-dir "$REVIEW_WORKSPACE" \
        --max-depth 0 \
        --max-width 1 \
        --max-timeout-seconds 1200 \
        --max-resource-units 1 \
        --timeout-seconds 1200 \
        --resource-units 1 \
        --output "<scratch dir>/offload/<slug>.attempt1.review.json" \
        --error "<scratch dir>/offload/<slug>.attempt1.review.err" \
        -- \
        -p "Read the recorded review artifact at <patch_file>. Verify its bytes against <patch_digest> before reviewing. Do not inspect the candidate checkout or generate another diff. Return exactly one verdict object for every criterion in <criteria>, copying each criterion_id exactly. Decide pass, fail, or hedge if unsure. Look for reasons the criterion FAILS before accepting pass. For every pass, quote one complete line verbatim from the artifact that proves it. Criteria: <criteria>" \
        --output-format json \
        --mode plan \
       --json-schema "$REVIEW_SCHEMA" \
       --add-dir "<repo root>" \
       --add-dir "<patch parent>" \
       --print-timeout 20m
     ```

      #### PowerShell
      ```powershell
      $ReviewSchema = '{"type":"object","properties":{"criteria":{"type":"array","items":{"type":"object","properties":{"criterion_id":{"type":"string"},"verdict":{"type":"string","enum":["pass","fail","hedge"]},"quote":{"type":"string"}},"required":["criterion_id","verdict","quote"]}}},"required":["criteria"]}'
      $ReviewWorkspace = "<scratch dir>/offload/<slug>-reviewer"
      & "$OffloadRoot/scripts/dispatch-worker.ps1" `
        --state "<scratch dir>/offload/dispatch.json" `
        --assignment-id "<slug>-reviewer" `
        --role reviewer `
        --source-repo "<repo root>" `
        --baseline $GateBaseline `
        --owned "README.md" `
        --workspace-dir $ReviewWorkspace `
        --max-depth 0 `
        --max-width 1 `
        --max-timeout-seconds 1200 `
        --max-resource-units 1 `
        --timeout-seconds 1200 `
        --resource-units 1 `
        --output "<scratch dir>/offload/<slug>.attempt1.review.json" `
        --error "<scratch dir>/offload/<slug>.attempt1.review.err" `
        '--' `
        -p "Read the recorded review artifact at <patch_file>. Verify its bytes against <patch_digest> before reviewing. Do not inspect the candidate checkout or generate another diff. Return exactly one verdict object for every criterion in <criteria>, copying each criterion_id exactly. Decide pass, fail, or hedge if unsure. Look for reasons the criterion FAILS before accepting pass. For every pass, quote one complete line verbatim from the artifact that proves it. Criteria: <criteria>" `
        --output-format json `
        --mode plan `

       --json-schema $ReviewSchema `
       --add-dir "<repo root>" `
       --add-dir "<patch parent>" `
       --print-timeout 20m
      ```

      Read `structured_output` from the JSON response to extract criteria verdicts and quotes.

    First recheck the recorded digest. Then run the data-only coverage and evidence verifier with the criteria file, reviewer JSON, and the same artifact:
    - Bash digest: `test "sha256:$(sha256sum "<patch_file>" | awk '{print tolower($1)}')" = "<patch_digest>"`
    - PowerShell digest: `$actualDigest = "sha256:$((Get-FileHash -Algorithm SHA256 -LiteralPath "<patch_file>").Hash.ToLowerInvariant())"; if ($actualDigest -ne "<patch_digest>") { throw "review artifact digest mismatch" }`
    - Bash verifier: `"$OFFLOAD_ROOT/scripts/check-review-verdict.sh" --criteria "<criteria file>" --review "<review JSON>" --artifact "<patch_file>"`
    - PowerShell verifier: `& "$OffloadRoot/scripts/check-review-verdict.ps1" --criteria "<criteria file>" --review "<review JSON>" --artifact "<patch_file>"`

    The verifier performs exact criterion coverage and literal line matching from parsed data. Exit 0 accepts the reviewer result (`agy+grep`). Exit 1 means every criterion was covered but a fail or hedge requires direct orchestrator review. Exit 2 means malformed or incomplete coverage, duplicate or unknown IDs, a forged quote, or another verification error. For exit 1 or 2, inspect the recorded artifact directly (`agy→orchestrator`).

3. **Integration of verified tasks.**
   - Disjoint tasks: Apply verified candidate patches sequentially via `execution-workspace integrate --manifest "<manifest>"`. The helper tests integration in a disposable scratch worktree before applying to the target.
   - Overlapping tasks: Run overlapping tasks serially. When Task 1 integrates, its resulting commit becomes the new baseline `$STAGE_BASELINE` for Task 2. Task 2's candidate worktree is created from this newly accepted baseline. Every accepted delta undergoes scope and gate verification before publication to the caller.

4. **Final combined gate check.**
   After all verified tasks are integrated into the integration target, execute all gate commands across all completed tasks together through the shared gate execution helper (`execute-gate.sh` or `execute-gate.ps1`).
   Every gate must normalize to `verification_status: "passed"` (`failure_class: "none"`). If any combined gate normalizes to quality failure or unrunnable, or if conflicts arise, the caller's working tree remains intact (the integrated changes are aborted and not published). Only publish when all combined gates pass cleanly.

## Step 6: Retry, recovery, and cleanup

Follow the shared recovery, retry accounting, and failure handling rules in [`SKILL.md`](../SKILL.md):

- **Stable worker IDs and retry ceiling.** Assign a stable `worker_id` to each logical task. Attempt 1 is initial dispatch; attempt 2 is its only possible retry. Maximum two attempts total per task.
- **Outcome tracking.** Record each attempt and verification outcome in `routing-outcomes.json`.
- **Baseline retention on retry.** Retries must retain the original verification baseline for that writing stage (e.g. `$GATE_BASELINE`). A failed attempt never becomes an implicitly trusted baseline. Create a fresh candidate worktree at the original baseline for attempt 2.
- **Implementer quality failure.** If an execution scope check violation occurs or a machine gate normalizes to `failure_class: "quality"` (non-zero exit code other than 126/127), this constitutes a quality failure. If a retry remains (attempt 2), redispatch once with the specific failure output and diagnostic evidence. Use `--route quality-retry` only if an evidence-backed escalation target is configured for `implementer` in `model-policy.json`; otherwise use `--route default`. If attempt 2 fails, halt that task.
- **Unrunnable gate execution.** If a gate command exits 126 or 127, it normalizes to `failure_class: "unrunnable"` with `verification_status: "not_performed"` and `allow_retry: false`. Gate exits 126 and 127 are not quality retries; preserve the command, exit code, and diagnostic evidence in `routing-outcomes.json` without spending or scheduling a quality retry.
- **Scout or gate-author operational failure.** If a scout or gate-author crashes, times out, or produces unparsable output, retry once using `--route default`. If the retry fails, complete that step directly as the orchestrator (`orchestrator (fallback)`).
- **Reviewer failure.** If reviewer output is unparsable or fails digest or quote verification, inspect the recorded artifact directly as the orchestrator (`agy→orchestrator`).
- **Quota exhaustion.** Explicit Gemini quota exhaustion triggers immediate quota handoff per [`SKILL.md`](../SKILL.md). Do not retry or switch models. Record still-running candidates immediately without waiting for siblings, preserve completed artifacts, and return unfinished work to the calling orchestrator.
- **Workspace cleanup.** After workers have terminated, clean up candidate worktrees:
  - Bash: `"$OFFLOAD_ROOT/scripts/execution-workspace.sh" cleanup --manifest "<manifest>" --status success|failed|retain`
  - PowerShell: `& "$OffloadRoot/scripts/execution-workspace.ps1" cleanup --manifest "<manifest>" --status success|failed|retain`
  Wait for active worker processes to terminate before calling cleanup. Pass `--status retain` if preserving a candidate workspace for orchestrator inspection.
