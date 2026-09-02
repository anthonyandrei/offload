---
status: accepted
---

# Use a portable proactive-offer contract

Offload will remove the Claude Code-specific `ExitPlanMode` hook from its supported core. The canonical integration is a model-readable proactive-offer contract that users can place in `AGENTS.md`, `CLAUDE.md`, or another host context file. The documentation will adapt the project's current global `AGENTS.md` rules as the worked example because they define qualifying implementation and research work, exclusions for narrow tasks, consent before dispatch, and once-per-session suppression after a refusal. Future vendor hooks may implement the same contract as optional adapters, but the core project will not depend on or maintain a vendor-specific lifecycle event.
