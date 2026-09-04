# offload

`offload` is an agent-agnostic skill that delegates plan execution and research tasks to headless `agy` workers (the Antigravity CLI, running Gemini models).

Whatever CLI coding agent loads this skill serves as the orchestrator: Claude Code, Codex CLI, or any agent that can read instructions and run shell commands. `agy` is the worker, not the orchestrator. The orchestrator never accepts worker claims at face value. It verifies work mechanically through test gates, execution scope checks, verbatim quote matching, independent citation auditing, and direct repository checks.

Offload's online-research workflow is adapted from Asa by Achibukz, used with permission. Do not publish a private repository URL, branch, commit, screenshots, or copied text.

## Publication boundary

Published source skills use the vendor-neutral contract in
[`docs/contracts/publication-compatibility.md`](docs/contracts/publication-compatibility.md).
`grill-with-docs` owns its interview and documentation workflow and can run
without offload. Offload is an explicit optional delegation layer. Adapters own
vendor command syntax, model catalogs, capability probes, and output parsing.

Published consumers use stable capabilities and internal model preferences,
with reasoning effort kept separate. They do not depend on vendor names, family
labels, or exact model IDs. The compatibility checker rejects unavailable
adapters and vendor-specific references. Capability support does not enforce
security. The orchestrator still owns isolation, execution scope checks,
cleanup, and acceptance gates.

## Worker safety and containment

- **`--mode plan` is a version-sensitive behavioral hint, not a write barrier.** The accepted `agy 1.1.25` probe blocked the tested direct write outside the permitted artifact area, but plan mode is not a sole safety control. Never rely on it alone to protect live repository files.
- **`--add-dir` grants directory access without confining writes.** A worker can edit files outside its assignment if pointed at a live repository tree.
- **Filesystem isolation.** Research workflows run inside disposable workspaces outside the live repository. Workers receive only scoped snapshots of declared files, keeping live repository files untouched.
- **Mechanical verification.** Execution workflows require a clean git working tree, execution scope checks (`check-execution-scope.sh` or `check-execution-scope.ps1`), frozen path checks, and automated test gates.
- **Prohibition on nested dispatch.** Assignments instruct workers not to dispatch nested workers.
- **Vendor-neutral worker adapters.** [`docs/worker-adapter-contract.md`](docs/worker-adapter-contract.md) defines the assignment, lifecycle, capability/model discovery, ownership, and normalized-result boundary. The current AGY launcher is the reference adapter; verification and cleanup remain with the orchestrator.
- **Orchestrator-owned dispatch.** `dispatch-worker.sh` or `dispatch-worker.ps1` is the only workflow entry point that admits an assignment, creates its worktree, and starts its worker process. The dispatcher sets `OFFLOAD_WORKER_CONTEXT=1` for the worker. Worker-context calls to the dispatcher, launcher, or execution-workspace lifecycle helpers fail closed and record a `nested_dispatch_rejected` event.
- **Structured follow-up requests.** A worker may return a request for more work in `structured_output`, but that request is data for the orchestrator to review. It never starts a process automatically.
- **Bounded assignment ledger.** The dispatcher records assignment ID, parent ID, depth, child IDs, role, owned and frozen paths, lifecycle timestamps, output and error paths, worktree manifest, and timeout/resource budget in an `offload-dispatch-state-v1` ledger. Root limits for depth, child width, timeout, and total resource units are immutable for descendants; admission rejects attempts that would exceed them.
- **Defense in depth.** Vendor sandbox behavior, including `agy --mode plan`, is a useful additional boundary but is not treated as enforcement. The workflow verifies the worker context, assignment ledger, worktree lifecycle, frozen paths, execution scope, and test gates mechanically.

## Supported environments

| Host path | Required runtime | Required tools | CI system |
|---|---|---|---|
| Native Windows | PowerShell 7+ | Git and `agy` | `windows-latest` |
| Linux with Bash | Bash 3.2+ | Git, `agy`, `jq`, and Python 3 | `ubuntu-latest` |
| macOS with Bash | Bash 3.2+ | Git, `agy`, `jq`, and Python 3 | `macos-latest` |
| Linux or macOS with PowerShell | PowerShell 7+ | Git and `agy` | Supported by contract, not a required CI job |

### Helper family selection

Orchestrators select helper scripts based on their current shell (`.sh` for Bash, `.ps1` for PowerShell), never by host operating system detection or universal launchers. Native Windows orchestrators require only PowerShell 7 (`pwsh`), Git, and `agy`. Windows workflows do not require Bash, WSL, Git Bash, Python, or `jq`.

### Claude adapter

The bounded Claude Code adapter is available as `scripts/run-claude-json.ps1` and
`scripts/run-claude-json.sh`. It accepts the versioned assignment contract in
[`docs/specs/0004-claude-adapter.md`](docs/specs/0004-claude-adapter.md), probes
the installed Claude CLI, forwards only the assignment's bounded prompt and
tool policy, and returns a normalized result with raw artifacts, process and
worktree ledger records, and scope and gate verification.

Set `CLAUDE_BIN` when Claude is not on `PATH`. The adapter accepts internal
`fast`, `balanced`, and `deep` preferences without mapping them to published
model IDs. A pinned model requires a caller-provided live catalog. Unsupported
or unmarked sandboxes fail closed. On Windows, use an isolated runtime such as
WSL, Git for Windows, or the supported native Claude binary; the adapter does
not turn the caller checkout into a sandbox.

## Requirements

- A CLI coding agent that can read skills and run shell commands (Claude Code, Codex CLI, or similar).
- [`agy`](https://antigravity.google), the Antigravity CLI, available on `PATH`, user-local bin (`~/.local/bin/agy` on POSIX, `%USERPROFILE%\.local\bin\agy.exe` on Windows), or configured via `AGY_BIN`.
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

#### Bash
```bash
cp -R /path/to/offload ~/.claude/skills/offload
```

#### PowerShell
```powershell
Copy-Item -Recurse -Path \path\to\offload -Destination $HOME\.claude\skills\offload
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
| scout | Execution | `gemini-3.8-flash-low` | Discovers repository-relative file paths touched by provisional tasks. |
| gate-author | Execution | `gemini-3.8-flash-high` | Authors executable test files from acceptance criteria. |
| implementer | Execution | `gemini-3.8-flash-high` | Modifies owned code files to satisfy gates. |
| reviewer | Execution | `gemini-3.8-flash-high` | Evaluates diffs adversarially against criteria for diff-gated tasks. |
| researcher | Research | `gemini-3.8-flash-high` | Collects structured findings for assigned evidence angles or bounded local scopes. |
| synthesizer | Web research | `gemini-3.8-flash-high` | Builds claim ledgers, resolves conflicts, and drafts answers. |
| auditor | Web research | `gemini-3.8-flash-high` | Independently verifies citation URLs and claims against live sources. |

Worker routing is governed by repository-root `model-policy.json`. Launchers accept `--role <role>` (and optional `--route default|quality-retry`) and resolve models dynamically. Callers must not supply `--model` or `--effort` flags.

A historical live smoke comparison against Gemini 3.7 retained Flash for every role. The proposed Pro split did not complete its mandatory synthesis stage, while the all-Flash control completed synthesis and citation audit with four supported claims. The recorded comparison is in [`tests/live-smoke-comparison.md`](tests/live-smoke-comparison.md).

## Workflows

### Execution workflow (`modes/execution.md`)

Used for code and file modifications across independent gated tasks.

1. **Split and scout.** Break work into provisional tasks. Dispatch parallel scouts under `--mode plan` via `dispatch-worker`, which wraps `run-agy-json`, with a JSON schema to identify touched files. If tasks overlap on files, serialize them.
2. **Assign gates.** Every task receives exactly one gate:
   - **Machine gate.** An automated test command exiting 0 on success. A gate-author worker writes the test. The orchestrator runs a red check against the untouched tree to verify failure, reads the test code to confirm intent, and commits the test to freeze it.
   - **Diff gate.** Plain-text criteria for tasks without test commands (such as documentation or configuration changes) receive stable IDs. A reviewer worker evaluates the immutable review artifact and returns exactly one verdict per ID. The orchestrator accepts only complete all-pass coverage whose evidence lines match the same artifact.
3. **Dispatch implementers.** Dispatch implementers in parallel from a clean git tree with explicit owned files, frozen paths, gate commands, and bounded budgets via `dispatch-worker`. The dispatcher wraps `execution-workspace` and `run-agy-json`; workers never call those lifecycle or launch interfaces directly.
4. **Mechanical verification.**
   - Execution scope check: verify touched paths against assigned owned and frozen paths using `check-execution-scope`:
     #### Bash
     ```bash
     "$OFFLOAD_ROOT/scripts/check-execution-scope.sh" --owned src/render.py --frozen tests/test_render.py
     ```
     #### PowerShell
     ```powershell
     & "$OffloadRoot/scripts/check-execution-scope.ps1" --owned src/render.py --frozen tests/test_render.py
     ```
   - Gate command: run the machine test command or run `check-review-verdict` against the reviewer JSON, stable criteria file, and recorded artifact after checking its digest.

### Repository research workflow (`modes/repo-research.md`)

Used for bounded local codebase investigations, audits, and invariant checks without mutating files.

1. **Assignment specification.** Every assignment declares four items:
   - One bounded question.
   - Allowed scope of files or directories.
   - Evidence expectations (file paths with line numbers or reproducible commands).
   - Explicit non-mutation rule.
2. **Filesystem isolation.** Create a disposable workspace with `make-research-workspace.sh` or `make-research-workspace.ps1`. The helper copies only declared scope paths into a snapshot directory (`<workspace>/repo/`). Run the worker pointed at the snapshot directory via `run-agy-json`.
3. **Verification protocol.** Run read-only orchestrator checks against the live repository:
   - Reject citations outside declared scope.
   - Check all high-priority findings directly in live files (`orchestrator+checked`).
   - Sample medium- and low-priority findings (`orchestrator+sampled`).
   - Mark unsupported claims as unverified (`agy+unverified`).
4. **Cleanup.** Run `cleanup-research-workspace.sh` or `cleanup-research-workspace.ps1` with `--status success`.

### Web research workflow (`modes/web-research.md`)

Used for technical investigations, documentation lookups, and multi-angle research against online sources.

1. **Stage 1: Dispatch researchers.** Split the question into independent evidence angles. Dispatch parallel researchers returning structured JSON claims with source URLs, publication dates, and source types via `run-agy-json`.
2. **Stage 2: Synthesize claim ledger.** Extract findings with `extract-structured-output`. A synthesizer worker merges findings into a structured claim ledger, discards unsupported incidental claims, preserves decision-relevant uncertainty, and drafts a proposed answer.
3. **Stage 3: Independent citation audit.** An independent auditor opens each URL cited in the proposed answer to verify resolution, direct claim support, date fitness, and primary versus derivative classification.
4. **Audit revision loop.** If the auditor requests revisions, the synthesizer runs one revision pass to narrow or remove rejected claims, followed by a final audit.
5. **Provenance and cleanup.** Validate and build `provenance.json` with `collect-provenance`, write `<workspace>/final.md`, and clean the workspace with `cleanup-research-workspace`.

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

The workspace helper creates a unique temporary directory outside the repository:

#### Bash
```bash
WORKSPACE=$(./scripts/make-research-workspace.sh --source-repo "$PWD" --path src/auth --path config.json)
```

#### PowerShell
```powershell
$Workspace = (& ./scripts/make-research-workspace.ps1 --source-repo (Get-Location).Path --path src/auth --path config.json).Trim()
```

The script copies only declared paths into `<workspace>/repo/` and creates the `.offload-research-workspace` marker. Worker prompts and `--add-dir` arguments point to the snapshot directory. The live repository remains untouched.

## Source policy

- **Public sources default.** Research workers query public web sources by default.
- **Explicit authorization for private sources.** Accessing private, internal, or authenticated repositories and APIs requires explicit user authorization for that specific run. Never forward cookies, session tokens, browser profiles, or environment credentials implicitly.

## Failure handling and recovery

Follow the shared recovery rules in `SKILL.md`:

- **Stable worker IDs and retry ceiling.** Each assignment retains a stable identifier across attempts. Attempt 1 is initial dispatch; attempt 2 is the only permitted retry (maximum two attempts per task).
- **Quality versus operational failures.** Failing a machine gate, scope check, or citation audit is a quality failure; operational failures include crashes, timeouts (20m), and unparsable output. Operational failures retry with `--route default` (no model escalation). Quality failures retry with `--route quality-retry` only when an evidence-backed target is configured in `model-policy.json`.
- **Immediate quota handoff.** If Gemini quota is exhausted, stop dispatching immediately and hand all unfinished work back to the calling orchestrator while preserving completed artifacts.
- **Outcome tracking.** Every attempt and verification verdict is recorded in `routing-outcomes.json` in the scratch workspace. Web research provenance optionally records routing attempt data in `provenance.json`.
- **Implementer failures.** If an implementer fails its gate or violates execution scope, retry once with the error output. If the retry fails, halt that task.
- **Researcher failures.** If a researcher crashes or times out, retry once. If the retry fails, synthesis proceeds as long as at least two independent evidence angles remain. The final report explicitly names any omitted angle.
- **Synthesis and audit failures.** Synthesis and citation audit are mandatory stages. If either stage crashes, times out, or fails to resolve citations after its retry budget, the run transitions to `partial` status.
- **Partial result contract.** A `partial` run returns verified claims and raw findings collected before the failure. It strictly withholds firm conclusions or recommendations, states the failed stage, and preserves all raw artifacts for debugging.

## Compact provenance and report contract

### Provenance tracking and workspace cleanup

At the end of a research run, `collect-provenance` validates and generates `provenance.json`:

#### Bash
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

#### PowerShell
```powershell
& ./scripts/collect-provenance.ps1 `
  --run-id "run-01" `
  --request-summary "Evaluate database migration options" `
  --selected-mode "web-research" `
  --profile "standard" `
  --start-time "2026-08-31T10:00:00Z" `
  --end-time "2026-08-31T10:04:30Z" `
  --duration-seconds 270 `
  --scratch-path "$Workspace" `
  --workers $WorkersJson `
  --final-citations $CitationsJson `
  --audit-verdicts $AuditsJson `
  --final-status "success" `
  --incomplete-stage-reasons "[]" `
  --output "$Workspace/provenance.json"
```

After generating provenance, `cleanup-research-workspace` cleans the temporary workspace:

#### Bash
```bash
./scripts/cleanup-research-workspace.sh --workspace "$WORKSPACE" --status success
```

#### PowerShell
```powershell
& ./scripts/cleanup-research-workspace.ps1 --workspace "$Workspace" --status success
```

- On `success`, the helper removes intermediate worker files and snapshot directories while preserving `final.md`, `provenance.json` when present, `routing-outcomes.json`, the workspace marker, and `evidence-disposition.json`. The disposition manifest records each routing evidence path, its pre-cleanup existence, a SHA-256 hash for existing regular files, and whether it was retained, pruned, missing, or left uninspected for safety.
- On `partial` or failure, the helper retains all raw artifacts and logs.

### Crash recovery and resource ownership

The adapters maintain a durable, orchestrator-owned resource ledger outside worker checkouts. Pass the same ledger, assignment ID, and parent ID to workspace and worker helpers when coordinating a run:

```bash
LEDGER="$SCRATCH/offload-resource-ledger.json"
WORKSPACE=$(./scripts/make-research-workspace.sh --ledger "$LEDGER" --assignment-id "$ASSIGNMENT" --parent-id "$PWD" --source-repo "$PWD" --path src/auth)
./scripts/run-agy-json.sh --role researcher --ledger "$LEDGER" --assignment-id "$ASSIGNMENT" --parent-id "$PWD" --output "$WORKSPACE/worker.json" --error "$WORKSPACE/worker.err" -- --prompt '...'
./scripts/cleanup-research-workspace.sh --workspace "$WORKSPACE" --status success --ledger "$LEDGER" --resource-id "research-workspace:$ASSIGNMENT"
```

If the orchestrator crashes, reconcile the ledger on its next run. Reconciliation terminates recorded worker processes before cleaning their resources and discovers AGY-native Git worktrees that were never registered as `unknown`. It never deletes dirty, unmerged, unowned, ambiguous, or otherwise unprovable resources.

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
- `agy+grep`: Recorded artifact reviewed by worker, verbatim quote and digest verified by the orchestrator.
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

## Proactive offer contract

Offload uses a portable, model-readable proactive-offer contract instead of vendor-specific hooks. Orchestrators offer offload unprompted when tasks meet qualified scale thresholds, ask for confirmation before dispatching, and respect user preference for the remainder of the session.

### Worked context example

Place this instruction block in your agent's project context file (`AGENTS.md`, `CLAUDE.md`, or custom instructions):

```markdown
## Offload delegation

- Use Offload when the user asks to offload, run work on AGY, use Gemini subagents, or accepts an AGY offer.
- Offer AGY once, before starting, when implementation splits into three or more independently gated tasks in a clean Git repository, or when a read-only audit or external research requires multiple distinct work lanes. Count research lanes by distinct questions or evidence responsibilities, not browser tabs.
- Keep narrow factual answers, explanations, single-source lookups, and focused code reviews local.
- Ask before dispatching.
- Ask once per session. If the user declines, continue locally without offering AGY again in that session.
- When Offload applies, let its skill instructions choose the appropriate workflow mode.
```

### Optional host adapters

Host automation or hooks that implement the proactive-offer contract must satisfy four requirements:

1. **Trigger conditions**: Trigger only when the proactive-offer conditions hold (3+ independently gated implementation tasks in a clean git repository, or multi-lane research/audit).
2. **Session state**: Keep once-per-session state and never ask repeatedly after a refusal.
3. **User consent**: Ask the user before dispatching workers.
4. **Fail open**: Fail open so a broken adapter never blocks the host agent's normal workflow.

## Deterministic test suite

Run the automated acceptance suite to verify contracts across supported helper families:

#### Bash
```bash
bash tests/test_research_modes.sh
bash tests/test_execution_scope.sh
bash tests/test_worker_adapter_contract.sh
```

#### PowerShell
```powershell
pwsh -File tests/test_research_helpers.ps1
pwsh -File tests/test_execution_scope.ps1
pwsh -File tests/test_worker_adapter_contract.ps1
pwsh -File tests/test_codex_adapter.ps1
```

The Codex worker boundary is documented in docs/codex-adapter.md. It discovers
the installed CLI structured-output support and selects models from the
host-provided CODEX_MODEL_CATALOG. It fails closed when either capability is
unavailable.

## Findings about agy

- **`agy` default `--print-timeout` is 5 minutes.** On expiry it writes no output at all. `offload` passes `--print-timeout 20m`.
- **`--output-format json` returns one flat JSON object.** Parse top-level fields `status`, `response`, `duration_seconds`, `num_turns`, and `usage`.
- **`--json-schema` outputs validated JSON in `structured_output`.** Parse `structured_output` rather than `response`.
- **Use `dispatch-worker.sh` or `dispatch-worker.ps1` for execution assignments.** They own assignment admission, worktree creation, result and error paths, and the bounded launch. The dispatcher wraps the lower-level `run-agy-json` helper, which rejects the unsupported `agy --output` flag.
- **Use structured output extractors (`extract-structured-output.sh` or `extract-structured-output.ps1`) between research stages.** They forward only validated `structured_output`, keeping verbose worker prose out of later prompts.
- **Model routing is governed by `model-policy.json`.** Launchers inject the policy-selected Gemini 3.8 Flash model (`gemini-3.8-flash-low` or `gemini-3.8-flash-high`) via `--role <role>`. Reasoning effort is encoded directly in the model ID; callers must not pass `--model` or `--effort`.
- **`--mode plan` is a version-sensitive behavioral hint, not a write barrier.** The accepted probe on `agy 1.1.25` blocked the tested direct write outside the permitted artifact area, but this observation is not a guarantee. `--add-dir` grants access without confining writes. Security relies on filesystem isolation and mechanical verification.

Run the maintainer-only compatibility probe when the installed `agy` behavior needs a refresh (never as a deterministic CI gate):

```text
pwsh -NoProfile -File scripts/probe-agy-compatibility.ps1 --workspace <disposable-workspace> --output <probe-report.json>
```

Published provenance and reports are redacted at the publication boundary. Browser/headless claims must carry an in-scope reality anchor. Process completion and exit 0 do not by themselves establish an accepted result; gates that cannot run use the `unrunnable` classification.

## License

MIT. See `LICENSE`.
