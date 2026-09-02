# Whole-skill review

Reviewed 2026-09-03 against `cfc9f4e` in `D:/dreiOS/Projects/offload`.

The modular router and central model policy are worth keeping. The skill's main weakness is the connection between its instructions and its helpers. Ordinary parallel execution fails scope checks, PowerShell research handoffs lose their output, and several verification paths accept incomplete evidence. I would fix these before relying on unattended runs.

This is a review, with no source changes. Thirteen confirmed findings follow. P1 means fix before relying on the affected workflow. P2 means a concrete correctness or verification gap that should follow. All findings have high confidence. The review used lint-skills and writing-for-agents for instructions, plus direct code inspection and disposable reproductions for runtime behavior.

## Coverage

The audited unit is the user-owned source repository, classified as owned-local. The installed skill is a tracked copy; it was used to launch isolated workers and was not edited. Usage counts and the user's global skill registry were outside this repository review. No skills-ledger.md was present.

| Unit | Status | Findings |
|---|---|---|
| SKILL.md, 205 lines | Clear mode routing; routing-record contract mismatch | F-11 |
| modes/execution.md | Verification and concurrency defects | F-02, F-03, F-04, F-05 |
| modes/repo-research.md | Broken PowerShell setup and record retention | F-01, F-10 |
| modes/web-research.md | Handoff, acceptance, partial-result, and retry defects | F-01, F-05, F-11, F-12, F-13 |
| Model policy and policy validation | No additional confirmed defect in the supported default routes | None |
| Launcher pair | PowerShell child lifetime defect | F-07 |
| Execution scope helper pair | Shared-tree accounting, committed edits, Bash failure handling | F-02, F-03, F-06 |
| Workspace creation and extraction helpers | PowerShell output contract mismatch | F-01 |
| Provenance helpers | Documented input disagrees with validator | F-11 |
| Cleanup helper pair | Routing history loss; PowerShell junction traversal | F-08, F-10 |
| Tests | Fifty PowerShell test groups do not execute | F-09 |
| README, context, specs, ADRs | Read for intent and consistency; no separate additional finding | None |

## Confirmed findings

### F-01 · P1 · PowerShell research commands cannot capture helper output

Location: [make-research-workspace.ps1:170](D:/dreiOS/Projects/offload/scripts/make-research-workspace.ps1:170), [extract-structured-output.ps1:77](D:/dreiOS/Projects/offload/scripts/extract-structured-output.ps1:77), [repo-research.md:40](D:/dreiOS/Projects/offload/modes/repo-research.md:40), [web-research.md:211](D:/dreiOS/Projects/offload/modes/web-research.md:211).

Both helpers write through `[Console]::Out`. The documented `& script.ps1` invocation captures PowerShell pipeline output, so the workspace expression calls `.Trim()` on null. The synthesis expression silently assigns null and loses researcher evidence. I encountered the workspace failure while starting this review. A separate extraction reproduction printed valid JSON to the console while the assigned variable remained null. Calling the helper as a native `pwsh -File` process captured the same output successfully.

Fix the helpers to emit pipeline values, or consistently invoke them through a native subprocess. Test the exact documented assignment expressions, including nonempty merged findings.

Lever: false capability claim. Kind: structural. Provenance: orchestrator, reproduced.

### F-02 · P1 · Parallel implementers fail each other's ownership checks

Location: [execution.md:136](D:/dreiOS/Projects/offload/modes/execution.md:136), [execution.md:178](D:/dreiOS/Projects/offload/modes/execution.md:178), [check-execution-scope.ps1:145](D:/dreiOS/Projects/offload/scripts/check-execution-scope.ps1:145), [check-execution-scope.sh:122](D:/dreiOS/Projects/offload/scripts/check-execution-scope.sh:122).

The workflow dispatches independent workers into the same working tree, then checks each worker against its own owned paths. Both helpers read the entire current working tree. With worker A changing only a.txt and worker B changing only b.txt, A's check reports b.txt and B's check reports a.txt. Both exit 1 even though ownership was respected.

Give each worker an isolated worktree and verify before integration, or redesign the batch workflow with explicit attribution. Passing the union of all owned files loses the promised per-worker ownership guarantee.

Lever: false capability claim. Kind: structural. Provenance: orchestrator+checked, reproduced.

### F-03 · P1 · Committed changes bypass ownership and frozen-path protection

Location: [check-execution-scope.ps1:145](D:/dreiOS/Projects/offload/scripts/check-execution-scope.ps1:145), [check-execution-scope.sh:138](D:/dreiOS/Projects/offload/scripts/check-execution-scope.sh:138), [execution.md:132](D:/dreiOS/Projects/offload/modes/execution.md:132).

Both scope helpers inspect `git status` without a recorded baseline revision. After a worker modifies a frozen gate and commits it, status is clean and the scope check exits 0. Freezing gates with a commit does not prevent this. The workflow also needs to verify gate-author changes before treating the resulting tree as the untouched baseline.

Record an immutable baseline before each writing stage. Account for committed, staged, unstaged, and new files, and verify frozen contents against that baseline. A prompt telling workers not to commit would not replace this check.

Lever: false capability claim. Kind: structural. Provenance: orchestrator+checked, reproduced.

### F-04 · P1 · Diff review omits staged changes and new files

Location: [execution.md:216](D:/dreiOS/Projects/offload/modes/execution.md:216), [execution.md:232](D:/dreiOS/Projects/offload/modes/execution.md:232), [execution.md:242](D:/dreiOS/Projects/offload/modes/execution.md:242).

Reviewers run bare `git diff`, and the orchestrator matches quotes against the same command. It excludes staged changes and untracked files. In the reproduction, one staged edit and one new file produced zero diff lines. A larger change can therefore pass checks on its unstaged portion while other changed content never reaches the reviewer.

Build one complete review artifact against the recorded baseline, explicitly including new files. Give that same artifact to the reviewer and quote verifier.

Lever: false capability claim. Kind: structural. Provenance: orchestrator+checked, reproduced.

### F-05 · P1 · Empty review and audit results satisfy acceptance rules

Location: [execution.md:210](D:/dreiOS/Projects/offload/modes/execution.md:210), [execution.md:246](D:/dreiOS/Projects/offload/modes/execution.md:246), [web-research.md:292](D:/dreiOS/Projects/offload/modes/web-research.md:292), [web-research.md:306](D:/dreiOS/Projects/offload/modes/web-research.md:306).

The reviewer schema accepts `{"criteria":[]}`. The auditor schema accepts `{"citation_audits":[],"final_status":"pass"}`. Both passed PowerShell's JSON Schema validation against the literal schemas in the documents. Execution accepts when all returned quotes match, without requiring every requested criterion. Web research accepts the auditor's pass status without matching audits to the claim ledger.

Assign criterion IDs and require exactly one verdict per requested ID. Match audit entries to every required claim/citation pair, reject missing or duplicate entries, and check that individual verdicts agree with the overall status. Adding only minItems would still allow partial coverage.

Lever: false capability claim. Kind: structural. Provenance: orchestrator, schema reproduction and instruction inspection.

### F-06 · P2 · Bash scope verification reports success when git status fails

Location: [check-execution-scope.sh:138](D:/dreiOS/Projects/offload/scripts/check-execution-scope.sh:138).

The process substitution feeding the touched-path loop does not propagate a failed `git status` exit. A controlled mock returning exit 73 for that command caused the helper to print the error and then return 0. PowerShell already checks the child exit status.

Capture status output with an explicitly checked exit code before parsing its NUL-delimited records. Add a failure-path test.

Lever: false capability claim. Kind: structural. Provenance: orchestrator+checked, reproduced with a mock, not a damaged repository.

### F-07 · P2 · PowerShell launcher leaves a worker running after output setup fails

Location: [run-agy-json.ps1:408](D:/dreiOS/Projects/offload/scripts/run-agy-json.ps1:408).

The launcher starts AGY before opening its output and error streams. Stream creation happens outside the cleanup block. When both paths point to the same file, the second open throws and the launcher exits, while the child keeps running. A disposable fake worker wrote its completion marker after the launcher had already failed.

Validate output paths and open both streams before launch. Ensure every post-launch failure terminates or explicitly hands off the child and disposes resources. Cover locked or invalid destinations as well as identical paths.

Lever: false capability claim. Kind: structural. Provenance: orchestrator+checked, reproduced.

### F-08 · P2 · PowerShell cleanup traverses nested junctions outside the workspace

Location: [cleanup-research-workspace.ps1:122](D:/dreiOS/Projects/offload/scripts/cleanup-research-workspace.ps1:122).

The helper checks whether each top-level entry is a reparse point, then recursively enumerates all files below ordinary directories to clear read-only attributes. That enumeration follows nested junctions. In a disposable reproduction, repo/nested-link pointed to a sibling directory outside the cleanup workspace. Cleanup changed the sibling file from read-only to normal, then failed to delete the junction. The file remained; external deletion was not observed.

Walk directories without following reparse points at any depth. Remove links themselves and change attributes only on files whose traversal remains inside the workspace.

Lever: false capability claim. Kind: structural. Provenance: orchestrator+checked, reproduced entirely under the audit's temporary directory.

### F-09 · P2 · Fifty PowerShell model-routing test groups never execute

Location: [test_model_routing.ps1:366](D:/dreiOS/Projects/offload/tests/test_model_routing.ps1:366).

Fifty groups are bare `{ ... }` expressions, which create and print ScriptBlock objects. They do not run the contained assertions. The suite exits 0 after reporting 147 assertions from the executed portions, while later coverage for invalid policies, invocation forms, escalation, and exit contracts is skipped.

Invoke those blocks or remove their outer braces. Check that a deliberate assertion failure inside a representative group makes the suite fail. The AST-derived list of all 50 groups is saved beside this report.

Lever: false capability claim. Kind: structural. Provenance: orchestrator, observed suite output and AST inspection.

### F-10 · P2 · Successful cleanup deletes required routing history

Location: [cleanup-research-workspace.ps1:111](D:/dreiOS/Projects/offload/scripts/cleanup-research-workspace.ps1:111), [cleanup-research-workspace.sh:130](D:/dreiOS/Projects/offload/scripts/cleanup-research-workspace.sh:130), [SKILL.md:120](D:/dreiOS/Projects/offload/SKILL.md:120).

The root contract requires routing-outcomes.json in the scratch workspace, but success cleanup retains only final.md, provenance.json, and the marker. A reproduction confirmed routing-outcomes.json was deleted. Web provenance embeds routing only optionally; repository research has no mandatory archival step.

Preserve routing-outcomes.json, or require a verified archival merge before cleanup. Preserve enough evidence to interpret retained attempt paths. Removing raw scratch files on success is an accepted design choice; losing the required history is the defect.

Lever: duplication, conflicting contracts. Kind: structural. Provenance: orchestrator+checked, reproduced.

### F-11 · P2 · Documented routing provenance has the wrong JSON shape

Location: [SKILL.md:143](D:/dreiOS/Projects/offload/SKILL.md:143), [web-research.md:325](D:/dreiOS/Projects/offload/modes/web-research.md:325), [collect-provenance.ps1:214](D:/dreiOS/Projects/offload/scripts/collect-provenance.ps1:214).

The instructions attach the individual attempt record as a worker's routing object. Both validators expect a container with schema_version and attempts. The documented shape failed with "routing missing required schema_version"; wrapping the same record in `{"schema_version":1,"attempts":[...]}` succeeded.

Choose one shape and show a complete example used by both shell tests. Prefer a worker-level container that retains both attempts.

Lever: duplication, conflicting contracts. Kind: structural. Provenance: orchestrator+checked, reproduced.

### F-12 · P2 · Failed researcher files block the documented partial-success path

Location: [web-research.md:197](D:/dreiOS/Projects/offload/modes/web-research.md:197), [web-research.md:210](D:/dreiOS/Projects/offload/modes/web-research.md:210), [web-research.md:316](D:/dreiOS/Projects/offload/modes/web-research.md:316).

Synthesis may continue after a researcher exhausts retries if two independent angles remain. The preparation snippets instead glob every researcher-*.json, including failed results. Two valid result files plus one ERROR envelope made extraction exit 2.

Build the merge input from verified successful attempts, explicitly exclude failed and superseded artifacts, then check the surviving evidence-angle count. Keep failed files for diagnostics.

Lever: false capability claim. Kind: structural. Provenance: orchestrator+checked, reproduced.

### F-13 · P2 · Retry examples overwrite the artifacts referenced by attempt history

Location: [web-research.md:200](D:/dreiOS/Projects/offload/modes/web-research.md:200), [web-research.md:279](D:/dreiOS/Projects/offload/modes/web-research.md:279), [web-research.md:307](D:/dreiOS/Projects/offload/modes/web-research.md:307), [run-agy-json.ps1:413](D:/dreiOS/Projects/offload/scripts/run-agy-json.ps1:413).

The one-revision loop reuses synthesizer.json and auditor.json. Both launchers truncate existing destinations. Repeating the documented dispatch replaces attempt 1's output, so an earlier routing record can point to attempt 2's evidence.

Keep worker identity stable while making artifact paths attempt-specific, such as synthesizer.attempt-1.json and synthesizer.attempt-2.json. Record those paths and explicitly select the accepted attempt for downstream stages.

Lever: information hierarchy, incomplete lifecycle instructions. Kind: structural. Provenance: orchestrator+checked, direct code and workflow inspection.

## Instruction quality

The 205-line root router meets the progressive-disclosure goal. The mode boundaries, bounded research assignments, retry ceiling, and distinction between operational and quality failures are useful. Keep the explicit statements that plan mode is only a behavioral hint and add-dir is not confinement.

The description ends with a workflow summary and allows research fan-out across "angles or files". The body and context contract make distinct work lanes the threshold and keep focused reviews local. Tighten the description to those trigger boundaries and remove the process summary. This is minor compared with the runtime findings.

The best next investment is a small set of executable workflow checks that run the documented shell handoffs. More repeated prose about verification will not catch F-01 or F-09. Keep policy definitions central and link to complete record examples so future changes do not recreate F-10 and F-11.

## Verification performed

All nine existing test entry points exited 0. Five ran in PowerShell 7. Four ran under Git Bash on Windows.

| Entry point | Observed result |
|---|---|
| tests/test_research_helpers.ps1 | Exit 0, 130 assertions |
| tests/test_execution_scope.ps1 | Exit 0, 103 assertions |
| tests/test_model_routing.ps1 | Exit 0, 147 executed assertions, 50 uninvoked groups |
| tests/test_workflow_static.ps1 | Exit 0, 72 assertions |
| tests/test_routing_provenance.ps1 | Exit 0, 40 assertions |
| tests/test_agy_helpers.sh | Exit 0 |
| tests/test_execution_scope.sh | Exit 0 |
| tests/test_research_modes.sh | Exit 0 |
| tests/test_model_routing.sh | Exit 0 |

Native Linux, macOS, and Bash 3.2 were not exercised. This was not a live web-research run or a quality comparison between models.

Additional disposable reproductions checked shared-tree scope, committed frozen changes, staged/new diff omissions, pipeline capture, Git failure propagation, schema acceptance, cleanup retention, provenance shape, partial-result merging, junction traversal, and child lifetime after launcher failure.

Evidence is in repro.log, bash-status-repro.log, repro-research.log, repro-helpers.log, and uninvoked-test-blocks.json beside this report. Reproduction scripts are also retained. Do not rerun them indiscriminately against existing fixture directories.

## Offload run

Three isolated AGY researchers used gemini-3.8-flash-high, one attempt each. The longest lane took about 6 minutes 56 seconds. I inspected all 18 returned claims against live source and adjusted severity myself. No lower-priority finding was accepted solely through sampling.

| Worker | Lane | Provenance | Result |
|---|---|---|---|
| execution | Execution safety | orchestrator+checked | Three findings accepted; gate-author concern narrowed into F-03; two claims not adopted |
| helpers | Shell helpers and parity | orchestrator+checked | Three findings accepted; two lower-impact observations retained below; one dangling-link claim unverified |
| research | Evidence and provenance | orchestrator+checked | Four findings accepted; syntax claim refuted; scalar-splat edge case excluded from supported workflow findings |

All scoped snapshot files still matched the source after the workers finished. Returned SUCCESS statuses were not treated as verification.

Rejected or limited claims:

- The alleged trailing backslash in the PowerShell auditor command is absent. The source uses backticks, and its code block parses.
- Scalar string splatting does expand to characters, but the claimed single-result synthesis path does not meet the workflow's requirement for two surviving independent angles. F-01 is the actual supported-path failure.
- A retry does not necessarily require throwing away the previous attempt's work. The lack of a prescribed rollback alone is not a confirmed defect.
- The absence of a final implementer commit is not independently a bug. A workflow may intentionally leave verified changes for its caller.
- Gate-author scope checking needs attention, but the worker overstated a standalone failure. The clean-tree requirement catches ordinary uncommitted stray changes; baseline and committed-change protection are covered by F-03.
- The helper worker's proposed index.lock reproduction was not used as proof. F-06 was demonstrated with a controlled failing git-status mock.
- Whitespace-only AGY_BIN falls back in PowerShell according to source inspection, while Bash rejects it. This is a lower-impact configuration inconsistency, not promoted to the main findings.
- Bash provenance routing validation lacks the dedicated counterpart of the PowerShell routing-provenance suite. This is a coverage observation, not proof of another runtime defect.
- The dangling-link claim remains unverified. Automatic approval review blocked the follow-up disposable test with "blocked by policy" and no further reason. It is excluded from confirmed findings.

Raw worker results, process timings, per-claim decisions, and source-attributed token usage are retained beside the report in routing-outcomes.json and verification.json. No retries were needed to finish the review locally.

## Recommended fix order

1. Repair PowerShell handoffs and activate the dormant test groups.
2. Define isolated execution and immutable baselines, then generate complete review artifacts.
3. Enforce criterion and citation coverage before accepting results.
4. Fix launcher failure cleanup, nested junction handling, and Bash failure propagation.
5. Align provenance shapes, attempt filenames, successful-input selection, and retention.

The source repository remains unchanged.

