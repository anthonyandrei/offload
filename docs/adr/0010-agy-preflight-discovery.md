# ADR 0010: Fail closed when AGY preflight cannot prove eligibility

- Status: superseded by [ADR 0011](0011-launch-first-admission-and-orchestrator-fallback.md)
- Date: 2026-09-06
- Extends: ADR 0008 and ADR 0009
- Issue: [#42](https://github.com/anthonyandrei/offload/issues/42)

## Context

AGY model discovery is useful for routing, but an installed CLI does not by
itself prove that a model is authenticated, entitled, billable through the
included route, or able to cover an assignment and its retry. A missing,
malformed, stale, unsupported, or timed-out observation must therefore remain
unknown. Treating it as verified or unlimited could start an ineligible or
unexpectedly billable worker.

The adapter contract already has separate access, entitlement, billing, and
usage fields. Issue #42 requires the AGY adapters and selectors to preserve
those distinctions across both supported shell families, with bounded
read-only discovery and no worker launch during preflight.

## Decision

Both AGY adapters perform bounded, read-only probes during catalog discovery:

1. Discover the installed model list.
2. Probe the provider's headless usage command.
3. Normalize the result into protocol version 2 preflight records.
4. Leave unsupported fields unknown and carry a precise reason forward.

The PowerShell adapter owns the deadline and kills the child process tree. The
Bash adapter uses GNU `timeout` with a completion marker when available. Its
fallback requires `setsid` or `pgrep` for process-tree cleanup and fails closed
when neither is available. Provider exit codes 124 and 137 remain provider
failures, not timeout evidence.

The adapters do not authenticate, change account or billing state, launch a
worker, send a billable prompt, or persist raw command output. The selectors
reject unknown access, entitlement, or billing. Automatic selection also
requires known, fresh usage with protocol capacity units and reservation
scopes. An explicit provider may proceed with unknown usage only when the
provider and pin are explicit and the other checks are verified; the selected
record marks that uncertainty.

Provider-confirmed failures, such as unauthenticated access, expired access,
wrong account, paid fallback, or exhausted usage, remain distinct from
verification that is unavailable or unsupported. The latter never becomes a
provider denial, exhaustion, or unlimited capacity.

## Live AGY 1.1.27 findings

The installed `agy` executable is version 1.1.27. The following read-only
commands were inspected:

| Probe | Result | Routing consequence |
| --- | --- | --- |
| `agy models` | Returns a model inventory | Discovery is available, but the inventory proves neither account access nor entitlement |
| `agy -p /usage --output-format json --print-timeout 15s` | Returns group-level fractions and reset times | The adapter keeps usage unknown because the response has no protocol capacity units or reservation data |
| `agy -p /credits --output-format json --print-timeout 20s` | Returns a credits/upgrade response | It does not prove account identity, model entitlement, billing route, or per-model capacity, so it is not used as eligibility evidence |

The current headless surface does not expose a supported non-secret account
identifier, per-model entitlement, billing route, or per-model capacity and
reservation units. As a result, the live adapter correctly keeps those
observations unknown and automatic AGY dispatch remains ineligible until the
provider exposes sufficient evidence or the user supplies an explicit,
verified route.

The relevant provider references are the [AGY CLI reference](https://www.agy.dev/docs/cli/reference/)
and [AGY headless guide](https://www.agy.dev/docs/cli/headless/).

## Consequences

- Both adapters have equivalent bounded discovery and fail-closed semantics.
- Selector and handoff diagnostics retain the distinction between confirmed
  provider failures and unavailable verification.
- Fixture-driven PowerShell and Bash suites cover verified, ineligible,
  unknown, stale, malformed, timed-out, redacted, and no-launch paths.
- The current AGY installation cannot be automatically dispatched from this
  adapter, which is safer than inferring eligibility from group fractions or
  the presence of an installed CLI.
