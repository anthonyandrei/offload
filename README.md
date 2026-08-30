# offload

`offload` is a skill for CLI coding agents. It sends work to `agy` (the Antigravity CLI, running
Gemini models) instead of running it in whatever agent you're already sitting in.

Whatever agent loads this skill stays the orchestrator: Claude Code, Codex CLI, anything that can
read a `SKILL.md` file and run shell commands. Anything except `agy`. `agy` is the worker here, not
the orchestrator too. The orchestrator never repeats what a worker says about its own work. It
checks the work, or checks what a second worker said about it.

Five worker roles split the labor:

| Role | Job |
|---|---|
| scout | Reads the repo, reports which files a task would touch. Can't write. |
| gate-author | Turns the orchestrator's acceptance criteria into a test file. |
| implementer | Does the task. |
| reviewer | Judges a finished diff against the criteria. Can't write. |
| researcher | Investigates a bounded question with concrete evidence. Can't write. |

The orchestrator still decides how the work splits and what "correct" means for each piece. That
judgment has no gate behind it, so it stays put. Everything downstream goes to a worker and then
gets checked: a red run and a read before a gate-author's test is trusted, an exit code for the
implementer's result, a grep against a quoted line before a reviewer's verdict is trusted, and direct evidence checks and sampling for research findings.

## What this does not do

This is not a general multi-agent framework. It won't do open-ended research fan-out with no
acceptance criteria. Every worker it dispatches answers to a gate or an evidence-backed verification protocol: a machine-gate command, written criteria
a reviewer judges the diff against, or a bounded read-only research/audit assignment with evidence citations subject to risk-based verification.

It does not sandbox a writing worker's filesystem access. `agy`'s `--add-dir` grants a worker
access to a directory. It does not confine the worker to it. Nothing in this skill can stop a
gate-author or implementer from editing a file it was not assigned. The skill catches that after
the fact by comparing the git diff to the assignment, and reports it. It cannot prevent it.

Scouts, reviewers, and researchers run under `--mode plan` instead. That one is a real restriction, not an
assignment. Confirmed by direct test: a worker in that mode told to create a file produces a plan
artifact and writes nothing to the working tree.

## Requirements

- A CLI coding agent that can load a `SKILL.md` file and run shell commands. This includes Claude
  Code, Codex CLI, and similar agents. `agy` is the worker this skill dispatches, so it cannot run
  the skill as its orchestrator.
- [`agy`](https://antigravity.google), the Antigravity CLI. `offload` looks for it on `PATH`
  first, then at `~/.local/bin/agy`.

Two more apply only to a run that dispatches a writing worker, a gate-author or an implementer:

- A git repository. There is no way to check a writing worker's changes without git.
- A clean working tree. `offload` can't tell your uncommitted changes from a worker's.

Only all-plan research/audit runs waive Git and clean-tree preconditions. Every gate-author or
implementer run retains them. An audit fan-out writes nothing, so there is nothing to check and
nothing to roll back. It runs anywhere.

## Install

**Option A: [skillshare](https://github.com/runkids/skillshare)**

```bash
skillshare install anthonyandrei/offload --track
skillshare sync
```

`--track` keeps the `.git` history, so `skillshare update offload` pulls new versions later.
Skillshare prefixes a tracked repo's folder with an underscore to hold it outside its normal sync
loop, so the skill lands at `_offload/` and you invoke it as `_offload`, not `offload`. Edits made
in place get clobbered on the next pull. Change things upstream instead.

**Option B: copy the file**

Copy `SKILL.md` into your agent's skills directory. For Claude Code, use
`~/.claude/skills/offload/SKILL.md`. There is nothing else to install. The skill is one file of
instructions for your agent to follow. It runs no code of its own.

## The execution gates and research lane

Every task `offload` dispatches carries a check instead of trusting worker assertions.

### Writing tasks: the two gates

For tasks that create or edit code or files, choose exactly one of two gates:

**Machine gate.** A command that exits 0 when the work is correct, usually a test. The
orchestrator writes the acceptance criteria; a gate-author worker turns them into a test file at a
path the orchestrator names. Before the test is frozen, the orchestrator red-checks it: runs it
against the untouched tree and requires a non-zero exit, so a tautology or an already-passing test
gets caught by an exit code, not a read. Then it reads the file, because a red check alone can't
tell a well-formed test from one that asserts the wrong thing. Only then is the file frozen, and
the implementer may not edit it.

Example: the task is "make `parse_date` handle a two-digit year." The orchestrator writes the
criterion, a gate-author writes `test_two_digit_year` in `tests/test_parser.py`, the orchestrator
confirms it fails against the current code and reads it, then freezes the file and dispatches the
implementer to make it pass.

**Diff gate.** For work with no natural pass/fail command: documentation, configuration, a
rewrite. The orchestrator writes the acceptance criteria as plain sentences. A reviewer worker,
never the implementer, reads the finished diff against them and returns a verdict per criterion.
Each `pass` carries a verbatim quote from the diff. The orchestrator greps that quote against the
real diff; a match closes the loop without a read. A criterion that fails, hedges, or quotes
something that doesn't match sends the orchestrator to read the diff itself.

Example: the task is "rewrite the install section so it matches the current flags." The criteria:
every flag named in the section must exist in `--help` output, and no install-relevant flag in
`--help` output is missing from the section.

### Read-only tasks: bounded research/audit lane

For codebase investigations, audits, or invariant checks that make no changes to files.

A research assignment declares:
1. Exactly one bounded question.
2. An allowed scope of files or directories.
3. Evidence expectations (file paths with line numbers/ranges or runnable reproduction commands).
4. An explicit non-mutation rule (read-only investigation, no file creation/edits, no nested workers).

The worker runs `gemini-3.7-flash-high` in `--mode plan` with a JSON schema returning a stable lane ID, lane kind, bounded question, findings, overall status, and uncertainty.

The verification flow directly checks findings instead of trusting claims:
- Rejects evidence outside the declared scope and inspects worker-supplied commands before running them.
- Confirms each priority, then directly checks every high-priority claim against code or command output.
- Samples lower-priority claims, leaves unsupported claims unverified, and records per-finding provenance.

Open-ended research without bounded questions, scope, and evidence expectations is out of scope.

## How it gets offered

You shouldn't have to remember this skill exists. Two pieces of text make your agent raise it on
its own.

The skill's description names two shapes it watches for. One is an implementation split: work that
breaks into three or more independent tasks, each with its own gate, in a clean git repo. The other
is a review, audit, lint, or check that fans out over a lot of files. Either shape loads the skill.

Loading it is not the same as running it. `Preconditions` says to offer first. State what would get
dispatched, then ask. Once per session, and a no settles it for that session.

That part needs its own line. A description can say when a skill is relevant, but it can't say how
you want to be treated about it. Add one line to whatever file your agent loads every session.
Use `~/.claude/CLAUDE.md` for Claude Code and `AGENTS.md` for agents that read that instead:

```markdown
## Skill precedence
- Work `_offload` fits: offer it once, then let a no stand for the rest of the session.
```

Keep the two separate. The description holds the triggers, the line holds the disposition. If the
line starts restating triggers you have two places to update and they will drift.

Notice early, shape late. A plan built for `agy` workers is a worse plan for doing the work
yourself, so the offer should come before the plan gets detailed, not after.

None of this is enforced. It's a nudge and a nudge can be missed. You'll notice the times it works
and you won't notice the times it should have fired.

## The hook (Claude Code only, optional)

`hooks/offload-ask.sh` is a Claude Code `PreToolUse` hook, so it only works if Claude Code is your
orchestrator. There's no equivalent for other agents yet. It fires just before Claude Code calls
`ExitPlanMode`, the moment a plan is about to be shown for approval, and asks whether to offload
the execution phase to `agy` workers. Answer no and nothing changes, the plan proceeds as normal.
Answer yes and the plan gains a dispatch spec before you approve it.

The hook is the deterministic version of the offer above. The offer is a suggestion the model can
miss; the hook fires every time, whether or not the work suits offloading. Worth installing if you
already run plan mode with permissions, since it hangs off `ExitPlanMode` and costs you nothing on
any other tool call. Skip it if you'd rather be asked only when it makes sense.

Without the hook, invoke the skill by asking for it, or by saying "offload this" once a plan
exists.

The hook needs [`jq`](https://jqlang.org) to parse its input. If `jq` is missing the hook does
nothing and plan mode works exactly as it does without it. A missing dependency never blocks plan
mode.

To install the hook, add this to `~/.claude/settings.json`, with the path pointing at wherever you
installed this repo:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "ExitPlanMode",
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/offload/hooks/offload-ask.sh"
          }
        ]
      }
    ]
  }
}
```

If you use [skillshare](https://github.com/runkids/skillshare) with its own
`SessionStart`/`SessionEnd` sync hooks copying `settings.json` to and from a shared location, add
this snippet to **both** copies. A hook added to only one copy is silently overwritten the next
time the session starts.

The hook asks once per session, the first time a plan reaches approval. It does not ask again for a
second plan later in the same session.

## Findings about `agy`

These came from building this skill. They may save you the same debugging.

- **`agy`'s default `--print-timeout` is 5 minutes. On expiry it writes no output at all**, not
  even a partial result. A run that is merely slow looks identical to one that crashed. `offload`
  uses `--print-timeout 20m` instead.
- **`--output-format json` returns one flat JSON object**: `status`, `response`,
  `duration_seconds`, `num_turns`, `usage`. Not a stream of events. Parse the top level directly.
- **A worker can succeed, crash, or time out, and those three outcomes mean different things.**
  Never fold them into one "failed." A timeout is often worth retrying with more time. A crash
  usually is not.
- **`--add-dir` grants access to a directory. It does not confine a worker to it.** No flag
  restricts which files inside the workspace a worker can touch. `--mode plan` is different. It is
  a real restriction, not an assignment: confirmed by direct test, a worker in `--mode plan` told
  to create a file produces a plan artifact instead and writes nothing to the working tree.
- **`--json-schema` composes with `--output-format json`.** Confirmed by direct test. The parsed,
  schema-validated object appears in a separate `structured_output` field on the result. Parse
  that field, not `response`, which still carries the model's conversational text and can include
  a stray duplicate of the same JSON as loose text.
- **`--effort` is not an independent flag on the flash models. It's baked into the model name.**
  `--model gemini-3.7-flash-high --effort low` errors with "conflicts with --effort=low". Pick the
  effort tier by picking `gemini-3.7-flash-low` / `-medium` / `-high` directly. Don't pass
  `--effort` alongside one of those model names.

## License

MIT. See `LICENSE`.
