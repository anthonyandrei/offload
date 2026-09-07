---
status: accepted
---

# Use implicit invocation for the offer gate

Offload will use its skill description to activate when an orchestrator is about to start a native multi-agent workflow for two or more independent, bounded assignments. The skill will ask once whether the user prefers another available worker provider before native delegation begins. File count is not a trigger because one coherent change may span many files. This replaces the global host-instruction nudge from ADR 0003, which duplicated routing policy outside the skill and still failed to trigger reliably.

This is a model-selected gate rather than a guaranteed lifecycle hook. Hosts that support implicit skill invocation can apply it without global configuration; other hosts still require explicit invocation or a host-specific integration.
