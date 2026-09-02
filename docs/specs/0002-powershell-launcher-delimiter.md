# PowerShell launcher delimiter fix

Status: implemented and verified

Date: 2026-09-03

Issue: [#2, PowerShell launcher passthrough invocation](https://github.com/anthonyandrei/offload/issues/2)

Related contract: [Platform-agnostic offload workflows](0001-platform-agnostic-workflows.md#worker-launch-and-output-capture)

## Problem and evidence

The documented PowerShell call to `run-agy-json.ps1` uses bare `--`. PowerShell consumes that token before the helper receives its arguments. The helper then rejects `-p` as an unknown launcher option.

A local reproduction on PowerShell 7.6.4 used a child `pwsh -Command` process to execute the documented call expression. Bare `--` produced exit code 2 and `unknown launcher option: -p`. Quoted `'--'` passed argument validation and reached executable resolution. An intentionally invalid `AGY_BIN` prevented worker launch in both probes. This confirmed parsing behavior, but did not verify end-to-end argument forwarding.

Eight launcher examples contain the faulty syntax: four in `modes/execution.md`, one in `modes/repo-research.md`, and three in `modes/web-research.md`.

The existing PowerShell test runner supplies arguments through `ProcessStartInfo.ArgumentList` to `pwsh -File`. That path bypasses parsing of a PowerShell call expression. Its fake worker also joins arguments into one string, so the space-preservation assertion cannot distinguish one argument from multiple arguments with the same joined text.

## Accepted decisions

1. Quoted `'--'` is the supported delimiter spelling in PowerShell command expressions. Keep the helper's requirement for a literal delimiter and its rejection of worker flags supplied without one.
2. A regression test that executes the actual call expression through `pwsh -Command` satisfies the interactive parsing requirement. Preserve the existing `-File` coverage. Verify argument boundaries using a JSON array captured by a fake worker.

Both decisions were explicitly accepted by the user. They clarify the existing helper contract and require no new architectural dependency or ADR.

## User stories

1. As a PowerShell orchestrator, I want the documented worker command to run after substituting its placeholders, so that I can follow any offload workflow without discovering a quoting workaround.
2. As a caller, I want prompts and paths containing spaces to reach the worker intact, so that my assignment retains its intended values.
3. As a maintainer, I want tests to exercise the documented command syntax and detect split arguments, so that a passing suite provides evidence for the actual invocation path.
4. As a caller, I want a missing delimiter to fail before launching a worker, so that malformed launcher arguments do not run an unintended assignment.

## Implementation plan

### Correct the public instructions

- Change the delimiter to `'--'` in all eight PowerShell launcher examples across the three mode documents.
- Update `Show-Usage` in `scripts/run-agy-json.ps1` to show the quoted delimiter. Add a short explanation of PowerShell consuming the bare token where it helps callers use the helper.
- Keep the clarification already recorded in specification 0001 and the launcher delimiter definition in `CONTEXT.md`.
- Preserve the required delimiter, forwarded `--output` rejection, and Bash invocation syntax.

### Strengthen the existing PowerShell acceptance suite

Work in `tests/test_research_helpers.ps1`. Keep the public process runner and the existing `Invoke-Helper` path for `pwsh -File`.

- Make the fake worker record its received arguments as a JSON array. Replace joined-string matching with argument-count and ordinal, element-by-element comparisons. Do not flatten either array for comparison.
- Add a child process that runs a PowerShell command expression through `pwsh -NoProfile -NonInteractive -Command`. The expression must call the real helper with the call operator, quoted `'--'`, and worker arguments beginning with `-p`. Passing the whole expression through `ProcessStartInfo.ArgumentList` is acceptable because PowerShell still parses that expression.
- Supply temporary paths and fixture values safely, for example through the child's environment. Do not interpolate unescaped paths or prompts into executable command text. Use a fake worker selected by `AGY_BIN`; no real worker or network access is needed.
- Include output and error paths containing spaces, a prompt containing spaces, and a forwarded path value containing spaces. Compare the full ordered worker argument array. The launcher delimiter and launcher output/error options must not appear in that array.
- Verify worker stdout and stderr land in their respective files, and that the child process reports the helper's exit code. Explicitly propagate `$LASTEXITCODE` from the command expression, including for a nonzero fake-worker exit.
- Add negative command-expression cases for bare `--` and an omitted delimiter. Both must return nonzero and leave the fake worker unlaunched. Use fresh capture paths or a launch marker for each case so previous artifacts cannot satisfy this assertion. Do not require exact diagnostic wording.

### Verify and review

Run `pwsh -NoProfile -File tests/test_research_helpers.ps1`. The existing Windows CI job already runs this suite; no new test dependency or CI job is required.

Review all PowerShell launcher examples and the usage text for the quoted delimiter. Confirm that Bash examples retain their existing syntax. Run the existing research-modes suite where Bash is available, or rely on the existing Ubuntu and macOS CI jobs for that check. Inspect the final diff for scope and whitespace errors.

## Acceptance criteria

1. Every PowerShell launcher example and the PowerShell usage message shows `'--'`.
2. A documented-style call expression parsed by PowerShell launches the fake worker successfully.
3. The captured JSON array matches the expected worker arguments exactly, including order, count, and values containing spaces.
4. Output/error paths containing spaces work, stdout and stderr remain separated, and worker exit codes propagate.
5. Bare and omitted delimiters fail before worker launch.
6. Existing `-File` tests remain and use argument-boundary assertions for forwarding. Existing launcher rejection and discovery checks continue to pass.
7. The PowerShell acceptance suite passes without credentials, a real `agy` service, or downloaded test dependencies. Existing CI remains green.

The quoted call already passes launcher parsing before this fix. Its new regression coverage may therefore pass immediately; it protects the accepted invocation contract. The documentation correction resolves the reported failure. Do not change parser behavior merely to force a red-to-green test transition.

## Out of scope

Automatic delimiter inference, accepting the bare delimiter form as valid, launcher API redesign, executable discovery changes, Bash helper changes, new dependencies, and expanded platform or PowerShell-version matrices are outside this fix.

## Completion state

Implementation is complete. The eight PowerShell examples, launcher usage text, and regression coverage were updated. The PowerShell acceptance suite passes; the Bash suite could not run in this Windows environment because Bash/WSL is unavailable.
