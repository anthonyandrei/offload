# offload

`offload` is an agent-agnostic skill that delegates plan execution and research tasks to headless `agy` subagent workers (the Antigravity CLI, running Gemini models).

Whatever CLI coding agent loads this skill serves as the orchestrator: Claude Code, Codex CLI, or any agent that can read instructions and run shell commands. `agy` is the worker, not the orchestrator. The orchestrator never accepts worker claims at face value. It verifies work mechanically through test gates, git diff ownership checks, verbatim quote matching, independent citation auditing, and direct repository checks.

Offload's online-research workflow is adapted from Asa by Achibukz, used with permission. Do not publish a private repository URL, branch, commit, screenshots, or copied text.

## Worker safety and containment

- **`--mode plan` is a behavioral hint, not a write barrier.** Direct testing showed that plan-mode workers can write files. Never rely on `--mode plan` alone to protect live repository files.
- **`--add-dir` grants directory access without confining writes.** A worker can edit files outside its assignment if pointed at a live repository tree.
- **Filesystem isolation.** Research workflows run inside disposable workspaces outside the live repository. Workers receive only scoped snapshots of declared files, keeping live repository files untouched.
- **Mechanical verification.** Execution workflows require a clean git working tree, frozen path checks, automated test gates, and mechanical ownership diffs (`comm -23`).
- **Prohibition on nested dispatch.** Assignments instruct workers not to dispatch nested workers.

## Requirements

- A CLI coding agent that can read skills and run shell commands (Claude Code, Codex CLI, or similar).
- [`agy`](https://antigravity.google), the Antigravity CLI, available on `PATH` or at `~/.local/bin/agy`.
- For execution workflows: a git repository with a clean working tree (`git status --porcelain` is empty). Research workflows run in disposable workspaces.

## Installation

### Option A: skillshare

```bash
skillshare install anthonyandrei/offload --track
skillshare sync
```

The `--track` flag keeps git history so `skillshare update offload` can pull updates. Skillshare places tracked repositories under an underscore prefix, so the skill installs at `_offload/` and is invoked as `_offload`.

### Option B: copy the entire skill directory

Copy the whole skill directory into your agent's skills folder:

```bash
cp -R /path/to/offload ~/.claude/skills/offload
```

Because `offload` contains mode documents in `modes/` and helper scripts in `scripts/`, you must copy the entire directory rather than a single file.

## Router and mode selection

Root `SKILL.md` is a lightweight router that resolves how a task runs. It routes tasks into three mode documents:

1. **Explicit mode override.** Honor explicit user requests specifying `execution`, `repo-research`, or `web-research`.
2. **Research-backed mutations.** When a code change depends on external research, route to `modes/web-research.md` first to gather evidence and audit citations. Pass the audited summary to `modes/execution.md` for implementation.
3. **Direct mutations.** Route code or file changes directly to `modes/execution.md`.
4. **Local read-only questions.** Route questions answerable from local repository files to `modes/repo-research.md`.
5. **External read-only questions.** Route questions requiring current web facts or external documentation to `modes/web-research.md`.
6. **Mixed local and external questions.** Route questions needing both local files and web evidence to `modes/web-research.md` with a declared repository snapshot.

Single factual lookups stay local with the orchestrator and are not offloaded.

## Worker roles

| Role | Mode | Default model | Job |
|---|---|---|---|
| scout | Execution | `gemini-3.7-flash-low` | Discovers repository-relative file paths touched by provisional tasks. |
| gate-author | Execution | `gemini-3.7-flash-high` | Authors executable test files from acceptance criteria. |
| implementer | Execution | `gemini-3.7-flash-high` | Modifies owned code files to satisfy gates. |
| reviewer | Execution | `gemini-3.7-flash-high` | Evaluates diffs adversarially against criteria for diff-gated tasks. |
| researcher | Research | `gemini-3.7-flash-high` | Collects structured findings for assigned evidence angles or bounded local scopes. |
| synthesizer | Web research | `gemini-3.7-flash-high` | Builds claim ledgers, resolves conflicts, and drafts answers. |
| auditor | Web research | `gemini-3.7-flash-high` | Independently verifies citation URLs and claims against live sources. |

The live smoke comparison retained Flash for every role. The proposed Pro split did not complete
its mandatory synthesis stage, while the all-Flash control completed synthesis and citation audit
with four supported claims. The recorded comparison is in
[`tests/live-smoke-comparison.md`](tests/live-smoke-comparison.md).

## Workflows

### Execution workflow (`modes/execution.md`)

Used for code and file modifications across independent gated tasks.

1. **Split and scout.** Break work into provisional tasks. Dispatch parallel scouts under `--mode plan` with a JSON schema to identify touched files. If tasks overlap on files, serialize them.
2. **Assign gates.** Every task receives exactly one gate:
   - **Machine gate.** An automated test command exiting 0 on success. A gate-author worker writes the test. The orchestrator runs a red check against the untouched tree to verify failure, reads the test code to confirm intent, and commits the test to freeze it.
   - **Diff gate.** Plain-text criteria for tasks without test commands (such as documentation or configuration changes). A reviewer worker evaluates the diff adversarially, returning verbatim quotes from the diff for each passed criterion. The orchestrator greps quotes against the real diff.
3. **Dispatch implementers.** Dispatch implementers in parallel from a clean git tree with explicit owned files, frozen paths, and gate commands.
4. **Mechanical verification.**
   - Ownership check: compare modified files against assigned files using `comm -23`:
     ```bash
     { git diff --name-only; git status --porcelain | awk '{print $2}'; } | sort -u > touched.txt
     printf '%s\n' "${OWNED[@]}" | sort -u > owned.txt
     comm -23 touched.txt owned.txt
     ```
   - Frozen paths check: run `git diff --quiet -- <frozen paths>` to confirm frozen tests remained untouched.
   - Gate command: run the machine test command or verify reviewer diff quotes.

### Repository research workflow (`modes/repo-research.md`)

Used for bounded local codebase investigations, audits, and invariant checks without mutating files.

1. **Assignment specification.** Every assignment declares four items:
   - One bounded question.
   - Allowed scope of files or directories.
   - Evidence expectations (file paths with line numbers or reproducible commands).
   - Explicit non-mutation rule.
2. **Filesystem isolation.** Create a disposable workspace. Copy only declared scope paths into a snapshot directory. Run the worker pointed at the snapshot directory.
3. **Verification protocol.** Run read-only orchestrator checks against the live repository:
   - Reject citations outside declared scope.
   - Check all high-priority findings directly in live files (`orchestrator+checked`).
   - Sample medium- and low-priority findings (`orchestrator+sampled`).
   - Mark unsupported claims as unverified (`agy+unverified`).

### Web research workflow (`modes/web-research.md`)

Used for technical investigations, documentation lookups, and multi-angle research against online sources.

1. **Stage 1: Dispatch researchers.** Split the question into independent evidence angles (such as official documentation, independent benchmarks, or failure modes). Dispatch parallel researchers returning structured JSON claims with source URLs, publication dates, and source types.
2. **Stage 2: Synthesize claim ledger.** A synthesizer worker merges researcher findings into a structured claim ledger. The synthesizer discards unsupported incidental claims, preserves decision-relevant uncertainty, and drafts a proposed answer.
3. **Stage 3: Independent citation audit.** An independent auditor opens each URL cited in the proposed answer to verify resolution, direct claim support, date fitness, and primary versus derivative classification.
4. **Audit revision loop.** If the auditor requests revisions, the synthesizer runs one revision pass to narrow or remove rejected claims, followed by a final audit.

## Research profiles and automatic deep triggers

Web research operates under two profiles:

- **Standard profile.** Dispatches 2 or 3 parallel researchers across distinct angles, followed by 1 synthesizer and 1 auditor. Use for general technical questions, documentation lookups, and library comparisons.
- **Deep profile.** Dispatches up to 5 researchers in total. Deep research starts from standard findings and adds only supplementary angles to resolve specific uncertainty or conflicts, without re-running standard angles.

Deep profile activates on explicit user request or automatically when one of four triggers occurs:

1. **Material source conflict.** High-trust primary sources directly contradict one another.
2. **Costly or hard-to-reverse decision.** Architectural choices, infrastructure migrations, or licensing commitments.
3. **Citation-sensitive output.** Formal specifications, security advisories, or compliance requirements.
4. **Substantial counterevidence.** Initial findings challenge core architectural assumptions.

The active profile and trigger are recorded in the report and in `provenance.json`.

## Workspace isolation and scoped snapshots

Research workers never run directly against live repository files.

`scripts/make-research-workspace.sh` creates a disposable directory outside the repository:

```bash
WORKSPACE=$(./scripts/make-research-workspace.sh --source-repo "$PWD" --path src/auth --path config.json)
```

The script copies only declared paths into `<workspace>/repo/`. Worker prompts and `--add-dir` arguments point to the snapshot directory. The live repository remains untouched.

## Source policy

- **Public sources default.** Research workers query public web sources by default.
- **Explicit authorization for private sources.** Accessing private, internal, or authenticated repositories and APIs requires explicit user authorization for that specific run. Never forward cookies, session tokens, browser profiles, or environment credentials implicitly.

## Failure handling and partial results

- **Implementer failures.** If an implementer fails its gate or violates ownership, retry once with the error output. If the retry fails, halt that task.
- **Researcher failures.** If a researcher crashes or times out, retry once. If the retry fails, synthesis proceeds as long as at least two independent evidence angles remain. The final report explicitly names any omitted angle.
- **Synthesis and audit failures.** Synthesis and citation audit are mandatory stages. If either stage crashes, times out, or fails to resolve citations, the run transitions to `partial` status.
- **Partial result contract.** A `partial` run returns verified claims and raw findings collected before the failure. It strictly withholds firm conclusions or recommendations, states the failed stage, and preserves all raw artifacts for debugging.

## Compact provenance and report contract

### Provenance tracking and workspace cleanup

At the end of a research run, `scripts/collect-provenance.sh` validates and generates `provenance.json`:

```bash
./scripts/collect-provenance.sh \
  --run-id "run-01" \
  --request-summary "Evaluate database migration options" \
  --selected-mode "web-research" \
  --profile "standard" \
  --start-time "2026-08-31T10:00:00Z" \
  --end-time "2026-08-31T10:04:30Z" \
  --duration-seconds 270 \
  --scratch-path "$WORKSPACE" \
  --workers "$WORKERS_JSON" \
  --final-citations "$CITATIONS_JSON" \
  --audit-verdicts "$AUDITS_JSON" \
  --final-status "success" \
  --incomplete-stage-reasons "[]" \
  --output "$WORKSPACE/provenance.json"
```

After generating provenance, `scripts/cleanup-research-workspace.sh` cleans the temporary workspace:

```bash
./scripts/cleanup-research-workspace.sh --workspace "$WORKSPACE" --status success
```

- On `success`, the script removes intermediate worker files and snapshot directories while preserving `final.md` and `provenance.json`.
- On `partial` or failure, the script retains all raw artifacts and logs.

### Shared report format

All modes format results into a consistent summary:

```markdown
## Offload run: N workers, <duration>

| worker | gate / lane | provenance | result | files / findings |
|--------|-------------|------------|--------|------------------|
| parser | pytest tests/test_parser.py | agy+red+read | ✓ 12/12 | as assigned (scout) |
| render | pytest tests/test_render.py | orchestrator (fallback) | ✓ 8/8 | ⚠ +1 stray |
| docs   | diff                        | agy+grep      | △ judged | as assigned (scout) |
| auth-audit | audit (isolated)        | orchestrator+checked (high) + orchestrator+sampled (med/low) | complete | 3 findings (2 verified, 1 unverified) |

### Claimed by Gemini, not verified
- "also improved error messages"
- "Legacy endpoints may be affected"
```

### Provenance values

- `orchestrator`: Step performed directly by orchestrator.
- `agy+red+read`: Gate written by worker, checked with red run and inspection.
- `agy+grep`: Diff reviewed by worker, verbatim quote verified in git diff.
- `agy→orchestrator`: Reviewer escalated, diff inspected by orchestrator.
- `orchestrator+checked`: Evidence directly verified in live repository.
- `orchestrator+sampled`: Sample of medium or low priority citations verified.
- `agy+unverified`: Finding lacking verifiable evidence.
- `orchestrator (fallback)`: Worker failed, completed by orchestrator.

### Result classifications

- **Proven**: Verified by automated test exit code or mechanical check.
- **Judged**: Evaluated against written criteria by diff reviewer or orchestrator.
- **Verified**: Confirmed by direct orchestrator check or codebase sampling.
- **Audited**: Verified by independent citation auditor against live sources.
- **Claimed**: Asserted in worker output without verification; explicitly marked unverified.

## Proactive offers and hook integration

The skill monitors for tasks that break into three or more gated implementation tasks, or audits that fan out across multiple files or angles.

When detected, the orchestrator offers offloading once per session. A negative response settles the decision for that session.

Add this instruction to `~/.claude/CLAUDE.md` or `AGENTS.md`:

```markdown
## Skill precedence
- Work `_offload` fits: offer it once, then let a no stand for the rest of the session.
```

### Claude Code plan mode hook (optional)

`hooks/offload-ask.sh` intercepts `ExitPlanMode` tool calls in Claude Code to ask whether to offload execution before showing the plan.

Add to `~/.claude/settings.json`:

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

The hook requires `jq`. If `jq` is absent, the hook passes through without blocking.

## Deterministic test suite

Run the automated acceptance suite to verify router structure, mode contracts, workspace isolation, provenance collection, and safety rules:

```bash
bash tests/test_research_modes.sh
```

## Findings about agy

- **`agy` default `--print-timeout` is 5 minutes.** On expiry it writes no output at all. `offload` passes `--print-timeout 20m`.
- **`--output-format json` returns one flat JSON object.** Parse top-level fields `status`, `response`, `duration_seconds`, `num_turns`, and `usage`.
- **`--json-schema` outputs validated JSON in `structured_output`.** Parse `structured_output` rather than `response`.
- **Flash model effort is set in the model name.** Use `gemini-3.7-flash-low`, `gemini-3.7-flash-medium`, or `gemini-3.7-flash-high`. Do not pass `--effort` alongside these models.
- **`--mode plan` is a behavioral hint, not a write barrier.** Direct tests showed plan-mode workers can write files. `--add-dir` grants directory access without confining writes. Security relies on workspace isolation and mechanical verification.

## License

MIT. See `LICENSE`.
