#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:TotalTests = 0
function Pass([string]$Name) { [void]($script:TotalTests++); [Console]::Out.WriteLine("ok - $Name") }
function Assert-True([bool]$Condition, [string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; Pass $Name }
function Assert-False([bool]$Condition, [string]$Name) { Assert-True (-not $Condition) $Name }

$root = Split-Path -Parent $PSScriptRoot
$make = Join-Path $root 'scripts/make-research-workspace.ps1'
$cleanup = Join-Path $root 'scripts/cleanup-research-workspace.ps1'
$pwsh = (Get-Command pwsh).Source
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('offload-research-ps-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$repo = Join-Path $tempRoot 'repo'

function Invoke-Script([string]$ScriptPath, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.WorkingDirectory = $tempRoot
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $ScriptPath) + $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

try {
    [IO.Directory]::CreateDirectory((Join-Path $repo 'notes')) | Out-Null
    & git -C $repo init -q
    & git -C $repo config user.name 'Test User'
    & git -C $repo config user.email 'test@example.com'
    [IO.File]::WriteAllText((Join-Path $repo 'notes/brief.md'), "brief source`n")
    [IO.File]::WriteAllText((Join-Path $repo 'notes/extra.md'), "extra source`n")
    & git -C $repo add .
    & git -C $repo commit -q -m initial

    $workspace = Join-Path $tempRoot 'snapshot'
    $created = Invoke-Script $make @('--source-repo', $repo, '--path', 'notes/brief.md', '--workspace', $workspace)
    Assert-True ($created.ExitCode -eq 0) 'research snapshot creation succeeds'
    Assert-True (Test-Path -LiteralPath (Join-Path $workspace '.offload-research-workspace') -PathType Leaf) 'research snapshot has a disposable marker'
    Assert-True (Test-Path -LiteralPath (Join-Path $workspace 'repo/notes/brief.md') -PathType Leaf) 'declared source path is copied'
    Assert-False (Test-Path -LiteralPath (Join-Path $workspace 'repo/notes/extra.md')) 'undeclared source path is not copied'

    $retained = Invoke-Script $cleanup @('--workspace', $workspace, '--retain')
    Assert-True ($retained.ExitCode -eq 0) 'research retain keeps the snapshot'
    Assert-True (Test-Path -LiteralPath $workspace -PathType Container) 'retained research snapshot remains'
    $removed = Invoke-Script $cleanup @('--workspace', $workspace)
    Assert-True ($removed.ExitCode -eq 0) 'research cleanup removes a marked snapshot'
    Assert-False (Test-Path -LiteralPath $workspace) 'removed research snapshot is gone'

    $lockedWorkspace = Join-Path $tempRoot 'locked-snapshot'
    $lockedCreated = Invoke-Script $make @('--source-repo', $repo, '--path', 'notes/brief.md', '--workspace', $lockedWorkspace)
    Assert-True ($lockedCreated.ExitCode -eq 0) 'research snapshot is available for cleanup failure verification'
    $lockedFile = Join-Path $lockedWorkspace 'repo/notes/brief.md'
    $lock = [IO.File]::Open($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $lockedCleanup = Invoke-Script $cleanup @('--workspace', $lockedWorkspace)
        Assert-False ($lockedCleanup.ExitCode -eq 0) 'research cleanup reports a removal failure'
        Assert-True ($lockedCleanup.Stderr.Contains($lockedWorkspace)) 'research cleanup reports the exact leftover workspace path'
    } finally {
        $lock.Dispose()
        if (Test-Path -LiteralPath $lockedWorkspace) {
            Remove-Item -LiteralPath $lockedWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $unmarked = Join-Path $tempRoot 'unmarked'
    [IO.Directory]::CreateDirectory($unmarked) | Out-Null
    $rejected = Invoke-Script $cleanup @('--workspace', $unmarked)
    Assert-False ($rejected.ExitCode -eq 0) 'research cleanup rejects an unmarked directory'
    Assert-True (Test-Path -LiteralPath $unmarked -PathType Container) 'rejected research directory is preserved'

    $bad = Join-Path $tempRoot 'bad'
    $traversal = Invoke-Script $make @('--source-repo', $repo, '--path', '../notes/brief.md', '--workspace', $bad)
    Assert-False ($traversal.ExitCode -eq 0) 'research snapshot rejects traversal paths'
    Assert-False (Test-Path -LiteralPath $bad) 'failed research snapshot leaves no workspace'

    $metadata = Join-Path $tempRoot 'metadata'
    $gitPath = Invoke-Script $make @('--source-repo', $repo, '--path', '.git', '--workspace', $metadata)
    Assert-False ($gitPath.ExitCode -eq 0) 'research snapshot rejects Git metadata'
    Assert-False (Test-Path -LiteralPath $metadata) 'metadata rejection leaves no workspace'

    $inside = Join-Path $repo 'snapshot'
    $insideSource = Invoke-Script $make @('--source-repo', $repo, '--path', 'notes/brief.md', '--workspace', $inside)
    Assert-False ($insideSource.ExitCode -eq 0) 'research snapshot rejects a workspace inside the source'
    Assert-False (Test-Path -LiteralPath $inside) 'source-bound workspace rejection leaves no workspace'

    $sourceAlias = Join-Path $tempRoot 'source-alias'
    New-Item -ItemType Junction -Path $sourceAlias -Target $repo | Out-Null
    $junctionWorkspace = Join-Path $sourceAlias 'snapshot'
    $junction = Invoke-Script $make @('--source-repo', $repo, '--path', 'notes/brief.md', '--workspace', $junctionWorkspace)
    Assert-False ($junction.ExitCode -eq 0) 'research snapshot rejects a workspace under a source junction'
    Assert-False (Test-Path -LiteralPath $junctionWorkspace) 'junction snapshot is not created'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

[Console]::Out.WriteLine("all powershell research workspace checks passed ($($script:TotalTests) tests)")
