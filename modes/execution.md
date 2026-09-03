# Execution mode

Dispatches `agy` workers to implement file and code changes across independent gated tasks through isolated workspaces.

## Preconditions and helper selection

Select the helper family matching your current host shell:

- **POSIX shells (Bash 3.2+)**: Use `scripts/run-agy-json.sh`, `scripts/check-execution-scope.sh`, and `scripts/execution-workspace.sh`. Requires Git, `agy`, `jq`, and Python 3.
- **PowerShell (PowerShell 7+)**: Use `scripts/run-agy-json.ps1`, `scripts/check-execution-scope.ps1`, and `scripts/execution-workspace.ps1`. Native Windows orchestrators require only PowerShell 7 (`pwsh`), Git, and `agy`. Windows workflows do not require Bash, WSL, Git Bash, Python, or `jq`.

Check these before dispatching writing tasks:

1. **`agy` is available.** Verify `agy` via `run-agy-json` or ensure `agy` is on `PATH`, user-local bin, or `AGY_BIN`.
2. **Target is a git repository.** Run `git rev-parse --is-inside-work-tree`.
3. **Working tree is clean.** Run `git status --porcelain`. A clean tree is required to track edits, isolate changes, and roll back failed tasks.
4. **Record baseline revision.** Record the caller repository baseline before creating workspaces:
   - Bash: `BASELINE=$(git rev-parse HEAD)`
   - PowerShell: `$Baseline = (git rev-parse HEAD).Trim()`
5. **Model policy and preflight check.** Complete the shared preflight model availability check described in [`SKILL.md`](../SKILL.md) before dispatching the first worker. All workers route through `model-policy.json`.
6. **Workspace isolation principle.** Writing workers are never dispatched directly into the caller's main checkout (`<repo root>`). All candidate mutations occur in isolated candidate worktrees created at the recorded baseline revision via `execution-workspace create`.

## Roles and models

Workers are dispatched by role using `run-agy-json` with `--role <role>`. The launcher resolves models dynamically from `model-policy.json`. Do not pass `--model` or `--effort` directly. Refer to [`SKILL.md`](../SKILL.md) for the shared model routing, preflight, and recovery contract.

| Role | Wave | Default model | Effort | Mode | Job |
|---|---|---|---|---|---|
| scout | 1 | `gemini-3.8-flash-low` | low | `plan` | Report repository-relative file paths a task touches. |
| gate-author | 2 | `gemini-3.8-flash-high` | high | `accept-edits` | Author an executable test file from acceptance criteria. |
| implementer | 3 | `gemini-3.8-flash-high` | high | `accept-edits` | Implement the task within owned files in candidate workspace. |
| reviewer | 4 | `gemini-3.8-flash-high` | high | `plan` | Evaluate git diff against criteria for diff-gated tasks. |

`--mode plan` provides a behavioral hint, not a write barrier. `--add-dir` grants directory access without confining writes. Protection relies on isolated candidate worktrees, mechanical execution scope checks with explicit baselines, frozen path checks, and test gates.

## Step 1: Split and scout

### Provisional split

Break work into provisional tasks with a slug and a concise description of goals.

### Choose gates

Assign each task exactly one gate:

- **Machine gate.** An executable test command that exits 0 on success. A gate-author creates the test in Step 2; you run a red check and read the test before freezing it. Record whether the task is behavior-preserving (waives the red check failure requirement).
- **Diff gate.** Plain-text criteria for tasks without automated tests (documentation, configuration, refactoring). A reviewer worker evaluates the diff against these criteria in Step 5.

### Scout

For provisional writing tasks, dispatch scouts in parallel using the matching launcher helper with `--role scout`. Scouts run in an isolated worktree at the recorded baseline:

#### Bash
```bash
OFFLOAD_ROOT="<path to installed _offload skill>"
SCOUT_WORKSPACE="<scratch dir>/offload/scout"
git worktree add --detach "$SCOUT_WORKSPACE" "$BASELINE"
SCOUT_SCHEMA='{"type":"object","properties":{"files":{"type":"array","items":{"type":"string"}}},"required":["files"]}'
"$OFFLOAD_ROOT/scripts/run-agy-json.sh" \
  --role scout \
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
$ScoutWorkspace = "<scratch dir>/offload/scout"
git worktree add --detach $ScoutWorkspace $Baseline
$ScoutSchema = '{"type":"object","properties":{"files":{"type":"array","items":{"type":"string"}}},"required":["files"]}'
& "$OffloadRoot/scripts/run-agy-json.ps1" `
  --role scout `
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
- Write final prose acceptance criteria for each task.

## Step 2: Author gates

Machine-gated tasks only. Skip for diff-gated tasks.

For each machine-gated task, create an isolated candidate worktree at the recorded `$BASELINE`, owning only the gate file and freezing source files. Then dispatch one gate-author per machine-gated task in parallel using `--role gate-author`:

#### Bash
```bash
GATE_WORKSPACE=$("$OFFLOAD_ROOT/scripts/execution-workspace.sh" create \
  --source-repo "<repo root>" \
  --task-id "gate-<slug>" \
  --baseline "$BASELINE" \
  --owned "<exact gate path>" \
  --frozen "<source path 1>" \
  --frozen "<source path 2>" \
  --manifest "<scratch dir>/offload/gate-<slug>.manifest.json")

"$OFFLOAD_ROOT/scripts/run-agy-json.sh" \
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
$GateWorkspace = (& "$OffloadRoot/scripts/execution-workspace.ps1" create `
  --source-repo "<repo root>" `
  --task-id "gate-<slug>" `
  --baseline $Baseline `
  --owned "<exact gate path>" `
  --frozen "<source path 1>" `
  --frozen "<source path 2>" `
  --manifest "<scratch dir>/offload/gate-<slug>.manifest.json").Trim()

& "$OffloadRoot/scripts/run-agy-json.ps1" `
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
TASK_WORKSPACE=$("$OFFLOAD_ROOT/scripts/execution-workspace.sh" create \
  --source-repo "<repo root>" \
  --task-id "<slug>" \
  --baseline "$GATE_BASELINE" \
  --owned "<owned path 1>" \
  --owned "<owned path 2>" \
  --frozen "<exact gate path>" \
  --manifest "<scratch dir>/offload/<slug>.manifest.json")

"$OFFLOAD_ROOT/scripts/run-agy-json.sh" \
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
$TaskWorkspace = (& "$OffloadRoot/scripts/execution-workspace.ps1" create `
  --source-repo "<repo root>" `
  --task-id "<slug>" `
  --baseline $GateBaseline `
  --owned "<owned path 1>" `
  --owned "<owned path 2>" `
  --frozen "<exact gate path>" `
  --manifest "<scratch dir>/offload/<slug>.manifest.json").Trim()

& "$OffloadRoot/scripts/run-agy-json.ps1" `
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
   Run `execution-workspace verify-export --manifest "<scratch dir>/offload/<slug>.manifest.json"`.
   This executes `check-execution-scope` against the candidate worktree with `--baseline <manifest.baseline> --owned <manifest.owned> --frozen <manifest.frozen>`.
   Any unowned modification or frozen path violation (such as edits to approved gates) fails and exits non-zero.
   On success, a verified binary patch is exported and its sha256 checksum is recorded in the manifest.

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

2. **Candidate gate execution.**
   - Machine gate: Run the frozen gate command in the candidate workspace (`$TASK_WORKSPACE`) and check exit code (0 required).
   - Diff gate: Dispatch an adversarial reviewer worker against `$TASK_WORKSPACE` using `--role reviewer`:

     #### Bash
     ```bash
     REVIEW_SCHEMA='{"type":"object","properties":{"criteria":{"type":"array","items":{"type":"object","properties":{"criterion":{"type":"string"},"verdict":{"type":"string","enum":["pass","fail","hedge"]},"quote":{"type":"string"}},"required":["criterion","verdict","quote"]}}},"required":["criteria"]}'
     "$OFFLOAD_ROOT/scripts/run-agy-json.sh" \
       --role reviewer \
        --output "<scratch dir>/offload/<slug>.attempt1.review.json" \
        --error "<scratch dir>/offload/<slug>.attempt1.review.err" \
       -- \
       -p "Run 'git diff' in this repository. Do not dispatch nested workers. For each criterion below, decide pass, fail, or hedge if unsure. Look for reasons the criterion FAILS before accepting pass. For every pass, quote one line verbatim from the diff that proves it. Criteria: <criteria>" \
       --output-format json \
       --mode plan \
       --json-schema "$REVIEW_SCHEMA" \
       --add-dir "$TASK_WORKSPACE" \
       --print-timeout 20m
     ```

     #### PowerShell
     ```powershell
     $ReviewSchema = '{"type":"object","properties":{"criteria":{"type":"array","items":{"type":"object","properties":{"criterion":{"type":"string"},"verdict":{"type":"string","enum":["pass","fail","hedge"]},"quote":{"type":"string"}},"required":["criterion","verdict","quote"]}}},"required":["criteria"]}'
     & "$OffloadRoot/scripts/run-agy-json.ps1" `
       --role reviewer `
        --output "<scratch dir>/offload/<slug>.attempt1.review.json" `
        --error "<scratch dir>/offload/<slug>.attempt1.review.err" `
       '--' `
       -p "Run 'git diff' in this repository. Do not dispatch nested workers. For each criterion below, decide pass, fail, or hedge if unsure. Look for reasons the criterion FAILS before accepting pass. For every pass, quote one line verbatim from the diff that proves it. Criteria: <criteria>" `
       --output-format json `
       --mode plan `
       --json-schema $ReviewSchema `
       --add-dir $TaskWorkspace `
       --print-timeout 20m
     ```

     Read `structured_output` from the JSON response to extract criteria verdicts and quotes.
     For each `pass` verdict, verify the quoted line against the actual diff inside `$TASK_WORKSPACE`:
     - Bash: `git -C "$TASK_WORKSPACE" diff | grep -F -- "<quote>"`
     - PowerShell: `(git -C $TaskWorkspace diff) | Select-String -SimpleMatch "<quote>"`

     If all quotes match verbatim, accept the verdict (`agy+grep`). If any quote fails to match, any criterion fails, or the reviewer hedges, inspect the diff directly (`agy→orchestrator`).

3. **Integration of verified tasks.**
   - Disjoint tasks: Apply verified candidate patches sequentially via `execution-workspace integrate --manifest "<manifest>"`. The helper tests integration in a disposable scratch worktree before applying to the target.
   - Overlapping tasks: Run overlapping tasks serially. When Task 1 integrates, its resulting commit becomes the new baseline `$STAGE_BASELINE` for Task 2. Task 2's candidate worktree is created from this newly accepted baseline. Every accepted delta undergoes scope and gate verification before publication to the caller.

4. **Final combined gate check.**
   After all verified tasks are integrated into the integration target, execute all gate commands across all completed tasks together.
   If any combined gate fails or conflicts arise, the caller's working tree remains intact (the integrated changes are aborted and not published). Only publish when all combined gates pass cleanly.

## Step 6: Retry, recovery, and cleanup

Follow the shared recovery, retry accounting, and failure handling rules in [`SKILL.md`](../SKILL.md):

- **Stable worker IDs and retry ceiling.** Assign a stable `worker_id` to each logical task. Attempt 1 is initial dispatch; attempt 2 is its only possible retry. Maximum two attempts total per task.
- **Outcome tracking.** Record each attempt and verification outcome in `routing-outcomes.json`.
- **Baseline retention on retry.** Retries must retain the original verification baseline for that writing stage (e.g. `$GATE_BASELINE`). A failed attempt never becomes an implicitly trusted baseline. Create a fresh candidate worktree at the original baseline for attempt 2.
- **Implementer quality failure.** If a gate fails or an execution scope check violation occurs, this constitutes a quality failure. If a retry remains (attempt 2), redispatch once with the specific failure output. Use `--route quality-retry` only if an evidence-backed escalation target is configured for `implementer` in `model-policy.json`; otherwise use `--route default`. If attempt 2 fails, halt that task.
- **Scout or gate-author operational failure.** If a scout or gate-author crashes, times out, or produces unparsable output, retry once using `--route default`. If the retry fails, complete that step directly as the orchestrator (`orchestrator (fallback)`).
- **Reviewer failure.** If reviewer output is unparsable or fails quote verification, inspect the diff directly as the orchestrator (`agy→orchestrator`).
- **Quota exhaustion.** Explicit Gemini quota exhaustion triggers immediate quota handoff per [`SKILL.md`](../SKILL.md). Do not retry or switch models. Record still-running candidates immediately without waiting for siblings, preserve completed artifacts, and return unfinished work to the calling orchestrator.
- **Workspace cleanup.** After workers have terminated, clean up candidate worktrees:
  - Bash: `"$OFFLOAD_ROOT/scripts/execution-workspace.sh" cleanup --manifest "<manifest>" --status success|failed|retain`
  - PowerShell: `& "$OffloadRoot/scripts/execution-workspace.ps1" cleanup --manifest "<manifest>" --status success|failed|retain`
  Wait for active worker processes to terminate before calling cleanup. Pass `--status retain` if preserving a candidate workspace for orchestrator inspection.
