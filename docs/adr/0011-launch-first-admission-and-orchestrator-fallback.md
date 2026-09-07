# ADR 0011: Use launch-first admission and orchestrator fallback

- Status: superseded by [ADR 0012](0012-keep-offload-outcome-based-and-runtime-dynamic.md)
- Date: 2026-09-07
- Supersedes: [ADR 0009](0009-select-compatible-workers-before-offering-offload.md) and [ADR 0010](0010-agy-preflight-discovery.md)
- Extends: [ADR 0008](0008-runtime-model-selection-through-adapters.md)

## Context

Offload grew from an AGY orchestrator into a provider-neutral framework. Its admission path also grew into an attempt to prove account entitlement, billing route, and enough quota for an assignment, verification, and retry before launching a worker. Providers do not consistently expose that evidence. The AGY adapter therefore returned unknown values that the selector treated as blockers, making ordinary AGY dispatch impossible even when a real launch could have succeeded.

Workers are fallible collaborators. The orchestrator must verify their work, but routine delegation does not need a workflow engine that predicts every provider failure before attempting a launch. The user also prefers hands-off recovery over a mid-run prompt asking whether to try another vendor.

## Decision

Provider discovery and run admission are separate operations. A manual or cached setup check may discover installed adapters, models, and provider-reported capabilities. Each run uses the provider named by the user or a configured default. It does not scan and rank every vendor by live usage before dispatch.

Run admission checks that the chosen adapter and model exist and that any required capability the provider can report is present. Missing or unsupported access, entitlement, billing, or usage data is not a blocker. A fresh, explicit provider denial, unavailable model, prohibited billing route, or exhausted quota may block launch. Otherwise, the launch itself is the definitive access and capacity check.

Adapters own catalog discovery, launch translation, and result normalization. They do not have to prove account or billing facts that the provider does not expose. Offload never switches providers silently.

When a worker fails, unfinished work returns to the orchestrator automatically. The orchestrator preserves usable partial output, completes the remaining work when it can do so safely, and reports the worker failure in the final result. It does not interrupt the run to offer another vendor. If safe completion is impossible, it returns a resumable partial result and explains the blocker.

Routine work defaults to one worker per bounded assignment with orchestrator verification. Separate scouts, gate authors, reviewers, citation auditors, or retries require a task-specific reason. Publication, integration, and acceptance gates still fail closed. Reports must not claim that a worker is running until launch has succeeded, and disposable workspace claims describe scoped project copies rather than operating-system containment.

## Consequences

- AGY and other providers can run when their CLI and model exist even if they cannot expose pre-launch quota or billing details.
- Known provider failures remain actionable, while unavailable telemetry no longer prevents useful work.
- The orchestrator may spend more of its own tokens after a worker failure, in exchange for fewer user interruptions and more reliable task completion.
- Capacity ledgers and speculative entitlement checks are no longer required for ordinary admission. Existing implementations that enforce them must be simplified to match this decision.
- Historical ADRs 0009 and 0010 remain available as the record of the stricter policy and why it was replaced.

## Implementation status

At acceptance, the selectors, adapter contract, skill instructions, and user documentation still implement or describe the superseded preflight policy. This ADR records the accepted replacement; aligning those files is separate implementation work.
