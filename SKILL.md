---
name: offload
description: Use when the user wants execution handed to another vendor's CLI agents instead of
  running it here. Triggers include "offload this", "run this on agy", "use gemini subagents to execute", or
  after answering yes to the offload question at the end of planning. Also reach for it
  unprompted, to offer this route, when work splits into three or more independently gated
  tasks in a clean git repository, or when the user asks for a review, audit, lint, or check
  that fans out across many files. Dispatches parallel headless agy workers, gates their
  output, and reports what was proven versus claimed.
---

# offload

If you are `agy`, stop here. This applies both when this skill dispatched you as a worker and when
you are a top-level `agy` session that happened to load this file. Return worker results to your
orchestrator. `agy` is the worker role this skill exists to dispatch to. Every step below assumes
an orchestrator that is not `agy`. Any other agent that can read this file and run shell commands
can orchestrate, including Claude Code, Codex CLI, and similar agents. `offload` dispatches scouts, gate-authors, implementers, reviewers, and researchers. Their assignments prohibit further worker dispatch, but the skill cannot enforce that rule if a worker ignores it.

## What this skill does

`offload` sends work to `agy` (the Antigravity CLI, running Gemini models) in five worker roles.
You stay the orchestrator. You decide how the work splits, write the acceptance criteria or
bounded questions for each piece, and read the small number of things that require judgment.
Workers handle repo discovery, gate authoring, the code itself, first-pass diff review, and
bounded research/audit.

You do not relay what a worker says about its own work. You check it, or you check what a second
worker said about it.

## Preconditions

**Offer before you dispatch.** When you reached this skill on your own rather than being asked
for it, put the choice to the user first: say what you would dispatch and ask whether to offload
it. Ask once per session. A no settles it. Run the work yourself for the rest of the session.

Check these before you dispatch anything. Refuse and state the failing check if any fails.
Checks 2 and 3 apply to any run that dispatches an `accept-edits` worker, such as a gate-author or
an implementer. Only all-plan research/audit runs waive Git and clean-tree preconditions. Every
gate-author or implementer run retains them. A worker that cannot write leaves nothing to audit
and nothing to roll back.

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
| researcher | parallel | `gemini-3.7-flash-high` | `plan` | Investigate a bounded question within an assigned scope. Evidence and findings only, can't write. |

`--mode plan` makes `agy` refuse to write. A direct test asked it to create a file and confirmed
that it produced a plan artifact without touching the working tree. Scout, reviewer, and researcher
use it because none of them should ever be capable of changing code, not just unlikely to.
Gate-author and implementer keep `accept-edits`, because writing files is the job.

Scout runs on the cheapest model in the fleet. Its job is repo discovery, not reasoning. If its
file list is wrong, the mechanical ownership check in Step 5 catches the fallout. The model choice
is cheap to be wrong about. `gate-author`, `implementer`, `reviewer`, and `researcher` stay on
`gemini-3.7-flash-high`, for the reason given at the end of Step 3: on DeepSWE it is the strongest
model `agy` exposes, by a wide margin.

## Step 1: Split and scout

### Provisional split

Break the work into provisional tasks or bounded research assignments: a slug and a one-sentence
description of what each should accomplish. For writing tasks, do not assign files yet; scouting
determines their file lists. If you already know two writing tasks will collide on a file, note it
now; the scout wave will confirm or correct it.

### Lanes and gates

Decide, per piece of work, which lane and check applies:

#### Writing tasks: the two gates
For tasks that create or edit code or files, choose exactly one of two gates:

**Machine gate.** A command that exits 0 when the work is correct. Authored in Step 2 by a
gate-author worker, from criteria you write here, then red-checked and read by you before it is
frozen. A test the implementer writes to prove its own work proves nothing. The same is true of a
test written by the implementer's sibling gate-author if nothing checks it. That is why Step 2 exists.

**Diff gate.** Use this for work with no natural pass/fail command, such as prose, documentation,
configuration, or a reorganization. Write the acceptance criteria as plain sentences now. A reviewer worker judges the
finished diff against them in Step 5; you read the diff yourself only when the reviewer's verdict
doesn't hold up.

For a machine-gated task, also decide: **is this task behavior-preserving?** A refactor's test
should pass before the change and after it. Record yes/no per task. Step 2's red check is waived
when the answer is yes.

#### Read-only tasks: bounded research/audit lane
Use this lane for investigating a specific codebase question, audit, or invariant check without
mutating files.

A research assignment must declare all four of:
1. **Exactly one bounded question.** Clear, specific inquiry (e.g. "Which API routes bypass session validation?").
2. **Allowed scope.** Explicit paths, directories, or modules the worker is permitted to inspect.
3. **Evidence expectations.** Concrete citations required (file paths with line ranges or runnable commands that demonstrate findings).
4. **Explicit non-mutation rule.** An unambiguous mandate: investigate only; do not create, edit, or delete any files; do not dispatch nested workers.

Open-ended research without a bounded question, defined scope, or evidence expectations is strictly out of scope.

### Scout

For provisional writing tasks, dispatch one scout per task in parallel, `--mode plan`,
`--model gemini-3.7-flash-low`:

```bash
AGY=$(command -v agy || echo "$HOME/.local/bin/agy")
SCOUT_SCHEMA='{"type":"object","properties":{"files":{"type":"array","items":{"type":"string"}}},"required":["files"]}'
"$AGY" -p "<task description>. List every repo-relative file path this task would need to read or change. Do not write or edit anything. Do not dispatch nested workers." \
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
`structured_output`, not `response`. `response` can carry a stray duplicate of the same JSON as
loose text.

Bounded research/audit tasks already have their allowed scope declared in their assignment and skip scouting.

### Finalize the split

Once every scout has returned or fallen back under Step 6, reconcile:

- Two writing tasks whose file lists overlap do not run in parallel. Serialize them.
- A file list that contradicts your provisional split (a task touching far more or less than
  expected) is a signal to resplit, not to ignore.
- Write the final acceptance criteria per task now, in prose, even for machine-gated tasks.
  Step 2's gate-author needs them.
- For research/audit assignments, finalize the single bounded question, allowed scope, evidence expectations, and non-mutation rule.

This is judgment, and it is the one place in this skill with nothing checking it. A wrong split can
drop a requirement or draw a task boundary incorrectly. Each task may pass its own gate while the
assembled result remains broken. Nothing downstream catches that.

## Step 2 — Author gates

Machine-gated writing tasks only. Skip this step entirely for diff-gated tasks and research/audit tasks.

Dispatch one gate-author per machine-gated task, parallel, `accept-edits`,
`gemini-3.7-flash-high`. The prompt states, in this order: the acceptance criteria, the exact test
file path to create, an explicit line that it must not touch any other file, a prohibition on nested
worker dispatch, and whether the task is behavior-preserving (so it knows to assert current
behavior is retained rather than new behavior appearing).

```bash
"$AGY" -p "<criteria>. Write this test at <exact path>. Do not touch any other file. Do not dispatch nested workers." \
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

## Step 3 — Dispatch implementers and researchers

One non-blocking background call per worker. Claude Code's `Bash` tool takes
`run_in_background: true`; use whatever your harness offers for the same thing. Dispatch every
worker in a wave before you collect any of them.

### Implementers (writing tasks)

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
that it must not touch any other file, a prohibition on nested worker dispatch, the frozen paths
(including the gate file from Step 2, if any), and the gate command so the worker can check itself
before finishing.

### Researchers (bounded research/audit lane)

Dispatched in parallel, `--mode plan`, `gemini-3.7-flash-high`.

```bash
RESEARCH_SCHEMA='{"type":"object","properties":{"lane_id":{"type":"string"},"lane_kind":{"type":"string","enum":["research","audit"]},"question":{"type":"string"},"overall_status":{"type":"string","enum":["complete","inconclusive","blocked"]},"uncertainty":{"type":"string"},"findings":{"type":"array","items":{"type":"object","properties":{"finding":{"type":"string"},"priority":{"type":"string","enum":["high","medium","low"]},"status":{"type":"string","enum":["confirmed","refuted","inconclusive"]},"evidence_locations":{"type":"array","items":{"type":"string"}},"evidence_commands":{"type":"array","items":{"type":"string"}}},"required":["finding","priority","status","evidence_locations"]}}},"required":["lane_id","lane_kind","question","overall_status","uncertainty","findings"]}'
"$AGY" -p "Lane ID: <stable lane slug>. Lane kind: <research or audit>. Question: <bounded question>. Allowed scope: <scope>. Evidence expectations: <expectations>. Non-mutation rule: investigate only, do not create or edit files, do not dispatch nested workers." \
  --model gemini-3.7-flash-high \
  --output-format json \
  --mode plan \
  --json-schema "$RESEARCH_SCHEMA" \
  --add-dir "<repo root>" \
  --print-timeout 20m \
  > "<scratch dir>/offload/<slug>.research.json" 2> "<scratch dir>/offload/<slug>.research.err"
```

The research assignment prompt states, in this order: a stable lane ID, the lane kind, the single bounded question, the allowed scope, the evidence expectations, and the explicit non-mutation rule prohibiting file modifications and nested worker dispatches.

### Model rationale

`--model` is `gemini-3.7-flash-high` for every role that writes code, judges diffs, or conducts research/audit. There is no
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

When `--json-schema` is used (scouts, reviewers, researchers), parse the validated `structured_output` object from the JSON result.

This applies to every role — scout, gate-author, implementer, reviewer, researcher. Three outcomes, and they
mean different things. Report them separately — never fold them into a single "failed":

- **`status: SUCCESS`** — the worker finished and believes it did the task. This is a claim, not
  a proof. Go to Step 5.
- **The process exited non-zero, or the output file is empty or unparsable** — the worker
  crashed. Retrying is usually worth it.
- **The process ran past its `--print-timeout` with no output file written at all** — the worker
  timed out. This can mean the task was too large for one call, not that the approach was wrong.

## Step 5 — Verify

Do this for every worker that reported `SUCCESS`. Do it yourself, or via a reviewer worker
for diff gates — never by asking the worker to confirm its own work.

### Writing tasks

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

#### The reviewer

Never the implementer, and never shown the implementer's `response` text — only the diff and your
criteria. `--mode plan`, `gemini-3.7-flash-high`, prompted adversarially: find reasons each
criterion **fails**; default to fail when unsure. This means the reviewer's own errors bias toward
sending work back to you, not past you.

```bash
REVIEW_SCHEMA='{"type":"object","properties":{"criteria":{"type":"array","items":{"type":"object","properties":{"criterion":{"type":"string"},"verdict":{"type":"string","enum":["pass","fail","hedge"]},"quote":{"type":"string"}},"required":["criterion","verdict","quote"]}}},"required":["criteria"]}'
"$AGY" -p "Run 'git diff' in this repository. Do not dispatch nested workers. For each criterion below, decide pass, fail, or hedge if you are not confident. Look for reasons the criterion FAILS before accepting that it passes. For every pass, quote one line verbatim from the diff that proves it. Criteria: <criteria>" \
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

### Research and audit lane

Never accept a researcher's findings on trust. Read `structured_output` and run this verification flow:

1. **Check scope before evidence.** Confirm that every cited location and command stays inside the assignment's allowed scope. Treat out-of-scope evidence as a violation and leave the finding unverified.
2. **Assess priority independently.** Confirm or correct each worker-supplied priority before choosing verification depth. A worker cannot avoid a direct check by labeling a serious finding medium or low.
3. **Directly check every high-priority claim.** Read the exact file locations cited in `evidence_locations`. Before running an `evidence_command`, inspect it and run it only when it is read-only, non-interactive, and inside the allowed scope. Otherwise, reproduce the claim with your own safe command or leave it unverified. Verify whether the code or command output directly proves the finding.
4. **Sample lower-priority claims.** For medium- and low-priority findings, spot-check a representative sample of safe, in-scope evidence locations and commands across the findings.
5. **Leave unsupported claims unverified.** If a claim lacks concrete evidence, cites out-of-scope evidence, proposes an unsafe or ambiguous command, or fails corroboration, mark it as `UNVERIFIED` (or `Claimed`) in the report.
6. **Record the sample and per-finding provenance.** Document priority corrections, the exact sample checked, scope or command violations, and the provenance for each finding (e.g. `orchestrator+checked` for direct high-priority checks, `orchestrator+sampled` for sampled medium/low claims, and `agy+unverified` for unsupported claims).

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

**Researcher.** Retry once if the worker crashed, output was unparsable, or results were inconclusive without inspecting the assigned scope. If the retry also fails, **you do the research yourself** (`orchestrator (fallback)`).

Never roll back a worker that passed because a sibling failed. Each task's result stands on its
own.

## Step 7 — Report

Use this shape every time, so it reads the same way run after run. `provenance` names who
authored the gate, who judged the result, or how research findings were verified — this is what keeps a worker's gate, verdict, or finding from being reported as if they carried the same weight as your own.

```markdown
## Offload run — N workers, <duration>

| worker | gate / lane | provenance | result | files / findings |
|--------|-------------|------------|--------|------------------|
| parser | pytest tests/test_parser.py | agy+red+read | ✓ 12/12 | as assigned (scout) |
| render | pytest tests/test_render.py | orchestrator (fallback) | ✓ 8/8 | ⚠ +1 stray |
| docs   | diff                        | agy+grep      | △ judged | as assigned (scout) |
| auth-audit | audit (plan-only)       | direct-check (high) + sample (med/low) | complete | 3 findings (2 verified, 1 unverified) |

### render — ownership violation
owned: src/render.py
also edited: src/util.py
<diff excerpt>

### docs — reviewer verdict
pass: 3/3 criteria, all quotes matched. No escalation.

### auth-audit — findings & verification sample
- [HIGH] [orchestrator+checked] Route `/api/v1/reset` lacks session check (src/auth/routes.py:L45-L52) — confirmed.
- [MED]  [orchestrator+sampled] Token expiry default is 30d (src/config.py:L18) — confirmed by sample.
- [LOW]  [agy+unverified] "Some legacy endpoints may also be affected" — unverified (no location cited).
Sample recorded: 1/1 high checked, 1/2 med/low sampled.

### Claimed by Gemini, not verified
- "also improved error messages"
- "Some legacy endpoints may also be affected"
```

Provenance values: `orchestrator` (you did it), `agy+red+read` (gate-author, validated by you),
`agy+grep` (reviewer, quotes matched, you didn't open the diff), `agy→orchestrator` (reviewer
escalated, you judged it), `orchestrator+checked` (research finding directly checked by you), `orchestrator+sampled` (research finding sampled by you), `agy+unverified` (research claim unverified), and `orchestrator (fallback)` for anything that degraded per Step 6.

Label every line one of four ways:

- **Proven** — a command ran and you read its exit code or output.
- **Judged** — a diff gate. Say who judged it, using the provenance values above. If a reviewer's
  verdict escalated to you and you are running as a lighter model than the one that planned this
  task, mark the line `NEEDS-STRONGER-REVIEW` so the user knows to check it themselves.
- **Verified** — a research/audit finding where evidence was directly checked (`orchestrator+checked`) or sampled (`orchestrator+sampled`).
- **Claimed** — the worker said it in its response text or unverified findings and nothing checked it. State it, but
  do not present it as fact.

## Limits

- **`--add-dir` grants access. It does not confine.** No flag stops an `accept-edits` worker from
  editing a file outside its assignment. Gate-author and implementer run `accept-edits`, so Step
  5's audit catches an ownership problem after the fact, not before. A clean starting tree
  (Precondition 3) is what makes an ownership violation recoverable with
  `git checkout -- <file>`. `--mode plan` carries the guarantee instead, for the three roles that
  have it (scout, reviewer, researcher): see Roles and models.
- **Preconditions and git requirement.** Only all-plan research/audit runs waive Git and clean-tree
  preconditions. Every gate-author or implementer run retains them. A writing worker has no gate
  outside a git repository. Precondition 2 refuses rather than falling back to a weaker check.
- **Assignments prohibit nested dispatch.** `offload` is designed for one level of delegation.
  The self-guard stops an `agy` process that loads this skill, and every assignment repeats
  the prohibition. The skill cannot enforce it when a worker ignores both instructions.
- **Open-ended research is out of scope.** The bounded research/audit lane requires exactly one
  bounded question, explicit allowed scope, concrete evidence expectations, and an explicit
  non-mutation rule. Unbounded exploratory tasks without these constraints cannot be verified.
- **The split itself has no gate.** Every check in this skill is local to one task. Step 1's
  finalize-the-split judgment is the only thing standing between a wrong decomposition and a run
  where every task passes.
