---
status: accepted
---

# Mark workspaces before cleanup

Each research workspace creator will write an Offload marker inside the new directory. Cleanup will refuse to remove workspace contents unless that marker exists, in addition to rejecting root, home, current, and repository paths. This changes the Bash and PowerShell helper contract together so native platform support does not reproduce the current broad deletion target.
