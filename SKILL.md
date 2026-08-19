---
name: offload
description: Use when the user wants execution handed to another vendor's CLI agents instead of
  running it here — "offload this", "run this on agy", "use gemini subagents to execute", or
  after answering yes to the offload question at the end of planning. Dispatches parallel
  headless agy workers, gates their output, and reports what was proven versus claimed.
---

# offload

If you are running as an `agy` worker, stop. Do not use this skill. Return your answer to your
orchestrator. `offload` dispatches workers. It does not run inside one.

## What this skill does

`offload` sends implementation work to `agy` (the Antigravity CLI, running Gemini models). You
stay the orchestrator. You plan the work, write the acceptance check for each piece, dispatch
`agy` workers in parallel, check their work against the acceptance check, and report the result.

You do not relay what a worker says about its own work. You check it.

## Preconditions

Check these before you dispatch anything. Refuse and state the failing check if any fails.

1. **`agy` is on the machine.** Try `agy` on `PATH` first. If that fails, try
   `~/.local/bin/agy`. If neither runs, refuse and tell the user to install `agy`.
2. **The target is a git repository.** Run `git rev-parse --is-inside-work-tree`. If it fails,
   refuse. There is no way to audit a worker's changes outside a repository.
3. **The working tree is clean.** Run `git status --porcelain`. If it prints anything for a
   tracked file, refuse and name the dirty files. A dirty tree makes it impossible to tell your
   changes from a worker's changes, and it makes rollback of a bad worker unsafe.

## Step 1 — Write the dispatch spec

Break the work into tasks. For each task, decide:

- **A slug.** Short, human-readable. You will use it to name output files and to talk about the
  task in the report.
- **The files it owns.** The exact paths this task is allowed to change. Nothing else.
- **A gate.** Exactly one of the two below.
- **Frozen paths**, if any. Paths the worker must not touch even though they relate to the task.

If two tasks would touch the same file, do not run them in parallel. Run them one after another
instead.

### The two gates

**Machine gate.** You write a command that exits 0 when the work is correct. Usually a test file
you author yourself, before dispatch, and mark frozen — the worker may not edit it. A test the
worker wrote to prove its own work proves nothing, because the worker can weaken the assertion
the moment it is inconvenient. Writing the test yourself keeps the check independent of the
worker that has to pass it.

A machine gate can also be a build, a lint, or any command with a real exit code. It does not
have to be a test framework.

**Diff gate.** For work with no natural pass/fail command — prose, documentation, configuration,
a reorganization. You write the acceptance criteria as plain sentences. After the worker
finishes, you read the diff yourself and judge it against those sentences. This is real Opus
quota spent on judgment, not a shortcut.

There is no third option. Work that is neither testable nor diffable — pure research with no
file changes — is out of scope for this skill.

## Step 2 — Dispatch

One `Bash` call per worker, with `run_in_background: true`. Dispatch every worker before you
collect any of them.

```bash
AGY=$(command -v agy || echo "$HOME/.local/bin/agy")
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
that it must not touch any other file, the frozen paths if any, and the gate command so the
worker can check itself before finishing.

`--model` defaults to `gemini-3.7-flash-high`. Use `gemini-3.1-pro-high` for a task that needs
harder reasoning than the default model handles well.

## Step 3 — Collect

The harness re-invokes you when each background call exits. Read the output file.
`--output-format json` returns one JSON object:

```json
{"status":"SUCCESS","response":"...","duration_seconds":36.4,"num_turns":1,"usage":{...}}
```

Three outcomes, and they mean different things. Report them separately — never fold them into a
single "failed":

- **`status: SUCCESS`** — the worker finished and believes it did the task. This is a claim, not
  a proof. Go to Step 4.
- **The process exited non-zero, or the output file is empty or unparsable** — the worker
  crashed. Retrying is usually worth it.
- **The process ran past its `--print-timeout` with no output file written at all** — the worker
  timed out. This can mean the task was too large for one call, not that the approach was wrong.

## Step 4 — Verify

Do this for every worker that reported `SUCCESS`. Do it yourself. Do not ask the worker to
confirm its own work.

1. **Ownership.** Run `git diff --name-only` (plus `git status --porcelain` for new files) and
   compare it against the files this task owned. Any other tracked file is an **ownership
   violation** — report it even when the gate passes. Untracked build noise (`__pycache__/`,
   `.pytest_cache/`, similar) is not a violation; a repo missing the right `.gitignore` entries
   is a separate problem, not this worker's fault.
2. **Frozen paths.** Run `git diff -- <frozen paths>`. It must be empty. A non-empty diff is a
   **frozen-file violation**, regardless of what the gate says.
3. **The gate.** Run the machine gate command and read its exit code, or read the diff against
   the written acceptance criteria for a diff gate.

## Step 5 — Retry once, then stop

If a gate fails, or a violation is found, re-dispatch that one worker once. Include the actual
gate output or the violation text in its new prompt — not just "try again." If the second attempt
still fails, stop. Report both attempts.

Never roll back a worker that passed because a sibling failed. Each task's result stands on its
own.

## Step 6 — Report

Use this shape every time, so it reads the same way run after run.

```markdown
## Offload run — N workers, <duration>

| worker | gate | result | files |
|--------|------|--------|-------|
| parser | pytest tests/test_parser.py | ✓ 12/12 | as assigned |
| render | pytest tests/test_render.py | ✓ 8/8 | ⚠ +1 stray |
| docs   | diff                        | △ judged | as assigned |

### render — ownership violation
owned: src/render.py
also edited: src/util.py
<diff excerpt>

### docs — NEEDS-OPUS-REVIEW
<your diff-gate judgment, then the diff itself>

### Claimed by Gemini, not verified
- "also improved error messages"
```

Label every line one of three ways:

- **Proven** — a command ran and you read its exit code or output.
- **Judged** — a diff gate. Say who judged it. If you are running as a lighter model than the one
  that planned this task, mark the line `NEEDS-OPUS-REVIEW` so the user knows to check it
  themselves.
- **Claimed** — the worker said it in its `response` text and nothing checked it. State it, but
  do not present it as fact.

## Limits, stated plainly

- **`--add-dir` grants access. It does not confine.** No flag stops a worker from editing a file
  outside its assignment. Step 4's audit catches this after the fact — it does not prevent it. A
  clean starting tree (Precondition 3) is what makes an ownership violation recoverable with
  `git checkout -- <file>`.
- **There is no gate outside a git repository.** If the target has no `.git`, refuse rather than
  fall back to a weaker check.
- **A worker can dispatch nothing further.** `offload` is one level of delegation. A worker must
  not spawn its own workers. This skill's self-guard at the top exists for exactly that case.
