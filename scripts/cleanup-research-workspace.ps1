#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:MarkerName = '.offload-research-workspace'
$script:MarkerContent = 'offload-research-workspace-v2'

function Fail([string]$Message, [int]$Code = 1) {
    [Console]::Error.WriteLine("Error: $Message")
    exit $Code
}

function Canonicalize-Path([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::Equals($full, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $root
    }
    return $full.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
}

function Same-Path([string]$Left, [string]$Right) {
    return [string]::Equals((Canonicalize-Path $Left), (Canonicalize-Path $Right), [System.StringComparison]::OrdinalIgnoreCase)
}

function Read-Marker([string]$Workspace) {
    if ((Get-Item -LiteralPath $Workspace -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        Fail ("refusing to clean a reparse point: " + $Workspace)
    }
    $marker = Join-Path $Workspace $script:MarkerName
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        Fail ("refusing to clean an unmarked directory: " + $Workspace)
    }
    $content = [System.IO.File]::ReadAllText($marker).Trim()
    if ($content -ne $script:MarkerContent) {
        Fail ("refusing to clean a directory with an invalid marker: " + $Workspace)
    }
    if (Test-Path -LiteralPath (Join-Path $Workspace '.git')) {
        Fail ("refusing to clean a Git checkout: " + $Workspace)
    }
}

function Remove-TreeSafely([string]$Path) {
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force)) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Remove-Item -LiteralPath $item.FullName -Force
        } elseif ($item.PSIsContainer) {
            Remove-TreeSafely $item.FullName
        } else {
            Remove-Item -LiteralPath $item.FullName -Force
        }
    }
    Remove-Item -LiteralPath $Path -Force
}

function Show-Usage {
    [Console]::Error.WriteLine(@'
Usage:
  cleanup-research-workspace.ps1 --workspace <path> [--retain]

Only a marked disposable snapshot can be removed. Reparse points are
removed as links and are never traversed.
'@)
}

if ($args.Count -eq 0) {
    Show-Usage
    exit 1
}

$workspace = ''
$retained = $false
$i = 0
while ($i -lt $args.Count) {
    $argument = [string]$args[$i]
    switch ($argument) {
        '--workspace' {
            $i++
            if ($i -ge $args.Count) { Fail '--workspace requires a path' }
            $workspace = [string]$args[$i]
        }
        { $_ -like '--workspace=*' } { $workspace = $argument.Substring(12) }
        '--retain' { $retained = $true }
        { $_ -in @('--help', '-h') } { Show-Usage; exit 0 }
        default { Fail ("unrecognized argument: " + $argument) }
    }
    $i++
}

if ($env:OFFLOAD_WORKER_CONTEXT -eq '1') {
    Fail 'worker context cannot remove a research snapshot' 126
}
if ([string]::IsNullOrWhiteSpace($workspace)) {
    Fail '--workspace is required'
}
$workspacePath = Canonicalize-Path $workspace
$root = Canonicalize-Path ([System.IO.Path]::GetPathRoot($workspacePath))
if (Same-Path $workspacePath $root) {
    Fail ("refusing to clean a filesystem root: " + $workspacePath)
}
foreach ($current in @((Get-Location).Path, [Environment]::CurrentDirectory)) {
    if (-not [string]::IsNullOrWhiteSpace($current) -and (Same-Path $workspacePath $current)) {
        Fail ("refusing to clean the current directory: " + $workspacePath)
    }
}
foreach ($homePath in @($env:USERPROFILE, $env:HOME) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
    if (Same-Path $workspacePath $homePath) {
        Fail ("refusing to clean a user home directory: " + $workspacePath)
    }
}
if (-not (Test-Path -LiteralPath $workspacePath -PathType Container)) {
    Fail ("workspace does not exist: " + $workspacePath)
}
Read-Marker $workspacePath

if ($retained) {
    [Console]::Out.WriteLine("Retained research workspace: $workspacePath")
    exit 0
}

Remove-TreeSafely $workspacePath
[Console]::Out.WriteLine("Removed research workspace: $workspacePath")
