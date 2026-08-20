---
name: offload
description: Use when the user wants execution handed to another vendor's CLI agents instead of
  running it here — "offload this", "run this on agy", "use gemini subagents to execute", or
  after answering yes to the offload question at the end of planning. Dispatches parallel
  headless agy workers, gates their output, and reports what was proven versus claimed.
---

# offload

If you are running as an `agy` worker, stop. Do not use this skill. Return your answer to your
orchestrator. `offload` dispatches workers — scouts, gate-authors, implementers, reviewers. None
of them dispatch further workers of their own.

## What this skill does

`offload` sends work to `agy` (the Antigravity CLI, running Gemini models) in four worker roles.
You stay the orchestrator. You decide how the work splits, write the acceptance criteria for each
piece, and read the small number of things that require judgment. Everything mechanical —
repo discovery, gate authoring, the code itself, first-pass diff review — goes to a worker.

You do not relay what a worker says about its own work. You check it, or you check what a second
worker said about it.

## Preconditions

Check these before you dispatch anything. Refuse and state the failing check if any fails.

1. **`agy` is on the machine.** Try `agy` on `PATH` first. If that fails, try
   `~/.local/bin/agy`. If neither runs, refuse and tell the user to install `agy`.
2. **The target is a git repository.** Run `git rev-parse --is-inside-work-tree`. If it fails,
   refuse. There is no way to audit a worker's changes outside a repository.
3. **The working tree is clean.** Run `git status --porcelain`. If it prints anything for a
   tracked file, refuse and name the dirty files. A dirty tree makes it impossible to tell your
   changes from a worker's changes, and it makes rollback of a bad worker unsafe.

## Roles and models

| Role | Wave | Model | Mode | Job |
|---|---|---|---|---|
| scout | 1 | `gemini-3.7-flash-low` | `plan` | Report which files a provisional task would touch. Paths, nothing else. |
| gate-author | 2 | `gemini-3.7-flash-high` | `accept-edits` | Turn your prose criteria into an executable test, at a path you name. |
| implementer | 3 | `gemini-3.7-flash-high` | `accept-edits` | Do the task. |
| reviewer | 4 | `gemini-3.7-flash-high` | `plan` | Judge a diff against your criteria, one verdict per criterion, diff-gated tasks only. |

`--mode plan` makes `agy` refuse to write — confirmed by direct test: asked to create a file, it
produces a plan artifact and touches nothing in the working tree. Scout and reviewer use it
because neither should ever be capable of changing code, not just unlikely to. Gate-author and
implementer keep `accept-edits`, because writing files is the job.

Scout runs on the cheapest model in the fleet. Its job is repo discovery, not reasoning, and if
its file list is wrong, the mechanical ownership check in Step 5 catches the fallout — the model
choice is cheap to be wrong about. `gate-author`, `implementer`, and `reviewer` stay on
`gemini-3.7-flash-high`, for the reason given at the end of Step 3: on DeepSWE it is the strongest
model `agy` exposes, by a wide margin.

## Step 1 — Split and scout

### Provisional split

Break the work into provisional tasks: a slug and a one-sentence description of what each should
accomplish. Do not assign files yet — that is what scouting is for. If you already know two tasks
will collide on a file, note it now; the scout wave will confirm or correct it.

### The two gates

Decide, per task, which gate applies. Exactly one of the two:

**Machine gate.** A command that exits 0 when the work is correct. Authored in Step 2 by a
gate-author worker, from criteria you write here, then red-checked and read by you before it is
frozen. A test the implementer writes to prove its own work proves nothing — the same is true of
a test the implementer's sibling gate-author wrote if nothing checks it, which is why Step 2 exists.

**Diff gate.** For work with no natural pass/fail command — prose, documentation, configuration, a
reorganization. Write the acceptance criteria as plain sentences now. A reviewer worker judges the
finished diff against them in Step 5; you read the diff yourself only when the reviewer's verdict
doesn't hold up.

There is no third option. Work that is neither testable nor diffable — pure research with no file
changes — is out of scope for this skill.

For a machine-gated task, also decide: **is this task behavior-preserving?** A refactor's test
should pass before the change and after it. Record yes/no per task — Step 2's red check is waived
when the answer is yes.

### Scout

One worker per provisional task, dispatched in parallel, `--mode plan`,
`--model gemini-3.7-flash-low`:

```bash
AGY=$(command -v agy || echo "$HOME/.local/bin/agy")
SCOUT_SCHEMA='{"type":"object","properties":{"files":{"type":"array","items":{"type":"string"}}},"required":["files"]}'
"$AGY" -p "<task description>. List every repo-relative file path this task would need to read or change. Do not write or edit anything." \
  --model gemini-3.7-flash-low \
  --output-format json \
  --mode plan \
  --json-schema "$SCOUT_SCHEMA" \
  --add-dir "<repo root>" \
  --print-timeout 20m \
  > "<scratch dir>/offload/<slug>.scout.json" 2> "<scratch dir>/offload/<slug>.scout.err"
```

Confirmed by direct test: `--json-schema` composes with `--output-format json` and adds a
`structured_output` field holding the validated object, separate from `response`. Read
`structured_output`, not `response` — `response` can carry a stray duplicate of the same JSON as
loose text.

### Finalize the split

Once every scout has returned (or fallen back — Step 6), reconcile:

- Two tasks whose file lists overlap do not run in parallel. Serialize them.
- A file list that contradicts your provisional split (a task touching far more or less than
  expected) is a signal to resplit, not to ignore.
- Write the final acceptance criteria per task now, in prose, even for machine-gated tasks —
  Step 2's gate-author needs them.

This is judgment. Nothing downstream checks whether the split itself is right — a wrong split
produces tasks that each pass their own gate while the assembled result is still broken.

## Step 2 — Author gates

Machine-gated tasks only. Skip this step entirely for diff-gated tasks.

Dispatch one gate-author per machine-gated task, parallel, `accept-edits`,
`gemini-3.7-flash-high`. The prompt states, in this order: the acceptance criteria, the exact test
file path to create, an explicit line that it must not touch any other file, and whether the task
is behavior-preserving (so it knows to assert current behavior is retained rather than new
behavior appearing).

```bash
"$AGY" -p "<criteria>. Write this test at <exact path>. Do not touch any other file." \
  --model gemini-3.7-flash-high \
  --output-format json \
  --add-dir "<repo root>" \
  --mode accept-edits \
  --print-timeout 20m \
  > "<scratch dir>/offload/<slug>.gate.json" 2> "<scratch dir>/offload/<slug>.gate.err"
```

For each gate-author that reports `SUCCESS` (three-outcome model, same as Step 4):

1. **File exists** at the path you named. If not, treat as a failure — Step 6.
2. **Red check.** Run the gate command against the tree as it stands (implementers have not run
   yet). Require non-zero exit — **unless the task is behavior-preserving**, in which case a
   passing gate here is correct and expected, not a tautology. A gate that passes when it should
   fail is caught here; one that fails when it should pass is a behavior-preserving task you
   forgot to mark.
3. **Read the file.** Tests are short. This is the only check that catches a well-formed test
   asserting the wrong thing — nothing mechanical can.
4. **Freeze and commit.** `git add` the gate files and commit them, e.g.
   `git commit -m "offload: freeze gates"`. This gives Step 5's ownership diff a clean baseline
   that already includes the gates, so a gate file never shows up as an implementer's stray edit.

## Step 3 — Dispatch implementers

One `Bash` call per worker, `run_in_background: true`. Dispatch every implementer before you
collect any of them.

```bash
"$AGY" -p "<task prompt>" \
  --model gemini-3.7-flash-high \
  --output-format json \
  --add-dir "<repo root>" \
  --mode accept-edits \
  --print-timeout 20m \
  > "<scratch dir>/offload/<slug>.json" 2> "<scratch dir>/offload/<slug>.err"
```

Use `20m` for `--print-timeout`, not `agy`'s own 5m default. On expiry `agy` writes no output at
all — a run that is merely slow looks identical to one that crashed, and the difference matters
for whether a retry is worth it.

The task prompt must state, in this order: the task, the exact files it owns, an explicit line
that it must not touch any other file, the frozen paths (including the gate file from Step 2, if
any), and the gate command so the worker can check itself before finishing.

`--model` is `gemini-3.7-flash-high` for every role that writes or judges code. There is no
escalation target inside `agy` worth reaching for. On DeepSWE (2026-08-20) it scores 65% pass@1,
against 47% for 3.6-flash and 36% for 3.5-flash, and no Gemini pro model has been measured at all.
The Claude models `agy` exposes are 4.6-era builds; the nearest measured relatives,
`claude-opus-4.8` at 59% and `claude-sonnet-5` at 54%, both score below the default.

If a task proves too hard for this model, that is a signal to pull the task back to the
orchestrator, not to shop for another model. Step 6 already stops after one retry.

To re-check this choice later, compare `agy models` against
[deepswe.datacurve.ai](https://deepswe.datacurve.ai/). Those pass@1 figures come from DeepSWE's
own harness, not from `agy`, so treat them as a ranking rather than a prediction.

## Step 4 — Collect

The harness re-invokes you when each background call exits. Read the output file.
`--output-format json` returns one JSON object:

```json
{"status":"SUCCESS","response":"...","duration_seconds":36.4,"num_turns":1,"usage":{...}}
```

This applies to every role — scout, gate-author, implementer, reviewer. Three outcomes, and they
mean different things. Report them separately — never fold them into a single "failed":

- **`status: SUCCESS`** — the worker finished and believes it did the task. This is a claim, not
  a proof. Go to Step 5.
- **The process exited non-zero, or the output file is empty or unparsable** — the worker
  crashed. Retrying is usually worth it.
- **The process ran past its `--print-timeout` with no output file written at all** — the worker
  timed out. This can mean the task was too large for one call, not that the approach was wrong.

## Step 5 — Verify

Do this for every implementer that reported `SUCCESS`. Do it yourself, or via a reviewer worker
for diff gates — never by asking the implementer to confirm its own work.

1. **Ownership, mechanically.** Build the set of paths this task actually touched, then diff it
   against the owned set:

   ```bash
   { git diff --name-only; git status --porcelain | awk '{print $2}'; } | sort -u > touched.txt
   printf '%s\n' "${OWNED[@]}" | sort -u > owned.txt
   comm -23 touched.txt owned.txt
   ```

   Empty output means clean. Anything printed is an **ownership violation** — report it even when
   the gate passes. Untracked build noise (`__pycache__/`, `.pytest_cache/`, similar) is not a
   violation; a repo missing the right `.gitignore` entries is a separate problem, not this
   worker's fault.
2. **Frozen paths, mechanically.** `git diff --quiet -- <frozen paths>; echo $?`. Zero means
   clean. Non-zero is a **frozen-file violation**, regardless of what the gate says.
3. **The gate.**
   - Machine gate: run the frozen command, read its exit code.
   - Diff gate: dispatch a reviewer.

### The reviewer

Never the implementer, and never shown the implementer's `response` text — only the diff and your
criteria. `--mode plan`, `gemini-3.7-flash-high`, prompted adversarially: find reasons each
criterion **fails**; default to fail when unsure. This means the reviewer's own errors bias toward
sending work back to you, not past you.

```bash
REVIEW_SCHEMA='{"type":"object","properties":{"criteria":{"type":"array","items":{"type":"object","properties":{"criterion":{"type":"string"},"verdict":{"type":"string","enum":["pass","fail","hedge"]},"quote":{"type":"string"}},"required":["criterion","verdict","quote"]}}},"required":["criteria"]}'
"$AGY" -p "Run 'git diff' in this repository. For each criterion below, decide pass, fail, or hedge if you are not confident. Look for reasons the criterion FAILS before accepting that it passes. For every pass, quote one line verbatim from the diff that proves it. Criteria: <criteria>" \
  --model gemini-3.7-flash-high \
  --output-format json \
  --mode plan \
  --json-schema "$REVIEW_SCHEMA" \
  --add-dir "<repo root>" \
  --print-timeout 20m \
  > "<scratch dir>/offload/<slug>.review.json" 2> "<scratch dir>/offload/<slug>.review.err"
```

For every `pass` verdict, `grep -F` the quoted line against the actual diff. A match confirms the
verdict without you reading anything. **A quote that doesn't match escalates, it does not fail** —
whitespace and line-wrapping make false negatives easy, so treat a mismatch as "go look," not as
proof the reviewer was wrong.

Open the diff yourself when: any criterion fails, any criterion hedges, or any quote fails to
match. Otherwise the reviewer's verdict stands on its own.

## Step 6 — Retry or fall back, then stop

**Implementer.** If a gate fails, or a violation is found, re-dispatch that one worker once.
Include the actual gate output or the violation text in its new prompt — not just "try again." If
the second attempt still fails, stop. Report both attempts.

**Scout or gate-author.** Retry once with the concrete reason (a missing file list, a gate that
red-checked green twice, a written-outside-its-path violation). If the retry also fails, **you do
that job yourself** — read the repo for that one task, or write that one gate — and the run
continues. This is the fallback path, not a dead end: the run's cost for that piece returns to
what it was before this skill grew these roles, and the report says so.

**Reviewer.** No retry. A reviewer problem (crash, unparsable output, or the escalation
conditions above) sends you straight to reading the diff yourself.

Never roll back a worker that passed because a sibling failed. Each task's result stands on its
own.

## Step 7 — Report

Use this shape every time, so it reads the same way run after run. `provenance` names who
authored the gate and who judged the result — this is what keeps a worker's gate and a worker's
verdict from being reported as if they carried the same weight as your own.

```markdown
## Offload run — N workers, <duration>

| worker | gate | provenance | result | files |
|--------|------|------------|--------|-------|
| parser | pytest tests/test_parser.py | agy+red+read | ✓ 12/12 | as assigned (scout) |
| render | pytest tests/test_render.py | opus (fallback) | ✓ 8/8 | ⚠ +1 stray |
| docs   | diff                        | agy+grep      | △ judged | as assigned (scout) |

### render — ownership violation
owned: src/render.py
also edited: src/util.py
<diff excerpt>

### docs — reviewer verdict
pass: 3/3 criteria, all quotes matched. No escalation.

### Claimed by Gemini, not verified
- "also improved error messages"
```

Provenance values: `opus` (you did it), `agy+red+read` (gate-author, validated by you),
`agy+grep` (reviewer, quotes matched, you didn't open the diff), `agy→opus` (reviewer escalated,
you judged it), and `opus (fallback)` for anything that degraded per Step 6.

Label every line one of three ways:

- **Proven** — a command ran and you read its exit code or output.
- **Judged** — a diff gate. Say who judged it, using the provenance values above. If a reviewer's
  verdict escalated to you and you are running as a lighter model than the one that planned this
  task, mark the line `NEEDS-OPUS-REVIEW` so the user knows to check it themselves.
- **Claimed** — the worker said it in its `response` text and nothing checked it. State it, but
  do not present it as fact.

## Limits, stated plainly

- **`--add-dir` grants access. It does not confine.** No flag stops an `accept-edits` worker from
  editing a file outside its assignment. `--mode plan` is a real guarantee for scout and reviewer —
  confirmed by direct test, it refuses to write at all — but gate-author and implementer still run
  `accept-edits`, and Step 5's audit catches an ownership problem after the fact, not before. A
  clean starting tree (Precondition 3) is what makes an ownership violation recoverable with
  `git checkout -- <file>`.
- **There is no gate outside a git repository.** If the target has no `.git`, refuse rather than
  fall back to a weaker check.
- **A worker can dispatch nothing further.** `offload` is one level of delegation. No worker —
  scout, gate-author, implementer, or reviewer — may spawn its own workers. This skill's
  self-guard at the top exists for exactly that case.
- **The split itself has no gate.** Every check in this skill is local to one task. A wrong
  decomposition — a requirement dropped, a task boundary drawn wrong — produces tasks that each
  pass their own gate while the assembled result is still broken. Nothing downstream catches this;
  Step 1's finalize-the-split judgment is what stands between the plan and that failure mode.
