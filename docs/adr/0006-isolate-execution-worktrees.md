---
status: accepted
---

# Isolate execution worktrees

Execution tasks will run inside dedicated, disposable Git worktrees created from a declared baseline revision rather than sharing the caller's working directory. An orchestrator-owned manifest stored outside the worker checkout tracks task identity, absolute paths, baseline revision, owned paths, and frozen paths.

## Context

Running multiple concurrent writers in a single working tree causes scope check collisions, race conditions, and unverified commits. Review finding F-02 identified that per-worker ownership cannot be checked reliably while writers share one checkout.

## Decision

Offload will introduce paired shell-native execution-workspace helpers with four lifecycle verbs:

1. `create`: Creates an isolated Git worktree (`git worktree add --detach`) at the specified baseline revision, places an `.offload-execution-workspace` marker file, and writes a manifest JSON file outside the worker checkout.
2. `verify-export`: Verifies the worker checkout against the manifest's baseline, owned paths, and frozen paths via `check-execution-scope`. If verified, stages all committed and uncommitted changes, exports a binary patch against the baseline, computes and records a SHA-256 content digest, and marks the manifest exported. Scope violations block export.
3. `integrate`: Verifies the patch artifact's SHA-256 digest against the manifest, preflights the changes inside a disposable integration worktree without mutating the caller checkout, detects conflicts, and publishes verified changes to the destination repository only after preflight passes. Failed integration retains candidate worktrees and artifacts without partial publishing.
4. `cleanup`: Verifies that the target directory is a manifest-owned execution worktree containing the workspace marker, is registered as a worktree of the source repository, and is not the process current directory, repository root, home, or filesystem root. Safe worktrees are removed and pruned.

## Consequences

- Implementers and gate authors can run independently without cross-contaminating working trees.
- Candidate verification occurs against isolated state before any change reaches the integration branch or caller repository.
- Untrusted worker processes have no access to orchestrator metadata because the manifest lives outside their checkout.
- Parity is maintained between Bash 3.2+ and PowerShell 7+ without introducing external dependencies beyond Git.
