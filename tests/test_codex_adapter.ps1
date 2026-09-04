#!/usr/bin/env pwsh
# tests/test_codex_adapter.ps1
# Contract tests for the Codex worker adapter.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$Root = Split-Path -Parent $PSScriptRoot
$Adapter = Join-Path $Root 'scripts/run-codex-json.ps1'
$TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("offload-codex-adapter-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpRoot | Out-Null

function Fail([string]$Message) {
    throw "FAIL: $Message"
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { Fail $Message }
    Write-Output "ok - $Message"
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        Fail "$Message (expected '$Expected', got '$Actual')"
    }
    Write-Output "ok - $Message"
}

function Write-JsonFile([string]$Path, $Value) {
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Invoke-Tool([string]$FilePath, [string[]]$ArgumentList, [hashtable]$Environment = @{}, [string]$WorkingDirectory = $TmpRoot) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($arg in $ArgumentList) { $psi.ArgumentList.Add($arg) }
    foreach ($entry in $Environment.GetEnumerator()) {
        $psi.Environment[$entry.Key] = [string]$entry.Value
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Invoke-Adapter([string[]]$ArgumentList, [hashtable]$Environment = @{}, [string]$WorkingDirectory = $TmpRoot) {
    $pwsh = (Get-Command pwsh).Source
    return Invoke-Tool $pwsh (@('-NoProfile', '-NonInteractive', '-File', $Adapter) + $ArgumentList) $Environment $WorkingDirectory
}

try {
    $FakeCodex = Join-Path $TmpRoot 'fake-codex.ps1'
    @'
$ArgsList = @($args)
$last = $null
for ($i = 0; $i -lt $ArgsList.Count; $i++) {
    if ($ArgsList[$i] -eq '--output-last-message') { $last = $ArgsList[$i + 1] }
}
if ($ArgsList -contains '--help' -or $ArgsList -contains '-h') {
    Write-Output 'Codex exec --json --output-schema --output-last-message --sandbox --ask-for-approval --cd'
    exit 0
}
if ($env:FAKE_CODEX_MODE -eq 'sleep') {
    while ($true) { Start-Sleep -Milliseconds 50 }
}
if ($env:FAKE_CODEX_MODE -eq 'malformed') {
    Set-Content -LiteralPath $last -Value '{not-json' -Encoding utf8
    Write-Output '{"type":"malformed"}'
    exit 0
}
if ($env:FAKE_CODEX_MODE -eq 'quota') {
    Set-Content -LiteralPath $last -Value '{"error":"quota exhausted"}' -Encoding utf8
    exit 0
}
$result = [ordered]@{ status = 'success'; structured_output = [ordered]@{ ok = $true; child_assignment_request = [ordered]@{ prompt = 'do more' } } }
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $last -Encoding utf8
Write-Output '{"type":"turn.completed"}'
'@ | Set-Content -LiteralPath $FakeCodex -Encoding utf8

    $FakeScope = Join-Path $TmpRoot 'fake-scope.ps1'
    @'
if ($env:FAKE_SCOPE_RESULT -eq 'fail') { exit 1 }
Set-Content -LiteralPath $env:FAKE_SCOPE_MARKER -Value 'scope checked' -Encoding utf8
exit 0
'@ | Set-Content -LiteralPath $FakeScope -Encoding utf8

    $FakeGate = Join-Path $TmpRoot 'fake-gate.ps1'
    @'
Set-Content -LiteralPath $env:FAKE_GATE_MARKER -Value 'gate checked' -Encoding utf8
exit 0
'@ | Set-Content -LiteralPath $FakeGate -Encoding utf8

    $pwsh = (Get-Command pwsh).Source

    $Catalog = Join-Path $TmpRoot 'catalog.json'
    Write-JsonFile $Catalog ([ordered]@{
        schema_version = 1
        revision = 'fake-catalog-1'
        models = @(
            [ordered]@{ id = 'fake-fast-model'; preference = 'fast'; efforts = @('low', 'medium') }
            [ordered]@{ id = 'fake-balanced-model'; preference = 'balanced'; efforts = @('medium', 'high') }
            [ordered]@{ id = 'fake-deep-model'; preference = 'deep'; efforts = @('high') }
        )
    })

    $capOutput = Join-Path $TmpRoot 'capabilities.json'
    $cap = Invoke-Adapter @('capabilities', '--output', $capOutput, '--codex', $FakeCodex) @{ CODEX_MODEL_CATALOG = $Catalog }
    Assert-Equal $cap.ExitCode 0 'capabilities discovery exits successfully'
    $capDoc = Get-Content -LiteralPath $capOutput -Raw | ConvertFrom-Json
    Assert-Equal $capDoc.vendor 'codex' 'capabilities report identifies Codex'
    Assert-True ($capDoc.supported_tools -contains 'exec') 'capabilities report includes exec tool'
    Assert-True ($capDoc.structured_output.supported) 'capabilities report includes structured output support'
    Assert-True ($capDoc.model_availability.available) 'capabilities report includes live model availability'
    Assert-True ($capDoc.effort_levels -contains 'high') 'capabilities report includes effort levels'

    $worktree = Join-Path $TmpRoot 'worktree'
    New-Item -ItemType Directory -Path $worktree | Out-Null
    $scopeMarker = Join-Path $TmpRoot 'scope.marker'
    $gateMarker = Join-Path $TmpRoot 'gate.marker'
    $assignment = Join-Path $TmpRoot 'success-assignment.json'
    Write-JsonFile $assignment ([ordered]@{
        schema_version = 1
        assignment_id = 'codex-success-1'
        parent_assignment_id = $null
        depth = 0
        prompt = 'Return the bounded result.'
        worktree = $worktree
        owned_paths = @('owned.txt')
        frozen_paths = @('tests/test_codex_adapter.ps1')
        baseline = 'HEAD'
        preference = 'balanced'
        effort = 'high'
        timeout_seconds = 10
        scope_check = @($pwsh, '-NoProfile', '-File', $FakeScope)
        final_gate = @($pwsh, '-NoProfile', '-File', $FakeGate)
        artifacts = @()
    })
    $resultOutput = Join-Path $TmpRoot 'success-result.json'
    $success = Invoke-Adapter @('run', '--assignment', $assignment, '--output', $resultOutput, '--error', (Join-Path $TmpRoot 'success.err'), '--codex', $FakeCodex) @{
        CODEX_MODEL_CATALOG = $Catalog
        FAKE_SCOPE_MARKER = $scopeMarker
        FAKE_GATE_MARKER = $gateMarker
    } $worktree
    Assert-Equal $success.ExitCode 0 'successful assignment exits successfully'
    $successDoc = Get-Content -LiteralPath $resultOutput -Raw | ConvertFrom-Json
    Assert-Equal $successDoc.status 'completed' 'successful assignment returns completed status'
    Assert-Equal $successDoc.model_selection.preference 'balanced' 'assignment keeps internal model preference'
    Assert-Equal $successDoc.model_selection.model_id 'fake-balanced-model' 'adapter selects catalog model for preference'
    Assert-True $successDoc.structured_output.ok 'successful assignment returns structured output'
    Assert-True ($successDoc.process.pid -gt 0) 'successful assignment reports process identity'
    Assert-Equal $successDoc.verification.scope_check 'passed' 'scope check runs before returning result'
    Assert-Equal $successDoc.verification.final_gate 'passed' 'final gate runs before returning result'
    Assert-True (Test-Path -LiteralPath $scopeMarker) 'scope check marker proves scope check ran'
    Assert-True (Test-Path -LiteralPath $gateMarker) 'final gate marker proves final gate ran'
    Assert-True ($successDoc.resources.artifacts.Count -ge 2) 'resource ledger reports worker artifacts'
    Assert-True (-not $successDoc.PSObject.Properties.Name.Contains('child_assignment')) 'nested dispatch is not promoted to an assignment'

    $malformedAssignment = Join-Path $TmpRoot 'malformed-assignment.json'
    Write-JsonFile $malformedAssignment ((Get-Content -LiteralPath $assignment -Raw | ConvertFrom-Json) | ForEach-Object { $_.assignment_id = 'codex-malformed-1'; $_ })
    $malformedOutput = Join-Path $TmpRoot 'malformed-result.json'
    $malformed = Invoke-Adapter @('run', '--assignment', $malformedAssignment, '--output', $malformedOutput, '--error', (Join-Path $TmpRoot 'malformed.err'), '--codex', $FakeCodex) @{
        CODEX_MODEL_CATALOG = $Catalog
        FAKE_CODEX_MODE = 'malformed'
        FAKE_SCOPE_MARKER = (Join-Path $TmpRoot 'malformed-scope.marker')
        FAKE_GATE_MARKER = (Join-Path $TmpRoot 'malformed-gate.marker')
    } $worktree
    Assert-True ($malformed.ExitCode -ne 0) 'malformed worker output exits nonzero'
    $malformedDoc = Get-Content -LiteralPath $malformedOutput -Raw | ConvertFrom-Json
    Assert-Equal $malformedDoc.status 'failed' 'malformed worker output is failed'
    Assert-Equal $malformedDoc.failure.kind 'malformed-output' 'malformed worker output records failure reason'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $TmpRoot 'malformed-gate.marker'))) 'malformed output cannot reach final gate'

    $scopeFailAssignment = Join-Path $TmpRoot 'scope-fail-assignment.json'
    Write-JsonFile $scopeFailAssignment ((Get-Content -LiteralPath $assignment -Raw | ConvertFrom-Json) | ForEach-Object { $_.assignment_id = 'codex-scope-fail-1'; $_ })
    $scopeFailOutput = Join-Path $TmpRoot 'scope-fail-result.json'
    $scopeFail = Invoke-Adapter @('run', '--assignment', $scopeFailAssignment, '--output', $scopeFailOutput, '--error', (Join-Path $TmpRoot 'scope-fail.err'), '--codex', $FakeCodex) @{
        CODEX_MODEL_CATALOG = $Catalog
        FAKE_SCOPE_RESULT = 'fail'
        FAKE_SCOPE_MARKER = (Join-Path $TmpRoot 'scope-fail-scope.marker')
        FAKE_GATE_MARKER = (Join-Path $TmpRoot 'scope-fail-gate.marker')
    } $worktree
    Assert-True ($scopeFail.ExitCode -ne 0) 'scope failure exits nonzero'
    $scopeFailDoc = Get-Content -LiteralPath $scopeFailOutput -Raw | ConvertFrom-Json
    Assert-Equal $scopeFailDoc.status 'scope-failure' 'scope failure is returned as scope-failure'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $TmpRoot 'scope-fail-gate.marker'))) 'scope failure blocks final gate'

    $unsupportedOutput = Join-Path $TmpRoot 'unsupported-result.json'
    $unsupported = Invoke-Adapter @('run', '--assignment', $assignment, '--output', $unsupportedOutput, '--error', (Join-Path $TmpRoot 'unsupported.err'), '--codex', $FakeCodex) @{
        FAKE_SCOPE_MARKER = (Join-Path $TmpRoot 'unsupported-scope.marker')
        FAKE_GATE_MARKER = (Join-Path $TmpRoot 'unsupported-gate.marker')
    } $worktree
    Assert-True ($unsupported.ExitCode -ne 0) 'unsupported host capability exits nonzero'
    $unsupportedDoc = Get-Content -LiteralPath $unsupportedOutput -Raw | ConvertFrom-Json
    Assert-Equal $unsupportedDoc.status 'unsupported' 'unsupported host capability fails closed'
    Assert-True ($unsupportedDoc.failure.reason -match 'model catalog') 'unsupported capability records a reason'

    $quotaAssignment = Join-Path $TmpRoot 'quota-assignment.json'
    Write-JsonFile $quotaAssignment ((Get-Content -LiteralPath $assignment -Raw | ConvertFrom-Json) | ForEach-Object { $_.assignment_id = 'codex-quota-1'; $_ })
    $quotaOutput = Join-Path $TmpRoot 'quota-result.json'
    $quota = Invoke-Adapter @('run', '--assignment', $quotaAssignment, '--output', $quotaOutput, '--error', (Join-Path $TmpRoot 'quota.err'), '--codex', $FakeCodex) @{
        CODEX_MODEL_CATALOG = $Catalog
        FAKE_CODEX_MODE = 'quota'
        FAKE_SCOPE_MARKER = (Join-Path $TmpRoot 'quota-scope.marker')
        FAKE_GATE_MARKER = (Join-Path $TmpRoot 'quota-gate.marker')
    } $worktree
    Assert-True ($quota.ExitCode -ne 0) 'quota exhaustion exits nonzero'
    $quotaDoc = Get-Content -LiteralPath $quotaOutput -Raw | ConvertFrom-Json
    Assert-Equal $quotaDoc.status 'quota-handoff' 'quota exhaustion is handed off'
    Assert-Equal $quotaDoc.failure.kind 'quota' 'quota exhaustion records failure reason'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $TmpRoot 'quota-gate.marker'))) 'quota exhaustion blocks final gate'

    $cancelFile = Join-Path $TmpRoot 'cancel.request'
    $cancelAssignment = Join-Path $TmpRoot 'cancel-assignment.json'
    Write-JsonFile $cancelAssignment ((Get-Content -LiteralPath $assignment -Raw | ConvertFrom-Json) | ForEach-Object { $_.assignment_id = 'codex-cancel-1'; $_; })
    $cancelOutput = Join-Path $TmpRoot 'cancel-result.json'
    New-Item -ItemType File -Path $cancelFile | Out-Null
    $canceled = Invoke-Adapter @('run', '--assignment', $cancelAssignment, '--output', $cancelOutput, '--error', (Join-Path $TmpRoot 'cancel.err'), '--codex', $FakeCodex, '--cancel-file', $cancelFile) @{
        CODEX_MODEL_CATALOG = $Catalog
        FAKE_CODEX_MODE = 'sleep'
        FAKE_SCOPE_MARKER = (Join-Path $TmpRoot 'cancel-scope.marker')
        FAKE_GATE_MARKER = (Join-Path $TmpRoot 'cancel-gate.marker')
    } $worktree
    Assert-True ($canceled.ExitCode -ne 0) 'cancellation exits nonzero'
    $canceledDoc = Get-Content -LiteralPath $cancelOutput -Raw | ConvertFrom-Json
    Assert-Equal $canceledDoc.status 'canceled' 'cancellation is recorded as canceled'
    Assert-True ($canceledDoc.process.exit_code -ne $null) 'cancellation records worker exit result'

    Write-Output 'all Codex adapter contract checks passed'
} finally {
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -LiteralPath $TmpRoot -Recurse -Force
    }
}
