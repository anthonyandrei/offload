# Execution mode

Dispatches `agy` workers to implement file and code changes across independent gated tasks.

## Preconditions

Check these before dispatching writing tasks:

1. **`agy` is available.** Verify `agy` on `PATH` or at `~/.local/bin/agy`.
2. **Target is a git repository.** Run `git rev-parse --is-inside-work-tree`.
3. **Working tree is clean.** Run `git status --porcelain`. A clean tree is required to track edits, isolate changes, and roll back failed tasks.

## Roles and models

| Role | Wave | Model | Mode | Job |
|---|---|---|---|---|
| scout | 1 | `gemini-3.7-flash-low` | `plan` | Report repository-relative file paths a task touches. |
| gate-author | 2 | `gemini-3.7-flash-high` | `accept-edits` | Author an executable test file from acceptance criteria. |
| implementer | 3 | `gemini-3.7-flash-high` | `accept-edits` | Implement the task within owned files. |
| reviewer | 4 | `gemini-3.7-flash-high` | `plan` | Evaluate git diff against criteria for diff-gated tasks. |

`--mode plan` provides a behavioral hint, not a write barrier. `--add-dir` grants directory access without confining writes. Protection relies on a clean git working tree, mechanical diff comparisons, frozen path checks, and test gates.

## Step 1: Split and scout

### Provisional split

Break work into provisional tasks with a slug and a concise description of goals.

### Choose gates

Assign each task exactly one gate:

- **Machine gate.** An executable test command that exits 0 on success. A gate-author creates the test in Step 2; you run a red check and read the test before freezing it. Record whether the task is behavior-preserving (waives the red check failure requirement).
- **Diff gate.** Plain-text criteria for tasks without automated tests (documentation, configuration, refactoring). A reviewer worker evaluates the diff against these criteria in Step 5.

### Scout

For provisional writing tasks, dispatch scouts in parallel:

```bash
AGY=$(command -v agy || echo "$HOME/.local/bin/agy")
SCOUT_SCHEMA='{"type":"object","properties":{"files":{"type":"array","items":{"type":"string"}}},"required":["files"]}'
"$AGY" -p "<task description>. List every repo-relative file path this task would need to read or change. Do not edit anything. Do not dispatch nested workers." \
  --model gemini-3.7-flash-low \
  --output-format json \
  --mode plan \
  --json-schema "$SCOUT_SCHEMA" \
  --add-dir "<repo root>" \
  --print-timeout 20m \
  > "<scratch dir>/offload/<slug>.scout.json" 2> "<scratch dir>/offload/<slug>.scout.err"
```

Read `structured_output` from the JSON response to extract the file list.

### Finalize split

Reconcile scout findings:

- If two writing tasks touch overlapping files, serialize them rather than running in parallel.
- If a scout returned unexpected paths, adjust task boundaries before proceeding.
- Write final prose acceptance criteria for each task.

## Step 2: Author gates

Machine-gated tasks only. Skip for diff-gated tasks.

Dispatch one gate-author per machine-gated task in parallel:

```bash
"$AGY" -p "<criteria>. Write this test at <exact path>. Do not touch any other file. Do not dispatch nested workers." \
  --model gemini-3.7-flash-high \
  --output-format json \
  --add-dir "<repo root>" \
  --mode accept-edits \
  --print-timeout 20m \
  > "<scratch dir>/offload/<slug>.gate.json" 2> "<scratch dir>/offload/<slug>.gate.err"
```

Verify each created gate:

1. **File existence.** Confirm the test file exists at the exact specified path.
2. **Red check.** Run the gate command against the untouched tree. Require a non-zero exit code, unless the task is marked behavior-preserving where 0 is expected.
3. **Read the test.** Read the test source to confirm assertions match the requirements.
4. **Freeze and commit.** Stage and commit gate files (`git add <gate file>` and `git commit -m "offload: freeze gates"`) to establish a clean baseline.

## Step 3: Dispatch implementers

Run from a clean git working tree. Dispatch implementers in parallel:

```bash
"$AGY" -p "<task prompt>. Owned files: <owned paths>. Frozen paths: <frozen paths>. Gate command: <gate cmd>. Do not touch any other file. Do not dispatch nested workers." \
  --model gemini-3.7-flash-high \
  --output-format json \
  --add-dir "<repo root>" \
  --mode accept-edits \
  --print-timeout 20m \
  > "<scratch dir>/offload/<slug>.json" 2> "<scratch dir>/offload/<slug>.err"
```

The prompt must specify owned files, frozen paths, the gate command, and prohibitions against touching unassigned files or dispatching nested workers.

## Step 4: Collect

Read worker JSON responses:

- `status: SUCCESS`: Worker completed execution. Proceed to verification in Step 5.
- Non-zero exit code or unparsable output: Worker crashed. Retry once.
- Timeout (no output written before timeout): Task was too large or slow.

## Step 5: Verify

Verify every worker reporting `SUCCESS`:

1. **Ownership verification.** Compare modified paths against assigned paths mechanically:

   ```bash
   { git diff --name-only; git status --porcelain | awk '{print $2}'; } | sort -u > touched.txt
   printf '%s\n' "${OWNED[@]}" | sort -u > owned.txt
   comm -23 touched.txt owned.txt
   ```

   Any path listed by `comm -23` represents an ownership violation. Report violations regardless of gate results.

2. **Frozen paths check.** Verify frozen files remain unmodified:

   ```bash
   git diff --quiet -- <frozen paths>; echo $?
   ```

   A non-zero exit indicates a frozen path violation.

3. **Gate execution.**
   - Machine gate: Run the frozen gate command and check the exit code (0 required).
   - Diff gate: Dispatch an adversarial reviewer worker to inspect the diff:

   ```bash
   REVIEW_SCHEMA='{"type":"object","properties":{"criteria":{"type":"array","items":{"type":"object","properties":{"criterion":{"type":"string"},"verdict":{"type":"string","enum":["pass","fail","hedge"]},"quote":{"type":"string"}},"required":["criterion","verdict","quote"]}}},"required":["criteria"]}'
   "$AGY" -p "Run 'git diff' in this repository. Do not dispatch nested workers. For each criterion below, decide pass, fail, or hedge if unsure. Look for reasons the criterion FAILS before accepting pass. For every pass, quote one line verbatim from the diff that proves it. Criteria: <criteria>" \
     --model gemini-3.7-flash-high \
     --output-format json \
     --mode plan \
     --json-schema "$REVIEW_SCHEMA" \
     --add-dir "<repo root>" \
     --print-timeout 20m \
     > "<scratch dir>/offload/<slug>.review.json" 2> "<scratch dir>/offload/<slug>.review.err"
   ```

   For each `pass` verdict, grep the quoted line against the actual diff. If all quotes match verbatim, accept the verdict (`agy+grep`). If any quote fails to match, any criterion fails, or the reviewer hedges, inspect the diff directly (`agy→orchestrator`).

## Step 6: Retry and fallback

- **Implementer failure.** If a gate fails or an ownership violation occurs, redispatch that worker once with the specific failure output. If the second run fails, halt that task.
- **Scout or gate-author failure.** Retry once with the concrete error. If the retry fails, complete that step directly as the orchestrator (`orchestrator (fallback)`).
- **Reviewer failure.** If reviewer output is unparsable or fails validation, inspect the diff directly as the orchestrator (`agy→orchestrator`).
