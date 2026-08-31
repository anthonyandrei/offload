---
name: offload
description: Use when the user wants execution or research handed to another vendor's CLI agents instead of running it here. Triggers include "offload this", "run this on agy", "use gemini subagents", or after answering yes to the offload offer. Also offer unprompted when implementation splits into three or more independently gated tasks in a clean git repository, or when a read-only audit or online research fans out across multiple angles or files. Dispatches parallel headless agy workers, gates their output, and reports what was proven versus claimed.
---

# offload

If you are `agy`, stop here. Return worker results to your orchestrator. `agy` is the worker role this skill dispatches. Any other agent that can read instructions and run shell commands can orchestrate, including Claude Code, Codex CLI, and similar agents. Assignments prohibit nested worker dispatch, but the skill cannot enforce that rule if a worker ignores it.

## What this skill does

`offload` delegates execution and research tasks to headless `agy` workers (the Antigravity CLI running Gemini models). You remain the orchestrator. You decompose tasks, set acceptance criteria or bounded questions, and verify evidence and gates. Workers handle exploration, test authoring, code implementation, diff review, and research evidence collection.

You never accept worker claims at face value. You verify output through mechanical checks, test execution, diff inspections, or secondary reviews.

## Preconditions

Check these requirements before dispatching workers:

1. **Offer before dispatch.** When reaching this skill unprompted, offer the choice to the user first. Describe the planned dispatch and ask for confirmation. Ask once per session. A negative response settles the decision for the rest of the session.
2. **Local factual lookups.** Keep a single factual lookup local with the orchestrator; do not offer or route it to offload.
3. **`agy` availability.** Verify `agy` on `PATH` or at `~/.local/bin/agy`. Refuse execution if neither exists.
4. **Git working tree.** Writing workflows (`modes/execution.md`) require a clean git repository (`git rev-parse --is-inside-work-tree` and empty `git status --porcelain`). Research workflows (`modes/repo-research.md`, `modes/web-research.md`) operate in isolated disposable workspaces.

## Routing

Once invoked, select a mode using this order:

1. **Explicit mode override.** Honor an explicit user request specifying a mode (`execution`, `repo-research`, or `web-research`).
2. **Research-backed mutation.** When a requested mutation depends on external research, route to `modes/web-research.md` first for evidence gathering and audit, then route to `modes/execution.md` for implementation.
3. **Direct mutation.** Route a direct file or code change with no external research prerequisite to `modes/execution.md`.
4. **Local read-only question.** Route a read-only question answerable from declared local files to `modes/repo-research.md`.
5. **External read-only question.** Route a read-only question requiring current or external evidence to `modes/web-research.md`.
6. **Mixed local and external question.** Route a question needing both local and external evidence to `modes/web-research.md` with a declared repository snapshot.

## Modes

Load the matching mode document for the selected route:

- [`modes/execution.md`](modes/execution.md): Dispatches scouts, gate-authors, implementers, and diff reviewers for code and file modifications.
- [`modes/repo-research.md`](modes/repo-research.md): Dispatches bounded local code investigations and audits in isolated workspaces with direct evidence verification.
- [`modes/web-research.md`](modes/web-research.md): Dispatches multi-angle online researchers, synthesis, and citation auditing in isolated workspaces.

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
- **Execution safety.** Execution mode requires a clean git baseline, mechanical ownership checks (`comm -23`), frozen path diffs, and test gates.
- **Prohibition on nested dispatch.** Workers are instructed not to dispatch nested workers.
- **Bounded scope requirement.** Open-ended research without a bounded question, declared scope, and evidence expectations is out of scope.
