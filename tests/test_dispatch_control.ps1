#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw "FAIL: $message" }
    [Console]::Out.WriteLine("ok - $message")
}

$root = Split-Path -Parent $PSScriptRoot
$dispatch = Join-Path $root 'scripts/dispatch-worker.ps1'
$workspaceHelper = Join-Path $root 'scripts/execution-workspace.ps1'
$pwsh = (Get-Command pwsh).Source
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "offload-dispatch-$([guid]::NewGuid().ToString('N'))"
[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null

try {
    $fakeAgy = Join-Path $tempRoot 'fake-agy.ps1'
    @'
$nestedOutput = Join-Path $env:DISPATCH_TEST_ROOT 'nested.json'
$nestedError = Join-Path $env:DISPATCH_TEST_ROOT 'nested.err'
& $env:PWsh_BIN -NoProfile -File $env:DISPATCH_SCRIPT `
    --state $env:DISPATCH_STATE `
    --assignment-id nested-worker `
    --parent-assignment-id root-worker `
    --role scout `
    --source-repo $env:DISPATCH_SOURCE_REPO `
    --baseline $env:DISPATCH_BASELINE `
    --owned README.md `
    --output $nestedOutput `
    --error $nestedError `
    --timeout-seconds 10 `
    --resource-units 1 `
    -- -p 'nested attempt'
$nestedExit = $LASTEXITCODE
if ($env:DISPATCH_TIMEOUT_TEST -eq '1') { Start-Sleep -Seconds 10 }
$result = [ordered]@{
    status = 'success'
    response = 'fake worker'
    structured_output = [ordered]@{
        request_more_work = [ordered]@{ role = 'scout'; prompt = 'inspect README.md' }
        nested_dispatch_exit = $nestedExit
        working_directory = (Get-Location).Path
    }
}
$result | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath $fakeAgy -Encoding utf8

    $state = Join-Path $tempRoot 'dispatch.json'
    $manifest = Join-Path $tempRoot 'root-worker.manifest.json'
    $timeoutManifest = Join-Path $tempRoot 'timeout-worker.manifest.json'
    $output = Join-Path $tempRoot 'root.json'
    $errorPath = Join-Path $tempRoot 'root.err'
    $workspace = Join-Path $tempRoot 'root-worktree'
    $baseline = (& git -C $root rev-parse HEAD).Trim()
    $envForWorker = @{
        AGY_BIN = $fakeAgy
        DISPATCH_SCRIPT = $dispatch
        DISPATCH_STATE = $state
        DISPATCH_SOURCE_REPO = $root
        DISPATCH_BASELINE = $baseline
        DISPATCH_TEST_ROOT = $tempRoot
        PWsh_BIN = $pwsh
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwsh
    @('-NoProfile', '-File', $dispatch,
      '--state', $state,
      '--assignment-id', 'root-worker',
      '--role', 'scout',
      '--max-depth', '2',
      '--max-width', '2',
      '--max-timeout-seconds', '30',
      '--max-resource-units', '4',
      '--resource-units', '1',
      '--timeout-seconds', '10',
      '--source-repo', $root,
      '--baseline', $baseline,
      '--owned', 'README.md',
      '--workspace-dir', $workspace,
      '--output', $output,
      '--error', $errorPath,
      '--', '-p', 'root attempt') | ForEach-Object { $psi.ArgumentList.Add($_) }
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
foreach ($key in $envForWorker.Keys) { $psi.Environment[$key] = $envForWorker[$key] }
$process = [System.Diagnostics.Process]::Start($psi)
$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()
$process.WaitForExit()

    Assert-True ($process.ExitCode -eq 0) "root dispatch succeeds: $stderr"
    Assert-True (Test-Path -LiteralPath $workspace -PathType Container) 'root dispatch creates the worker worktree'
    Assert-True (Test-Path -LiteralPath $state -PathType Leaf) 'root dispatch writes a dispatch ledger'
    $ledger = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json
    Assert-True ($ledger.assignments.Count -eq 1) 'nested worker does not create a tracked child assignment'
    $assignment = $ledger.assignments[0]
    Assert-True ($assignment.assignment_id -eq 'root-worker' -and $null -eq $assignment.parent_assignment_id -and $assignment.depth -eq 0) 'root assignment records its identity, parent, and depth'
    Assert-True ($assignment.budget.timeout_seconds -eq 10 -and $assignment.budget.resource_units -eq 1) 'assignment records its bounded budget'
    Assert-True ($assignment.owned_paths[0] -eq 'README.md' -and $assignment.lifecycle_state -eq 'completed') 'assignment records owned paths and lifecycle state'
    Assert-True (@($ledger.events | Where-Object { $_.type -eq 'nested_dispatch_rejected' -and $_.assignment_id -eq 'nested-worker' -and $_.request.parent_assignment_id -eq 'root-worker' }).Count -eq 1) 'ledger records the rejected nested-dispatch attempt'
    $workerResult = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
    Assert-True ($workerResult.structured_output.request_more_work.role -eq 'scout') 'worker requests remain structured result data'
    Assert-True ($workerResult.structured_output.nested_dispatch_exit -ne 0) 'worker nested dispatch does not start a process'
    Assert-True ([System.IO.Path]::GetFullPath($workerResult.structured_output.working_directory) -eq [System.IO.Path]::GetFullPath($workspace)) 'worker starts inside its admitted worktree'

    $rejectedOutput = Join-Path $tempRoot 'rejected.json'
    $rejectedError = Join-Path $tempRoot 'rejected.err'
    & $pwsh -NoProfile -File $dispatch `
        --state $state `
        --assignment-id over-budget-worker `
        --parent-assignment-id root-worker `
        --role scout `
        --max-depth 2 `
        --max-width 2 `
        --max-timeout-seconds 30 `
        --max-resource-units 4 `
        --resource-units 4 `
        --timeout-seconds 10 `
        --source-repo $root `
        --baseline $baseline `
        --owned README.md `
        --output $rejectedOutput `
        --error $rejectedError `
        -- -p 'over budget attempt' 2>$rejectedError 1>$rejectedOutput
    $rejectedExit = $LASTEXITCODE
    Assert-True ($rejectedExit -eq 126) 'dispatcher rejects assignments before exceeding resource budget'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $tempRoot 'over-budget-worker.manifest.json'))) 'rejected assignment does not create a worktree manifest'
    $ledger = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json
    Assert-True (@($ledger.events | Where-Object { $_.assignment_id -eq 'over-budget-worker' -and $_.reason -eq 'maximum resource budget exceeded' }).Count -eq 1) 'ledger records the resource-budget rejection'

    $timeoutOutput = Join-Path $tempRoot 'timeout-worker.json'
    $timeoutError = Join-Path $tempRoot 'timeout-worker.err'
    $previousTimeoutFlag = $env:DISPATCH_TIMEOUT_TEST
    try {
        $env:DISPATCH_TIMEOUT_TEST = '1'
        & $pwsh -NoProfile -File $dispatch `
            --state $state `
            --assignment-id timeout-worker `
            --parent-assignment-id root-worker `
            --role scout `
            --max-depth 2 `
            --max-width 2 `
            --max-timeout-seconds 30 `
            --max-resource-units 4 `
            --resource-units 1 `
            --timeout-seconds 2 `
            --source-repo $root `
            --baseline $baseline `
            --owned README.md `
            --output $timeoutOutput `
            --error $timeoutError `
            -- -p 'timeout attempt'
        $timeoutExit = $LASTEXITCODE
    } finally {
        if ($null -eq $previousTimeoutFlag) { Remove-Item Env:DISPATCH_TIMEOUT_TEST -ErrorAction SilentlyContinue } else { $env:DISPATCH_TIMEOUT_TEST = $previousTimeoutFlag }
    }
    $timeoutDiagnostic = if (Test-Path -LiteralPath $timeoutError -PathType Leaf) { Get-Content -LiteralPath $timeoutError -Raw } else { '<missing error file>' }
    Assert-True ($timeoutExit -eq 124) "dispatcher stops a worker before its timeout budget is exceeded (exit $timeoutExit; $timeoutDiagnostic)"
    $ledger = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json
    $timeoutAssignment = @($ledger.assignments | Where-Object { $_.assignment_id -eq 'timeout-worker' })[0]
    Assert-True ($timeoutAssignment.lifecycle_state -eq 'failed' -and $timeoutAssignment.exit_code -eq 124) 'ledger records a timed-out assignment as failed'
} finally {
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        & $workspaceHelper cleanup --manifest $manifest --status success 2>$null | Out-Null
    }
    if (Test-Path -LiteralPath $timeoutManifest -PathType Leaf) {
        & $workspaceHelper cleanup --manifest $timeoutManifest --status success 2>$null | Out-Null
    }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

[Console]::Out.WriteLine('dispatch control checks passed')
