# ADR 0009: Select compatible workers before offering offload

- Status: accepted, implementation pending
- Date: 2026-09-05
- Extends: ADR 0003 and ADR 0008

## Context

The host routing instructions still say to offer AGY. The implementation already accepts an adapter override, but the documentation and workflow arguments retain AGY assumptions. A fixed provider name in global instructions hides the adapter choice and encourages hosts to keep suggesting the same worker.

## Decision

The orchestrator chooses a worker from configured, compatible adapters before making the offload offer. The offer names that worker and gives a brief reason for choosing it. A provider explicitly named by the user takes precedence, subject to compatibility and availability checks. Existing offer thresholds, authorization, and once-per-session refusal handling remain in force.

Support means any orchestrator capable of reading the skill and running its shell helpers can delegate to a worker through a compatible adapter with verified required capabilities. Installing an arbitrary agent CLI does not establish worker support. Vendor launch syntax and output translation remain adapter responsibilities.

Worker selection must check which providers the user can actually access through authenticated adapters and read current usage limits before assessing whether a provider can handle the assignment. CLI installation and a catalog entry alone do not establish available quota. Adapters own provider-specific usage retrieval and normalization, including the applicable limit windows, remaining allowance, reset times, and observation time when available. Missing data must remain distinguishable from confirmed available capacity.

Eligibility requires current access to the selected worker and model under the intended account and billing route. A saved login or installed CLI is insufficient. If subscription access has expired and no authorized alternative access remains, exclude that provider. Do not silently switch to paid API billing to make it eligible. A quota percentage alone is insufficient evidence of entitlement.

Providers with unavailable usage data are excluded from automatic selection. The user may explicitly choose such a provider after the uncertainty is disclosed, provided access and required capabilities are otherwise established. This exception does not override known access failures or quota exhaustion.

Capacity estimates include the assignment, verification, and one retry, accounting for other workers sharing the same quota. Begin with conservative estimates and refine them from recorded runs. Among eligible workers, rank by task capability and expected quality, then use remaining capacity as the tie-breaker.

## Consequences

Host instructions must describe worker selection without fixing the provider to AGY. Adapter selection must preserve assignment requirements through launch and result validation. Accepted architecture does not establish that the current adapters are interchangeable in every workflow.

This decision does not authorize silent provider switching on retry or quota exhaustion; ADR 0008 and the existing handoff rules still apply.

The estimation algorithm, numeric thresholds, and usage freshness interval remain implementation details to specify and validate. A remaining-usage percentage alone does not guarantee that an assignment will finish.

## Usage interface evidence

Checked on 2026-09-05. These establish available interfaces, not completed offload integration.

- [AGY CLI reference](https://www.agy.dev/docs/cli/reference/) documents `/usage`, with `/quota` as an alias, for model quota usage. The [headless guide](https://www.agy.dev/docs/cli/headless/) warns that slash commands such as `/usage` break streaming JSON flow. The installed version's standalone quota output still needs validation.
- [Claude commands](https://code.claude.com/docs/en/commands) documents `/usage` for plan limits and activity. [Status-line data](https://code.claude.com/docs/en/statusline) can expose five-hour and seven-day usage and reset times, subject to version and account support, only after the first API response. This does not establish a fresh pre-dispatch query by itself.
- [Codex app-server](https://learn.chatgpt.com/docs/app-server) provides `account/rateLimits/read`. The Codex desktop usage tool also returned live short-window and weekly limits during this audit. A portable adapter integration remains to be implemented.

## Verified baseline

Read-only inspection on 2026-09-05 established the following. No live Claude or Codex worker run was performed in this audit.

- The shared host instruction source, `%APPDATA%/skillshare/skills/global-config/CLAUDE.md`, lines 14-18, tells hosts to offer AGY. The inspected Claude, Codex, Gemini, and OpenCode global instructions contain that wording. Codex and OpenCode link to the shared source.
- The inspected Claude and Codex hook registrations invoke `global-config/scripts/skillshare-sync.ps1`. They do not directly contain the AGY offer. Editing generated host copies alone would leave the shared source stale.
- The installed and repository `SKILL.md` files had matching SHA-256 hashes. The installed scripts include AGY, Claude, and Codex adapters, so the problem is not simply an old installed router.
- `scripts/run-agy-json.ps1:175` accepts `--adapter`, then `OFFLOAD_ADAPTER_BIN`, and defaults to `agy-adapter.ps1`. The launcher filename does not restrict dispatch to AGY. No process or user adapter override was configured during inspection.
- `SKILL.md:35` and `SKILL.md:42` still require AGY. `modes/repo-research.md` supplies an inline JSON schema through `--json-schema`.
- `scripts/run-codex-json.ps1:238` treats that schema argument as a path. Its later schema handling substitutes a generic schema when the path does not exist. The inline schema therefore does not reach Codex as the requested schema through this path.
- The Claude adapter's catalog branch probes CLI output support and reads a supplied catalog. It does not verify current subscription entitlement. String model entries set `available` and `quota_available` to true; object entries default missing values to true. It therefore does not yet implement the eligibility checks in this decision.

The AGY research worker supplied additional claims. The orchestrator rejected its assertion that the launcher filename makes dispatch AGY-only and did not accept its blanket claim that every non-AGY workflow fails. The findings above reflect direct inspection, not those broader claims.
