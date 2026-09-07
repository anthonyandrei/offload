# Benchmark references for runtime routing

- Date: 2026-09-07
- Status: accepted as advisory evidence

## Conclusion

Benchmark references can ground an orchestrator's choice of vendor, model, and reasoning effort without becoming a routing matrix or admission dependency. The orchestrator should consult a relevant source when the choice materially affects expected cost or quality, prefer evidence for the exact model and effort, account for harness differences, and proceed by judgment when evidence is absent.

Initial task-to-reference guidance:

- **Coding and implementation:** [DeepSWE](https://deepswe.datacurve.ai/) reports software-engineering success, effort, token use, steps, and benchmark cost under a common mini-swe-agent harness. Its results are advisory because the harness differs from native worker CLIs.
- **General non-coding work:** [LiveBench](https://livebench.ai/) provides objective, category-level evaluation for reasoning, data analysis, language, and instruction following, with public [evaluation code and data](https://github.com/LiveBench/LiveBench). Use the relevant category rather than its overall score.
- **Multi-step web research:** [FutureSearch Deep Research Bench](https://drb.futuresearch.ai/) compares research configurations using accuracy, cost, and estimated runtime. Its [paper](https://arxiv.org/abs/2506.06287) documents the benchmark and research harness.
- **Citation-heavy research reports:** [DeepResearch Bench](https://deepresearch-bench.github.io/) evaluates report quality and citation support through RACE and FACT. Its [repository](https://github.com/Ayanami0730/deep_research_bench) publishes tasks, reports, and evaluation code. Scores apply to complete research systems and should not be transferred automatically to their base models.
- **Optional cost and speed context:** [Artificial Analysis](https://artificialanalysis.ai/models) provides broad cross-vendor quality, price, speed, and latency information with a documented [data API](https://artificialanalysis.ai/data-api). It remains optional because its composite methodology and API access introduce their own constraints.

Human-preference leaderboards such as Arena can serve as subjective tie-breakers, but preference is not a substitute for correctness. Tool-use benchmarks such as BFCL are useful only when function calling is central to the assignment.

## Boundaries

- Benchmark evidence ranks only plausible candidates; it does not establish that a CLI exists or can launch.
- Benchmark prices estimate API execution, not subscription quota or marginal CLI cost.
- Whole-agent research benchmarks measure the search stack, prompts, and harness as well as the underlying model.
- Missing exact model or effort data stays missing. Family resemblance is weak evidence, not a synthetic score.
- No benchmark lookup, parser, cache, freshness gate, or API is required for delegation.
- The orchestrator's review of the actual result outranks the worker's benchmark reputation.
