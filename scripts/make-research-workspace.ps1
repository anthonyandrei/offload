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

function Path-IsWithin([string]$Child, [string]$Parent) {
    $childPath = Canonicalize-Path $Child
    $parentPath = Canonicalize-Path $Parent
    if (Same-Path $childPath $parentPath) {
        return $true
    }
    $prefix = $parentPath.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
    return $childPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePointsInPath([string]$Path) {
    $probe = Canonicalize-Path $Path
    while (-not [string]::IsNullOrWhiteSpace($probe)) {
        if (Test-Path -LiteralPath $probe) {
            $item = Get-Item -LiteralPath $probe -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail ("refusing to use a path containing a reparse point: " + $probe)
            }
        }
        $parent = [System.IO.Directory]::GetParent($probe)
        if ($null -eq $parent) {
            break
        }
        $probe = $parent.FullName
    }
}

function Test-SafeWorkspacePath([string]$Workspace, [string]$Source) {
    $workspacePath = Canonicalize-Path $Workspace
    Assert-NoReparsePointsInPath $workspacePath
    $root = Canonicalize-Path ([System.IO.Path]::GetPathRoot($workspacePath))
    if (Same-Path $workspacePath $root) {
        Fail ("refusing to use a filesystem root: " + $workspacePath)
    }

    foreach ($current in @((Get-Location).Path, [Environment]::CurrentDirectory)) {
        if (-not [string]::IsNullOrWhiteSpace($current) -and (Same-Path $workspacePath $current)) {
            Fail ("refusing to use the current directory: " + $workspacePath)
        }
    }
    foreach ($homePath in @($env:USERPROFILE, $env:HOME) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
        if (Same-Path $workspacePath $homePath) {
            Fail ("refusing to use a user home directory: " + $workspacePath)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Source) -and (Path-IsWithin $workspacePath $Source)) {
        Fail ("research workspace must be outside the source directory: " + $workspacePath)
    }
}

function Normalize-RelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Fail 'research path cannot be empty'
    }
    if ([System.IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('/') -or $Path.StartsWith('\')) {
        Fail ("research path must be relative: " + $Path)
    }

    $parts = $Path.Replace('\', '/').Split('/')
    $clean = [System.Collections.Generic.List[string]]::new()
    foreach ($part in $parts) {
        if ([string]::IsNullOrEmpty($part) -or $part -eq '.') {
            continue
        }
        if ($part -eq '..') {
            Fail ("research path escapes the source directory: " + $Path)
        }
        if ($part -eq '.git') {
            Fail 'research snapshots cannot include Git metadata'
        }
        $clean.Add($part)
    }
    if ($clean.Count -eq 0) {
        Fail ("research path resolves to the source directory: " + $Path)
    }
    return ($clean -join '/')
}

function Assert-NoReparsePoints([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail ("research snapshots cannot copy links or reparse points: " + $Path)
    }
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $Path -Force -Recurse) {
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail ("research snapshots cannot copy links or reparse points: " + $child.FullName)
            }
        }
    }
}

function Remove-TreeSafely([string]$Path) {
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
        } elseif ($item.PSIsContainer) {
            Remove-TreeSafely $item.FullName
        } else {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
        }
    }
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
}

function Show-Usage {
    [Console]::Error.WriteLine(@'
Usage:
  make-research-workspace.ps1 --source-repo <path> --path <relative-path> [--path <relative-path> ...] [--workspace <path>]

The helper copies only the declared source paths into a marked disposable
snapshot under the workspace's repo directory.
'@)
}

$source = ''
$workspace = ''
$paths = [System.Collections.Generic.List[string]]::new()
$i = 0
while ($i -lt $args.Count) {
    $argument = [string]$args[$i]
    switch ($argument) {
        '--source-repo' {
            $i++
            if ($i -ge $args.Count) { Fail '--source-repo requires a path' }
            $source = [string]$args[$i]
        }
        '--path' {
            $i++
            if ($i -ge $args.Count) { Fail '--path requires a relative path' }
            $paths.Add([string]$args[$i])
        }
        '--workspace' {
            $i++
            if ($i -ge $args.Count) { Fail '--workspace requires a path' }
            $workspace = [string]$args[$i]
        }
        { $_ -like '--source-repo=*' } { $source = $argument.Substring(14) }
        { $_ -like '--path=*' } { $paths.Add($argument.Substring(7)) }
        { $_ -like '--workspace=*' } { $workspace = $argument.Substring(12) }
        { $_ -in @('--help', '-h') } { Show-Usage; exit 0 }
        default { Fail ("unrecognized argument: " + $argument) }
    }
    $i++
}

if ($env:OFFLOAD_WORKER_CONTEXT -eq '1') {
    Fail 'worker context cannot create a research snapshot' 126
}
if ([string]::IsNullOrWhiteSpace($source)) { Fail '--source-repo is required' }
if ($paths.Count -eq 0) { Fail 'at least one --path is required' }

$sourcePath = Canonicalize-Path $source
if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
    Fail ("source directory does not exist: " + $sourcePath)
}
$gitCheck = & git -C $sourcePath rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0) {
    Fail ("source directory is not a Git repository: " + $sourcePath)
}
$sourcePath = Canonicalize-Path ([string]$gitCheck.Trim())

$relativePaths = [System.Collections.Generic.List[string]]::new()
foreach ($rawPath in $paths) {
    $relativePath = Normalize-RelativePath $rawPath
    $sourceItemPath = Join-Path $sourcePath ($relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $sourceItemPath)) {
        Fail ("declared research path does not exist: " + $rawPath)
    }
    Assert-NoReparsePoints $sourceItemPath
    [void]$relativePaths.Add($relativePath)
}

if ([string]::IsNullOrWhiteSpace($workspace)) {
    $workspace = Join-Path ([System.IO.Path]::GetTempPath()) ("offload-research-" + [Guid]::NewGuid().ToString('N'))
} else {
    $workspace = Canonicalize-Path $workspace
}
Test-SafeWorkspacePath $workspace $sourcePath
if (Test-Path -LiteralPath $workspace) {
    Fail ("workspace already exists: " + $workspace)
}
try {
    [System.IO.Directory]::CreateDirectory($workspace) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $workspace $script:MarkerName), $script:MarkerContent + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $repoRoot = Join-Path $workspace 'repo'
    foreach ($relativePath in $relativePaths) {
        $sourceItemPath = Join-Path $sourcePath ($relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        $destinationPath = Join-Path $repoRoot ($relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        $destinationParent = Split-Path -Parent $destinationPath
        [System.IO.Directory]::CreateDirectory($destinationParent) | Out-Null
        $sourceItem = Get-Item -LiteralPath $sourceItemPath -Force
       if ($sourceItem.PSIsContainer) {
           [System.IO.Directory]::CreateDirectory($destinationPath) | Out-Null
            foreach ($child in Get-ChildItem -LiteralPath $sourceItemPath -Force) {
                Copy-Item -LiteralPath $child.FullName -Destination $destinationPath -Recurse -Force
            }
       } else {
            Copy-Item -LiteralPath $sourceItemPath -Destination $destinationPath -Force
        }
    }
} catch {
    $creationError = $_.Exception.Message
    $cleanupIncomplete = $false
    if (Test-Path -LiteralPath $workspace) {
        try { Remove-TreeSafely $workspace } catch { $cleanupIncomplete = $true }
        if (Test-Path -LiteralPath $workspace) { $cleanupIncomplete = $true }
    }
    if ($cleanupIncomplete) {
        [Console]::Error.WriteLine("WARNING: cleanup incomplete; leftover path: $workspace")
    }
    if ($creationError.StartsWith('Error:')) {
        [Console]::Error.WriteLine($creationError)
    } else {
        [Console]::Error.WriteLine("Error: could not create research snapshot: " + $creationError)
    }
    exit 1
}

[Console]::Out.WriteLine($workspace)
