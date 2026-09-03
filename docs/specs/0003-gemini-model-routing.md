---
status: ready-for-agent
labels:
  - ready-for-agent
date: 2026-09-03
---

# Gemini model routing

This specification implements the decisions in [ADR 0005](../adr/0005-bound-model-routing-to-gemini-and-explicit-rules.md). It is ready for implementation. No launcher or workflow behavior changed during specification work.

Related material:

- [Domain terms](../../CONTEXT.md)
- [Model research and evidence limits](../research/2026-09-03-model-routing.md)
- [Shell platform contract](0001-platform-agnostic-workflows.md)
- [PowerShell delimiter contract](0002-powershell-launcher-delimiter.md)

## Problem and intended result

Offload assigns Gemini 3.7 Flash through model IDs repeated in workflow instructions. Its launchers forward the caller's model arguments without enforcing a shared routing policy. Changing a role's model therefore requires coordinated edits, and callers can select models outside the intended limits.

Move the baseline to Gemini 3.8 Flash and make one shared policy authoritative for every worker role in every mode. Both shell families must resolve and validate selections before launching AGY. Keep routing explainable through role defaults and explicit quality escalation rules.

The objective is verified task success first, followed by elapsed time and quota consumption. The initial defaults are an approved baseline, not a claim that they are optimal for every task. Record enough evidence to evaluate later changes.

## User stories

1. As an offload user, I want Gemini workers for delegated work, so that delegation uses the usage allowance I prefer.
2. As an offload user, I want reasoning effort capped at high, so that neither normal work nor recovery exceeds my chosen limit.
3. As an orchestrator, I want a default model for each worker role, so that the same assignment follows the same routing rule across modes.
4. As an orchestrator, I want the approved 3.8 Flash baseline, so that new work no longer depends on the older default.
5. As a maintainer, I want one model policy shared across platforms, so that changing a role does not leave conflicting workflow instructions.
6. As an orchestrator, I want invalid routing requests rejected before dispatch, so that missing settings cannot silently select an unintended model.
7. As an orchestrator, I want model escalation only after a verified quality failure and with supporting evidence, so that a larger model name does not substitute for demonstrated suitability.
8. As an offload user, I want at most one retry for each assignment, so that repeated failures cannot create an open-ended run.
9. As an orchestrator, I want timeouts and tool failures distinguished from quality failures, so that recovery addresses the failure that occurred.
10. As an offload user, I want unfinished work returned immediately when Gemini quota runs out, so that I can decide how to continue.
11. As an orchestrator, I want completed work and verification requirements preserved during handoff, so that recovery does not lose useful results or accept unchecked changes.
12. As a maintainer, I want verified outcomes, elapsed time, and available usage evidence recorded per attempt, so that later model choices can be compared fairly.
13. As a maintainer, I want the migration checked through the actual launchers and a small live smoke test, so that the new baseline is usable without a full comparison against 3.7.
14. As a caller, I want existing prompt forwarding, output capture, isolation, and verification to keep working, so that model routing does not change the assignment's meaning or safeguards.

## Accepted routing policy

The first policy revision assigns these defaults:

| Role | Default model | Effort |
| --- | --- | --- |
| scout | `gemini-3.8-flash-low` | low |
| gate-author | `gemini-3.8-flash-high` | high |
| implementer | `gemini-3.8-flash-high` | high |
| reviewer | `gemini-3.8-flash-high` | high |
| researcher | `gemini-3.8-flash-high` | high |
| synthesizer | `gemini-3.8-flash-high` | high |
| auditor | `gemini-3.8-flash-high` | high |

The researcher role has the same default in repository and web research. Mode selection, web research profiles, worker permissions, and assignment scope remain separate from model selection.

Only Gemini models are eligible. Permitted effort levels are low, medium, and high, with high as the ceiling. The first revision has no configured escalation targets. Existing evidence does not justify assigning Pro or medium effort to a default role, or selecting an automatic escalation target.

Future promotions require repeated representative offload runs using the same inputs and verification gates. Compare verified success before considering time or usage. Published benchmarks identify candidates; they do not establish local superiority. A future promotion proposal must define its cases and repeat count before evaluation, then attach the results and limitations to the policy change.

The initial 3.7-to-3.8 migration is the accepted exception. It needs the integration checks below, not a full comparative benchmark. Neither published coding results nor the migration smoke test establishes lower AGY quota consumption.

## Implementation decisions

### Shared policy

Add one repository-root `model-policy.json`. Resolve it relative to the installed helper location, never the caller's current directory. Include it in installation and manual-copy instructions. No environment override, per-mode policy file, or caller-supplied policy path is needed.

The policy has these fields:

| Field | Contract |
| --- | --- |
| `schema_version` | Integer `1`; reject unsupported versions. |
| `policy_revision` | Nonempty revision identifier, initially `2026-09-03.1`; change it whenever routing behavior changes. |
| `max_effort` | `high` for this release. |
| `max_retries_per_worker` | Integer `1`. |
| `quota_action` | `handoff`. |
| `roles` | Object containing exactly the seven roles above. |
| `roles.<role>.default_model` | Complete AGY model ID, including its effort suffix. |
| `roles.<role>.quality_escalation` | Initially `null` for every role. A configured entry contains `model` and `evidence_path`. |

The model ID is the source of effort information. Do not store a second editable effort value for each selection. Validate the Gemini prefix and a terminal `low`, `medium`, or `high` effort suffix. Reject empty IDs, non-Gemini IDs, unknown effort suffixes, and selections above the ceiling. Actual availability also requires the AGY preflight below.

A non-null escalation entry must name a different eligible model and a nonempty repository-relative path to an existing evaluation document inside the skill directory. The document must identify the role, baseline, candidate, comparison method, results, and promotion decision. Helpers validate the entry and path; the maintainer reviewing a promotion validates the quality of its evidence. A file's existence does not prove superiority.

Both shell families validate the whole policy before dispatch, including unused roles and escalation entries. Missing or malformed JSON, missing roles, invalid types or values, and unsupported schema versions fail closed. Use existing POSIX dependencies and PowerShell's native JSON support. Add no Windows dependency on Bash, jq, or Python.

### Launcher contract

Extend `scripts/run-agy-json.sh` and `scripts/run-agy-json.ps1` with two options before the required delimiter:

- `--role <role>` is required and selects a policy role.
- `--route <route>` is optional, defaults to `default`, and accepts `default` or `quality-retry`.

The default route resolves `default_model`. The quality-retry route resolves that role's configured escalation model. If no target exists, reject the quality-retry request before AGY starts. Never infer a Pro target or silently replace the requested route with the default. An allowed same-model retry explicitly uses the default route.

The launcher injects exactly one `--model` selection from the policy. Reject caller-supplied `--model` and `--effort` options after the delimiter, including equals forms. Current AGY help exposes those long options without short aliases. Preserve ordinary prompt text containing those strings. Option validation must distinguish an option from the value of an AGY prompt or other value-taking option. Do not search prompt substrings or flatten argument arrays.

Missing or duplicate routing options, unknown roles or routes, invalid policy, and attempted model overrides return an argument/configuration error before launching a worker. Use exit code 2 and an actionable stderr diagnostic. The missing-role diagnostic should direct old callers to supply a role and remove their model flag.

Preserve executable resolution through `AGY_BIN`, PATH, and the existing user-local fallback. An invalid explicit `AGY_BIN` still fails without trying another binary. Preserve stdout/stderr file capture, exact worker exit codes, prompt and path argument boundaries, and forwarded `--output` rejection. PowerShell command expressions must continue to use quoted `'--'` as specified in specification 0002.

Do not add an independent `--effort` argument. The selected AGY model ID already encodes effort. Do not introduce a custom model override or bypass option.

The launcher enforces the selection boundary. It does not judge task quality, authorize a retry, or persist a global retry counter. Those responsibilities remain with the orchestrator following the shared rules. Direct AGY invocation can bypass a helper, so this is a workflow contract rather than process containment.

### Workflow integration and preflight

Update the root router, all three mode documents, README, and AGENTS.md to use the shared policy. Active dispatch examples supply roles and omit literal model IDs. Give the root router one shared routing and recovery section; mode documents refer to it and retain their existing mode-specific steps. Keep the root skill below 500 lines.

Before the first worker in a run, the orchestrator reads the policy and checks the selected defaults against the available Gemini IDs reported by the resolved AGY installation. If a required model is absent or availability cannot be established, report the blocked dispatch and return the affected work. Do not silently downgrade to 3.7, use AGY's default, or pick a similarly named model. Check an escalation model before using it too. Avoid repeating catalog discovery for every worker in the same run unless AGY reports that availability changed.

Replace every active 3.7 default, including command examples and current role summaries. Preserve historical research, smoke results, and completed specifications as records of what ran. Link current model summaries to the policy instead of maintaining another editable routing table. This specification and the accepted ADR record the initial revision.

Maintain the existing 20-minute worker timeout, clean-repository precondition for writing workflows, disposable research workspaces, execution scope checks, frozen paths, gates, review quote validation, and citation auditing. Model selection does not weaken any of them.

## Recovery and retry accounting

A worker means one logical assignment, not one process invocation. Track a stable worker ID across attempts. Attempt 1 is the initial call; attempt 2 is its only possible retry. A new process name, model, conversation, or revision prompt does not reset the count. A genuinely separate assignment has its own ID.

Only a completed response rejected by the applicable verification process counts as a quality failure. Examples include failing implementation gates, invalid review evidence, and unsupported synthesis claims. A reported worker `SUCCESS` or exit code zero does not establish verified success. A crash, timeout, or response that cannot be parsed is an operational failure rather than evidence that a different model would do better.

| Observed result | Required action |
| --- | --- |
| Verified success | Accept according to the mode's existing verification contract. No retry. |
| Quality failure, retry remains, and the mode permits correction | Retry once with concrete verification feedback. Use `quality-retry` only when that role has an evidence-backed target; otherwise use the default model. |
| Quality failure after the retry, or the mode requires immediate fallback | Stop retrying. Follow that mode's halt, partial-result, or orchestrator fallback path. |
| Timeout, process/tool error, or unusable response | Follow the mode's existing recovery rule, with at most one same-model retry where it permits one. No model escalation. |
| Unknown failure | Record uncertainty and follow the operational-failure path. Do not infer a quality problem or quota exhaustion. |
| Explicit Gemini quota exhaustion | Stop scheduling workers and immediately hand unfinished work back to the calling orchestrator. No automatic retry, wait for reset, model switch, or paid-credit activation. |

Quota classification requires explicit AGY quota evidence from structured output or a diagnostic. A generic timeout, HTTP throttling message, or tool failure alone is insufficient. Classify quota before the other recovery rules when the evidence is present.

The one-retry ceiling does not grant a retry in stages that currently fall back or return partial immediately. Preserve these mode distinctions:

- Execution keeps its scout and gate-author fallback, implementer gate/scope retry, and direct orchestrator review fallback.
- Repository research keeps its bounded same-model operational retry and subsequent orchestrator fallback.
- Web research keeps its minimum-angle requirement and partial-result behavior for failed mandatory synthesis or audit stages. Its allowed synthesis revision uses the synthesizer's second attempt; the final audit uses the auditor's second attempt. Earlier retries consume those same budgets. Exhaustion returns a partial result rather than creating a new assignment to repeat the stage.

An escalation consumes attempt 2. No third invocation is permitted for the same logical assignment, even when the second failure has a different cause.

On quota handoff, preserve completed artifacts and list verified, unverified, failed, pending, and still-running assignments. Include process or job references and output paths for workers already running. Do not wait for sibling workers to finish before reporting the handoff or schedule replacement workers. The calling orchestrator takes ownership of any running work. Outputs recovered later still need the original verification. Keep the existing worker timeout bound and incomplete-work cleanup rules.

## Outcome records and reporting

Maintain a `routing-outcomes.json` artifact in each run's existing scratch workspace. The orchestrator owns it and updates it after dispatch and verification. This is a bounded run record, not a new service or persistent scheduler. Use a top-level `schema_version` of 1 and an `attempts` array.

Each attempt records:

| Field | Contract |
| --- | --- |
| `worker_id`, `role`, `mode` | Stable assignment identity and existing mode name. |
| `attempt` | Integer 1 or 2. |
| `policy_revision`, `route`, `model`, `effort` | Resolved selection; derive effort from the model ID. |
| `reason` | Initial default or the observed failure and recovery decision that authorized attempt 2. |
| `started_at`, `ended_at`, `duration_seconds` | UTC timestamps and observed elapsed time; ending values are null while running. |
| `exit_code` | Actual process exit code, or null when unavailable. |
| `state` | `running`, `completed`, `failed`, or `interrupted`. This is process state, not a quality verdict. |
| `failure_class` | `none`, `quality`, `timeout`, `tool_error`, `quota`, `unrunnable`, or `unknown`. A gate exit 126/127 is `unrunnable` and does not consume a retry. |
| `verification` | `pending`, `passed`, `failed`, or `not_performed`, using the applicable mode's checks. |
| `evidence_paths` | Output, error, gate, review, or audit artifact references that support the outcome. |
| `usage` | Null when unavailable; otherwise source-attributed reported measurements with explicit units. |

Pending assignments that never dispatched belong in the final handoff/report, not in fabricated attempt records. Failed dispatches still belong in the report with their configuration or availability diagnostics.

The retry ceiling is per logical worker: `(worker_id, attempt)` pairs are unique, each worker has at most two attempts, and attempt 2 reuses the same stable `worker_id`. An explicit `accepted_attempt` must resolve to that same worker's existing verified artifact; a newer or wildcard artifact is never selected implicitly.

Record tokens, elapsed time, quota counters, or other usage measurements only when actually observed. Token counts and wall time are not interchangeable with AGY quota consumption. Missing usage stays null. Do not copy secrets or entire prompts into the routing record.

The final report links the run record and summarizes selected models, verification results, retries, and any handoff. Preserve the distinction between proven, judged, verified, audited, and worker-claimed results. In web research, add the corresponding attempt record as an optional `routing` object in each provenance worker entry. Extend both provenance validators to validate present routing objects while accepting historical entries without them. Do not replace the existing provenance schema or manufacture missing historical measurements.

## Verification and acceptance criteria

Use the existing public launcher tests with a fake AGY selected through `AGY_BIN`. Exercise shell processes and captured argument arrays rather than mocking JSON readers or internal policy-resolution functions. For invalid-policy cases, copy the helper family and policy into a disposable fixture directory, then alter the fixture policy. No production-only test override is needed.

Required automated coverage:

1. Every role resolves to the exact initial model on Bash and PowerShell. Researcher behavior is identical across research modes.
2. The launcher forwards exactly one policy-selected model and preserves all other supported arguments, including prompts and paths with spaces. Prompt values containing model-option text remain intact.
3. Missing, malformed, or unsupported policies, invalid role maps, non-Gemini IDs, effort violations, unknown roles/routes, duplicate routing arguments, and caller model/effort overrides fail before the fake worker starts.
4. A null escalation target rejects a quality-retry request. A fixture policy with a valid evidence-backed target dispatches that target. Missing or escaping evidence paths and identical default/target models fail validation.
5. Existing executable-resolution, output capture, stderr capture, nonzero exit, required delimiter, and forwarded-output rejection tests keep passing. PowerShell retains both `-File` and actual command-expression coverage with quoted `'--'`.
6. Outcome/provenance validation accepts valid routing records and legacy workers without routing data, while rejecting invalid attempt numbers, role/effort values, and negative durations. Pending ending values and unavailable usage remain valid.
7. Static workflow checks require role-based dispatch and shared recovery references in every mode. They reject active 3.7 dispatch defaults and preserve the router size limit without treating historical results as current policy.

Review the documented recovery paths against these cases: implementation quality failure then failed retry; timeout then quality failure on attempt 2; reviewer fallback; synthesis revision followed by final audit; an exhausted synthesis/audit retry budget; and quota exhaustion while another worker is running. For each, verify the described invocation count, selection, artifact handling, and final status. These are orchestration-instruction checks, not claims that the launcher can enforce an agent's reasoning.

Run the existing Bash research-mode and execution-scope suites on Ubuntu and macOS, and the PowerShell research-helper and execution-scope suites on Windows. Keep the existing CI jobs and test frameworks. Wire added coverage into those suites rather than introducing a separate runtime or CI platform.

After automated checks pass, perform a small live smoke check through the real launcher:

- A low-effort scout discovers known files in a disposable fixture.
- A high-effort implementer makes a tiny owned-file change in a clean disposable Git repository, then passes its scope check and deterministic gate.
- A high-effort researcher reads a scoped fixture and returns structured findings that the orchestrator checks against it.

These checks cover the two selected model IDs and both plan and accept-edits invocation paths. Fake-worker tests cover every role and both shells. Use the existing worker timeout and recovery budget, record live attempts and outcomes, and report the platform used. Do not use the production repository as the mutation fixture. A failed or quota-blocked smoke check leaves migration verification incomplete; it does not authorize a fallback model or a claim of successful migration.

Completion requires the shared policy, both launchers, active workflow instructions, outcome recording, provenance compatibility, passing platform contract tests, and successful live smoke evidence. The implementation report must identify anything that could not be verified. No comparative claim about optimal effort, Pro suitability, or quota savings follows from passing these checks.

## Out of scope

- Implementation work during this specification task.
- Non-Gemini workers or reasoning effort above high.
- Automatic selection based on free-form task classification, learned routing, or per-request experimentation.
- Initial medium-effort or Pro defaults, or unevaluated escalation targets.
- A full 3.7-versus-3.8 benchmark, exhaustive role benchmark suite, or fixed repeat count for future promotions.
- Automatic quota waiting, paid-credit activation, quota-driven model switching, or account management.
- A new orchestration engine, persistent retry scheduler, telemetry dashboard, or quota estimator.
- Changes to mode inference, research profiles, permission models, isolation, verification standards, or the worker timeout.
- Rewriting historical evidence to use current model names, deploying an installed skill update, or publishing a release.
