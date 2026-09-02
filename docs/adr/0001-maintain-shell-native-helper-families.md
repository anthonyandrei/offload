---
status: accepted
---

# Maintain shell-native helper families

Offload will maintain Bash 3.2+ and PowerShell 7+ helper families with matching command contracts instead of replacing the helpers with a shared runtime or adding an operating-system-detecting launcher. Orchestrators select the family for their current shell, not their operating system. Contract tests enforce equivalent behavior. This keeps native Windows workflows independent of WSL, Git Bash, Python, and `jq`, at the cost of maintaining two implementations.

## Consequences

All documented workflows, including execution and research, must have native commands for both supported shells. The PowerShell launcher resolves `agy` from `AGY_BIN`, then `Get-Command agy`, then `%USERPROFILE%\.local\bin\agy.exe`; an invalid explicit `AGY_BIN` fails without fallback. Documentation selects helpers by host shell. CI runs both helper families and treats behavior drift as a failure.
