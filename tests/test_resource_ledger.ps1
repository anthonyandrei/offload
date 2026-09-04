#!/usr/bin/env pwsh
# tests/test_resource_ledger.ps1
# Focused acceptance tests for the durable resource ledger and reconciliation.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:TotalTests = 0
function Pass([string]$name) { $script:TotalTests++; [Console]::Out.WriteLine("ok - $name") }
function Fail([string]$name, [string]$reason = '') { $script:TotalTests++; [Console]::Error.WriteLine("FAIL: $name - $reason"); exit 1 }
function Assert-True([bool]$value, [string]$name, [string]$reason = '') { if ($value) { Pass $name } else { $failure = if ($reason) { $reason } else { 'condition was false' }; Fail $name $failure } }
function Assert-False([bool]$value, [string]$name, [string]$reason = '') { $failure = if ($reason) { $reason } else { 'condition was true' }; Assert-True (-not $value) $name $failure }
function Assert-Equal($actual, $expected, [string]$name) { if ($actual -eq $expected) { Pass $name } else { Fail $name "expected '$expected', got '$actual'" } }
function Assert-NotEqual($actual, $expected, [string]$name) { if ($actual -ne $expected) { Pass $name } else { Fail $name "expected a value other than '$expected'" } }

$ledgerScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/resource-ledger.ps1'
$pwsh = (Get-Command pwsh).Source
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('offload-test-ledger-ps-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpRoot | Out-Null

function Invoke-Ledger([string[]]$Arguments) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwsh; $psi.WorkingDirectory = $tmpRoot; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.ArgumentList.Add('-NoProfile'); $psi.ArgumentList.Add('-NonInteractive'); $psi.ArgumentList.Add('-File'); $psi.ArgumentList.Add($ledgerScript)
    foreach ($argument in $Arguments) { $psi.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd(); $stderr = $process.StandardError.ReadToEnd(); $process.WaitForExit()
    [PSCustomObject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Init-Repo([string]$path) {
    New-Item -ItemType Directory -Path $path | Out-Null
    & git -C $path init -q; & git -C $path config user.name Test; & git -C $path config user.email test@example.com
    Set-Content -LiteralPath (Join-Path $path 'tracked.txt') -Value 'base'
    & git -C $path add .; & git -C $path commit -q -m init
}

try {
    $ledger = Join-Path $tmpRoot 'ledger.json'
    $resource = Join-Path $tmpRoot 'owned'
    New-Item -ItemType Directory -Path $resource | Out-Null
    Set-Content -LiteralPath (Join-Path $resource '.owner') -Value 'owned-v1' -NoNewline

    $result = Invoke-Ledger @('init', '--ledger', $ledger)
    Assert-Equal $result.ExitCode 0 'ledger initializes'
    $result = Invoke-Ledger @('register', '--ledger', $ledger, '--assignment-id', 'a1', '--parent-id', 'orchestrator', '--resource-type', 'directory', '--path', $resource, '--owner-marker', '.owner=owned-v1', '--resource-id', 'dir:1', '--state', 'active')
    Assert-Equal $result.ExitCode 0 'resource registers before cleanup'
    $record = (Get-Content -LiteralPath $ledger -Raw | ConvertFrom-Json).resources[0]
    Assert-Equal $record.assignment_id 'a1' 'record stores assignment identity'
    Assert-Equal $record.parent_id 'orchestrator' 'record stores parent identity'
    Assert-Equal $record.resource_type 'directory' 'record stores resource type'
    Assert-True ([IO.Path]::IsPathFullyQualified($record.path)) 'record stores absolute path'
    Assert-Equal $record.owner_marker.name '.owner' 'record stores owner marker'
    Assert-True (-not [string]::IsNullOrWhiteSpace($record.created_at)) 'record stores creation timestamp'

    $result = Invoke-Ledger @('cleanup', '--ledger', $ledger, '--resource-id', 'dir:1')
    Assert-Equal $result.ExitCode 0 'owned directory cleanup succeeds'
    Assert-False (Test-Path -LiteralPath $resource) 'owned directory is removed'
    $result = Invoke-Ledger @('cleanup', '--ledger', $ledger, '--resource-id', 'dir:1')
    $repeat = $result.Stdout | ConvertFrom-Json
    Assert-Equal $repeat.state 'removed' 'repeat cleanup is idempotent'

    $retained = Join-Path $tmpRoot 'retained'
    New-Item -ItemType Directory -Path $retained | Out-Null
    Set-Content -LiteralPath (Join-Path $retained '.owner') -Value 'different' -NoNewline
    Invoke-Ledger @('register', '--ledger', $ledger, '--assignment-id', 'a2', '--parent-id', 'orchestrator', '--resource-type', 'directory', '--path', $retained, '--owner-marker', '.owner=owned-v1', '--resource-id', 'dir:2', '--state', 'active') | Out-Null
    $result = Invoke-Ledger @('cleanup', '--ledger', $ledger, '--resource-id', 'dir:2')
    $classification = $result.Stdout | ConvertFrom-Json
    Assert-True ($classification.retained -eq $true) 'unowned directory is retained'
    Assert-Equal $classification.state 'unknown' 'unowned directory is classified unknown'
    Assert-True (Test-Path -LiteralPath $retained) 'unowned evidence remains on disk'

    $process = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30') -PassThru -WindowStyle Hidden
    try {
        $start = $process.StartTime.ToUniversalTime().ToString('o')
        Invoke-Ledger @('register', '--ledger', $ledger, '--assignment-id', 'a3', '--parent-id', 'orchestrator', '--resource-type', 'worker-process', '--process-id', "$($process.Id)", '--process-start-time', $start, '--owner-marker', 'agy-worker=agy-worker-v1', '--resource-id', 'worker:3', '--state', 'active') | Out-Null
        $processRecord = @((Get-Content -LiteralPath $ledger -Raw | ConvertFrom-Json).resources | Where-Object { $_.resource_id -eq 'worker:3' })[0]
        Assert-True (-not [string]::IsNullOrWhiteSpace($processRecord.process_identity.start_time)) 'process record stores process start timestamp'
        $result = Invoke-Ledger @('cleanup', '--ledger', $ledger, '--resource-id', 'worker:3')
        $classification = $result.Stdout | ConvertFrom-Json
        Assert-True ($classification.removed -eq $true) 'owned worker process cleanup succeeds'
        $null = $process.WaitForExit(10000)
        $process.Refresh()
        Assert-True $process.HasExited 'worker process is terminated before cleanup completes'
    } finally { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() } }

    $repo = Join-Path $tmpRoot 'repo'; Init-Repo $repo
    $baseline = (git -C $repo rev-parse HEAD).Trim()
    $unknownWorktree = Join-Path $tmpRoot 'unknown-worktree'
    & git -C $repo worktree add --detach $unknownWorktree $baseline | Out-Null
    try {
        $result = Invoke-Ledger @('reconcile', '--ledger', $ledger, '--source-repo', $repo)
        Assert-Equal $result.ExitCode 0 'reconciliation completes'
        $unknown = @((Get-Content -LiteralPath $ledger -Raw | ConvertFrom-Json).resources | Where-Object { $_.assignment_id -eq 'unknown' })
        Assert-Equal $unknown.Count 1 'reconciliation records unknown worktree'
        Assert-Equal $unknown[0].state 'unknown' 'unknown worktree is retained for review'
        Assert-True (Test-Path -LiteralPath $unknownWorktree) 'unknown worktree remains on disk'
    } finally { & git -C $repo worktree remove --force $unknownWorktree | Out-Null; & git -C $repo worktree prune | Out-Null }

    $badLedger = Join-Path $resource 'ledger.json'
    $result = Invoke-Ledger @('register', '--ledger', $badLedger, '--assignment-id', 'a4', '--parent-id', 'orchestrator', '--resource-type', 'directory', '--path', $resource, '--owner-marker', '.owner=owned-v1')
    Assert-NotEqual $result.ExitCode 0 'ledger inside resource is rejected'
    [Console]::Out.WriteLine("all resource ledger powershell tests passed ($($script:TotalTests) tests)")
} finally {
    if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
