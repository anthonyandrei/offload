---
name: offload
description: Outsource bounded implementation or research work to an external vendor. Use when the user explicitly asks to offload, names an external vendor or model, approves outsourcing after the orchestrator defines a bounded assignment, or a bounded task would otherwise be delegated to a native subagent and needs an external alternative.
---

# offload

Offload is an external-vendor outsourcing workflow. The calling agent remains the orchestrator: it defines the assignment, routes it, reviews the result, handles bounded recovery, and gives the final report.

Native subagent or native multi-agent calling is outside the Offload contract. Keep narrow factual answers, explanations, single-source lookups, and focused code reviews local. An external worker must not dispatch nested workers.

## Activation and consent

Activate Offload only when:

- the user explicitly asks to outsource or offload, or names an external vendor or model; OR
- the orchestrator defines one bounded implementation or research assignment with an objective, scope, acceptance criteria, deliverables, and authority boundary, offers external outsourcing when the task would otherwise be delegated to a native subagent, and the user approves.

Generic outsourcing approval allows routing across available external vendors and one benchmark- and usage-guided cross-vendor quality escalation. A named vendor constrains routing and escalation to that vendor. A named exact model remains pinned without replacement or escalation. A decline leaves the assignment with the orchestrator.

## Before outsourcing

- Describe one bounded assignment with its objective, in-scope paths or questions, acceptance criteria, deliverables, and authority boundary.
- Discover plausible external vendors, models, and tools dynamically through the current runtime. Do not publish or depend on a copied vendor catalog, command syntax, exact model matrix, adapter interface, role matrix, normalized quota protocol, routing algorithm, capacity ledger, performance ledger, or persistent benchmark cache.
- Consult the relevant advisory benchmark reference below for every model and reasoning-effort choice. Prefer current evidence for the exact candidate and effort. Keep missing, mismatched, or stale evidence visible without blocking launch, and never combine incomparable benchmarks into a synthetic score.
- Inspect native vendor usage or capacity information when available. Confirmed exhaustion removes a candidate from automatic selection. Unknown, unsupported, stale, or unclear usage does not block launch; a real launch is the definitive admission check.
- Select the lightest model and lowest reasoning effort that appear capable of the assignment's requirements and acceptance criteria. Use benchmark fit, capacity, cost, speed, and orchestrator judgment as tie-breakers.
- Honor explicitly named vendors and exact models.
- Start one external worker per bounded assignment by default. Split work only when the pieces are genuinely independent and each has its own acceptance criteria.

## Implementation work

- Place implementation work in an appropriately isolated disposable worktree or project copy. The external worker must not write directly to the orchestrator's live checkout before review.
- Give the worker its assignment and acceptance criteria. Do not give it authority to widen its paths, change the assignment, dispatch nested workers, or alter orchestrator state.
- After launch, inspect the actual files and diff. Check scope, intent, and the relevant project checks. A success message from the worker is evidence to inspect, not an acceptance decision.
- Accept or integrate changes only when the criteria and relevant verification pass. Reject out-of-scope or unverified changes, then finish the assignment yourself or report the remaining blocker.
- Remove the disposable workspace after accepted integration. If partial output must be preserved, name it in the report and clean it when the orchestrator has recovered what it needs.

## Research work

- Define bounded questions and evidence responsibilities. Use separate disposable snapshots when repository context or concurrent work makes isolation useful.
- Prefer credible primary sources and claim-level support. Reject broken citations or claims not supported by their cited sources. Mark inference, uncertainty, disagreement, missing evidence, and stale evidence plainly.
- A worker's research synthesis is not accepted solely because it contains citations or reports success. The orchestrator reviews the sources and the claims they support.
- Do not require a universal result envelope or provider-specific research record. Keep only the evidence needed to support the final answer.

## Failure handling and bounded escalation

- Launch failure, timeout, quota failure, or tool failure returns the unfinished assignment and any usable partial output to the orchestrator without automatic provider switching.
- A quality-gate failure, such as unmet acceptance criteria, an unverified diff, or unsupported research citations, permits exactly one automatic escalation after refreshing benchmark and usage checks.
- The escalation chooses the smallest credible improvement among available capable candidates. Generic approval permits cross-vendor escalation. A named vendor constrains escalation to that vendor. A named exact model remains pinned.
- If the escalation fails its quality gate, stop automatic attempts. No third automatic attempt is permitted. Finish the assignment locally when safe; otherwise report the usable partial result, failure, and precise blocker.

## Final report

State the bounded assignment, selected vendor and model, benchmark evidence consulted, native usage observations, actual result, files or sources inspected, verification performed, escalation details, remaining uncertainty, and any failure or blocker. Say whether disposable workspaces were removed. Do not claim a worker ran until its launch succeeded.

## Benchmark references

- **Coding and implementation:** [DeepSWE](https://deepswe.datacurve.ai/) reports software-engineering success, effort, token use, steps, and benchmark cost under a common mini-swe-agent harness. Treat it as advisory because the harness differs from native worker CLIs.
- **General non-coding work:** [LiveBench](https://livebench.ai/) provides objective, category-level evaluation for reasoning, data analysis, language, and instruction following. Its [evaluation code and data](https://github.com/LiveBench/LiveBench) are public. Use the relevant category rather than its overall score.
- **Multi-step web research:** [FutureSearch Deep Research Bench](https://drb.futuresearch.ai/) compares research configurations by accuracy, cost, and estimated runtime. Its [paper](https://arxiv.org/abs/2506.06287) documents the benchmark and research harness.
- **Citation-heavy research reports:** [DeepResearch Bench](https://deepresearch-bench.github.io/) evaluates report quality and citation support. Its [repository](https://github.com/Ayanami0730/deep_research_bench) publishes the tasks and evaluation code. Scores apply to complete research systems and should not be transferred automatically to their base models.
- **Optional cost and speed context:** [Artificial Analysis](https://artificialanalysis.ai/models) provides cross-vendor quality, price, speed, and latency information with a documented [data API](https://artificialanalysis.ai/data-api). It remains optional because its composite methodology and API access introduce their own constraints.

Human-preference leaderboards such as Arena can serve as subjective tie-breakers, but preference is not a substitute for correctness. Tool-use benchmarks such as BFCL are useful only when function calling is central to the assignment.

Benchmark evidence ranks plausible candidates; it does not establish that a CLI exists, that an account has access, or that a launch will succeed. Benchmark prices estimate API execution, not subscription quota or marginal CLI cost. Whole-agent research benchmarks measure the search stack, prompts, and harness as well as the underlying model. Missing exact model or effort data stays missing. No benchmark lookup, parser, cache, freshness gate, or API is required. The orchestrator's review of the actual result outranks benchmark reputation.

## Retained helpers

- The generic [execution scope checker](scripts/check-execution-scope.sh) and [execution workspace helper](scripts/execution-workspace.sh) enforce the retained implementation safety outcomes.
