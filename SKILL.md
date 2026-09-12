---
name: offload
description: Outsource bounded repository reconnaissance, analysis, test investigation, implementation, research, transformations, artifact-producing work, and independently executable long-running work to an external vendor. Use when the user explicitly asks to offload, names an external vendor or model, approves outsourcing after the orchestrator defines a bounded assignment, or a bounded task would otherwise be delegated to a native subagent and needs an external alternative.
---

# offload

Offload is an external-vendor outsourcing workflow for bounded work that benefits from independent execution. The calling agent remains the orchestrator: it defines the assignment, routes it, reviews the result, handles bounded recovery, and gives the final report.

Eligible work includes bounded repository reconnaissance, code or document analysis, test investigation, implementation, research, writing and other transformations, artifact-producing work, and independently executable long-running work. Open-ended, indefinite, or tightly interactive work stays local. Native subagents and native multi-agent calls stay outside the contract. An external worker must not dispatch nested workers.

## Activation and consent

Activate Offload only when:

- the user explicitly asks to outsource or offload, or names an external vendor or model; or
- the orchestrator defines one bounded assignment with an objective, scope, acceptance criteria, deliverables, and authority, offers external outsourcing when the work would otherwise be delegated to a native subagent, and the user approves.

A high-effort or long-running assignment is a reason to offer Offload, not permission to launch silently. Generic approval permits routing across available external vendors. A named vendor constrains routing and escalation to that vendor. A named exact model remains pinned. A decline leaves the assignment with the orchestrator.

## Assignment contract

Every assignment uses the same shape: objective, scope, acceptance criteria, deliverables, and authority. The authority boundary names the sources the worker may inspect, the outputs it may produce, and the side effects it may take. The normal boundary excludes external side effects and credential handling.

Use one external worker per bounded assignment by default. Phases with shared authority and acceptance criteria may remain in one assignment. Genuinely independent work keeps separate boundaries, especially when it has different deliverables, permissions, or verification.

## Runtime discovery and routing

Discover vendors, models, tools, and capabilities at runtime. Runtime discovery follows this precedence:

1. Version-matched official documentation establishes capability.
2. Installed version and native help establish invocation details.
3. A real launch is the definitive admission check.

Report a mismatch as uncertainty instead of guessing. Keep a transient launch record for the current run only. It may contain the selected tool, installed version, documentation source, invocation shape, model or effort setting, usage observation, and launch result. Exclude credentials, tokens, and secrets from that record and from the final report. Vendor and model details remain run-time facts rather than fixed contract content.

Use relevant advisory benchmark references and native usage observations to choose the lightest model and lowest reasoning effort that appear capable of meeting the acceptance criteria. Missing evidence does not block launch. Unknown or stale evidence does not block launch. Confirmed exhaustion removes a candidate from automatic selection. Never combine incomparable benchmarks into a synthetic score.

Honor explicitly named vendors and exact models. Generic approval permits cross-vendor escalation. A named vendor constrains escalation to that vendor. An exact model remains pinned.

## Work safeguards

Implementation runs in an isolated disposable worktree or project copy. The external worker cannot write to the live checkout. The orchestrator inspects the actual diff, checks scope and intent, and runs relevant checks before accepting the result.

Repository reconnaissance may use a complete disposable workspace. Temporary notes stay disposable. A writable workspace does not grant authority to change accepted source.

Research starts with bounded questions and evidence responsibilities.

- Prefer credible primary sources and claim-level support. Reject broken citations or claims not supported by their cited sources. Mark inference, uncertainty, disagreement, missing evidence, and stale evidence plainly.
- A worker's research synthesis is not accepted solely because it contains citations or reports success. The orchestrator reviews the sources and the claims they support.
- Do not require a universal result envelope or provider-specific research record. Keep only the evidence needed to support the final answer.

For transformations and artifact-producing work, scope the source, output, format, and acceptance checks. Accept the deliverables only after those checks pass.

## Failure handling and bounded escalation

Infrastructure failures, including launch, timeout, quota, and tool failures, return the unfinished assignment and any usable partial output to the orchestrator without automatic provider switching. The assignment remains unfinished until the orchestrator completes it locally or reports the blocker.

A quality-gate failure, such as unmet acceptance criteria, an unverified diff, or unsupported research citations, permits exactly one automatic escalation after refreshing benchmark and usage checks. Choose the smallest credible improvement among available capable candidates.

If the escalation fails its quality gate, stop automatic attempts. No third automatic attempt is permitted. Finish the assignment locally when safe. Otherwise report the usable partial result and precise blocker.

## Lifecycle and final report

The orchestrator captures deliverables, diffs, evidence, and transient run facts before cleanup. Remove and verify every disposable worktree, snapshot, or project copy on every terminal path, including success, launch failure, timeout, quality-gate failure, escalation failure, and local finish.

If cleanup fails, preserve the usable result and report a prominent cleanup warning with the exact path that remains. The final report states the assignment, selected vendor and model, benchmark evidence, usage observations, launch facts, result, files or sources inspected, verification, escalation details, remaining uncertainty, failures or blockers, and cleanup status. Do not claim a worker ran until its launch succeeded.

## Advisory benchmark references

- Coding and implementation: [DeepSWE](https://deepswe.datacurve.ai/) reports software-engineering success, effort, token use, steps, and benchmark cost under a common mini-swe-agent harness. Treat it as advisory because the harness differs from native worker CLIs.
- General non-coding work: [LiveBench](https://livebench.ai/) provides objective, category-level evaluation for reasoning, data analysis, language, and instruction following. Use the relevant category rather than its overall score.
- Multi-step web research: [FutureSearch Deep Research Bench](https://drb.futuresearch.ai/) compares research configurations by accuracy, cost, and estimated runtime. Its [paper](https://arxiv.org/abs/2506.06287) documents the benchmark and research harness.
- Citation-heavy research reports: [DeepResearch Bench](https://deepresearch-bench.github.io/) evaluates report quality and citation support. Scores apply to complete research systems and should not be transferred automatically to their base models.
- Optional cost and speed context: [Artificial Analysis](https://artificialanalysis.ai/models) provides cross-vendor quality, price, speed, and latency information with a documented [data API](https://artificialanalysis.ai/data-api). It remains optional because its composite methodology and API access introduce their own constraints.

Human-preference leaderboards can serve as subjective tie-breakers, but preference is not a substitute for correctness. Tool-use benchmarks are useful only when function calling is central to the assignment.

Benchmark evidence ranks plausible candidates. It does not establish that a tool exists, that an account has access, or that a launch will succeed. Benchmark prices estimate API execution, not subscription quota or marginal CLI cost. Whole-agent research benchmarks measure the search stack, prompts, and harness as well as the underlying model. Missing exact model or effort data stays missing. The orchestrator's review of the actual result outranks benchmark reputation.

## Retained helpers

- The generic execution scope checker (scripts/check-execution-scope.sh) and execution workspace helper (scripts/execution-workspace.sh) enforce the retained implementation safety outcomes.
