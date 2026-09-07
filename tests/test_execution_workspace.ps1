#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:TotalTests = 0
function Pass([string]$Name) { [void]($script:TotalTests++); [Console]::Out.WriteLine("ok - $Name") }
function Assert-True([bool]$Condition, [string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; Pass $Name }
function Assert-False([bool]$Condition, [string]$Name) { Assert-True (-not $Condition) $Name }

$root = Split-Path -Parent $PSScriptRoot
$helper = Join-Path $root 'scripts/execution-workspace.ps1'
$pwsh = (Get-Command pwsh).Source
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('offload-exec-ps-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$repo = Join-Path $tempRoot 'repo'
$workspace = Join-Path $tempRoot 'checkout'

function Invoke-Helper([string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.WorkingDirectory = $tempRoot
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $helper) + $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

try {
    [IO.Directory]::CreateDirectory($repo) | Out-Null
    & git -C $repo init -q
    & git -C $repo config user.name 'Test User'
    & git -C $repo config user.email 'test@example.com'
    [IO.File]::WriteAllText((Join-Path $repo 'owned.txt'), "owned`n")
    [IO.File]::WriteAllText((Join-Path $repo 'unowned.txt'), "unowned`n")
    & git -C $repo add .
    & git -C $repo commit -q -m initial
    $baseline = (& git -C $repo rev-parse HEAD).Trim()

    $created = Invoke-Helper @('create', '--source-repo', $repo, '--task-id', 'acceptance', '--baseline', $baseline, '--workspace', $workspace)
    Assert-True ($created.ExitCode -eq 0) 'create makes a worktree'
    Assert-True (Test-Path -LiteralPath $workspace -PathType Container) 'workspace exists'
    Assert-True (Test-Path -LiteralPath (Join-Path $workspace '.offload-execution-workspace') -PathType Leaf) 'workspace has a disposable marker'
    $registered = (& git -C $repo worktree list --porcelain) -join "`n"
    $workspaceSlashPath = $workspace.Replace([IO.Path]::DirectorySeparatorChar, '/')
    Assert-True ($registered.Contains($workspace) -or $registered.Contains($workspaceSlashPath)) 'workspace is registered with Git'

    [IO.File]::WriteAllText((Join-Path $workspace 'owned.txt'), "owned changed`n")
    $owned = Invoke-Helper @('check', '--workspace', $workspace, '--baseline', $baseline, '--owned', 'owned.txt')
    Assert-True ($owned.ExitCode -eq 0) 'owned worktree change passes scope check'

    [IO.File]::WriteAllText((Join-Path $workspace 'unowned.txt'), "unowned changed`n")
    $unowned = Invoke-Helper @('check', '--workspace', $workspace, '--baseline', $baseline, '--owned', 'owned.txt')
    Assert-False ($unowned.ExitCode -eq 0) 'unowned worktree change fails scope check'

    [IO.File]::WriteAllText((Join-Path $workspace 'unowned.txt'), "unowned`n")
    $retained = Invoke-Helper @('cleanup', '--source-repo', $repo, '--workspace', $workspace, '--retain')
    Assert-True ($retained.ExitCode -eq 0) 'retain leaves a valid workspace in place'
    Assert-True (Test-Path -LiteralPath $workspace -PathType Container) 'retained workspace remains available for review'

    $cleaned = Invoke-Helper @('cleanup', '--source-repo', $repo, '--workspace', $workspace)
    Assert-True ($cleaned.ExitCode -eq 0) 'cleanup removes a marked registered worktree'
    Assert-False (Test-Path -LiteralPath $workspace) 'cleaned workspace is gone'

    $unmarked = Join-Path $tempRoot 'unmarked'
    [IO.Directory]::CreateDirectory($unmarked) | Out-Null
    $rejected = Invoke-Helper @('cleanup', '--source-repo', $repo, '--workspace', $unmarked)
    Assert-False ($rejected.ExitCode -eq 0) 'cleanup rejects an unmarked directory'
    Assert-True (Test-Path -LiteralPath $unmarked -PathType Container) 'rejected directory is preserved'

    $sourceAlias = Join-Path $tempRoot 'source-alias'
    New-Item -ItemType Junction -Path $sourceAlias -Target $repo | Out-Null
    $junctionWorkspace = Join-Path $sourceAlias 'checkout'
    $junction = Invoke-Helper @('create', '--source-repo', $repo, '--task-id', 'junction', '--baseline', $baseline, '--workspace', $junctionWorkspace)
    Assert-False ($junction.ExitCode -eq 0) 'create rejects a workspace under a source junction'
    Assert-False (Test-Path -LiteralPath $junctionWorkspace) 'junction workspace is not created'
} finally {
    if ((Test-Path -LiteralPath $repo -PathType Container) -and (Test-Path -LiteralPath $workspace -PathType Container)) {
        & git -C $repo worktree remove --force $workspace 2>$null
    }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

[Console]::Out.WriteLine("all powershell execution workspace checks passed ($($script:TotalTests) tests)")
