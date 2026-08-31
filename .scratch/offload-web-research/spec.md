# Offload research modes

Status: ready for agent

Publication: local scratch spec. This repository has no project-specific issue-tracker workflow,
and this task did not authorize publishing an external issue.

## Problem

`offload` currently puts implementation work and bounded repository audits in one 420-line
`SKILL.md`. It has no workflow for cited online research. Its current safety model also treats
`agy --mode plan` as a write barrier, but direct probes showed that plan-mode workers can write.
That claim appears in the skill, README, and project instructions.

The private Asa project by Achibukz has a useful research shape: parallel evidence gathering,
synthesis, and an independent audit. Copying Asa into this public MIT repository would expose
private work and create a licensing problem. Installing Asa as a dependency would also make a
private package part of `offload`'s public setup.

## Solution

Keep `offload` as one Skillshare-tracked skill. Turn its root `SKILL.md` into a short router and
move each workflow into a mode document. Reimplement the research shape in original language and
small shell helpers. Do not copy Asa source, prompts, tests, or documentation.

Add a `web-research` mode that dispatches researchers, a synthesizer, and an independent auditor.
Every worker runs in a disposable directory. Mixed repository and online research receives only a
temporary copy of paths the orchestrator declares. The live repository is never exposed to a
research worker.

Credit the idea in public documentation with this wording:

> Offload's online-research workflow is adapted from Asa by Achibukz, used with permission.

Do not publish the private repository URL, branch name, commit, screenshots, or copied text.

## User stories

1. As an offload user, I want one skill invocation for execution and research, so that I do not
   have to learn separate skills.
2. As an offload user, I want the router to infer the mode from my request, so that the common path
   needs no extra syntax.
3. As an offload user, I want to override the inferred mode, so that I can correct an ambiguous
   route.
4. As an offload user, I want small factual lookups to stay with the orchestrator, so that a simple
   answer does not fan out into a full run.
5. As an offload user, I want online research to require multiple evidence angles, a real
   comparison, or a citation audit, so that offloading pays for its overhead.
6. As an offload user, I want a standard research profile, so that ordinary research gets broad
   evidence without an oversized run.
7. As an offload user, I want a deep profile when I request it or when a named risk trigger fires,
   so that difficult decisions get more scrutiny.
8. As an offload user, I want the report to name an automatic deep trigger, so that I know why the
   run expanded.
9. As an offload user, I want every final citation opened and checked by an independent auditor,
   so that a plausible URL is not treated as support.
10. As an offload user, I want claims tied to their citations, source quality, conflicts, and
    uncertainty, so that I can judge the answer rather than trust a worker count.
11. As an offload user, I want primary and independent sources to outweigh repeated secondary
    coverage, so that five workers repeating one source do not look like five confirmations.
12. As an offload user, I want unsupported incidental claims removed, so that the final answer does
    not preserve noise for completeness.
13. As an offload user, I want unresolved claims kept only when they affect the decision and marked
    clearly, so that uncertainty remains visible where it matters.
14. As an offload user, I want a failed mandatory stage to return a partial result instead of a firm
    synthesis, so that incomplete research cannot masquerade as a finished answer.
15. As a repository owner, I want research workers isolated from the live working tree, so that a
    worker write cannot change my files.
16. As a repository owner, I want mixed repository and web research to copy only declared paths,
    so that unrelated private material is not sent to workers.
17. As an offload user, I want public sources used by default and private online sources used only
    after explicit authorization, so that credentials and signed-in data are not passed silently.
18. As an offload user, I want compact provenance retained without successful worker transcripts,
    so that I can audit the result without keeping a bloated run history.
19. As an offload user, I want raw artifacts retained when a run fails, so that the failure can be
    diagnosed.
20. As an offload user, I want research to finish before implementation begins, so that workers
    implement from an audited result instead of changing the target while evidence is still being
    gathered.
21. As an existing offload user, I want execution and repository research behavior preserved, so
    that adding web research does not break established workflows.
22. As an installer, I want Skillshare to install the router, modes, and helpers together, so that
    no plugin or private dependency is required.
23. As an implementer, I want deterministic tests around routing, isolation, failure handling, and
    provenance, so that most behavior can be checked without spending model calls.
24. As a maintainer, I want one live comparison of the proposed model split, so that the role
    assignments rest on observed research output rather than a coding benchmark.

## Invocation and routing

Generic research does not automatically invoke `offload`. Invoke it when the user asks to offload,
or offer it once when a request has enough fan-out to benefit. For web research, that means at
least two independent evidence angles, a real comparison, or a citation audit. Keep a single
factual lookup local. A declined offer remains declined for the session.

Once invoked, the router uses this order:

1. Honor an explicit mode override.
2. If a requested mutation depends on new external evidence, route to `web-research` first and
   `execution` second.
3. Route a direct file or code mutation with no research prerequisite to `execution`.
4. Route a read-only question answerable from declared local files to `repo-research`.
5. Route a read-only question that needs current or external evidence to `web-research`.
6. Route a question that needs local and external evidence to `web-research` with a scoped
   repository snapshot.

The root skill owns only shared preconditions, this routing decision, mode loading, and the final
cross-mode report contract. It must not duplicate mode procedures.

## Repository layout

The implementation stays inside the existing repository and keeps the package as one skill.

| Path | Responsibility |
|---|---|
| `SKILL.md` | Short trigger and router document, under 500 lines |
| `modes/execution.md` | Existing scout, gate-author, implementer, and diff-review workflow |
| `modes/repo-research.md` | Existing bounded local research and audit workflow |
| `modes/web-research.md` | Standard and deep online research workflow |
| `scripts/make-research-workspace.sh` | Create a disposable run directory and optional scoped repository copy |
| `scripts/collect-provenance.sh` | Build and validate the compact run record from stage artifacts |
| `scripts/cleanup-research-workspace.sh` | Remove successful raw artifacts while retaining final output and provenance |
| `tests/` | High-level shell tests with a fake `agy`, fixtures, and the live smoke procedure |
| `README.md` | Human-facing use, installation, limits, safety correction, and attribution |
| `AGENTS.md` | Maintainer-facing architecture and current worker guarantees |

Do not add a monolithic workflow runner. The orchestrator retains decomposition, source judgment,
deep-trigger judgment, synthesis acceptance, and failure decisions. Shell helpers handle only
temporary directories, copying declared paths, artifact cleanup, schema checks, and provenance
assembly.

Skillshare already tracks the whole repository. Installation must keep using the tracked skill.
The manual installation option must copy the whole skill directory, not only `SKILL.md`.

## Mode contracts

### Execution

Move the current writing workflow into `modes/execution.md` without changing its accepted behavior:

- Scout tentative file ownership.
- Choose one machine or diff gate per writing task.
- Red-check and read machine gates before freezing them.
- Dispatch implementers only from a clean Git working tree.
- Check touched paths, frozen paths, and the selected gate.
- Retry a failed implementer once, then stop that task.

Correct the worker-safety claim throughout the repository. `--mode plan` is a behavioral hint, not
a write barrier. Scouts and reviewers must run from disposable directories or against disposable
repository copies when a write would otherwise reach live files. Never say that `--add-dir` or
plan mode confines a worker.

### Repository research

Move the current bounded local investigation into `modes/repo-research.md`. Preserve its required
assignment fields:

- One bounded question.
- Declared file or directory scope.
- Concrete evidence expectations.
- A rule against modifying files or dispatching nested workers.

Replace plan-mode safety with filesystem isolation. Copy the declared scope into a disposable
workspace, run the worker there, and verify findings against the live repository with read-only
orchestrator commands. Existing priority correction, direct checking of high-priority findings,
sampling of lower-priority findings, and unsupported-claim labeling remain in place.

### Web research

The standard profile dispatches two or three researchers in parallel, then one synthesizer, then
one auditor. Assign each researcher a distinct evidence angle. Overlap is allowed only when it
tests a conflict or the independence of a source.

The deep profile uses no more than five researchers in total. It starts from standard-profile
findings and adds only the angles needed to resolve the trigger. Do not rerun the standard work.
Deep activates when the user asks for it or when one of these conditions appears:

- Material source conflict.
- A costly or hard-to-reverse decision.
- Citation-sensitive output.
- Substantial counterevidence.

Record the trigger in the report and provenance. If no trigger appears, use standard.

Researchers use `gemini-3.7-flash-high`. The synthesizer and auditor use
`gemini-3.1-pro-high`. Keep the split only if the live smoke comparison supports it. Otherwise use
`gemini-3.7-flash-high` for every role and record that decision in the test result and docs.

Every worker gets a 20-minute timeout. A timed-out mandatory stage is incomplete even if other
workers returned useful material.

## Evidence and claim rules

Researchers return claims, not essays. Each finding must identify its evidence angle, the claim,
supporting source URLs, source type, publication or update date when available, conflicts, and
uncertainty. Prefer primary sources. Treat sources that repeat the same upstream report as one
line of evidence.

The synthesizer builds a claim ledger from researcher outputs. It may combine claims only when the
citations support the same proposition. It removes unsupported incidental claims. It retains an
unresolved claim only when it could change the answer or decision, and labels the gap.

The auditor is independent. It receives the proposed synthesis and claim ledger, not the
synthesizer's private reasoning. It opens every citation intended for the final answer and checks:

- The URL resolves to the named source.
- The source supports the nearby claim, either directly or with a stated inference.
- The source date is suitable for a time-sensitive claim.
- The source is primary, secondary, or a repeated derivative.
- Conflicting evidence and material uncertainty remain visible.

The final report calls supported claims `audited`, never `verified`. Repository research may keep
its existing verification vocabulary because the orchestrator can reproduce local evidence.

If the auditor rejects a citation, the synthesizer may remove or narrow the claim and return it for
one audit pass. Do not create an open-ended revision loop. If the second audit still fails, omit an
incidental claim or retain a decision-relevant claim as unresolved.

## Worker isolation

Every research run creates a unique temporary directory outside the live repository. Launch all
researchers, the synthesizer, and the auditor with that directory as their working directory.

For mixed repository and web research:

1. The orchestrator declares the smallest required paths.
2. The workspace helper copies only those paths into a snapshot under the temporary directory.
3. Workers receive the snapshot path, never the live repository path.
4. The orchestrator verifies local claims against the live repository using read-only commands.
5. Cleanup removes the copied repository material after a successful run.

Workers use public web sources by default. Private or authenticated sources require the user's
explicit authorization for that run. Never forward cookies, tokens, browser profiles, environment
credentials, or session data implicitly.

## Stage outputs

Keep schemas in the web-research mode or a disclosed schema resource. Do not embed large JSON
schemas in the root router.

The researcher result contains:

- Stable run and angle identifiers.
- Completion status and failure reason.
- The bounded question and evidence angle.
- Findings with claim text, source records, conflicts, and uncertainty.
- Search gaps and counterevidence.

The synthesizer result contains:

- A claim ledger with decision relevance.
- A proposed answer with claim-level citation references.
- Conflicts, inferences, unresolved claims, and omitted unsupported claims.
- The profile used and any deep trigger.

The auditor result contains:

- One entry for every citation in the proposed final answer.
- Resolve status, support verdict, source classification, independence notes, and date fitness.
- A final status of `pass`, `revise`, or `incomplete`.
- Exact claims that must be removed, narrowed, or marked unresolved.

The compact provenance JSON contains:

- Run identifier, request summary, selected mode, profile, and deep trigger.
- Start time, end time, duration, and scratch path.
- Every worker's role, model, status, duration, and artifact name.
- Declared repository snapshot paths, if any.
- Final citation URLs and audit verdicts.
- Final run status and incomplete-stage reasons.

On success, retain only the final Markdown result and provenance JSON in the scratch directory.
Remove raw worker responses and the repository snapshot. On failure or incomplete status, retain
raw stage artifacts and the snapshot for diagnosis. Do not write research artifacts into the
repository or a global history unless the user asks.

## Failure behavior

Researcher failure may receive one retry with the concrete failure. A missing researcher does not
block synthesis when the remaining evidence still covers at least two independent angles, but the
report must name the missing angle.

Synthesis and audit are mandatory. A crash, timeout, unparsable result, or unresolved audit failure
in either stage changes the run to `partial`. A partial run may return audited claims collected so
far, but it must withhold a firm synthesis or recommendation. State which stage failed and keep the
raw artifacts.

Do not convert worker disagreement into a vote. Resolve conflicts by source quality,
independence, directness, and recency. If those checks do not settle the conflict, keep it
unresolved.

## Research plus implementation

Treat research and mutation as separate phases:

1. Finish the research workflow and its audit.
2. Reduce the result to the final answer, claim ledger, and compact provenance.
3. Use that compact result as an input to `execution`.
4. Apply the existing Git, ownership, frozen-path, and gate checks to implementation.

Do not pass raw research transcripts to implementers. Do not start implementation from a partial
research result unless the user explicitly accepts the named gaps.

## Documentation decisions

Write `SKILL.md`, mode files, schemas, prompts, and `AGENTS.md` for agents using the
`writing-for-agents` rules. Keep shared instructions in the router and branch-specific detail in
the selected mode. The root skill must remain under 500 lines.

Write maintained human-facing documentation in Anthony's voice using `write-like-me`. Apply
`unslop` to all prose. Update README examples and findings so they do not claim plan mode prevents
writes. Add the agreed Asa attribution without a private link.

## Test strategy

Test through the highest public seam: invoke the router and helpers as an orchestrator would. Use a
fake `agy` executable that records arguments and returns fixture JSON. Do not add internal mocking
hooks solely for tests.

### Deterministic acceptance tests

1. An explicit override selects the named mode.
2. A local-only bounded question selects repository research.
3. A current or external question selects web research.
4. A mixed local and external question selects web research and copies only declared repository
   paths.
5. A direct mutation selects execution.
6. A mutation that depends on external evidence completes research and audit before execution.
7. A single factual lookup does not trigger an offload offer.
8. Standard web research dispatches two or three researchers, one synthesizer, and one auditor in
   the required order.
9. Deep research never exceeds five researchers and does not repeat completed standard angles.
10. Each named deep trigger selects deep and appears in provenance.
11. Workers run from a disposable directory and receive no live repository path.
12. A scoped snapshot contains declared paths and excludes undeclared paths.
13. Successful cleanup keeps only the final result and provenance.
14. Failed cleanup retains raw artifacts and the snapshot.
15. Provenance contains every required field and rejects a missing mandatory field.
16. A failed or timed-out synthesizer produces a partial result with no firm recommendation.
17. A failed or timed-out auditor produces a partial result with no firm recommendation.
18. The auditor receives every citation used by the proposed final answer.
19. An unsupported incidental claim disappears from the final result.
20. A decision-relevant unsupported claim remains only as unresolved.
21. Existing execution and repository research fixtures still pass after the files move.
22. Repository text contains no claim that plan mode or `--add-dir` prevents writes.
23. `SKILL.md` remains below 500 lines and every mode pointer resolves.
24. Manual installation instructions copy the whole directory.

### Live smoke comparison

Run one fixed standard-profile web question twice. Use the proposed split for one run and
`gemini-3.7-flash-high` for every role in the other. Record runtime, completed stages, citation
resolution, supported claim count, conflict handling, and uncertainty handling.

Keep the Pro synthesizer and auditor only if the split completes all mandatory stages, does not
regress citation support, and improves synthesis or audit judgment enough to justify its runtime.
This is a recorded maintainer judgment, not a permanent benchmark claim. If the split does not
clear that bar, change the mode and docs to Flash for all roles before release.

## Completion criteria

Implementation is complete when:

- The router and all three mode documents exist and their responsibilities do not overlap.
- Execution and repository research preserve their prior accepted behavior.
- Web research implements standard, deep, synthesis, audit, isolation, and failure contracts.
- No live repository path reaches a research worker.
- No document claims plan mode is a write barrier.
- Deterministic tests pass with the fake `agy`.
- The live smoke comparison is recorded and the shipped model assignment matches its result.
- README and AGENTS match actual behavior and installation.
- Public documentation includes the agreed attribution and no private repository details.
- The final diff contains no copied Asa source, prompts, tests, or documentation.

## Out of scope

- Publishing, vendoring, installing, or linking the private Asa repository.
- Making Asa a runtime dependency.
- Packaging `offload` as a Codex plugin.
- Subagent activity visibility, live dashboards, streaming traces, or chat integrations.
- A general autonomous research daemon or monolithic workflow engine.
- Unbounded research with no question or evidence angles.
- Automatic access to authenticated or private online sources.
- Credential, cookie, or browser-session forwarding.
- Claims that an audited result is true with certainty.
- Permanent storage of successful raw worker transcripts.
- Replacing the orchestrator's judgment with worker votes or a numeric confidence average.
- Changing unrelated execution behavior, hooks, or repository structure.
