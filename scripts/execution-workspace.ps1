#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:MarkerName = '.offload-execution-workspace'
$script:MarkerContent = 'offload-execution-workspace-v2'
$script:GeneratedParentMarkerName = '.offload-execution-parent'
$script:GeneratedParentMarkerContent = 'offload-execution-parent-v1'
$script:ScriptDir = Split-Path -Parent $PSCommandPath
$script:ScopeChecker = Join-Path $script:ScriptDir 'check-execution-scope.ps1'

function Fail([string]$Message, [int]$Code = 1) {
    [Console]::Error.WriteLine("Error: $Message")
    exit $Code
}

function Cleanup-Fail([string]$LeftoverPath, [string]$Message, [int]$Code = 1) {
    [Console]::Error.WriteLine("WARNING: cleanup incomplete; leftover path: $LeftoverPath")
    Fail $Message $Code
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
    if ([string]::IsNullOrEmpty($childPath) -or [string]::IsNullOrEmpty($parentPath)) {
        return $false
    }
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

function Run-Process {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FileName
    $info.WorkingDirectory = $WorkingDirectory
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    foreach ($argument in $Arguments) {
        $info.ArgumentList.Add($argument)
    }

    try {
        $process = [System.Diagnostics.Process]::Start($info)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdout
            Stderr = $stderr
        }
    } catch {
        Fail ("failed to start " + $FileName + ": " + $_.Exception.Message)
    }
}

function Run-Git {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    return Run-Process -FileName 'git' -Arguments $Arguments -WorkingDirectory $WorkingDirectory
}

function Require-GitRepository([string]$Path) {
    $result = Run-Git -WorkingDirectory $Path -Arguments @('rev-parse', '--show-toplevel')
    if ($result.ExitCode -ne 0) {
        Fail ("not a Git repository: " + $Path + " " + $result.Stderr.Trim())
    }
    return Canonicalize-Path $result.Stdout.Trim()
}

function Resolve-Commit([string]$Repository, [string]$Revision) {
    if ([string]::IsNullOrWhiteSpace($Revision)) {
        Fail 'baseline is required'
    }
    $result = Run-Git -WorkingDirectory $Repository -Arguments @('rev-parse', '--verify', ("{0}^{{commit}}" -f $Revision))
    if ($result.ExitCode -ne 0) {
        Fail ("baseline does not resolve to a commit: " + $Revision + " " + $result.Stderr.Trim())
    }
    return $result.Stdout.Trim()
}

function Test-SafeWorkspacePath([string]$Workspace, [string]$SourceRepository) {
    $workspacePath = Canonicalize-Path $Workspace
    if ([string]::IsNullOrWhiteSpace($workspacePath)) {
        Fail 'workspace path is empty'
    }
    Assert-NoReparsePointsInPath $workspacePath

    $root = Canonicalize-Path ([System.IO.Path]::GetPathRoot($workspacePath))
    if (Same-Path $workspacePath $root) {
        Fail ("refusing to use a filesystem root as a workspace: " + $workspacePath)
    }

    $currentPaths = @((Get-Location).Path, [Environment]::CurrentDirectory)
    foreach ($current in $currentPaths) {
        if (-not [string]::IsNullOrWhiteSpace($current) -and (Same-Path $workspacePath $current)) {
            Fail ("refusing to use the current directory as a workspace: " + $workspacePath)
        }
    }

    $homePaths = @($env:USERPROFILE, $env:HOME) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($homePath in $homePaths) {
        if (Same-Path $workspacePath $homePath) {
            Fail ("refusing to use a user home directory as a workspace: " + $workspacePath)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SourceRepository) -and (Path-IsWithin $workspacePath $SourceRepository)) {
        Fail ("workspace must be outside the source repository: " + $workspacePath)
    }
}

function Read-Marker([string]$Workspace) {
    if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
        Fail ("workspace does not exist: " + $Workspace)
    }
    $workspaceItem = Get-Item -LiteralPath $Workspace -Force
    if (($workspaceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail ("refusing to use a reparse point as a workspace: " + $Workspace)
    }
    $marker = Join-Path $Workspace $script:MarkerName
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        Fail ("workspace is not marked as disposable: " + $Workspace)
    }
    $content = [System.IO.File]::ReadAllText($marker).Trim()
    if ($content -ne $script:MarkerContent) {
        Fail ("workspace marker is invalid: " + $Workspace)
    }
}

function Get-RegisteredWorktrees([string]$SourceRepository) {
    $result = Run-Git -WorkingDirectory $SourceRepository -Arguments @('worktree', 'list', '--porcelain')
    if ($result.ExitCode -ne 0) {
        Fail ("could not inspect Git worktrees: " + $result.Stderr.Trim())
    }

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($result.Stdout -split '\r?\n')) {
        if ($line.StartsWith('worktree ')) {
            $paths.Add((Canonicalize-Path $line.Substring('worktree '.Length)))
        }
    }
    return $paths
}

function Require-RegisteredWorktree([string]$SourceRepository, [string]$Workspace) {
    foreach ($path in (Get-RegisteredWorktrees $SourceRepository)) {
        if (Same-Path $path $Workspace) {
            return
        }
    }
    Fail ("workspace is not registered as a worktree of " + $SourceRepository + ": " + $Workspace)
}

function Get-GeneratedParent([string]$Workspace) {
    $parent = Split-Path -Parent $Workspace
    if ([string]::IsNullOrWhiteSpace($parent)) {
        return ''
    }
    $name = Split-Path -Leaf $parent
    if (-not $name.StartsWith('offload-exec-', [System.StringComparison]::Ordinal)) {
        return ''
    }
    $marker = Join-Path $parent $script:GeneratedParentMarkerName
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        return ''
    }
    $markerItem = Get-Item -LiteralPath $marker -Force
    if (($markerItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail ("refusing to use a generated execution parent marker reparse point: " + $parent)
    }
    if ([System.IO.File]::ReadAllText($marker).Trim() -ne $script:GeneratedParentMarkerContent) {
        Fail ("generated execution parent marker is invalid: " + $parent)
    }
    return $parent
}

function Remove-EmptyGeneratedParent([string]$Workspace) {
    $parent = Get-GeneratedParent $Workspace
    if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
        return
    }
    $marker = Join-Path $parent $script:GeneratedParentMarkerName
    $children = @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop | Where-Object { $_.Name -ne $script:GeneratedParentMarkerName })
    if ($children.Count -eq 0) {
        Remove-Item -LiteralPath $marker -Force -ErrorAction Stop
        Remove-Item -LiteralPath $parent -Force -ErrorAction Stop
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

function Cleanup-FailedExecutionCreation([string]$SourcePath, [string]$WorkspacePath, [string]$GeneratedParentPath) {
    if (-not [string]::IsNullOrWhiteSpace($WorkspacePath) -and (Test-Path -LiteralPath $WorkspacePath)) {
        try {
            & git -C $SourcePath worktree remove --force $WorkspacePath 2>$null | Out-Null
        } catch {}
        if (Test-Path -LiteralPath $WorkspacePath) {
            try { Remove-TreeSafely $WorkspacePath } catch {}
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($GeneratedParentPath) -and (Test-Path -LiteralPath $GeneratedParentPath)) {
        try { Remove-TreeSafely $GeneratedParentPath } catch {}
    }

    $leftovers = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @($WorkspacePath, $GeneratedParentPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
        if (Test-Path -LiteralPath $path) { $leftovers.Add($path) }
    }
    if ($leftovers.Count -gt 0) {
        foreach ($path in $leftovers) {
            [Console]::Error.WriteLine("WARNING: cleanup incomplete; leftover path: $path")
        }
    }
}

function Show-Usage {
    [Console]::Error.WriteLine(@'
Usage:
  execution-workspace.ps1 create --source-repo <path> --task-id <id> --baseline <revision> [--workspace <path>]
  execution-workspace.ps1 check --workspace <path> --baseline <revision> --owned <path> [--owned <path> ...] [--frozen <path> ...]
  execution-workspace.ps1 cleanup --source-repo <path> --workspace <path> [--retain]

The create command makes a marked detached Git worktree. The check command
delegates final scope inspection to the generic scope checker. The cleanup
command removes only a marked worktree registered with the source repository.
'@)
}

function Command-Create([string[]]$CommandArgs) {
    $source = ''
    $taskId = ''
    $baseline = ''
    $workspace = ''
    $generatedParent = ''
    $i = 0

    while ($i -lt $CommandArgs.Count) {
        $argument = [string]$CommandArgs[$i]
        switch -Regex ($argument) {
            '^--source-repo$' {
                $i++
                if ($i -ge $CommandArgs.Count) { Fail '--source-repo requires a path' }
                $source = [string]$CommandArgs[$i]
            }
            '^--source-repo=' { $source = $argument.Substring(14) }
            '^--task-id$' {
                $i++
                if ($i -ge $CommandArgs.Count) { Fail '--task-id requires a value' }
                $taskId = [string]$CommandArgs[$i]
            }
            '^--task-id=' { $taskId = $argument.Substring(10) }
            '^--baseline$' {
                $i++
                if ($i -ge $CommandArgs.Count) { Fail '--baseline requires a revision' }
                $baseline = [string]$CommandArgs[$i]
            }
            '^--baseline=' { $baseline = $argument.Substring(11) }
            '^--workspace$' {
                $i++
                if ($i -ge $CommandArgs.Count) { Fail '--workspace requires a path' }
                $workspace = [string]$CommandArgs[$i]
            }
            '^--workspace=' { $workspace = $argument.Substring(12) }
            '^(--help|-h)$' { Show-Usage; exit 0 }
            default { Fail ("unrecognized argument for create: " + $argument) }
        }
        $i++
    }

    if ($env:OFFLOAD_WORKER_CONTEXT -eq '1') {
        Fail 'worker context cannot create or mutate an execution workspace' 126
    }
    if ([string]::IsNullOrWhiteSpace($source)) { Fail '--source-repo is required' }
    if ([string]::IsNullOrWhiteSpace($taskId) -or $taskId -notmatch '^[A-Za-z0-9._-]+$') {
        Fail '--task-id must contain only letters, numbers, dots, underscores, and hyphens'
    }

    $sourcePath = Require-GitRepository (Canonicalize-Path $source)
    $resolvedBaseline = Resolve-Commit $sourcePath $baseline
    if ([string]::IsNullOrWhiteSpace($workspace)) {
        $generatedParent = Join-Path ([System.IO.Path]::GetTempPath()) ("offload-exec-{0}-{1}" -f $taskId, ([Guid]::NewGuid().ToString('N')))
        $workspace = Join-Path $generatedParent 'checkout'
    } else {
        $workspace = Canonicalize-Path $workspace
    }
    Test-SafeWorkspacePath $workspace $sourcePath
    if (Test-Path -LiteralPath $workspace) {
        Fail ("workspace already exists: " + $workspace)
    }

    $parent = Split-Path -Parent $workspace
    try {
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            [System.IO.Directory]::CreateDirectory($parent) | Out-Null
            if (-not [string]::IsNullOrWhiteSpace($generatedParent)) {
                [System.IO.File]::WriteAllText((Join-Path $generatedParent $script:GeneratedParentMarkerName), $script:GeneratedParentMarkerContent + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
            }
        }

        $result = Run-Git -WorkingDirectory $sourcePath -Arguments @('worktree', 'add', '--detach', $workspace, $resolvedBaseline)
        if ($result.ExitCode -ne 0) {
            throw ("could not create execution worktree: " + $workspace + ": " + $result.Stderr.Trim())
        }
        [System.IO.File]::WriteAllText((Join-Path $workspace $script:MarkerName), $script:MarkerContent + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    } catch {
        $creationError = $_.Exception.Message
        Cleanup-FailedExecutionCreation $sourcePath $workspace $generatedParent
        Fail $creationError
    }

    [Console]::Out.WriteLine($workspace)
}

function Command-Check([string[]]$CommandArgs) {
    $workspace = ''
    $baseline = ''
    $owned = [System.Collections.Generic.List[string]]::new()
    $frozen = [System.Collections.Generic.List[string]]::new()
    $i = 0

    while ($i -lt $CommandArgs.Count) {
        $argument = [string]$CommandArgs[$i]
        switch ($argument) {
            '--workspace' {
                $i++
                if ($i -ge $CommandArgs.Count) { Fail '--workspace requires a path' }
                $workspace = [string]$CommandArgs[$i]
            }
            '--baseline' {
                $i++
                if ($i -ge $CommandArgs.Count) { Fail '--baseline requires a revision' }
                $baseline = [string]$CommandArgs[$i]
            }
            '--owned' {
                $i++
                if ($i -ge $CommandArgs.Count) { Fail '--owned requires a path' }
                $owned.Add([string]$CommandArgs[$i])
            }
            '--frozen' {
                $i++
                if ($i -ge $CommandArgs.Count) { Fail '--frozen requires a path' }
                $frozen.Add([string]$CommandArgs[$i])
            }
            { $_ -like '--workspace=*' } { $workspace = $argument.Substring(12) }
            { $_ -like '--baseline=*' } { $baseline = $argument.Substring(11) }
            { $_ -like '--owned=*' } { $owned.Add($argument.Substring(8)) }
            { $_ -like '--frozen=*' } { $frozen.Add($argument.Substring(9)) }
            { $_ -in @('--help', '-h') } { Show-Usage; exit 0 }
            default { Fail ("unrecognized argument for check: " + $argument) }
        }
        $i++
    }

    if ([string]::IsNullOrWhiteSpace($workspace)) { Fail '--workspace is required' }
    if ([string]::IsNullOrWhiteSpace($baseline)) { Fail '--baseline is required' }
    if ($owned.Count -eq 0) { Fail 'at least one --owned path is required' }
    $workspacePath = Canonicalize-Path $workspace
    Read-Marker $workspacePath

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('-NoProfile')
    $arguments.Add('-NonInteractive')
    $arguments.Add('-File')
    $arguments.Add($script:ScopeChecker)
    $arguments.Add('--baseline')
    $arguments.Add($baseline)
    $arguments.Add('--owned')
    $arguments.Add($script:MarkerName)
    foreach ($path in $owned) {
        $arguments.Add('--owned')
        $arguments.Add([string]$path)
    }
    foreach ($path in $frozen) {
        $arguments.Add('--frozen')
        $arguments.Add([string]$path)
    }

    $result = Run-Process -FileName 'pwsh' -Arguments $arguments.ToArray() -WorkingDirectory $workspacePath
    if (-not [string]::IsNullOrEmpty($result.Stdout)) {
        [Console]::Out.Write($result.Stdout)
    }
    if (-not [string]::IsNullOrEmpty($result.Stderr)) {
        [Console]::Error.Write($result.Stderr)
    }
    if ($result.ExitCode -eq 0) {
        Read-Marker $workspacePath
    }
    exit $result.ExitCode
}

function Command-Cleanup([string[]]$CommandArgs) {
    $source = ''
    $workspace = ''
    $retain = $false
    $i = 0

    while ($i -lt $CommandArgs.Count) {
        $argument = [string]$CommandArgs[$i]
        switch ($argument) {
            '--source-repo' {
                $i++
                if ($i -ge $CommandArgs.Count) { Fail '--source-repo requires a path' }
                $source = [string]$CommandArgs[$i]
            }
            '--workspace' {
                $i++
                if ($i -ge $CommandArgs.Count) { Fail '--workspace requires a path' }
                $workspace = [string]$CommandArgs[$i]
            }
            '--retain' { $retain = $true }
            { $_ -like '--source-repo=*' } { $source = $argument.Substring(14) }
            { $_ -like '--workspace=*' } { $workspace = $argument.Substring(12) }
            { $_ -in @('--help', '-h') } { Show-Usage; exit 0 }
            default { Fail ("unrecognized argument for cleanup: " + $argument) }
        }
        $i++
    }

    if ($env:OFFLOAD_WORKER_CONTEXT -eq '1') {
        Fail 'worker context cannot remove an execution workspace' 126
    }
    if ([string]::IsNullOrWhiteSpace($source)) { Fail '--source-repo is required' }
    if ([string]::IsNullOrWhiteSpace($workspace)) { Fail '--workspace is required' }
    $sourcePath = Require-GitRepository (Canonicalize-Path $source)
    $workspacePath = Canonicalize-Path $workspace
    Test-SafeWorkspacePath $workspacePath $sourcePath
    Read-Marker $workspacePath
    Require-RegisteredWorktree $sourcePath $workspacePath
    $generatedParent = Get-GeneratedParent $workspacePath

    if ($retain) {
        [Console]::Out.WriteLine("Retained execution workspace: $workspacePath")
        exit 0
    }

    $result = Run-Git -WorkingDirectory $sourcePath -Arguments @('worktree', 'remove', '--force', $workspacePath)
    if ($result.ExitCode -ne 0) {
        Cleanup-Fail $workspacePath ("could not remove execution worktree; leftover path: " + $workspacePath + ": " + $result.Stderr.Trim())
    }
    if (Test-Path -LiteralPath $workspacePath) {
        try {
            Remove-TreeSafely $workspacePath
        } catch {
            Cleanup-Fail $workspacePath ("could not remove execution worktree; leftover path: " + $workspacePath + ": " + $_.Exception.Message)
        }
    }
    if (Test-Path -LiteralPath $workspacePath) {
        Cleanup-Fail $workspacePath ("cleanup left execution worktree; leftover path: " + $workspacePath)
    }
    Run-Git -WorkingDirectory $sourcePath -Arguments @('worktree', 'prune') | Out-Null
    try {
        Remove-EmptyGeneratedParent $workspacePath
    } catch {
        Cleanup-Fail $generatedParent ("could not remove generated execution workspace parent; leftover path: " + $generatedParent + ": " + $_.Exception.Message)
    }
    if (-not [string]::IsNullOrWhiteSpace($generatedParent) -and (Test-Path -LiteralPath $generatedParent)) {
        Cleanup-Fail $generatedParent ("cleanup left generated execution workspace parent; leftover path: " + $generatedParent)
    }
    [Console]::Out.WriteLine("Removed execution workspace: $workspacePath")
}

if ($args.Count -eq 0) {
    Show-Usage
    exit 1
}

$command = [string]$args[0]
$commandArgs = if ($args.Count -gt 1) { [string[]]$args[1..($args.Count - 1)] } else { @() }

switch ($command) {
    'create' { Command-Create $commandArgs }
    'check' { Command-Check $commandArgs }
    'cleanup' { Command-Cleanup $commandArgs }
    { $_ -in @('--help', '-h') } { Show-Usage; exit 0 }
    default { Fail ("unrecognized command: " + $command + " (expected create, check, or cleanup)") }
}
