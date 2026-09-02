---
status: accepted
---

# Bound model routing to Gemini and explicit rules

Decision date: 2026-09-03.

Offload will select worker models from the Gemini models available through AGY. Anthony chose this boundary because Gemini provides the usage allowance he wants for delegated work. Routing will prioritize verified task success, then elapsed time and quota use. Each role will have a default model and reasoning effort, with explicit rules for escalation. The orchestrator will apply those rules when choosing a model.

High is the maximum permitted reasoning effort. Routing and recovery must respect this ceiling; a model escalation cannot increase effort beyond high.

The first release uses these defaults:

| Role | Model |
| --- | --- |
| scout | `gemini-3.8-flash-low` |
| gate-author | `gemini-3.8-flash-high` |
| implementer | `gemini-3.8-flash-high` |
| reviewer | `gemini-3.8-flash-high` |
| researcher, in either research mode | `gemini-3.8-flash-high` |
| synthesizer | `gemini-3.8-flash-high` |
| auditor | `gemini-3.8-flash-high` |

This release records worker outcomes for later optimization. Medium effort and Pro assignments become defaults only after evaluation; neither receives a default role assignment in the initial release.

One shared model policy will define routing for all modes. Both shell-native helper families will read and validate that policy, enforcing the permitted selections. Individual workflow documents must not maintain independent model assignments. This makes policy changes consistent across modes and platforms.

Subsequent changes to role defaults must earn promotion through repeated runs on representative offload tasks using the same inputs and verification gates. Published benchmarks identify candidates; local results decide promotion.

The initial migration from 3.7 Flash to 3.8 Flash is an accepted exception. Published coding results justify the requested baseline update, subject to a small integration smoke test rather than a full 3.7-versus-3.8 comparison. This exception does not establish optimal effort levels, Pro assignments, or lower AGY quota consumption. Anthony accepted those evidence limits when approving the lighter migration check.

Recovery will distinguish failed quality checks from timeouts, tool errors, and exhausted quota. Only a failed quality check triggers a retry with a model shown to perform better on that work. Other failure classes require their own recovery rules. A model name such as Pro does not establish that it is a better escalation target.

Each worker has at most one retry. A model escalation consumes that retry and does not start a fresh retry budget.

When Gemini quota is exhausted, offload immediately returns unfinished work to the calling orchestrator. It does not automatically wait for quota to reset, activate paid credits, or switch Gemini models in search of more quota. The handoff preserves completed work and applicable verification requirements.

## Consequences

Claude and GPT-OSS are outside the routing policy even when AGY lists them. Research and evaluation should focus on Gemini candidates. Model availability alone does not establish suitability for a role.

The migration baseline and first-release role assignments are settled. Existing mode-specific recovery continues within the single-retry ceiling, except that exhausted quota returns work immediately. Timeouts and tool errors do not justify model escalation. Evaluation cases and repeat counts for later promotions are deferred until such a promotion is proposed.

These are accepted design decisions. Dispatch commands and helpers still need implementation and verification; this documentation does not itself change their behavior.
