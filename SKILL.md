---
name: offload
description: Use when the user wants execution or research handed to another vendor's CLI agents instead of running it here. Triggers include "offload this", "run this on agy", "use gemini subagents", or after answering yes to the offload offer. Also offer unprompted when implementation splits into three or more independently gated tasks in a clean git repository, or when a read-only audit or online research fans out across multiple angles or files. Dispatches parallel headless agy workers, gates their output, and reports what was proven versus claimed.
---

# offload

If you are `agy`, stop here. Return worker results to your orchestrator. `agy` is the worker role this skill dispatches. Any other agent that can read instructions and run shell commands can orchestrate, including Claude Code, Codex CLI, and similar agents. Assignments prohibit nested worker dispatch, but the skill cannot enforce that rule if a worker ignores it.

## What this skill does

`offload` delegates execution and research tasks to headless `agy` workers (the Antigravity CLI running Gemini models routed via `model-policy.json`). You remain the orchestrator. You decompose tasks, set acceptance criteria or bounded questions, and verify evidence and gates. Workers handle exploration, test authoring, code implementation, diff review, and research evidence collection.

You never accept worker claims at face value. You verify output through mechanical checks, test execution, diff inspections, or secondary reviews.

## Preconditions and helper selection

Select the helper family matching your current host shell:

- **POSIX shells (Bash 3.2+)**: Use `.sh` scripts in `scripts/`. Requires Git, `agy`, `jq`, and Python 3.
- **PowerShell (PowerShell 7+)**: Use `.ps1` scripts in `scripts/`. Native Windows orchestrators require only PowerShell 7 (`pwsh`), Git, and `agy`. Windows workflows do not require Bash, WSL, Git Bash, Python, or `jq`.

Check these requirements before dispatching workers:

1. **Offer before dispatch.** When reaching this skill unprompted, offer the choice to the user first following the proactive offer contract. Describe the planned dispatch and ask for confirmation. Ask once per session. A negative response settles the decision for the rest of the session.
2. **Local factual lookups.** Keep a single factual lookup local with the orchestrator; do not offer or route it to offload.
3. **`agy` availability.** Verify `agy` is invokable. The launcher resolves `AGY_BIN` first if set, then `PATH`, then the user-local bin directory (`~/.local/bin/agy` on POSIX, `%USERPROFILE%\.local\bin\agy.exe` on Windows). An invalid explicit `AGY_BIN` fails immediately without fallback.
4. **Git working tree.** Writing workflows (`modes/execution.md`) require a clean git repository (`git rev-parse --is-inside-work-tree` and empty `git status --porcelain`). Research workflows (`modes/repo-research.md`, `modes/web-research.md`) operate in isolated disposable workspaces.
5. **Preflight model availability check.** Before dispatching the first worker in a run:
   - Read repository-root `model-policy.json` (resolved relative to helper scripts, never the caller's working directory).
   - Check selected default models against available Gemini model IDs reported by the resolved `agy` installation.
   - If a required model is absent or availability cannot be established, block dispatch and return the affected work to the caller. Do not silently downgrade to 3.7, fall back to AGY's unverified default, or pick a similarly named model.
   - When a quality-retry escalation model is used, check its availability before dispatch as well.
   - Avoid repeating catalog discovery for every worker in the same run unless AGY reports that availability changed.
6. **Policy installation, updates, and revert.**
   - `model-policy.json` is located at repository root alongside helper scripts. Installation must copy the entire skill directory (including `model-policy.json`).
   - The policy enforces `schema_version: 1`, a non-empty `policy_revision` (e.g. `"2026-09-03.1"`), `max_effort: "high"`, `max_retries_per_worker: 1`, `quota_action: "handoff"`, and exactly seven role mappings: `scout`, `gate-author`, `implementer`, `reviewer`, `researcher`, `synthesizer`, and `auditor`.
   - To update policy: edit `model-policy.json` in the skill root and update `policy_revision`. To revert: restore the prior revision. Launchers validate the entire policy on every invocation. Missing or invalid policy fails closed before launching workers.
   - A non-null `quality_escalation` entry must specify an eligible Gemini model and a valid, non-escaping repo-relative `evidence_path` pointing to an existing evaluation document inside the skill directory.

## Routing

Once invoked, select a mode using this order:

1. **Explicit mode override.** Honor an explicit user request specifying a mode (`execution`, `repo-research`, or `web-research`).
2. **Research-backed mutation.** When a requested mutation depends on external research, route to `modes/web-research.md` first for evidence gathering and audit, then route to `modes/execution.md` for implementation.
3. **Direct mutation.** Route a direct file or code change with no external research prerequisite to `modes/execution.md`.
4. **Local read-only question.** Route a read-only question answerable from declared local files to `modes/repo-research.md`.
5. **External read-only question.** Route a read-only question requiring current or external evidence to `modes/web-research.md`.
6. **Mixed local and external question.** Route a question needing both local and external evidence to `modes/web-research.md` with a declared repository snapshot.

## Modes

Load the matching mode document for the selected route and shell-specific commands:

- [`modes/execution.md`](modes/execution.md): Dispatches scouts, gate-authors, implementers, and diff reviewers for code and file modifications.
- [`modes/repo-research.md`](modes/repo-research.md): Dispatches bounded local code investigations and audits in isolated workspaces with direct evidence verification.
- [`modes/web-research.md`](modes/web-research.md): Dispatches multi-angle online researchers, synthesis, and citation auditing in isolated workspaces.

## Shared model routing and launcher contract

Offload routes all workers through the repository-root `model-policy.json`. Launchers resolve model IDs and inject `--model` before launching `agy`. Callers must never pass `--model` or `--effort` after `--`.

### Launcher invocation

- **POSIX shells**: `"$OFFLOAD_ROOT/scripts/run-agy-json.sh" --role <role> [--route <default|quality-retry>] --output <out> --error <err> -- <agy args...>`
- **PowerShell**: `& "$OffloadRoot/scripts/run-agy-json.ps1" --role <role> [--route <default|quality-retry>] --output <out> --error <err> '--' <agy args...>`

In PowerShell command expressions, always quote the delimiter (`'--'`).

### Roles and default models

| Role | Default model | Effort | Primary mode |
|---|---|---|---|
| `scout` | `gemini-3.8-flash-low` | low | Execution |
| `gate-author` | `gemini-3.8-flash-high` | high | Execution |
| `implementer` | `gemini-3.8-flash-high` | high | Execution |
| `reviewer` | `gemini-3.8-flash-high` | high | Execution |
| `researcher` | `gemini-3.8-flash-high` | high | Repo research / Web research |
| `synthesizer` | `gemini-3.8-flash-high` | high | Web research |
| `auditor` | `gemini-3.8-flash-high` | high | Web research |

### Routes

- `--route default` (default): Resolves `default_model` for the specified role.
- `--route quality-retry`: Resolves `quality_escalation.model` for that role. If `quality_escalation` is `null` or unconfigured, the launcher rejects the request with exit code 2 before starting `agy`. Never infer an escalation model or replace the route.

## Shared recovery, retry accounting, and failure handling

### Stable worker IDs and retry ceiling

- A worker represents one logical assignment, not a single process run.
- Assign each logical assignment a stable `worker_id` across attempts.
- **Attempt 1** is the initial dispatch.
- **Attempt 2** is its only permitted retry. Maximum two attempts total per assignment.
- Changing process IDs, models, conversations, or prompt instructions does not reset the retry count.

### Failure classification and recovery rules

1. **Verified success**: Output passes mechanical gates and verification checks. Accept result; no retry.
2. **Quality failure**: The worker completed with a parsable response (exit code 0), but the output fails verification (e.g. machine gate failure, execution scope violation, reviewer quote mismatch, unsupported synthesis claim, or audit rejection).
   - If retry budget remains and mode permits correction: retry once (attempt 2) with concrete verification feedback. Use `--route quality-retry` only when an evidence-backed escalation target is configured in policy; otherwise use `--route default`.
   - If attempt 2 fails or the mode requires immediate fallback: stop retrying and follow that mode's halt, partial-result, or orchestrator fallback path.
3. **Operational failure**: Process crash (nonzero exit code), timeout (20 minutes with no output), unparsable JSON, or tool failure.
   - Follow mode's recovery rule with at most one same-model retry (`--route default`) where permitted. Never escalate models for operational failures.
4. **Unknown failure**: Record uncertainty and follow the operational-failure path. Do not assume a quality failure or quota issue.
5. **Quota exhaustion**: Explicit Gemini quota error reported by `agy` structured output or diagnostics. Trigger immediate quota handoff.

### Immediate quota handoff

When explicit Gemini quota exhaustion is detected:
- Stop dispatching new workers immediately.
- Return unfinished work to the calling orchestrator without waiting for running siblings.
- Do not retry automatically, wait for reset, switch models, or activate paid credits.
- Preserve completed artifacts.
- Report status of all assignments: verified, unverified, failed, pending (never dispatched), and still running (with process/job references and output paths). The calling orchestrator takes ownership.

## Run outcome records (`routing-outcomes.json`)

The orchestrator maintains `routing-outcomes.json` in each run's scratch workspace. It records process and verification history per attempt:

- Top-level fields: `schema_version` (integer 1) and `attempts` (array).
- Each attempt object records:
  - `worker_id`: Stable assignment identifier.
  - `role`: One of the 7 policy roles.
  - `mode`: `execution`, `repo-research`, or `web-research`.
  - `attempt`: Integer 1 or 2.
  - `policy_revision`: Policy revision string.
  - `route`: `"default"` or `"quality-retry"`.
  - `model`: Resolved AGY model ID.
  - `effort`: Derived effort suffix (`low`, `medium`, `high`).
  - `reason`: Initial dispatch or observed failure and recovery decision authorizing attempt 2.
  - `started_at`: ISO 8601 UTC timestamp.
  - `ended_at`: ISO 8601 UTC timestamp (null while running).
  - `duration_seconds`: Observed elapsed time (null while running).
  - `exit_code`: Worker process exit code (null while running).
  - `state`: `"running"`, `"completed"`, `"failed"`, or `"interrupted"`.
  - `failure_class`: `"none"`, `"quality"`, `"timeout"`, `"tool_error"`, `"quota"`, or `"unknown"`.
  - `verification`: `"pending"`, `"passed"`, `"failed"`, or `"not_performed"`.
  - `evidence_paths`: Array of output, error, gate, review, or audit artifact paths.
  - `usage`: Source-attributed reported usage object with explicit units, or null when unavailable.

Pending assignments that never dispatched are listed in the final handoff report, not as attempt records. In web research runs, routing history for a worker may optionally be attached as a `routing` container (`{schema_version: 1, attempts: [...]}`) in each worker entry within `provenance.json`. See [`modes/web-research.md`](modes/web-research.md#provenance-and-cleanup) and canonical fixture [`tests/fixtures/routing-worker.json`](tests/fixtures/routing-worker.json) for the complete worker record example.

## Shared report contract

Use this standard report format across all modes:

```markdown
## Offload run — N workers, <duration>

| worker | gate / lane | provenance | result | files / findings |
|--------|-------------|------------|--------|------------------|
| parser | pytest tests/test_parser.py | agy+red+read | ✓ 12/12 | as assigned (scout) |
| render | pytest tests/test_render.py | orchestrator (fallback) | ✓ 8/8 | ⚠ +1 stray |
| docs   | diff                        | agy+grep      | △ judged | as assigned (scout) |
| auth-audit | audit (isolated)        | orchestrator+checked (high) + orchestrator+sampled (med/low) | complete | 3 findings (2 verified, 1 unverified) |

### render — ownership violation
owned: src/render.py
also edited: src/util.py
<diff excerpt>

### docs — reviewer verdict
pass: 3/3 criteria, all quotes matched verbatim. No escalation.

### auth-audit — findings & verification sample
- [HIGH] [orchestrator+checked] Route `/api/v1/reset` lacks session check (src/auth/routes.py:L45-L52) — confirmed.
- [MED]  [orchestrator+sampled] Token expiry default is 30d (src/config.py:L18) — confirmed by sample.
- [LOW]  [agy+unverified] "Legacy endpoints may be affected" — unverified (no location cited).
Sample recorded: 1/1 high checked, 1/2 med/low sampled.

### Claimed by Gemini, not verified
- "also improved error messages"
- "Legacy endpoints may be affected"
```

### Provenance values

- `orchestrator`: Step performed directly by the orchestrator.
- `agy+red+read`: Gate written by gate-author, validated by red check and read.
- `agy+grep`: Diff reviewed by worker, verbatim quote verified in git diff.
- `agy→orchestrator`: Reviewer escalated or hedged, diff inspected by orchestrator.
- `orchestrator+checked`: Evidence location or command directly verified in repository.
- `orchestrator+sampled`: Sample of medium- or low-priority citations verified.
- `agy+unverified`: Finding or claim lacking verifiable evidence.
- `orchestrator (fallback)`: Worker failed or timed out, completed by orchestrator.

### Result classifications

- **Proven**: Verified by an automated command exit code or mechanical check.
- **Judged**: Evaluated against written criteria by a diff reviewer or orchestrator.
- **Verified**: Confirmed by direct orchestrator check (`orchestrator+checked`) or sampling (`orchestrator+sampled`) against repository files.
- **Audited**: Verified by an independent citation auditor worker against live sources.
- **Claimed**: Asserted by worker output without independent verification; labeled explicitly as unverified.

## Limits and worker safety

- **`--mode plan` is a behavioral hint, not a write barrier.** Direct probes showed that plan-mode workers can write files. Never rely on `--mode plan` alone to protect live repository files.
- **`--add-dir` grants directory access without confining writes.** A worker can edit files outside its assignment if pointed at the live tree.
- **Filesystem isolation.** Research modes run in disposable workspaces with scoped file snapshots. Live repository files are never exposed directly to research workers.
- **Execution safety.** Execution mode requires a clean git baseline, mechanical execution scope checks (`check-execution-scope.sh` or `check-execution-scope.ps1`), frozen path diffs, and test gates.
- **Prohibition on nested dispatch.** Workers are instructed not to dispatch nested workers.
- **Bounded scope requirement.** Open-ended research without a bounded question, declared scope, and evidence expectations is out of scope.
- **Worker timeout.** Every worker runs with a bounded timeout (`--print-timeout 20m`).
