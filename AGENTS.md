# offload

Agent-agnostic skill that delegates plan execution and research to headless `agy` subagent workers.

## Key decisions and architecture

- **Orchestrator-agnostic, worker-fixed**: Any agent capable of reading `SKILL.md` and running shell commands can orchestrate, including Claude Code, Codex CLI, and similar agents. `agy` is reserved for the worker role. The self-guard stops an `agy` process that loads this skill. Every assignment instructs workers not to dispatch nested workers, but the skill cannot enforce that prohibition if a worker ignores it.
- **Modular mode architecture**: Root `SKILL.md` is a lightweight router under 500 lines owning shared preconditions, mode inference, explicit overrides, mode loading, and the shared report contract. Workflows are isolated into dedicated mode documents: `modes/execution.md` (code and file mutations), `modes/repo-research.md` (bounded local investigations and audits), and `modes/web-research.md` (online research, synthesis, and citation auditing).
- **Routing hierarchy**: Once invoked, the router resolves mode in this order:
  1. Honor explicit mode override.
  2. Route research-backed mutations to `web-research` first and `execution` second.
  3. Route direct file or code mutations to `execution`.
  4. Route local read-only questions to `repo-research`.
  5. Route external read-only questions to `web-research`.
  6. Route mixed local and external questions to `web-research` with a scoped snapshot.
  Single factual lookups stay local with the orchestrator.
- **Worker roles, models, and modes**:
  - `scout` (`gemini-3.7-flash-low`, `--mode plan`): Discovers file paths for provisional tasks.
  - `gate-author` (`gemini-3.7-flash-high`, `accept-edits`): Generates automated test files from acceptance criteria.
  - `implementer` (`gemini-3.7-flash-high`, `accept-edits`): Modifies owned code files.
  - `reviewer` (`gemini-3.7-flash-high`, `--mode plan`): Evaluates git diffs adversarially against criteria.
  - `researcher` (`gemini-3.7-flash-high`, `--mode plan`): Collects structured findings for bounded questions within assigned scopes.
  - `synthesizer` and `auditor` (`gemini-3.7-flash-high`): Synthesizes claim ledgers and audits citation veracity for web research. A live smoke comparison retained Flash for every role because the proposed Pro split did not complete its mandatory synthesis stage.
- **Corrected worker guarantees**: `--mode plan` is a behavioral hint, not a write barrier; direct testing showed plan-mode workers can write files. `--add-dir` grants directory access without confining writes. Security and containment rely on filesystem isolation (disposable workspaces with scoped file snapshots for research) and mechanical verification (clean git working trees, `comm -23` ownership diffs, frozen path diffs, and test gates for execution).
- **Verification over claims**: Worker JSON status (`SUCCESS`/`ERROR`) is not trusted alone. Implementers are verified via mechanical git ownership diffs, frozen paths, and gate commands. Reviewers are verified via verbatim diff quote matching. Research findings are verified against the live repository with read-only orchestrator commands after scope validation, with direct checks on high-priority claims and sampling on lower-priority claims.
- **Preconditions**: Writing workflows require a clean git repository. Research workflows operate in isolated disposable workspaces.
- **Offer, not gate**: For implementation splits of 3+ gated tasks or multi-angle audit fan-outs, the orchestrator offers offloading once per session; a negative response settles the decision for that session.
- **Optional hook (Claude Code only)**: `hooks/offload-ask.sh` intercepts `ExitPlanMode` to offer execution offload deterministically.
- **Installation**: Tracked public repo (`github.com/anthonyandrei/offload`), installed via `skillshare install anthonyandrei/offload --track` as `_offload`. Manual installation copies the entire skill directory.
