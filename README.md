# offload

`offload` is a Claude Code skill. It sends implementation work to `agy` (the Antigravity CLI,
running Gemini models) instead of running the work in Claude Code itself.

Claude Code stays the orchestrator. It does not repeat what a worker says about its own work. It
checks the work, or checks what an independent second worker said about it.

Four worker roles split the labor:

| Role | Job |
|---|---|
| scout | Reads the repo, reports which files a task would touch. Can't write. |
| gate-author | Turns the orchestrator's acceptance criteria into a test file. |
| implementer | Does the task. |
| reviewer | Judges a finished diff against the criteria. Can't write. |

The orchestrator still decides how the work splits and what "correct" means for each piece. That
judgment has no gate behind it, so it stays put. Everything downstream of that decision goes to a
worker, then gets checked: a red run and a read before a gate-author's test is trusted, an exit
code for the implementer's result, a grep against a quoted line before a reviewer's verdict is
trusted.

## What this does not do

This is not a general multi-agent framework. It does not do open-ended research fan-out with no
acceptance criteria at all. Every worker `offload` dispatches answers to a gate: a command, or
written criteria a reviewer judges the diff against.

It does not sandbox an `accept-edits` worker's filesystem access. `agy`'s `--add-dir` flag grants
a worker access to a directory. It does not confine the worker to that directory. Nothing in this
skill can stop a gate-author or implementer from editing a file it was not assigned. The skill
catches this after the fact, by comparing the git diff to the assignment, and reports it. It
cannot prevent it. Scout and reviewer workers use `agy`'s `--mode plan` instead. That's a real
restriction, not an assignment: confirmed by direct test, a worker in that mode asked to create a
file produces a plan artifact and writes nothing to the working tree.

## Requirements

- [Claude Code](https://claude.com/claude-code).
- [`agy`](https://antigravity.google), the Antigravity CLI. `offload` looks for it on `PATH`
  first, then at `~/.local/bin/agy`.
- A git repository. `offload` refuses to run outside one, because it has no way to check a
  worker's changes without git.
- A clean working tree before each run. `offload` refuses on a dirty tree, because it cannot
  tell your uncommitted changes from a worker's changes.

## Install

**Option A: [skillshare](https://github.com/runkids/skillshare)**

```bash
skillshare install anthonyandrei/offload --track
skillshare sync
```

`--track` keeps the `.git` history, so `skillshare update offload` pulls new versions later.
Skillshare prefixes a tracked repo's folder with an underscore to hold it outside its normal sync
loop, so the skill lands at `_offload/` and you invoke it as `_offload`, not `offload`. Edits made
in place get clobbered on the next pull; change things upstream instead.

**Option B: copy the file**

Copy `SKILL.md` into `~/.claude/skills/offload/SKILL.md`. There is nothing else to install. The
skill is one file of instructions for Claude Code to follow. It runs no code of its own.

## The two gates

Every task `offload` dispatches carries exactly one gate: a way to check the work, not trust it.

**Machine gate.** A command that exits 0 when the work is correct, usually a test. The
orchestrator writes the acceptance criteria; a gate-author worker turns them into the test file,
at a path the orchestrator names. Before the test is frozen, the orchestrator red-checks it: runs
it against the untouched tree and requires a non-zero exit, so a tautology or an already-passing
test gets caught by an exit code, not a read. Then it reads the file itself, because a red check
alone can't tell a well-formed test from one that asserts the wrong thing. Only then is the file
frozen; the implementer may not edit it.

Example: the task is "make `parse_date` handle a two-digit year." The orchestrator writes the
criterion, a gate-author worker writes `test_two_digit_year` in `tests/test_parser.py`, the
orchestrator confirms it fails against the current code and reads it, then freezes the file and
dispatches the implementer to make it pass.

**Diff gate.** For work with no natural pass/fail command: documentation, configuration, a
rewrite. The orchestrator writes the acceptance criteria as plain sentences. A reviewer worker,
never the implementer, reads the finished diff against them and returns a verdict per criterion.
Each `pass` carries a verbatim quote from the diff. The orchestrator greps that quote against the
real diff; a match closes the loop without a read. A criterion that fails, hedges, or quotes
something that doesn't match sends the orchestrator to read the diff itself.

Example: the task is "rewrite the install section so it matches the current flags." The
orchestrator's criteria: every flag named in the section must exist in `--help` output, and no
flag in `--help` output relevant to install is missing from the section.

## How it gets offered

You shouldn't have to remember this skill exists. Two pieces of text make Claude Code raise it on
its own.

The skill's description names two shapes it watches for. One is an implementation split: work that
breaks into three or more independent tasks, each with its own gate, in a clean git repo. The other
is a review, audit, lint, or check that fans out over a lot of files. Either shape loads the skill.

Loading it is not the same as running it. `Preconditions` says to offer first. State what would get
dispatched, then ask. Once per session, and a no settles it for that session.

That part needs its own line, because a description can say when a skill is relevant but not how
you want to be treated about it. One line in `~/.claude/CLAUDE.md`:

```markdown
## Skill precedence
- Work `_offload` fits: offer it once, then let a no stand for the rest of the session.
```

Keep the two separate. The description holds the triggers; the line holds the disposition. If the
line starts restating triggers you have two places to update and they will drift.

Notice early, shape late. A plan built for `agy` workers is a worse plan for doing the work
yourself, so the offer should come before the plan gets detailed, not after.

None of this is enforced. It's a nudge and a nudge can be missed. You'll notice the times it works
and you won't notice the times it should have fired.

## The hook (optional)

`hooks/offload-ask.sh` is a Claude Code `PreToolUse` hook. It fires just before Claude Code calls
`ExitPlanMode`, the moment a plan is about to be shown for approval, and asks whether to offload
the execution phase to `agy` workers. Answer no, and nothing changes: the plan proceeds as normal.
Answer yes, and the plan gains a dispatch spec before you approve it.

The hook is the deterministic version of the offer above. The description-based offer is a
suggestion the model can miss; the hook fires every time, whether or not the work suits offloading.
It's worth installing if you already run plan mode with permissions, since it hangs off
`ExitPlanMode` and costs you nothing on any other tool call. Skip it if you'd rather be asked only
when it makes sense.

Without the hook, invoke the skill directly by asking for it, or by saying "offload this" once a
plan exists.

The hook needs [`jq`](https://jqlang.org) to parse its input. If `jq` is missing, the hook does
nothing and plan mode works exactly as it does without it. A missing dependency never blocks plan
mode.

To install the hook, add this to `~/.claude/settings.json`, with the path pointing at wherever
you installed this repo:

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

The hook asks the question once per session, the first time a plan reaches approval. It does not
ask again for a second plan later in the same session.

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
- **`--add-dir` grants access to a directory. It does not confine a worker to it.** There is no
  flag that restricts which files inside the workspace a worker can touch. `--mode plan` is
  different. It is a real restriction, not an assignment: confirmed by direct test, a worker in
  `--mode plan` told to create a file produces a plan artifact instead and writes nothing to the
  working tree.
- **`--json-schema` composes with `--output-format json`.** Confirmed by direct test. The parsed,
  schema-validated object appears in a separate `structured_output` field on the result. Parse
  that field, not `response`, which still carries the model's conversational text and can include
  a stray duplicate of the same JSON as loose text.
- **`--effort` is not an independent flag on the flash models. It's baked into the model name.**
  `--model gemini-3.7-flash-high --effort low` errors with "conflicts with --effort=low". Pick the
  effort tier by picking `gemini-3.7-flash-low` / `-medium` / `-high` directly; don't pass
  `--effort` alongside one of those model names.

## License

MIT. See `LICENSE`.
