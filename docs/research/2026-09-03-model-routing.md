# Gemini model routing research

Date: 2026-09-03. Run: `offload-model-routing-20260903`. Status: **partial**.

The final citation audit requested another narrowing and reported one unresolved URL. The permitted revision cycle is exhausted. This note retains supported findings and local observations; it does not recommend role assignments. Raw artifacts remain in the research workspace recorded in the accompanying provenance file.

## Settled design decisions

[ADR 0005](../adr/0005-bound-model-routing-to-gemini-and-explicit-rules.md) records the accepted policy: Gemini only, verified success before elapsed time and quota use, role defaults with explicit escalation, repeated local comparisons before promotion, and separate recovery for quality failures, timeouts, tool errors, and exhausted quota. These are user decisions, not research findings. Gemini 3.8 Flash is the requested migration baseline; dispatch defaults have not changed.

## Direct local observations

The orchestrator ran `agy models` on this host. It listed Gemini 3.8, 3.7, and 3.6 Flash with low, medium, and high effort, plus Gemini 3.1 Pro with low and high effort. Model availability establishes that a candidate can be selected, not that it suits a role.

Current mode documents assign 3.7 Flash low to scouts and 3.7 Flash high to the other worker roles. They repeat literal model IDs; the launcher forwards the caller's selection.

Six applicable invocations in this research run completed using `gemini-3.8-flash-high`. Two synthesis drafts needed correction by citation auditors. These are compatibility observations, not a controlled comparison or an estimate of task success.

The existing [live smoke comparison](../../tests/live-smoke-comparison.md) stopped one Pro synthesis after 4 minutes 27 seconds without output. Flash completed synthesis and audit. That single comparison does not establish permanent role superiority or a general Pro timeout rate.

## Findings supported by the final AGY audit

- **Audited; also opened by the orchestrator.** AGY documentation displays separate Gemini and Claude/GPT usage groups, each with five-hour and weekly limits. It does not establish relative quota consumption across Gemini models. [AGY models](https://www.antigravity.google/docs/models/)
- **Audited by AGY.** The searched vendor evaluation methodology describes benchmark setups such as mini-swe and OSWorld. It supplies no measurements for this repository's offload roles. This is a finding about the searched document, not a claim that no relevant evidence exists elsewhere. [Gemini 3.8 Flash evaluation methodology](https://deepmind.google/models/evals-methodology/gemini-3-8-flash)
- **Audited by AGY.** The searched AGY models and plans pages supply no comparative offload-role latency, tool success rates, or per-model quota consumption measurements. [AGY models](https://www.antigravity.google/docs/models/), [AGY plans](https://www.antigravity.google/docs/plans/)

## Rejected or unresolved

The final auditor only partially supported the claim connecting specific effort levels to latency and timeouts, and marked its model-card URL unresolved. The claim is omitted. Earlier drafts also transferred Gemini API capabilities to AGY and proposed Pro escalation without local evidence. Those claims are not accepted.

The research does not establish winning role assignments, useful escalation targets, comparative quota costs, or reliable automatic recovery from quota exhaustion. API capabilities and prices do not establish AGY behavior or allowance consumption.

## Offload run, seven invocations

All invocations used `gemini-3.8-flash-high` in plan mode in a disposable workspace. Workers received public research questions and the observed catalog, with no live repository snapshot. Exact run duration, citations, audit verdicts, and artifact paths are recorded in [provenance](2026-09-03-model-routing.provenance.json).

| Worker | Lane | Provenance | Result | Findings |
| --- | --- | --- | --- | --- |
| researcher-gemini | Gemini capabilities | AGY findings, then citation audit | Completed | Candidate evidence and limits |
| researcher-operations | AGY availability and usage | AGY findings, then citation audit | Completed | Catalog and quota documentation |
| researcher-alternatives | Non-Gemini alternatives | Orchestrator cancellation | Cancelled | Scope removed after Gemini-only decision; no findings used |
| synthesizer | Initial claim ledger | AGY | Completed; revision required | Unsupported transfers removed later |
| auditor | Initial citation audit | Independent AGY invocation | Revise | Rejected capability and escalation assumptions |
| synthesizer-revised | One permitted revision | AGY | Completed | Four narrowed claims |
| auditor-final | Final citation audit | Independent AGY invocation | Revise | Three claims supported; one omitted |

The final audit's unresolved citation makes the run partial under the offload web-research contract. All mandatory stages ran. No further revision workers were dispatched. Any implementation that depends on the research requires review and acceptance of these gaps under that contract.

## Orchestrator follow-up on DeepSWE

On 2026-09-03, Anthony asked whether DeepSWE already supports migrating to 3.8 Flash. A focused primary-source lookup found Google's launch post reporting stronger software engineering performance and favorable DeepSWE performance relative to larger frontier models at lower cost. The same post says 3.8 can spend more tokens and tool calls on complex tasks, especially at higher effort, and points compute-constrained users toward lower effort or 3.7 Flash. Stronger benchmark performance therefore does not establish lower token consumption than 3.7 or lower AGY quota use. [Google's Gemini 3.8 launch post](https://blog.google/innovation-and-ai/models-and-research/gemini-models/3-8-flash-and-3-8-flash-cyber/)

The orchestrator retrieved this text through web search; direct page opening failed. This follow-up was not part of the AGY audit and does not change that run's partial status.

Accepted adjustment: use the published evidence to justify the requested 3.8 baseline migration, check integration with a small smoke test, and reserve repeated comparative evaluations for subsequent changes to effort or model assignments by role. Anthony approved this specific exception to the local-promotion requirement after reviewing the evidence limits. ADR 0005 records it. The original research run remains partial.
