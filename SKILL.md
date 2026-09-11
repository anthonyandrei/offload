---
name: offload
description: Delegate bounded implementation or research work to another worker provider. Use when the user explicitly asks to offload, names a worker provider, accepts an offload offer, or when the orchestrator is about to start a native multi-agent workflow for two or more independent, bounded assignments.
---

# offload

Offload is an optional delegation workflow. The calling agent remains the orchestrator: it owns the assignment, reviews the result, finishes unfinished work, and gives the final report.

Keep narrow factual answers, explanations, single-source lookups, and focused code reviews local. Explicit requests, named worker providers, and accepted offers bypass the two-lane proactive threshold. A worker must not dispatch another worker.

## Before delegation

- Describe one bounded assignment. Include the objective, in-scope paths or questions, acceptance criteria, deliverables, and the boundary of the worker's authority.
- If the user named a provider, honor that choice. Otherwise inspect the worker tools currently available to the host. When the choice matters, use each tool's current native help or model-listing facility rather than relying on copied instructions.
- When worker, model, or reasoning-effort choices materially affect expected cost or quality, consult a relevant benchmark source below. Prefer current evidence for the exact model and effort under consideration. If exact evidence is absent, select from task demands, required capabilities, current availability, cost, and judgment. Missing or stale benchmark evidence never blocks an attempted launch.
- Unknown entitlement, billing, quota, capacity, or benchmark information never blocks an attempted launch. The real launch is the definitive usability check.
- Start one worker per bounded assignment by default. Split work only when the pieces are genuinely independent and each has its own acceptance criteria.

Do not encode provider command syntax, copied help text, exact model identifiers, a universal catalog, or a role matrix in this workflow. Those details belong to the worker tool and the current runtime.

## Implementation work

- Place implementation work in an appropriately isolated disposable worktree or project copy. The worker must not write directly to the orchestrator's live checkout before review.
- Give the worker its assignment and acceptance criteria. Do not give it authority to widen its paths, change the assignment, dispatch nested workers, or alter orchestrator state.
- After launch, inspect the actual files and diff. Check scope, intent, and the relevant project checks. A success message from the worker is evidence to inspect, not an acceptance decision.
- Accept or integrate changes only when the criteria and relevant verification pass. Reject out-of-scope or unverified changes, then finish the assignment yourself or report the remaining blocker.
- Remove the disposable workspace after accepted integration. If partial output must be preserved, name it in the report and clean it when the orchestrator has recovered what it needs.

## Research work

- Define bounded questions and evidence responsibilities. Use separate disposable snapshots when repository context or concurrent work makes isolation useful.
- Prefer credible primary sources and claim-level support. Reject broken citations or claims not supported by their cited sources. Mark inference, uncertainty, disagreement, missing evidence, and stale evidence plainly.
- A worker's research synthesis is not accepted solely because it contains citations or reports success. The orchestrator reviews the sources and the claims they support.
- Do not require a universal result envelope or provider-specific research record. Keep only the evidence needed to support the final answer.

## Launch failure and fallback

- A failed launch or failed run returns the unfinished assignment and any usable partial output to the orchestrator automatically.
- Do not hide a failed launch with an Offload-managed second automatic attempt or a silent provider switch. The orchestrator may make a new, explicit decision after reporting what failed.
- The orchestrator completes the remaining work when it can do so safely. Otherwise it reports a resumable partial result, the failure, and the precise blocker.

## Proactive offer gate

When an orchestrator is about to start a native multi-agent workflow for two or more independent, bounded assignments (delegation lanes) in implementation or research:

- Offer Offload once immediately before native worker delegation begins, asking whether the user prefers another available worker provider.
- Keep the offer vendor-neutral unless the user already named a provider.
- Require user consent before dispatching Offload workers. If the user declines, proceed with the native multi-agent workflow and do not offer again during that session.
- File count alone does not trigger an offer; a single coherent change spanning multiple files remains local unless it contains two or more independent assignments.
- Explicit requests, named worker providers, and accepted offers bypass this threshold.
- Implicit activation at this gate is model-selected guidance rather than a guaranteed host lifecycle hook.

## Final report

State the bounded assignment, worker choice when relevant, actual result, files or sources inspected, verification performed, remaining uncertainty, and any failure or fallback. Say whether disposable workspaces were removed. Do not claim a worker ran until its launch succeeded.

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
