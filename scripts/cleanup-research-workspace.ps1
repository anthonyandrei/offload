#!/usr/bin/env pwsh
# scripts/cleanup-research-workspace.ps1
# Cleans up research workspaces while verifying safety markers and preserving outputs.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Show-Usage {
    [Console]::Error.WriteLine("Usage: cleanup-research-workspace.ps1 --workspace <path> --status <success|partial|failed>")
}

function Fail([string]$message, [int]$exitCode = 1) {
    [Console]::Error.WriteLine("Error: $message")
    exit $exitCode
}

$workspace = ""
$status = ""

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    if ($arg -eq '--workspace') {
        $i++
        if ($i -ge $args.Count) {
            Show-Usage
            Fail "--workspace requires a path"
        }
        $workspace = [string]$args[$i]
    } elseif ($arg -eq '--status') {
        $i++
        if ($i -ge $args.Count) {
            Show-Usage
            Fail "--status requires a value"
        }
        $status = [string]$args[$i]
    } elseif ($arg -eq '-h' -or $arg -eq '--help') {
        Show-Usage
        exit 0
    } else {
        Show-Usage
        Fail "unrecognized argument: $arg"
    }
    $i++
}

if ([string]::IsNullOrWhiteSpace($workspace) -or [string]::IsNullOrWhiteSpace($status)) {
    Show-Usage
    Fail "--workspace and --status are required"
}

if ($status -notin @('success', 'partial', 'failed')) {
    Fail "invalid status: $status (must be success, partial, or failed)"
}

if (-not (Test-Path -LiteralPath $workspace -PathType Container)) {
    Fail "workspace directory does not exist: $workspace"
}

$canonicalWs = [System.IO.Path]::GetFullPath($workspace)
$trimmedWs = $canonicalWs.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

# Reject filesystem root
$pathRoot = [System.IO.Path]::GetPathRoot($canonicalWs)
$trimmedRoot = $pathRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
if ([string]::Equals($trimmedWs, $trimmedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or [string]::IsNullOrEmpty($trimmedWs)) {
    Fail "unsafe workspace path (filesystem root): $canonicalWs"
}

# Reject process current directory
$pwshCwd = [System.IO.Path]::GetFullPath((Get-Location).Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
if ([string]::Equals($trimmedWs, $pwshCwd, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "unsafe workspace path (process current directory): $canonicalWs"
}
$envCwd = [System.IO.Path]::GetFullPath([System.Environment]::CurrentDirectory).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
if ([string]::Equals($trimmedWs, $envCwd, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "unsafe workspace path (process current directory): $canonicalWs"
}

# Reject user home directory
$homeDirs = @($env:USERPROFILE, $env:HOME) | Where-Object { -not [string]::IsNullOrEmpty($_) }
foreach ($h in $homeDirs) {
    $canonH = [System.IO.Path]::GetFullPath($h).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if ([string]::Equals($trimmedWs, $canonH, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "unsafe workspace path (user home directory): $canonicalWs"
    }
}

# Reject Git worktree root
$gitPath = [System.IO.Path]::Combine($canonicalWs, '.git')
if ([System.IO.Directory]::Exists($gitPath) -or [System.IO.File]::Exists($gitPath)) {
    Fail "unsafe workspace path (git worktree root): $canonicalWs"
}

# Reject unmarked directory or invalid marker version
$markerFile = [System.IO.Path]::Combine($canonicalWs, '.offload-research-workspace')
if (-not [System.IO.File]::Exists($markerFile)) {
    Fail "directory lacks offload workspace marker: $canonicalWs"
}

$markerRaw = [System.IO.File]::ReadAllText($markerFile, [System.Text.Encoding]::UTF8)
if ($markerRaw.Trim() -ne 'offload-research-workspace-v1') {
    Fail "invalid workspace marker version: $canonicalWs"
}

# Cleanup according to status
if ($status -eq 'success') {
    $entries = [System.IO.Directory]::GetFileSystemEntries($canonicalWs)
    foreach ($entry in $entries) {
        $baseName = [System.IO.Path]::GetFileName($entry)
        if ($baseName -in @('final.md', 'provenance.json', '.offload-research-workspace')) {
            continue
        }

        # Safe removal without following links out of the workspace
        if ([System.IO.Directory]::Exists($entry)) {
            $attr = [System.IO.File]::GetAttributes($entry)
            if ($attr.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                [System.IO.Directory]::Delete($entry, $false)
            } else {
                # Clear any read-only attributes
                foreach ($file in [System.IO.Directory]::GetFiles($entry, "*", [System.IO.SearchOption]::AllDirectories)) {
                    $fAttr = [System.IO.File]::GetAttributes($file)
                    if ($fAttr.HasFlag([System.IO.FileAttributes]::ReadOnly)) {
                        [System.IO.File]::SetAttributes($file, [System.IO.FileAttributes]::Normal)
                    }
                }
                [System.IO.Directory]::Delete($entry, $true)
            }
        } elseif ([System.IO.File]::Exists($entry)) {
            $fAttr = [System.IO.File]::GetAttributes($entry)
            if ($fAttr.HasFlag([System.IO.FileAttributes]::ReadOnly)) {
                [System.IO.File]::SetAttributes($entry, [System.IO.FileAttributes]::Normal)
            }
            [System.IO.File]::Delete($entry)
        }
    }
}

exit 0
