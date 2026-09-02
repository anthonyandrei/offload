# Platform-agnostic offload workflows

Status: ready for implementation

Issue: [#1, Add native Windows / PowerShell support for research workflows](https://github.com/anthonyandrei/offload/issues/1)

Related decisions:

- [ADR 0001: Maintain shell-native helper families](../adr/0001-maintain-shell-native-helper-families.md)
- [ADR 0002: Centralize execution scope checks](../adr/0002-centralize-execution-scope-checks.md)
- [ADR 0003: Use a portable proactive-offer contract](../adr/0003-use-a-portable-proactive-offer-contract.md)
- [ADR 0004: Mark workspaces before cleanup](../adr/0004-mark-workspaces-before-cleanup.md)

## Problem

Offload describes itself as agent-agnostic, but its commands assume a POSIX shell. Native Windows orchestrators cannot run the documented workflows without WSL or Git Bash. The research helpers require Bash, and parts of the execution workflow require POSIX tools such as `awk`, `sort`, and `comm`. The optional proactive-offer hook also depends on a Claude Code lifecycle event and JSON format.

The result is a mismatch between the project's stated boundary and its executable path. An orchestrator can run `agy.exe` on Windows but cannot follow Offload's isolation, output capture, provenance, cleanup, or execution verification procedures as written.

## Solution

Maintain two shell-native helper families with the same observable contracts:

- Bash 3.2 or newer for POSIX-shell orchestrators.
- PowerShell 7 or newer for PowerShell orchestrators.

All execution, repository-research, and web-research instructions must provide a native path for both families. Native Windows must require only PowerShell 7, Git, and `agy`. It must not require Bash, WSL, Git Bash, Python, or `jq`.

Replace the Claude Code hook with a model-readable proactive-offer contract. Include the current global `AGENTS.md` offload rules as the worked example. Host-specific automation may implement the contract, but no vendor hook belongs to the supported core.

## User stories

1. As a Windows orchestrator user, I want to run execution workflows in PowerShell, so that I do not need WSL or Git Bash.
2. As a Windows orchestrator user, I want to run repository research in PowerShell, so that scoped snapshots and live-repository verification remain reproducible.
3. As a Windows orchestrator user, I want to run web research in PowerShell, so that worker output, synthesis, citation audit, provenance, and cleanup use the documented workflow.
4. As a Bash orchestrator user, I want existing helper commands to keep working, so that Windows support does not break current installations.
5. As an orchestrator user, I want `AGY_BIN` to override automatic discovery, so that I can select a specific worker executable.
6. As an orchestrator user, I want an invalid explicit `AGY_BIN` to fail immediately, so that Offload does not run a different executable than the one I selected.
7. As a research user, I want snapshot creation to reject paths that escape the source repository or traverse links, so that workers receive only the declared scope.
8. As a research user, I want cleanup to reject directories that Offload did not create, so that a bad argument cannot erase unrelated files.
9. As an execution user, I want one command to detect unowned changes and modified frozen paths, so that worker scope is checked the same way in every shell.
10. As an agent user, I want portable context instructions for proactive offers, so that my agent can suggest Offload without a vendor-specific hook.
11. As an adapter author, I want a small proactive-offer contract, so that I can implement host automation without copying Claude Code behavior by accident.
12. As a maintainer, I want CI to run the helper contracts on Windows, macOS, and Linux, so that supported platforms cannot drift unnoticed.
13. As a maintainer, I want tests to invoke helper scripts as real processes, so that they verify user-visible behavior rather than implementation details.
14. As a user diagnosing a failed research run, I want partial and failed cleanup to retain raw artifacts, so that the failure remains inspectable.

## Supported environments

| Host path | Required runtime | Required tools | CI system |
|---|---|---|---|
| Native Windows | PowerShell 7+ | Git and `agy` | `windows-latest` |
| Linux with Bash | Bash 3.2+ | Git, `agy`, `jq`, and Python 3 | `ubuntu-latest` |
| macOS with Bash | Bash 3.2+ | Git, `agy`, `jq`, and Python 3 | `macos-latest` |
| Linux or macOS with PowerShell | PowerShell 7+ | Git and `agy` | Supported by contract, not a required CI job |

The documentation selects a helper family from the current shell. It must not use operating-system detection or a universal launcher.

## Helper families

The PowerShell family adds these scripts:

- `scripts/make-research-workspace.ps1`
- `scripts/run-agy-json.ps1`
- `scripts/extract-structured-output.ps1`
- `scripts/collect-provenance.ps1`
- `scripts/cleanup-research-workspace.ps1`
- `scripts/check-execution-scope.ps1`

The Bash family retains its five current research helpers and adds:

- `scripts/check-execution-scope.sh`

The existing Bash research helpers may change where this specification adds a shared contract, such as workspace markers and cleanup checks. Existing accepted arguments must remain valid.

### Shared command rules

Both families must follow these rules:

- Use the existing GNU-style long argument names, including repeated arguments and the `--` delimiter used by `run-agy-json`.
- Write machine-readable or path output to stdout.
- Write warnings, usage text, and diagnostics to stderr.
- Return zero on success and nonzero on validation, safety, parsing, or child-process failure.
- Preserve paths containing spaces and non-ASCII characters.
- Do not depend on the current working directory when resolving a script sibling or caller-supplied absolute path.
- Do not require identical diagnostic wording or identical validation error codes across helper families.
- Do require `run-agy-json` to return the exit code produced by `agy`.

Tests must compare behavior and artifacts. They must not compare script source or internal function names.

## Helper contracts

### Research workspace creation

`make-research-workspace.sh` and `make-research-workspace.ps1` accept:

- Optional `--source-repo <path>`.
- Zero or more `--path <repository-relative-path>` arguments.

On success, each helper must:

- Create a unique directory under the host temporary directory.
- Write `.offload-research-workspace` at the workspace root with the exact content `offload-research-workspace-v1` followed by a newline.
- Print only the absolute workspace path to stdout.
- If a source repository is supplied, copy each existing declared path to `repo/<declared-path>`.
- Warn and continue when a declared path does not exist.
- Preserve file contents and relative directory structure.

Each helper must reject a declared path when it:

- Is absolute or rooted.
- Resolves outside the source repository.
- Contains a parent traversal component.
- Is or contains a symbolic link, junction, or other reparse point.

On any rejection or copy failure, the helper must remove the workspace it created and return nonzero.

### Worker launch and output capture

`run-agy-json.sh` and `run-agy-json.ps1` accept:

- Required `--output <file>`.
- Required `--error <file>`.
- Required `--` delimiter followed by one or more `agy` arguments.

PowerShell command expressions must quote the delimiter as `'--'`. Bare `--` is consumed by PowerShell before the script receives its arguments. The literal delimiter remains required by both helpers. See [the issue #2 fix plan](0002-powershell-launcher-delimiter.md) for the accepted command-parser regression coverage.

Both helpers must:

- Reject `--output` and `--output=<value>` inside the forwarded `agy` arguments.
- Create parent directories for output and error files.
- Write `agy` stdout only to the output file.
- Write `agy` stderr only to the error file.
- Forward all worker arguments without reordering or splitting values that contain spaces.
- Return the worker exit code.

The PowerShell helper resolves `agy` in this order:

1. Non-empty `AGY_BIN`.
2. `Get-Command agy`.
3. `%USERPROFILE%\.local\bin\agy.exe`.

If `AGY_BIN` is non-empty but does not resolve to an invokable file or command, the helper must fail without trying later sources. The final discovery error must name the sources it checked.

The Bash helper keeps the equivalent existing order of `AGY_BIN`, `command -v agy`, and `$HOME/.local/bin/agy`. An invalid explicit `AGY_BIN` must also fail without fallback.

### Structured-output extraction

`extract-structured-output.sh` and `extract-structured-output.ps1` accept an optional `--array` followed by one or more JSON result files.

Without `--array`, the helper emits each input file's `structured_output` as compact JSON. With `--array`, it emits one compact JSON array containing each input file's `structured_output` in argument order.

The helper must fail when an input file is missing, contains invalid JSON, has a non-object top level, or lacks `structured_output`. It must never emit the top-level worker `response` field as part of extracted output.

### Provenance collection

`collect-provenance.sh` and `collect-provenance.ps1` retain the current build and validation interfaces and produce the same JSON shape.

Both helpers must:

- Accept JSON arrays either as inline JSON or as a path to a JSON file where the current Bash helper allows both.
- Preserve `deep_trigger` as `null` when absent or empty.
- Parse `duration_seconds` as a non-negative number.
- Validate the current allowed values for mode, profile, and final status.
- Require every current provenance field.
- Write UTF-8 JSON with a trailing newline.
- Avoid adding platform-specific fields or path normalization to the schema.

The PowerShell implementation must use PowerShell and .NET JSON support. It must not call Python or `jq`.

### Research workspace cleanup

`cleanup-research-workspace.sh` and `cleanup-research-workspace.ps1` accept required `--workspace <path>` and `--status <success|partial|failed>` arguments.

Before deleting content, both helpers must resolve the target to an absolute path and reject:

- A missing or non-directory target.
- A filesystem root.
- The current user's home directory.
- The process current directory.
- A Git worktree root.
- A directory without `.offload-research-workspace` containing the exact version marker.

For `success`, cleanup preserves only `final.md`, `provenance.json`, and the workspace marker. It removes all other children without following links out of the workspace.

For `partial` and `failed`, cleanup validates the target and marker but preserves all contents.

### Execution scope check

`check-execution-scope.sh` and `check-execution-scope.ps1` run inside a Git worktree and accept:

- One or more repeated `--owned <repository-relative-path>` arguments.
- Zero or more repeated `--frozen <repository-relative-path>` arguments.

The helpers must use Git plumbing or machine-readable Git output rather than parsing human-formatted status columns. They must account for:

- Modified tracked files.
- Deleted tracked files.
- Both paths involved in renames or copies.
- Untracked files that are not ignored.
- Paths containing spaces and non-ASCII characters.

Path comparison follows Git's repository-relative path representation. A touched path passes ownership only when it exactly matches an owned file or is contained by an owned directory. A frozen path fails when that file or any path under that directory changed.

The helper prints each unowned or frozen-path violation to stdout and returns nonzero when violations exist. It prints nothing and returns zero when the execution scope is valid. It must not modify the repository or create comparison files in the worktree.

## Workflow documentation changes

### Root router

Update `SKILL.md` to:

- Define helper selection by current shell.
- State the native Windows requirements.
- Remove POSIX-only `agy` discovery language.
- Keep the router below 500 lines.
- Keep the proactive-offer trigger and consent rules host-independent.
- Point to the mode documents for shell-specific commands.

### Execution mode

Update `modes/execution.md` to:

- Provide adjacent Bash and PowerShell worker launch examples.
- Route worker calls through the matching `run-agy-json` helper.
- Replace inline `awk`, `sort`, and `comm` ownership logic with the matching `check-execution-scope` helper.
- Provide native frozen-path and gate commands for each shell where the command differs.
- Preserve worker roles, models, retry rules, gate semantics, and verification provenance.

### Repository research mode

Update `modes/repo-research.md` to:

- Provide Bash and PowerShell workspace creation and worker launch examples.
- Use the matching `make-research-workspace` and `run-agy-json` helpers.
- Keep workers inside the disposable snapshot.
- Preserve the existing verification protocol against the live repository.

### Web research mode

Update `modes/web-research.md` to:

- Provide Bash and PowerShell commands for workspace creation, all worker stages, structured-output extraction, provenance generation, and cleanup.
- Use `ConvertFrom-Json` and `ConvertTo-Json` or the PowerShell extractor where Bash currently uses inline `jq`.
- Preserve worker schemas, profiles, deep triggers, retry limits, partial-result behavior, and citation-audit rules.

### README

Update `README.md` to:

- Add the support matrix and helper-selection rule.
- Provide installation and invocation examples for Bash and PowerShell.
- Replace POSIX-only examples in all workflows with adjacent Bash and PowerShell examples or links to the mode documents.
- Remove the Claude Code hook setup and `jq` hook requirement.
- Add the proactive-offer contract and the worked context-file example below.

The worked example must preserve these rules from the current global `AGENTS.md`, with wording adjusted only to make the snippet self-contained:

- Use Offload when the user asks for AGY, Gemini workers, or accepts an offer.
- Offer once before starting when implementation has at least three independently gated tasks in a clean Git repository.
- Offer once when a read-only audit or external research task requires multiple distinct work lanes.
- Count research lanes by distinct questions or evidence responsibilities, not browser tabs.
- Keep narrow factual answers, explanations, single-source lookups, and focused reviews local.
- Ask before dispatching.
- After a refusal, continue locally and do not offer again during that session.
- Let the Offload skill choose the workflow after invocation.

Document an optional adapter contract with four requirements:

1. Trigger only when the proactive-offer conditions hold.
2. Keep once-per-session state.
3. Ask the user before dispatching workers.
4. Fail open so a broken adapter never blocks the host's normal workflow.

Delete `hooks/offload-ask.sh` and remove references to the `hooks/` implementation. Do not replace it with a PowerShell hook.

### Project context

Update `AGENTS.md` after implementation so its architecture summary uses the terms in `CONTEXT.md`, names both helper families, replaces `comm` with the execution scope check, and replaces the Claude-only hook decision with the proactive-offer contract.

## Test strategy

Tests must invoke scripts through their public command-line interfaces. Do not add mocks inside helper implementations.

### Bash acceptance suite

Extend the current Bash tests and add focused files where needed. The suite must cover:

- Existing router and mode structure checks.
- Presence of both helper families in documentation.
- Bash syntax validation and executable bits.
- Worker launch argument forwarding and output separation using a fake `agy`.
- Explicit `AGY_BIN` precedence and invalid-value failure.
- Structured-output extraction in scalar and array modes.
- Missing, malformed, and unstructured JSON rejection.
- Scoped workspace copying, missing-path warnings, traversal rejection, and link rejection.
- Workspace marker creation.
- Provenance build and validation behavior.
- Success cleanup retention.
- Partial and failed cleanup retention.
- Refusal to clean an unmarked or unsafe directory.
- Execution scope success and violations in a temporary Git repository.
- Modified, deleted, renamed, copied, untracked, ignored, spaced, and non-ASCII path cases.

### PowerShell acceptance suite

Add a PowerShell suite that covers the same observable cases. It must use temporary directories and a fake `agy` command. It must run without Bash, Python, `jq`, Pester, or other downloaded test dependencies.

The suite may use a small local assertion harness written in PowerShell. A failing assertion must return a nonzero process exit code.

### Documentation contract checks

Tests must fail when:

- A mode mentions only one helper family for a required operation.
- Active documentation still requires the Claude Code hook.
- Active documentation still uses `comm` for execution verification.
- Native Windows instructions invoke Bash, Python, or `jq`.
- `SKILL.md` reaches 500 lines.
- README installation stops copying the entire skill directory.

### CI

Add one GitHub Actions workflow with these jobs:

- Ubuntu Bash contract suite on `ubuntu-latest`.
- macOS Bash contract suite on `macos-latest`.
- Windows PowerShell contract suite on `windows-latest` using `pwsh`.

Jobs must not install or call the real `agy` service. They must use local fake commands and require no credentials.

## Implementation order

1. Add failing contract tests for PowerShell files, workspace markers, cleanup refusal, and execution scope checks.
2. Add the PowerShell research helpers and make their tests pass.
3. Add both execution scope helpers and make their Git fixture tests pass.
4. Update the Bash workspace and cleanup helpers for the marker contract.
5. Update all mode documents and the root router.
6. Replace the vendor hook documentation with the proactive-offer contract and delete the hook implementation.
7. Update README and project context.
8. Add the three CI jobs and run every local suite available on the development host.

Each step must preserve unrelated working-tree changes. The implementation must not normalize file modes or line endings as a side effect.

## Acceptance criteria

The implementation is complete when all of these statements are true:

1. A native Windows orchestrator can follow execution, repository-research, and web-research workflows using PowerShell 7 without WSL or Git Bash.
2. Native Windows helpers do not call Bash, Python, or `jq`.
3. Bash and PowerShell helpers preserve equivalent structured output, workspace isolation, provenance, cleanup, and execution-scope behavior.
4. `AGY_BIN` works in both families and remains authoritative when set.
5. PowerShell discovery can invoke an ordinary Windows `agy` command or `%USERPROFILE%\.local\bin\agy.exe`.
6. Cleanup refuses unmarked and unsafe directories.
7. Execution verification catches unowned changes and frozen-path changes without `comm`.
8. README and every mode document state the supported shell path and contain no required vendor-specific hook.
9. The proactive-offer example preserves the accepted global `AGENTS.md` behavior.
10. Ubuntu, macOS, and Windows CI jobs pass without credentials or a real `agy` service.
11. Existing Bash acceptance behavior continues to pass.
12. `SKILL.md` remains below 500 lines.

## Out of scope

- Windows PowerShell 5.1.
- A universal launcher that detects the host operating system.
- A shared Python, Node.js, or compiled helper implementation.
- Maintained hooks for Claude Code, Codex, or another vendor.
- Automatic editing of a user's global context files.
- Script signing, execution-policy changes, or package installation.
- Changes to worker roles, models, schemas, retry counts, research profiles, or report classifications.
- Changes to the `agy` CLI.
- Exact diagnostic wording across Bash and PowerShell.
- Live `agy` calls in CI.
- Redesigning the execution workflow beyond portable launch and scope verification.
