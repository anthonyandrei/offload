---
status: accepted
---

# Centralize execution scope checks

Execution ownership and frozen-path verification will move from inline shell pipelines into paired `check-execution-scope.sh` and `check-execution-scope.ps1` helpers. Both helpers discover tracked and untracked changes through Git, compare them with repeated `--owned` and `--frozen` arguments, print violations, and return a nonzero exit code on failure. This removes the workflow's dependency on `awk`, `sort`, and `comm` and gives CI one contract to test across shells.
