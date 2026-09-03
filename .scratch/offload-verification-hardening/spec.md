---
status: ready-for-agent
labels:
  - ready-for-agent
date: 2026-09-04
---

# Offload verification and launcher hardening

Status: ready for implementation.

Publication: local scratch specification. This repository has no configured issue-tracker workflow, and this task did
not authorize publishing an external issue.

## Problem

The accepted review identified three correctness gaps in the current offload workflow:

1. The PowerShell launcher can start `agy` with a child process working directory different from the caller's current
   workspace. Relative paths in a worker prompt can therefore resolve against the launcher repository instead of the
   isolated research workspace.
2. `cleanup-research-workspace` treats the top-level `routing-outcomes.json.attempts` array as if it could contain at most
   two entries total. A valid run with several workers can contain one or two attempts per worker and is rejected. The
   current uniqueness check also treats the attempt number as globally unique instead of unique per worker.
3. A worker process can exit successfully while returning missing, empty, malformed, or unverified work. The workflow
   needs to keep process completion, artifact validity, and verification status separate.

The live compatibility probe against the installed `agy` 1.1.25 also clarified the plan-mode contract. The plan arm and
no-mode arm exposed the same 57 tools and `always-proceed` permission mode. Plan mode added a plan system command and
the tested direct write to the scratch path was rejected, while the no-mode arm wrote its sentinel. This is useful
version-specific evidence, but it does not prove that plan mode is a complete write boundary: other tools and command
paths remain available, and `--add-dir` grants access without confining writes.

## Intended result

Make the workflow's actual safety and acceptance boundaries explicit and mechanically enforceable:

- read workers continue to receive `--mode plan`, but documentation treats it as a behavioral hint;
- research workers remain isolated from the live repository and execution workers remain protected by scope and gate
  checks;
- PowerShell launches `agy` in the caller-declared workspace;
- routing history supports any number of logical workers while enforcing at most two attempts per worker;
- successful process exit never bypasses structured-output, artifact, scope, or review gates;
- gate commands that cannot run are reported as `unrunnable` and do not trigger a model retry;
- browser or headless claims carry a checkable reality anchor;
- published provenance and reports redact credential-shaped values;
- a maintainer-only compatibility probe records future `agy` plan-mode behavior without becoming a live-model CI gate.

## User stories

1. As an orchestrator, I want every research worker's relative paths to resolve inside its assigned workspace, so that
   a worker cannot accidentally inspect or modify the launcher repository because of a process-directory mismatch.
2. As a maintainer, I want the Bash and PowerShell launchers to have the same workspace-directory contract, so that a
   workflow behaves consistently on both supported platforms.
3. As an orchestrator, I want plan mode's observed behavior and its limits documented accurately, so that I can use it
   as a useful worker hint without treating it as a security boundary.
4. As an orchestrator, I want a worker's process state recorded separately from its verification state, so that exit 0
   cannot be reported as verified success by itself.
5. As an orchestrator, I want malformed, empty, or incomplete structured output rejected at the existing extraction and
   selection seams, so that downstream stages receive only substantive worker results.
6. As an orchestrator, I want a gate that exits 126 or 127 classified as `unrunnable`, so that missing or unusable gate
   tooling is reported clearly and does not waste the worker's retry budget.
7. As an orchestrator, I want routing history to retain all workers and their attempts, so that parallel runs remain
   auditable without rejecting valid histories.
8. As an orchestrator, I want accepted attempts to point to one verified artifact for the same logical worker, so that a
   retry cannot silently replace or shadow the evidence selected for downstream work.
9. As a user reviewing browser or headless work, I want claims tied to a saved screenshot, DOM, network, console, or
   equivalent artifact, so that the report distinguishes observed state from worker assertion.
10. As a user receiving provenance or a final report, I want credential-shaped values redacted at the publication
    boundary, so that diagnostic output does not expose secrets while raw scratch evidence remains available under the
    existing cleanup policy.
11. As a maintainer, I want deterministic tests for these contracts, so that normal verification does not depend on a
    live Gemini call or on the current behavior of an external CLI.
12. As a maintainer, I want a repeatable live compatibility probe for `agy` version changes, so that plan-mode claims are
    refreshed from evidence instead of copied forward indefinitely.

## Scope

The implementation covers the shared launcher contract, research-workspace cleanup, worker-result acceptance, report
redaction, headless evidence anchors, and their documentation and tests. It preserves the existing model policy,
two-attempt ceiling, quota handoff, isolated research workspaces, frozen execution paths, and review-artifact checks.

The primary files and seams are:

- `scripts/run-agy-json.ps1` and `scripts/run-agy-json.sh`;
- `scripts/cleanup-research-workspace.ps1` and `scripts/cleanup-research-workspace.sh`;
- `scripts/extract-structured-output.ps1` and `scripts/extract-structured-output.sh`;
- `scripts/select-research-outputs.ps1` and `scripts/select-research-outputs.sh`;
- `scripts/collect-provenance.ps1` and `scripts/collect-provenance.sh`;
- the existing PowerShell and Bash acceptance suites and routing fixtures;
- `SKILL.md`, `README.md`, `modes/repo-research.md`, `modes/web-research.md`, and the routing specification that
  currently documents the attempt record.

Use the highest existing public seam for each behavior. Do not add a private helper solely to make an internal unit
test pass when the launcher, extractor, selector, cleanup command, or provenance command already exposes the behavior.

## Functional requirements

### 1. PowerShell child working directory

`run-agy-json.ps1` MUST set `System.Diagnostics.ProcessStartInfo.WorkingDirectory` before starting `agy`.

- The value MUST be the caller's current filesystem location at the time the launcher is invoked.
- The launcher MUST resolve the location through the PowerShell provider and reject non-filesystem locations with a clear
  configuration error before starting `agy`.
- The launcher MUST NOT silently use `$PSScriptRoot`, the repository root, or the process's inherited .NET directory.
- Existing output and error path handling, model-policy resolution, argument validation, delimiter behavior, timeout,
  and exit-code propagation MUST remain unchanged.
- No new caller-facing `--cwd` option is required for this change. A future explicit alternate-directory option is out
  of scope.

The Bash launcher already inherits the invoking shell's directory. Add a parity test rather than changing its behavior
unless the test demonstrates a separate defect.

### 2. Plan-mode documentation and safety contract

Keep `--mode plan` in read-role invocations and examples. Update wording in all maintained documentation and static tests
so that it states:

- plan mode is a version-sensitive behavioral hint;
- the accepted probe observed additional plan behavior and blocked the tested direct write outside the permitted artifact
  area on `agy` 1.1.25;
- the exposed tools and command paths mean plan mode MUST NOT be the sole containment or safety mechanism;
- `--add-dir` grants access but does not confine writes;
- filesystem isolation, scoped snapshots, execution-scope checks, frozen paths, and mechanical gates remain the actual
  safety and verification controls.

Documentation MUST NOT claim either that plan mode guarantees no writes or that the current probe proves plan mode is
useless. It should describe the observed behavior and the boundary of the evidence.

### 3. Routing-outcomes attempt identity

Preserve the existing top-level shape:

```json
{
  "schema_version": 1,
  "attempts": []
}
```

Change validation in both cleanup helpers and all associated documentation/fixtures as follows:

- `attempts` MAY contain records for any number of logical workers.
- Each record MUST have a stable `worker_id` and integer `attempt` equal to 1 or 2.
- The pair `(worker_id, attempt)` MUST be unique within the record.
- Each `worker_id` MUST have no more than two records.
- Attempt 2 MUST remain a retry of the same logical `worker_id`; changing process, model, or prompt does not create a
  new worker.
- An attempt record MUST retain the existing routing, state, failure, verification, evidence, and usage fields.
- A per-worker `accepted_attempt` MUST identify an existing attempt for that same worker whose verification passed and
  whose selected artifact exists.
- Optional nested routing histories in `provenance.json` MUST follow the same per-worker invariant.

The cleanup helpers MUST reject a worker with three attempts, a missing or invalid attempt number, a duplicate
`(worker_id, attempt)` pair, or an accepted attempt that does not resolve to a verified artifact. They MUST accept, for
example, attempt 1 for workers A, B, and C plus attempt 2 for worker B.

The helpers MUST continue to preserve valid routing evidence and produce the existing disposition manifest. No migration
of old records is needed because a record with at most two total attempts remains valid under the new rules.

### 4. Worker-result acceptance

The workflow MUST distinguish these states:

1. process completed;
2. output envelope parsed;
3. structured output passed the mode's schema and substantive-field checks;
4. evidence, scope, gate, review, or citation checks passed;
5. one attempt was explicitly accepted for downstream use.

An exit code of 0, a top-level worker status, or a nonempty prose `response` alone MUST NOT establish state 3, 4, or 5.

At the existing extractor and selector seams:

- reject missing, invalid, scalar, or otherwise unparsable structured output;
- require the mode-specific success status and the nonempty fields named by that mode's assignment schema;
- require evidence paths or equivalent result references where the mode contract calls for them;
- preserve explicit accepted-attempt selection and never select by wildcard, newest filename, or process completion time;
- keep worker prose out of downstream structured prompts unless it is explicitly part of the validated schema.

For execution work, acceptance continues to require the relevant gate plus execution-scope and frozen-path checks. For
research work, acceptance continues to require the relevant artifact and orchestrator verification rules. The change is
to make these requirements authoritative in the acceptance path and reports, not to replace them with a new universal
content schema.

### 5. Unrunnable gates

Extend the shared failure vocabulary with `unrunnable`.

- When a configured gate process exits 126 or 127, normalize the gate result to `unrunnable`.
- Record `verification: not_performed` when the gate could not run; retain the command, exit code, and diagnostic path
  as evidence.
- Do not treat this as a worker quality failure and do not spend a model retry on it.
- Return an actionable error naming the missing, non-executable, or unavailable gate command.
- Preserve existing handling for worker crashes, timeouts, tool failures, quota exhaustion, and quality failures.
- Update validators, fixtures, reports, and documentation that enumerate `failure_class` values.

If a worker process itself exits 126 or 127, classify it as `unrunnable` only when the launcher can establish that the
configured worker command was not runnable. Otherwise retain the existing operational or unknown classification rather
than guessing.

### 6. Reality anchors for headless and browser claims

For an assignment that makes a browser, GUI, rendering, or other externally observable headless claim, the accepted
result MUST include at least one reality anchor. A reality anchor is a saved artifact such as a screenshot, DOM snapshot,
network capture, console log, rendered file, or equivalent machine-checkable output.

The anchor contract MUST include:

- an explicit type;
- a path or artifact identifier;
- the claim or acceptance criterion it supports;
- existence and regular-file checks;
- containment within the assigned scratch/evidence area or an explicitly owned output path.

The report MUST mark a claim without a valid anchor as unverified or failed according to the mode's existing halt rules.
Non-browser assignments are not required to manufacture a reality anchor.

### 7. Publication-boundary redaction

Before writing `provenance.json`, `final.md`, or a user-facing handoff/report, sanitize worker-derived strings and copied
diagnostics. Raw worker artifacts remain governed by the existing success/partial cleanup policy and are not rewritten by
the redaction pass.

The redaction pass MUST cover credential-shaped values including authorization and bearer headers, cookies, private-key
blocks, password/secret/token/API-key assignments, and credential-bearing query parameters. It MUST preserve ordinary
public URLs, file paths, hashes, counts, and non-secret field names. Replacements MUST be stable markers such as
`[REDACTED]`, never a partial secret.

The pass MUST be tested with both positive secret-shaped fixtures and negative fixtures for normal URLs, hashes, and
fields such as `token_count`.

Credential forwarding rules remain unchanged: workers do not receive cookies, session tokens, browser profiles, or
environment credentials implicitly.

### 8. Maintainer-only compatibility probe

Add a shell-parity probe for future `agy` compatibility checks. It MUST run in a disposable workspace and use the same
fixed prompt, role, model policy, and output schema for two arms:

- `agy --mode plan`;
- the same invocation without `--mode plan`.

The probe MUST capture, for each arm:

- `agy --version`;
- process exit code and structured-output parse result;
- initialization permission mode, available-tool summary, and expanded command summary when exposed;
- the result of an intentional sentinel write to the disposable workspace;
- output/error artifact paths and any reported duration or usage.

The probe MUST report observations and warnings, not convert one version's behavior into a permanent safety guarantee.
It MUST fail the compatibility review if it cannot establish which arm ran or whether the sentinel check was performed.
It MUST NOT run as part of the normal deterministic test suite or silently alter the repository.

## Documentation decisions

Update the maintained contract wherever it currently describes the affected behavior:

- `SKILL.md`: plan-mode limits, per-worker attempt identity, result acceptance, and `unrunnable` handling;
- `modes/repo-research.md` and `modes/web-research.md`: isolation, accepted evidence, reality anchors where applicable,
  and publication redaction;
- `README.md`: user-facing explanation and deterministic test commands;
- `docs/specs/0003-gemini-model-routing.md`: the corrected attempt-record invariant and failure vocabulary;
- static documentation tests and canonical routing fixtures.

Keep the current role/model policy and the historical nature of the 3.7 comparison clear. Do not introduce a second
source of truth for routing or retry rules.

## Test strategy

Use fake `agy` and temporary workspaces for deterministic tests. Test through the public scripts, not by mocking private
PowerShell or shell functions.

### Launcher tests

- Invoke `run-agy-json.ps1` from a temporary directory containing spaces.
- Have the fake worker emit its observed current directory and assert it equals the temporary directory.
- Assert the existing model injection, delimiter, output/error paths, exit-code propagation, and caller-flag rejection
  tests still pass.
- Run the equivalent Bash inheritance test.

### Routing and cleanup tests

- Accept three workers with one attempt each.
- Accept workers A, B, and C at attempt 1 plus worker B at attempt 2.
- Reject three attempts for one worker.
- Reject duplicate `(worker_id, attempt)` pairs while allowing the same attempt number on different workers.
- Reject an invalid attempt number and an accepted attempt whose verification or artifact is invalid.
- Preserve and hash retained evidence in the disposition manifest.
- Exercise both PowerShell and Bash cleanup helpers against equivalent fixtures.

### Acceptance and failure tests

- Reject exit 0 with missing structured output.
- Reject valid JSON with missing or empty mode-required fields.
- Accept a fully structured result only after its applicable evidence/gate/scope/review checks pass.
- Verify explicit accepted-attempt selection after a retry.
- Normalize gate exit 126 and 127 to `unrunnable`, preserve diagnostics, and assert no retry is scheduled.
- Preserve existing operational, quality, timeout, quota, and partial-result behavior.

### Reality and redaction tests

- Accept a browser/headless claim with a valid in-scope anchor.
- Reject or mark unverified a claim with a missing, out-of-scope, or nonexistent anchor.
- Redact representative authorization, cookie, token, secret, private-key, and credential-query values.
- Confirm normal public URLs, hashes, counts, and non-secret names remain intact.

### Documentation and compatibility tests

- Update static checks so no maintained document calls plan mode a complete write barrier or the sole safety control.
- Validate the compatibility-probe output shape with a checked-in fixture or fake runner.
- Keep the live compatibility probe out of deterministic CI and document the command used by maintainers.

The existing suites remain required, including `tests/test_research_helpers.ps1`, `tests/test_workflow_static.ps1`,
`tests/test_research_modes.sh`, and the execution-scope tests for both shell families.

## Implementation order

1. Update the shared contract and routing fixture expectations, including the per-worker attempt identity and
   `unrunnable` vocabulary.
2. Fix the PowerShell launcher working directory and add cross-platform launcher regression tests.
3. Fix both cleanup helpers and add multi-worker routing fixtures.
4. Tighten structured-result acceptance and gate classification at the extractor/selector and existing execution-gate
   seams.
5. Add reality-anchor validation and publication-boundary redaction, with focused fixtures.
6. Update documentation and static tests.
7. Add the maintainer-only live compatibility probe and document when to run it.
8. Run the full deterministic suite, then run the compatibility probe only when the installed `agy` behavior or supported
   version requires a refresh.

## Completion criteria

The work is complete when:

- a PowerShell worker observes the caller's filesystem directory as its child working directory;
- Bash and PowerShell tests cover the same launcher contract;
- multi-worker routing histories clean successfully while more than two attempts for one worker fail closed;
- accepted attempts are explicit, per-worker, verified, and artifact-backed;
- exit 0 cannot bypass structured-output or mode-specific verification;
- gate exits 126 and 127 produce `unrunnable` without model retry;
- required headless claims have in-scope reality anchors;
- published provenance and reports contain no fixture secrets while raw scratch evidence follows existing retention rules;
- documentation accurately describes the observed plan-mode behavior and continues to require filesystem isolation;
- deterministic tests pass without a live model call;
- the compatibility probe can produce a complete two-arm observation when run by a maintainer.

## Out of scope

- Removing `--mode plan` from read workers or claiming that it guarantees no writes.
- Running research workers against the live repository or relying on `--add-dir` as containment.
- Replacing isolated workspaces with in-place read agents, symlinked mutable environments, or blanket `git add -A`.
- Retrying from failed commits, placing red tests on the main branch, or weakening frozen-path and execution-scope
  checks.
- Introducing a default STORM-style workflow, background Telegram/daemon integration, streaming dashboards, or unrelated
  chat/provider integrations.
- Changing the Gemini model policy, quota policy, maximum retry ceiling, or historical 3.7 comparison beyond the
  documentation needed for this contract.
- Making the live compatibility probe a required CI step or a production safety gate.
- Publishing to an external issue tracker, copying private source material from the comparison repository, or importing
  implementation details that are not supported by this repository's own contracts and tests.
- Broad cleanup, refactoring, or redesign outside the files and seams listed in this specification.
