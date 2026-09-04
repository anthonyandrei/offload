#!/usr/bin/env pwsh
# tests/test_verification_hardening_routing.ps1
# Executable gate test suite for offload verification hardening: routing cleanup criterion.
# Implements contracts specified in offload-verification-hardening/spec.md (Sections 3, 5, Test Strategy).
# Constraints: Uses public scripts and temporary fixtures, no live Gemini calls, fail-closed assertions.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# ---------------------------------------------------------------------------
# Compact Self-Contained Assertion Harness
# ---------------------------------------------------------------------------

$script:TotalTests = 0
$script:FailedTests = 0

function Pass([string]$name) {
    $script:TotalTests++
    [Console]::Out.WriteLine("ok - $name")
}

function Fail([string]$name, [string]$reason = "") {
    $script:TotalTests++
    $script:FailedTests++
    $msg = if ($reason) { "FAIL: $name - $reason" } else { "FAIL: $name" }
    [Console]::Error.WriteLine($msg)
    exit 1
}

function Assert-True([bool]$condition, [string]$name, [string]$reason = "") {
    if ($condition) {
        Pass $name
    } else {
        $r = if ($reason) { $reason } else { "Condition was false" }
        Fail $name $r
    }
}

function Assert-False([bool]$condition, [string]$name, [string]$reason = "") {
    if (-not $condition) {
        Pass $name
    } else {
        $r = if ($reason) { $reason } else { "Condition was true" }
        Fail $name $r
    }
}

function Assert-Equal($actual, $expected, [string]$name) {
    if ($actual -eq $expected) {
        Pass $name
    } else {
        Fail $name "Expected '$expected', got '$actual'"
    }
}

# ---------------------------------------------------------------------------
# Public Script Process Runners
# ---------------------------------------------------------------------------

$PwshBin = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $PwshBin) {
    $PwshBin = (Get-Process -Id $PID).Path
}

$RootDir = Split-Path -Parent $PSScriptRoot
$ScriptsDir = Join-Path $RootDir 'scripts'
$CleanupPs1 = Join-Path $ScriptsDir 'cleanup-research-workspace.ps1'
$CleanupSh = Join-Path $ScriptsDir 'cleanup-research-workspace.sh'
$ProvenancePs1 = Join-Path $ScriptsDir 'collect-provenance.ps1'
$ProvenanceSh = Join-Path $ScriptsDir 'collect-provenance.sh'

if (-not (Test-Path -LiteralPath $CleanupPs1 -PathType Leaf)) {
    Fail "init" "Script '$CleanupPs1' not found"
}
if (-not (Test-Path -LiteralPath $ProvenancePs1 -PathType Leaf)) {
    Fail "init" "Script '$ProvenancePs1' not found"
}

function Invoke-ToolProcess {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = $null
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($arg in $ArgumentList) {
        $psi.ArgumentList.Add($arg)
    }
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    foreach ($key in $Environment.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$Environment[$key]
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Stdout   = $stdoutTask.GetAwaiter().GetResult()
        Stderr   = $stderrTask.GetAwaiter().GetResult()
    }
}

function Invoke-CleanupPs1 {
    param(
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = $null
    )
    $pwshArgs = @('-NoProfile', '-NonInteractive', '-File', $CleanupPs1) + $ArgumentList
    return Invoke-ToolProcess -FilePath $PwshBin -ArgumentList $pwshArgs -WorkingDirectory $WorkingDirectory
}

function Invoke-ProvenancePs1 {
    param(
        [string[]]$ArgumentList = @()
    )
    $pwshArgs = @('-NoProfile', '-NonInteractive', '-File', $ProvenancePs1) + $ArgumentList
    return Invoke-ToolProcess -FilePath $PwshBin -ArgumentList $pwshArgs
}

function Find-BashBin {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $pathBash = (Get-Command bash -ErrorAction SilentlyContinue)?.Source
    if ($pathBash) { $candidates.Add($pathBash) }
    $candidates.Add('C:\Program Files\Git\bin\bash.exe')
    $candidates.Add('C:\Program Files\Git\usr\bin\bash.exe')
    foreach ($c in $candidates) {
        if ([System.IO.File]::Exists($c)) {
            try {
                $res = Invoke-ToolProcess -FilePath $c -ArgumentList @('-c', 'exit 0')
                if ($res.ExitCode -eq 0) {
                    return $c
                }
            } catch {}
        }
    }
    return $null
}

$BashBin = Find-BashBin

function Invoke-CleanupSh {
    param(
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = $null
    )
    if (-not $BashBin) {
        return $null
    }
    $bashScriptPath = $CleanupSh.Replace('\', '/')
    $normalizedArgs = @()
    foreach ($a in $ArgumentList) {
        $normalizedArgs += $a.Replace('\', '/')
    }
    $bashArgs = @($bashScriptPath) + $normalizedArgs
    return Invoke-ToolProcess -FilePath $BashBin -ArgumentList $bashArgs -WorkingDirectory $WorkingDirectory
}

function Invoke-ProvenanceSh {
    param(
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = $null
    )
    if (-not $BashBin -or -not (Test-Path -LiteralPath $ProvenanceSh -PathType Leaf)) {
        return $null
    }
    $bashScriptPath = $ProvenanceSh.Replace('\', '/')
    $normalizedArgs = @()
    foreach ($a in $ArgumentList) {
        $normalizedArgs += $a.Replace('\', '/')
    }
    $bashArgs = @($bashScriptPath) + $normalizedArgs
    return Invoke-ToolProcess -FilePath $BashBin -ArgumentList $bashArgs -WorkingDirectory $WorkingDirectory
}

# ---------------------------------------------------------------------------
# Test Environment Setup
# ---------------------------------------------------------------------------

$TmpRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "offload-routing-test-$([System.Guid]::NewGuid().ToString('N'))")
[System.IO.Directory]::CreateDirectory($TmpRoot) | Out-Null

function New-TestWorkspace([string]$name) {
    $wsPath = Join-Path $TmpRoot $name
    if (Test-Path -LiteralPath $wsPath) {
        Remove-Item -Recurse -Force -LiteralPath $wsPath
    }
    [System.IO.Directory]::CreateDirectory($wsPath) | Out-Null
    Set-Content -LiteralPath (Join-Path $wsPath '.offload-research-workspace') -Value "offload-research-workspace-v1`n" -NoNewline
    return $wsPath
}

function New-RoutingAttempt([hashtable]$overrides = @{}) {
    $att = [ordered]@{
        worker_id           = "worker-1"
        role                = "researcher"
        mode                = "repo-research"
        attempt             = 1
        policy_revision     = "2026-09-03.1"
        route               = "default"
        model               = "gemini-3.8-flash-high"
        effort              = "high"
        reason              = "Initial dispatch"
        started_at          = "2026-09-03T00:00:00Z"
        ended_at            = "2026-09-03T00:01:00Z"
        duration_seconds    = 60
        exit_code           = 0
        state               = "completed"
        failure_class       = "none"
        verification_status = "passed"
        evidence_paths      = @()
        usage               = $null
    }
    foreach ($k in $overrides.Keys) {
        $att[$k] = $overrides[$k]
    }
    return $att
}

function New-BaseProvenance([string]$scratchPath, [array]$workers = @()) {
    return [ordered]@{
        run_id                    = "test-run"
        request_summary           = "test run summary"
        selected_mode             = "repo-research"
        profile                   = "standard"
        deep_trigger              = $null
        start_time                = "2026-09-03T00:00:00Z"
        end_time                  = "2026-09-03T00:05:00Z"
        duration_seconds          = 300
        scratch_path              = $scratchPath
        workers                   = $workers
        repository_snapshot_paths = @()
        final_citations           = @()
        audit_verdicts            = @()
        final_status              = "success"
        incomplete_stage_reasons  = @()
    }
}

try {
    # =======================================================================
    # Group 1: Multi-Worker Routing Records in cleanup-research-workspace.ps1
    # =======================================================================

    # 1.1 Accept three workers with one attempt each
    $ws1 = New-TestWorkspace "multi-worker-three"
    Set-Content -LiteralPath (Join-Path $ws1 'final.md') -Value "final report"
    [System.IO.Directory]::CreateDirectory((Join-Path $ws1 'evidence')) | Out-Null
    Set-Content -LiteralPath (Join-Path $ws1 'evidence/w1.json') -Value "worker 1 evidence"
    Set-Content -LiteralPath (Join-Path $ws1 'evidence/w2.json') -Value "worker 2 evidence"
    Set-Content -LiteralPath (Join-Path $ws1 'evidence/w3.json') -Value "worker 3 evidence"
    Set-Content -LiteralPath (Join-Path $ws1 'disposable.txt') -Value "should be pruned"

    $prov1 = New-BaseProvenance $ws1 @(
        [ordered]@{ id = "worker-1"; role = "researcher"; status = "completed"; output = "evidence/w1.json"; accepted_attempt = 1 },
        [ordered]@{ id = "worker-2"; role = "researcher"; status = "completed"; output = "evidence/w2.json"; accepted_attempt = 1 },
        [ordered]@{ id = "worker-3"; role = "researcher"; status = "completed"; output = "evidence/w3.json"; accepted_attempt = 1 }
    )
    $prov1 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws1 'provenance.json') -Encoding utf8

    $routingRecord1 = [ordered]@{
        schema_version = 1
        attempts = @(
            (New-RoutingAttempt @{ worker_id = "worker-1"; attempt = 1; evidence_paths = @("evidence/w1.json") }),
            (New-RoutingAttempt @{ worker_id = "worker-2"; attempt = 1; evidence_paths = @("evidence/w2.json") }),
            (New-RoutingAttempt @{ worker_id = "worker-3"; attempt = 1; evidence_paths = @("evidence/w3.json") })
        )
    }
    $routingPath1 = Join-Path $ws1 'routing-outcomes.json'
    $routingRecord1 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $routingPath1 -Encoding utf8

    $res1 = Invoke-CleanupPs1 @('--workspace', $ws1, '--status', 'success')
    Assert-Equal $res1.ExitCode 0 "accept-three-workers-one-attempt: exit code is 0"
    Assert-True (Test-Path -LiteralPath (Join-Path $ws1 'final.md')) "accept-three-workers-one-attempt: final.md retained"
    Assert-True (Test-Path -LiteralPath (Join-Path $ws1 'provenance.json')) "accept-three-workers-one-attempt: provenance.json retained"
    Assert-True (Test-Path -LiteralPath $routingPath1) "accept-three-workers-one-attempt: routing-outcomes.json retained"
    $dispPath1 = Join-Path $ws1 'evidence-disposition.json'
    Assert-True (Test-Path -LiteralPath $dispPath1) "accept-three-workers-one-attempt: evidence-disposition.json created"
    Assert-False (Test-Path -LiteralPath (Join-Path $ws1 'disposable.txt')) "accept-three-workers-one-attempt: disposable file pruned"
    $survivingRouting1 = Get-Content -LiteralPath $routingPath1 -Raw | ConvertFrom-Json
    Assert-Equal @($survivingRouting1.attempts).Count 3 "accept-three-workers-one-attempt: retains all 3 attempts"
    $disp1 = Get-Content -LiteralPath $dispPath1 -Raw | ConvertFrom-Json
    Assert-Equal @($disp1.entries).Count 3 "accept-three-workers-one-attempt: disposition covers all 3 worker evidence paths"

    # 1.2 Accept workers A, B, and C at attempt 1 plus worker B at attempt 2
    $ws2 = New-TestWorkspace "multi-worker-retry"
    Set-Content -LiteralPath (Join-Path $ws2 'final.md') -Value "final report"
    [System.IO.Directory]::CreateDirectory((Join-Path $ws2 'evidence')) | Out-Null
    Set-Content -LiteralPath (Join-Path $ws2 'evidence/wa1.json') -Value "worker a attempt 1 evidence"
    Set-Content -LiteralPath (Join-Path $ws2 'evidence/wb1.json') -Value "worker b attempt 1 evidence"
    Set-Content -LiteralPath (Join-Path $ws2 'evidence/wb2.json') -Value "worker b attempt 2 evidence"
    Set-Content -LiteralPath (Join-Path $ws2 'evidence/wc1.json') -Value "worker c attempt 1 evidence"

    $prov2 = New-BaseProvenance $ws2 @(
        [ordered]@{ id = "worker-a"; role = "researcher"; status = "completed"; output = "evidence/wa1.json"; accepted_attempt = 1 },
        [ordered]@{ id = "worker-b"; role = "researcher"; status = "completed"; output = "evidence/wb2.json"; accepted_attempt = 2 },
        [ordered]@{ id = "worker-c"; role = "researcher"; status = "completed"; output = "evidence/wc1.json"; accepted_attempt = 1 }
    )
    $prov2 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws2 'provenance.json') -Encoding utf8

    $routingRecord2 = [ordered]@{
        schema_version = 1
        attempts = @(
            (New-RoutingAttempt @{ worker_id = "worker-a"; attempt = 1; evidence_paths = @("evidence/wa1.json") }),
            (New-RoutingAttempt @{
                worker_id = "worker-b"
                attempt = 1
                exit_code = 1
                state = "failed"
                failure_class = "quality"
                verification_status = "failed"
                evidence_paths = @("evidence/wb1.json")
            }),
            (New-RoutingAttempt @{
                worker_id = "worker-b"
                attempt = 2
                route = "quality-retry"
                reason = "Retry authorized after quality gate failure on attempt 1"
                evidence_paths = @("evidence/wb2.json")
            }),
            (New-RoutingAttempt @{ worker_id = "worker-c"; attempt = 1; evidence_paths = @("evidence/wc1.json") })
        )
    }
    $routingPath2 = Join-Path $ws2 'routing-outcomes.json'
    $routingRecord2 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $routingPath2 -Encoding utf8

    $res2 = Invoke-CleanupPs1 @('--workspace', $ws2, '--status', 'success')
    Assert-Equal $res2.ExitCode 0 "accept-workers-a-b-c-and-b-retry: exit code is 0"
    $survivingRouting2 = Get-Content -LiteralPath $routingPath2 -Raw | ConvertFrom-Json
    Assert-Equal @($survivingRouting2.attempts).Count 4 "accept-workers-a-b-c-and-b-retry: retains all 4 attempts"
    $bAttempts = @($survivingRouting2.attempts | Where-Object { $_.worker_id -eq 'worker-b' } | Sort-Object attempt)
    Assert-Equal $bAttempts.Count 2 "accept-workers-a-b-c-and-b-retry: worker-b has exactly 2 attempts"
    Assert-Equal $bAttempts[0].verification_status 'failed' "accept-workers-a-b-c-and-b-retry: retains worker-b attempt 1 failed status"
    Assert-Equal $bAttempts[1].verification_status 'passed' "accept-workers-a-b-c-and-b-retry: retains worker-b attempt 2 passed status"
    $dispPath2 = Join-Path $ws2 'evidence-disposition.json'
    $disp2 = Get-Content -LiteralPath $dispPath2 -Raw | ConvertFrom-Json
    Assert-Equal @($disp2.entries).Count 4 "accept-workers-a-b-c-and-b-retry: disposition covers all 4 evidence paths"

    # 1.3 Accept multi-worker run without provenance.json (routing-outcomes.json only)
    $ws1c = New-TestWorkspace "multi-worker-no-provenance"
    Set-Content -LiteralPath (Join-Path $ws1c 'final.md') -Value "final"
    [System.IO.Directory]::CreateDirectory((Join-Path $ws1c 'evidence')) | Out-Null
    Set-Content -LiteralPath (Join-Path $ws1c 'evidence/w1.json') -Value "w1"
    Set-Content -LiteralPath (Join-Path $ws1c 'evidence/w2.json') -Value "w2"
    $routingRecord1c = [ordered]@{
        schema_version = 1
        attempts = @(
            (New-RoutingAttempt @{ worker_id = "worker-1"; attempt = 1; evidence_paths = @("evidence/w1.json") }),
            (New-RoutingAttempt @{ worker_id = "worker-2"; attempt = 1; evidence_paths = @("evidence/w2.json") })
        )
    }
    $routingRecord1c | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws1c 'routing-outcomes.json') -Encoding utf8
    $res1c = Invoke-CleanupPs1 @('--workspace', $ws1c, '--status', 'success')
    Assert-Equal $res1c.ExitCode 0 "accept-multi-worker-without-provenance: exit code is 0"

    # =======================================================================
    # Group 2: Rejection of Invalid Routing Records in cleanup
    # =======================================================================

    # 2.1 Reject three attempts for one worker
    $ws3 = New-TestWorkspace "reject-three-attempts-one-worker"
    Set-Content -LiteralPath (Join-Path $ws3 'raw-worker.json') -Value "raw data"
    $routingRecord3 = [ordered]@{
        schema_version = 1
        attempts = @(
            (New-RoutingAttempt @{ worker_id = "worker-a"; attempt = 1; state = "failed"; verification_status = "failed"; failure_class = "quality" }),
            (New-RoutingAttempt @{ worker_id = "worker-a"; attempt = 2; state = "failed"; verification_status = "failed"; failure_class = "quality" }),
            (New-RoutingAttempt @{ worker_id = "worker-a"; attempt = 3; state = "completed"; verification_status = "passed"; failure_class = "none" })
        )
    }
    $routingRecord3 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws3 'routing-outcomes.json') -Encoding utf8

    $res3 = Invoke-CleanupPs1 @('--workspace', $ws3, '--status', 'success')
    Assert-True ($res3.ExitCode -ne 0) "reject-three-attempts-one-worker: non-zero exit code"
    Assert-True (Test-Path -LiteralPath (Join-Path $ws3 'raw-worker.json')) "reject-three-attempts-one-worker: preserves raw artifacts"

    # 2.2 Reject duplicate (worker_id, attempt) pair
    $ws4 = New-TestWorkspace "reject-duplicate-worker-attempt"
    Set-Content -LiteralPath (Join-Path $ws4 'raw-worker.json') -Value "raw data"
    $routingRecord4 = [ordered]@{
        schema_version = 1
        attempts = @(
            (New-RoutingAttempt @{ worker_id = "worker-a"; attempt = 1 }),
            (New-RoutingAttempt @{ worker_id = "worker-a"; attempt = 1 })
        )
    }
    $routingRecord4 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws4 'routing-outcomes.json') -Encoding utf8

    $res4 = Invoke-CleanupPs1 @('--workspace', $ws4, '--status', 'success')
    Assert-True ($res4.ExitCode -ne 0) "reject-duplicate-worker-attempt: non-zero exit code"
    Assert-True (Test-Path -LiteralPath (Join-Path $ws4 'raw-worker.json')) "reject-duplicate-worker-attempt: preserves raw artifacts"

    # 2.3 Reject attempt 0
    $ws5a = New-TestWorkspace "reject-attempt-zero"
    $rec5a = [ordered]@{
        schema_version = 1
        attempts = @((New-RoutingAttempt @{ worker_id = "worker-a"; attempt = 0 }))
    }
    $rec5a | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws5a 'routing-outcomes.json') -Encoding utf8
    $res5a = Invoke-CleanupPs1 @('--workspace', $ws5a, '--status', 'success')
    Assert-True ($res5a.ExitCode -ne 0) "reject-invalid-attempt-number: attempt 0 rejected"

    # 2.4 Reject attempt 3
    $ws5b = New-TestWorkspace "reject-attempt-three"
    $rec5b = [ordered]@{
        schema_version = 1
        attempts = @((New-RoutingAttempt @{ worker_id = "worker-a"; attempt = 3 }))
    }
    $rec5b | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws5b 'routing-outcomes.json') -Encoding utf8
    $res5b = Invoke-CleanupPs1 @('--workspace', $ws5b, '--status', 'success')
    Assert-True ($res5b.ExitCode -ne 0) "reject-invalid-attempt-number: attempt 3 rejected"

    # 2.5 Reject missing attempt number
    $ws5c = New-TestWorkspace "reject-missing-attempt"
    $attNoNum = New-RoutingAttempt @{ worker_id = "worker-a" }
    $attNoNum.Remove("attempt")
    $rec5c = [ordered]@{ schema_version = 1; attempts = @($attNoNum) }
    $rec5c | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws5c 'routing-outcomes.json') -Encoding utf8
    $res5c = Invoke-CleanupPs1 @('--workspace', $ws5c, '--status', 'success')
    Assert-True ($res5c.ExitCode -ne 0) "reject-invalid-attempt-number: missing attempt rejected"

    # 2.6 Reject non-integer attempt number
    $ws5d = New-TestWorkspace "reject-string-attempt"
    $attStrNum = New-RoutingAttempt @{ worker_id = "worker-a"; attempt = "1" }
    $rec5d = [ordered]@{ schema_version = 1; attempts = @($attStrNum) }
    $rec5d | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws5d 'routing-outcomes.json') -Encoding utf8
    $res5d = Invoke-CleanupPs1 @('--workspace', $ws5d, '--status', 'success')
    Assert-True ($res5d.ExitCode -ne 0) "reject-invalid-attempt-number: string attempt rejected"

    # 2.7 Reject empty worker_id
    $ws5e = New-TestWorkspace "reject-empty-worker-id"
    $rec5e = [ordered]@{
        schema_version = 1
        attempts = @((New-RoutingAttempt @{ worker_id = ""; attempt = 1 }))
    }
    $rec5e | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws5e 'routing-outcomes.json') -Encoding utf8
    $res5e = Invoke-CleanupPs1 @('--workspace', $ws5e, '--status', 'success')
    Assert-True ($res5e.ExitCode -ne 0) "reject-empty-worker-id: empty worker_id rejected"

    # =======================================================================
    # Group 3: Per-Worker accepted_attempt and Verified Artifact Validation
    # =======================================================================

    # 3.1 Valid accepted_attempt in provenance.json (accepted_attempt: 2 where attempt 2 passed and artifact exists)
    $ws6a = New-TestWorkspace "valid-accepted-attempt"
    [System.IO.Directory]::CreateDirectory((Join-Path $ws6a 'evidence')) | Out-Null
    Set-Content -LiteralPath (Join-Path $ws6a 'evidence/w1.attempt1.json') -Value "att1"
    Set-Content -LiteralPath (Join-Path $ws6a 'evidence/w1.attempt2.json') -Value "att2"
    Set-Content -LiteralPath (Join-Path $ws6a 'final.md') -Value "final"

    $routingRecord6a = [ordered]@{
        schema_version = 1
        attempts = @(
            (New-RoutingAttempt @{
                worker_id = "worker-1"; attempt = 1; exit_code = 1; state = "failed";
                failure_class = "quality"; verification_status = "failed";
                evidence_paths = @("evidence/w1.attempt1.json")
            }),
            (New-RoutingAttempt @{
                worker_id = "worker-1"; attempt = 2; route = "quality-retry";
                verification_status = "passed"; evidence_paths = @("evidence/w1.attempt2.json")
            })
        )
    }
    $routingRecord6a | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6a 'routing-outcomes.json') -Encoding utf8

    $prov6a = New-BaseProvenance $ws6a @(
        [ordered]@{
            id = "worker-1"
            role = "researcher"
            status = "completed"
            output = "evidence/w1.attempt2.json"
            accepted_attempt = 2
        }
    )
    $prov6a | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6a 'provenance.json') -Encoding utf8

    $res6a = Invoke-CleanupPs1 @('--workspace', $ws6a, '--status', 'success')
    Assert-Equal $res6a.ExitCode 0 "accepted-attempt: valid accepted attempt 2 resolves to verified artifact"

    # 3.2 Reject accepted_attempt whose verification failed
    $ws6b = New-TestWorkspace "reject-accepted-attempt-failed-ver"
    Set-Content -LiteralPath (Join-Path $ws6b 'raw.json') -Value "raw"
    [System.IO.Directory]::CreateDirectory((Join-Path $ws6b 'evidence')) | Out-Null
    Set-Content -LiteralPath (Join-Path $ws6b 'evidence/w1.attempt1.json') -Value "att1"

    $routingRecord6b = [ordered]@{
        schema_version = 1
        attempts = @(
            (New-RoutingAttempt @{
                worker_id = "worker-1"; attempt = 1; state = "failed";
                failure_class = "quality"; verification_status = "failed";
                evidence_paths = @("evidence/w1.attempt1.json")
            })
        )
    }
    $routingRecord6b | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6b 'routing-outcomes.json') -Encoding utf8

    $prov6b = New-BaseProvenance $ws6b @(
        [ordered]@{
            id = "worker-1"
            role = "researcher"
            status = "completed"
            output = "evidence/w1.attempt1.json"
            accepted_attempt = 1
        }
    )
    $prov6b | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6b 'provenance.json') -Encoding utf8

    $res6b = Invoke-CleanupPs1 @('--workspace', $ws6b, '--status', 'success')
    Assert-True ($res6b.ExitCode -ne 0) "reject-accepted-attempt-failed-ver: rejects accepted attempt whose verification failed"
    Assert-True (Test-Path -LiteralPath (Join-Path $ws6b 'raw.json')) "reject-accepted-attempt-failed-ver: preserves raw artifacts"

    # 3.3 Reject accepted_attempt whose verification is pending or not_performed
    $ws6b2 = New-TestWorkspace "reject-accepted-attempt-pending-ver"
    Set-Content -LiteralPath (Join-Path $ws6b2 'raw.json') -Value "raw"
    [System.IO.Directory]::CreateDirectory((Join-Path $ws6b2 'evidence')) | Out-Null
    Set-Content -LiteralPath (Join-Path $ws6b2 'evidence/w1.attempt1.json') -Value "att1"

    $routingRecord6b2 = [ordered]@{
        schema_version = 1
        attempts = @(
            (New-RoutingAttempt @{
                worker_id = "worker-1"; attempt = 1; verification_status = "pending";
                evidence_paths = @("evidence/w1.attempt1.json")
            })
        )
    }
    $routingRecord6b2 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6b2 'routing-outcomes.json') -Encoding utf8

    $prov6b2 = New-BaseProvenance $ws6b2 @(
        [ordered]@{
            id = "worker-1"
            role = "researcher"
            status = "completed"
            output = "evidence/w1.attempt1.json"
            accepted_attempt = 1
        }
    )
    $prov6b2 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6b2 'provenance.json') -Encoding utf8

    $res6b2 = Invoke-CleanupPs1 @('--workspace', $ws6b2, '--status', 'success')
    Assert-True ($res6b2.ExitCode -ne 0) "reject-accepted-attempt-pending-ver: rejects accepted attempt whose verification is pending"

    # 3.4 Reject accepted_attempt whose artifact does not exist
    $ws6c = New-TestWorkspace "reject-accepted-attempt-missing-art"
    Set-Content -LiteralPath (Join-Path $ws6c 'raw.json') -Value "raw"
    $routingRecord6c = [ordered]@{
        schema_version = 1
        attempts = @(
            (New-RoutingAttempt @{
                worker_id = "worker-1"; attempt = 1; verification_status = "passed";
                evidence_paths = @("evidence/nonexistent.json")
            })
        )
    }
    $routingRecord6c | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6c 'routing-outcomes.json') -Encoding utf8

    $prov6c = New-BaseProvenance $ws6c @(
        [ordered]@{
            id = "worker-1"
            role = "researcher"
            status = "completed"
            output = "evidence/nonexistent.json"
            accepted_attempt = 1
        }
    )
    $prov6c | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6c 'provenance.json') -Encoding utf8

    $res6c = Invoke-CleanupPs1 @('--workspace', $ws6c, '--status', 'success')
    Assert-True ($res6c.ExitCode -ne 0) "reject-accepted-attempt-missing-art: rejects accepted attempt whose artifact is missing"
    Assert-True (Test-Path -LiteralPath (Join-Path $ws6c 'raw.json')) "reject-accepted-attempt-missing-art: preserves raw artifacts"

    # 3.5 Reject accepted_attempt pointing to non-existent attempt number for worker
    $ws6d = New-TestWorkspace "reject-accepted-attempt-nonexistent-num"
    Set-Content -LiteralPath (Join-Path $ws6d 'raw.json') -Value "raw"
    [System.IO.Directory]::CreateDirectory((Join-Path $ws6d 'evidence')) | Out-Null
    Set-Content -LiteralPath (Join-Path $ws6d 'evidence/w1.json') -Value "att"

    $routingRecord6d = [ordered]@{
        schema_version = 1
        attempts = @(
            (New-RoutingAttempt @{ worker_id = "worker-1"; attempt = 1; verification_status = "passed"; evidence_paths = @("evidence/w1.json") })
        )
    }
    $routingRecord6d | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6d 'routing-outcomes.json') -Encoding utf8

    $prov6d = New-BaseProvenance $ws6d @(
        [ordered]@{
            id = "worker-1"
            role = "researcher"
            status = "completed"
            output = "evidence/w1.json"
            accepted_attempt = 2
        }
    )
    $prov6d | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6d 'provenance.json') -Encoding utf8

    $res6d = Invoke-CleanupPs1 @('--workspace', $ws6d, '--status', 'success')
    Assert-True ($res6d.ExitCode -ne 0) "reject-accepted-attempt-nonexistent-num: rejects accepted_attempt 2 when only attempt 1 exists"
    Assert-True (Test-Path -LiteralPath (Join-Path $ws6d 'raw.json')) "reject-accepted-attempt-nonexistent-num: preserves raw artifacts"

    # 3.6 Reject invalid accepted_attempt number (e.g. 0 or 3)
    $ws6e = New-TestWorkspace "reject-accepted-attempt-invalid-val"
    Set-Content -LiteralPath (Join-Path $ws6e 'raw.json') -Value "raw"
    [System.IO.Directory]::CreateDirectory((Join-Path $ws6e 'evidence')) | Out-Null
    Set-Content -LiteralPath (Join-Path $ws6e 'evidence/w1.json') -Value "att"

    $routingRecord6e = [ordered]@{
        schema_version = 1
        attempts = @(
            (New-RoutingAttempt @{ worker_id = "worker-1"; attempt = 1; verification_status = "passed"; evidence_paths = @("evidence/w1.json") })
        )
    }
    $routingRecord6e | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6e 'routing-outcomes.json') -Encoding utf8

    $prov6e = New-BaseProvenance $ws6e @(
        [ordered]@{
            id = "worker-1"
            role = "researcher"
            status = "completed"
            output = "evidence/w1.json"
            accepted_attempt = 3
        }
    )
    $prov6e | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6e 'provenance.json') -Encoding utf8

    $res6e = Invoke-CleanupPs1 @('--workspace', $ws6e, '--status', 'success')
    Assert-True ($res6e.ExitCode -ne 0) "reject-accepted-attempt-invalid-val: rejects accepted_attempt 3"

    # 3.7 Multi-worker provenance: all workers valid -> succeeds
    $ws6f = New-TestWorkspace "multi-worker-valid-provenance"
    Set-Content -LiteralPath (Join-Path $ws6f 'final.md') -Value "final"
    [System.IO.Directory]::CreateDirectory((Join-Path $ws6f 'evidence')) | Out-Null
    Set-Content -LiteralPath (Join-Path $ws6f 'evidence/w1.json') -Value "w1"
    Set-Content -LiteralPath (Join-Path $ws6f 'evidence/w2.att2.json') -Value "w2"

    $routingRecord6f = [ordered]@{
        schema_version = 1
        attempts = @(
            (New-RoutingAttempt @{ worker_id = "worker-1"; attempt = 1; verification_status = "passed"; evidence_paths = @("evidence/w1.json") }),
            (New-RoutingAttempt @{ worker_id = "worker-2"; attempt = 1; verification_status = "failed"; failure_class = "quality"; state = "failed" }),
            (New-RoutingAttempt @{ worker_id = "worker-2"; attempt = 2; route = "quality-retry"; verification_status = "passed"; evidence_paths = @("evidence/w2.att2.json") })
        )
    }
    $routingRecord6f | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6f 'routing-outcomes.json') -Encoding utf8

    $prov6f = New-BaseProvenance $ws6f @(
        [ordered]@{ id = "worker-1"; role = "researcher"; status = "completed"; output = "evidence/w1.json"; accepted_attempt = 1 },
        [ordered]@{ id = "worker-2"; role = "researcher"; status = "completed"; output = "evidence/w2.att2.json"; accepted_attempt = 2 }
    )
    $prov6f | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6f 'provenance.json') -Encoding utf8

    $res6f = Invoke-CleanupPs1 @('--workspace', $ws6f, '--status', 'success')
    Assert-Equal $res6f.ExitCode 0 "multi-worker-valid-provenance: all workers verified with valid artifacts succeeds"

    # 3.8 Multi-worker provenance: worker 1 valid, but worker 2 artifact missing -> rejected
    $ws6g = New-TestWorkspace "multi-worker-one-invalid-artifact"
    Set-Content -LiteralPath (Join-Path $ws6g 'raw.json') -Value "raw"
    [System.IO.Directory]::CreateDirectory((Join-Path $ws6g 'evidence')) | Out-Null
    Set-Content -LiteralPath (Join-Path $ws6g 'evidence/w1.json') -Value "w1"

    $routingRecord6g = [ordered]@{
        schema_version = 1
        attempts = @(
            (New-RoutingAttempt @{ worker_id = "worker-1"; attempt = 1; verification_status = "passed"; evidence_paths = @("evidence/w1.json") }),
            (New-RoutingAttempt @{ worker_id = "worker-2"; attempt = 1; verification_status = "passed"; evidence_paths = @("evidence/missing-w2.json") })
        )
    }
    $routingRecord6g | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6g 'routing-outcomes.json') -Encoding utf8

    $prov6g = New-BaseProvenance $ws6g @(
        [ordered]@{ id = "worker-1"; role = "researcher"; status = "completed"; output = "evidence/w1.json"; accepted_attempt = 1 },
        [ordered]@{ id = "worker-2"; role = "researcher"; status = "completed"; output = "evidence/missing-w2.json"; accepted_attempt = 1 }
    )
    $prov6g | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws6g 'provenance.json') -Encoding utf8

    $res6g = Invoke-CleanupPs1 @('--workspace', $ws6g, '--status', 'success')
    Assert-True ($res6g.ExitCode -ne 0) "multi-worker-one-invalid-artifact: rejects when one worker artifact is missing"

    # =======================================================================
    # Group 4: Acceptance of Extended Failure Class 'unrunnable'
    # =======================================================================

    # 4.1 Accept failure_class unrunnable
    $ws7 = New-TestWorkspace "failure-class-unrunnable"
    Set-Content -LiteralPath (Join-Path $ws7 'final.md') -Value "final"
    [System.IO.Directory]::CreateDirectory((Join-Path $ws7 'evidence')) | Out-Null
    Set-Content -LiteralPath (Join-Path $ws7 'evidence/diag.txt') -Value "gate exit 127"

    $routingRecord7 = [ordered]@{
        schema_version = 1
        attempts = @(
            (New-RoutingAttempt @{
                worker_id = "worker-gate"
                role = "gate-author"
                mode = "execution"
                attempt = 1
                exit_code = 127
                state = "failed"
                failure_class = "unrunnable"
                verification_status = "not_performed"
                evidence_paths = @("evidence/diag.txt")
            })
        )
    }
    $routingRecord7 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws7 'routing-outcomes.json') -Encoding utf8

    $res7 = Invoke-CleanupPs1 @('--workspace', $ws7, '--status', 'success')
    Assert-Equal $res7.ExitCode 0 "failure-class-unrunnable: cleanup accepts failure_class unrunnable"

    # 4.2 Reject unknown failure_class
    $ws7b = New-TestWorkspace "reject-unknown-failure-class"
    $rec7b = [ordered]@{
        schema_version = 1
        attempts = @((New-RoutingAttempt @{ worker_id = "worker-1"; attempt = 1; failure_class = "nonexistent_class" }))
    }
    $rec7b | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ws7b 'routing-outcomes.json') -Encoding utf8
    $res7b = Invoke-CleanupPs1 @('--workspace', $ws7b, '--status', 'success')
    Assert-True ($res7b.ExitCode -ne 0) "reject-unknown-failure-class: rejects unknown failure_class"

    # =======================================================================
    # Group 5: Evidence Disposition Manifest Hashing and Idempotence
    # =======================================================================

    $ws8 = New-TestWorkspace "evidence-disposition-hashing"
    Set-Content -LiteralPath (Join-Path $ws8 'final.md') -Value "retained final report"
    [System.IO.Directory]::CreateDirectory((Join-Path $ws8 'evidence')) | Out-Null
    $prunedContent = "content to be pruned and hashed"
    $prunedFile = Join-Path $ws8 'evidence/payload.txt'
    Set-Content -LiteralPath $prunedFile -Value $prunedContent -NoNewline
    $expectedHash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($prunedContent))).ToLowerInvariant()

    $outsideFile = Join-Path $TmpRoot 'outside-evidence.txt'
    Set-Content -LiteralPath $outsideFile -Value "outside evidence"

    $routingRecord8 = [ordered]@{
        schema_version = 1
        attempts = @(
            (New-RoutingAttempt @{
                worker_id = "worker-1"
                attempt = 1
                evidence_paths = @("evidence/payload.txt", "final.md", "missing.json", "../outside-evidence.txt")
            })
        )
    }
    $routingPath8 = Join-Path $ws8 'routing-outcomes.json'
    $routingRecord8 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $routingPath8 -Encoding utf8

    $res8 = Invoke-CleanupPs1 @('--workspace', $ws8, '--status', 'success')
    Assert-Equal $res8.ExitCode 0 "evidence-disposition: cleanup exits 0"
    $dispPath8 = Join-Path $ws8 'evidence-disposition.json'
    Assert-True (Test-Path -LiteralPath $dispPath8) "evidence-disposition: manifest created"
    $disp8 = Get-Content -LiteralPath $dispPath8 -Raw | ConvertFrom-Json
    Assert-Equal $disp8.schema_version 1 "evidence-disposition: schema_version is 1"

    $prunedEntry = @($disp8.entries | Where-Object path -eq 'evidence/payload.txt')[0]
    Assert-Equal $prunedEntry.disposition 'pruned' "evidence-disposition: pruned disposition"
    Assert-Equal $prunedEntry.sha256 $expectedHash "evidence-disposition: pruned file sha256 matches"

    $retainedEntry = @($disp8.entries | Where-Object path -eq 'final.md')[0]
    Assert-Equal $retainedEntry.disposition 'retained' "evidence-disposition: retained disposition"

    $missingEntry = @($disp8.entries | Where-Object path -eq 'missing.json')[0]
    Assert-Equal $missingEntry.disposition 'missing' "evidence-disposition: missing disposition"

    $outsideEntry = @($disp8.entries | Where-Object path -eq '../outside-evidence.txt')[0]
    Assert-Equal $outsideEntry.disposition 'uninspected' "evidence-disposition: outside path uninspected"

    # Idempotence: repeated cleanup preserves routing outcomes and manifest
    $routingBeforeRepeat = Get-Content -LiteralPath $routingPath8 -Raw
    $dispBeforeRepeat = Get-Content -LiteralPath $dispPath8 -Raw
    $res8Repeat = Invoke-CleanupPs1 @('--workspace', $ws8, '--status', 'success')
    Assert-Equal $res8Repeat.ExitCode 0 "evidence-disposition: repeated cleanup exits 0"
    Assert-Equal (Get-Content -LiteralPath $routingPath8 -Raw) $routingBeforeRepeat "evidence-disposition: preserves routing outcomes on repeat"
    Assert-Equal (Get-Content -LiteralPath $dispPath8 -Raw) $dispBeforeRepeat "evidence-disposition: preserves manifest on repeat"

    # =======================================================================
    # Group 6: Nested Routing in provenance.json (collect-provenance.ps1)
    # =======================================================================

    # 6.1 Valid single-attempt nested routing passes validation
    $provPath9a = Join-Path $TmpRoot 'prov-nested-valid.json'
    $provData9a = [ordered]@{
        run_id = "test-run"; request_summary = "test"; selected_mode = "web-research"; profile = "standard"; deep_trigger = $null;
        start_time = "2026-09-03T00:00:00Z"; end_time = "2026-09-03T00:05:00Z"; duration_seconds = 300; scratch_path = $TmpRoot;
        workers = @(
            [ordered]@{
                id = "researcher-web-1"
                role = "researcher"
                status = "completed"
                output = "researcher-web-1.json"
                accepted_attempt = 1
                routing = [ordered]@{
                    schema_version = 1
                    attempts = @(
                        (New-RoutingAttempt @{ worker_id = "researcher-web-1"; mode = "web-research"; attempt = 1; evidence_paths = @("researcher-web-1.json") })
                    )
                }
            }
        )
        repository_snapshot_paths = @(); final_citations = @("https://example.com"); audit_verdicts = @(); final_status = "success"; incomplete_stage_reasons = @()
    }
    $provData9a | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $provPath9a -Encoding utf8
    $res9a = Invoke-ProvenancePs1 @('--validate', $provPath9a)
    Assert-Equal $res9a.ExitCode 0 "provenance-nested-routing: valid nested routing passes validation"

    # 6.2 Reject worker nested routing with 3 attempts
    $provPath9b = Join-Path $TmpRoot 'prov-nested-three-attempts.json'
    $provData9b = [ordered]@{
        run_id = "test-run"; request_summary = "test"; selected_mode = "web-research"; profile = "standard"; deep_trigger = $null;
        start_time = "2026-09-03T00:00:00Z"; end_time = "2026-09-03T00:05:00Z"; duration_seconds = 300; scratch_path = $TmpRoot;
        workers = @(
            [ordered]@{
                id = "researcher-web-1"
                role = "researcher"
                status = "completed"
                output = "researcher-web-1.json"
                accepted_attempt = 1
                routing = [ordered]@{
                    schema_version = 1
                    attempts = @(
                        (New-RoutingAttempt @{ worker_id = "researcher-web-1"; mode = "web-research"; attempt = 1; evidence_paths = @("att1.json") }),
                        (New-RoutingAttempt @{ worker_id = "researcher-web-1"; mode = "web-research"; attempt = 2; evidence_paths = @("att2.json") }),
                        (New-RoutingAttempt @{ worker_id = "researcher-web-1"; mode = "web-research"; attempt = 3; evidence_paths = @("att3.json") })
                    )
                }
            }
        )
        repository_snapshot_paths = @(); final_citations = @("https://example.com"); audit_verdicts = @(); final_status = "success"; incomplete_stage_reasons = @()
    }
    $provData9b | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $provPath9b -Encoding utf8
    $res9b = Invoke-ProvenancePs1 @('--validate', $provPath9b)
    Assert-True ($res9b.ExitCode -ne 0) "provenance-nested-routing: rejects worker with 3 attempts"

    # 6.3 Accept failure_class unrunnable in provenance routing
    $provPath9c = Join-Path $TmpRoot 'prov-nested-unrunnable.json'
    $provData9c = [ordered]@{
        run_id = "test-run"; request_summary = "test"; selected_mode = "web-research"; profile = "standard"; deep_trigger = $null;
        start_time = "2026-09-03T00:00:00Z"; end_time = "2026-09-03T00:05:00Z"; duration_seconds = 300; scratch_path = $TmpRoot;
        workers = @(
            [ordered]@{
                id = "researcher-web-1"
                role = "researcher"
                status = "completed"
                output = "researcher-web-1.json"
                accepted_attempt = 1
                routing = [ordered]@{
                    schema_version = 1
                    attempts = @(
                        (New-RoutingAttempt @{
                            worker_id = "researcher-web-1"
                            mode = "web-research"
                            attempt = 1
                            failure_class = "unrunnable"
                            verification_status = "not_performed"
                            evidence_paths = @("researcher-web-1.json")
                        })
                    )
                }
            }
        )
        repository_snapshot_paths = @(); final_citations = @("https://example.com"); audit_verdicts = @(); final_status = "success"; incomplete_stage_reasons = @()
    }
    $provData9c | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $provPath9c -Encoding utf8
    $res9c = Invoke-ProvenancePs1 @('--validate', $provPath9c)
    Assert-Equal $res9c.ExitCode 0 "provenance-nested-routing: accepts unrunnable failure_class"

    # 6.4 Reject duplicate (worker_id, attempt) in nested routing
    $provPath9d = Join-Path $TmpRoot 'prov-nested-duplicate.json'
    $provData9d = [ordered]@{
        run_id = "test-run"; request_summary = "test"; selected_mode = "web-research"; profile = "standard"; deep_trigger = $null;
        start_time = "2026-09-03T00:00:00Z"; end_time = "2026-09-03T00:05:00Z"; duration_seconds = 300; scratch_path = $TmpRoot;
        workers = @(
            [ordered]@{
                id = "researcher-web-1"
                role = "researcher"
                status = "completed"
                output = "researcher-web-1.json"
                accepted_attempt = 1
                routing = [ordered]@{
                    schema_version = 1
                    attempts = @(
                        (New-RoutingAttempt @{ worker_id = "researcher-web-1"; mode = "web-research"; attempt = 1 }),
                        (New-RoutingAttempt @{ worker_id = "researcher-web-1"; mode = "web-research"; attempt = 1 })
                    )
                }
            }
        )
        repository_snapshot_paths = @(); final_citations = @("https://example.com"); audit_verdicts = @(); final_status = "success"; incomplete_stage_reasons = @()
    }
    $provData9d | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $provPath9d -Encoding utf8
    $res9d = Invoke-ProvenancePs1 @('--validate', $provPath9d)
    Assert-True ($res9d.ExitCode -ne 0) "provenance-nested-routing: rejects duplicate attempt number"

    # 6.5 Multi-worker nested routing in provenance.json
    $provPath9e = Join-Path $TmpRoot 'prov-nested-multi-worker.json'
    $provData9e = [ordered]@{
        run_id = "test-run"; request_summary = "test"; selected_mode = "web-research"; profile = "standard"; deep_trigger = $null;
        start_time = "2026-09-03T00:00:00Z"; end_time = "2026-09-03T00:05:00Z"; duration_seconds = 300; scratch_path = $TmpRoot;
        workers = @(
            [ordered]@{
                id = "researcher-1"
                role = "researcher"
                status = "completed"
                output = "w1.json"
                accepted_attempt = 1
                routing = [ordered]@{
                    schema_version = 1
                    attempts = @(
                        (New-RoutingAttempt @{ worker_id = "researcher-1"; mode = "web-research"; attempt = 1; evidence_paths = @("w1.json") })
                    )
                }
            },
            [ordered]@{
                id = "researcher-2"
                role = "researcher"
                status = "completed"
                output = "w2.att2.json"
                accepted_attempt = 2
                routing = [ordered]@{
                    schema_version = 1
                    attempts = @(
                        (New-RoutingAttempt @{ worker_id = "researcher-2"; mode = "web-research"; attempt = 1; state = "failed"; verification_status = "failed"; failure_class = "quality"; evidence_paths = @("w2.att1.json") }),
                        (New-RoutingAttempt @{ worker_id = "researcher-2"; mode = "web-research"; attempt = 2; route = "quality-retry"; verification_status = "passed"; evidence_paths = @("w2.att2.json") })
                    )
                }
            }
        )
        repository_snapshot_paths = @(); final_citations = @("https://example.com"); audit_verdicts = @(); final_status = "success"; incomplete_stage_reasons = @()
    }
    $provData9e | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $provPath9e -Encoding utf8
    $res9e = Invoke-ProvenancePs1 @('--validate', $provPath9e)
    Assert-Equal $res9e.ExitCode 0 "provenance-nested-routing: accepts multi-worker nested routing"

    # =======================================================================
    # Group 7: Cross-Platform Parity with Bash Helpers
    # =======================================================================

    if ($BashBin) {
        # 7.1 Multi-worker three workers (Bash)
        $wsBash1 = New-TestWorkspace "bash-multi-worker-three"
        Set-Content -LiteralPath (Join-Path $wsBash1 'final.md') -Value "final"
        [System.IO.Directory]::CreateDirectory((Join-Path $wsBash1 'evidence')) | Out-Null
        Set-Content -LiteralPath (Join-Path $wsBash1 'evidence/w1.json') -Value "w1"
        Set-Content -LiteralPath (Join-Path $wsBash1 'evidence/w2.json') -Value "w2"
        Set-Content -LiteralPath (Join-Path $wsBash1 'evidence/w3.json') -Value "w3"
        Set-Content -LiteralPath (Join-Path $wsBash1 'disposable.txt') -Value "disposable"
        $prov1 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $wsBash1 'provenance.json') -Encoding utf8
        $routingRecord1 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $wsBash1 'routing-outcomes.json') -Encoding utf8

        $resBash1 = Invoke-CleanupSh @('--workspace', $wsBash1, '--status', 'success')
        Assert-Equal $resBash1.ExitCode 0 "bash-accept-three-workers-one-attempt: exit code is 0"
        Assert-True (Test-Path -LiteralPath (Join-Path $wsBash1 'routing-outcomes.json')) "bash-accept-three-workers-one-attempt: routing retained"
        Assert-True (Test-Path -LiteralPath (Join-Path $wsBash1 'evidence-disposition.json')) "bash-accept-three-workers-one-attempt: disposition created"
        Assert-False (Test-Path -LiteralPath (Join-Path $wsBash1 'disposable.txt')) "bash-accept-three-workers-one-attempt: disposable pruned"

        # 7.2 Workers A, B, C attempt 1 + worker B attempt 2 (Bash)
        $wsBash2 = New-TestWorkspace "bash-multi-worker-retry"
        Set-Content -LiteralPath (Join-Path $wsBash2 'final.md') -Value "final"
        [System.IO.Directory]::CreateDirectory((Join-Path $wsBash2 'evidence')) | Out-Null
        Set-Content -LiteralPath (Join-Path $wsBash2 'evidence/wa1.json') -Value "wa1"
        Set-Content -LiteralPath (Join-Path $wsBash2 'evidence/wb1.json') -Value "wb1"
        Set-Content -LiteralPath (Join-Path $wsBash2 'evidence/wb2.json') -Value "wb2"
        Set-Content -LiteralPath (Join-Path $wsBash2 'evidence/wc1.json') -Value "wc1"
        $prov2 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $wsBash2 'provenance.json') -Encoding utf8
        $routingRecord2 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $wsBash2 'routing-outcomes.json') -Encoding utf8

        $resBash2 = Invoke-CleanupSh @('--workspace', $wsBash2, '--status', 'success')
        Assert-Equal $resBash2.ExitCode 0 "bash-accept-workers-retry: exit code is 0"

        # 7.3 Reject three attempts for one worker (Bash)
        $wsBash3 = New-TestWorkspace "bash-reject-three-attempts"
        Set-Content -LiteralPath (Join-Path $wsBash3 'raw.json') -Value "raw"
        $routingRecord3 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $wsBash3 'routing-outcomes.json') -Encoding utf8
        $resBash3 = Invoke-CleanupSh @('--workspace', $wsBash3, '--status', 'success')
        Assert-True ($resBash3.ExitCode -ne 0) "bash-reject-three-attempts: non-zero exit code"
        Assert-True (Test-Path -LiteralPath (Join-Path $wsBash3 'raw.json')) "bash-reject-three-attempts: preserves raw artifacts"

        # 7.4 Reject duplicate (worker_id, attempt) pair (Bash)
        $wsBash4 = New-TestWorkspace "bash-reject-duplicate-attempt"
        Set-Content -LiteralPath (Join-Path $wsBash4 'raw.json') -Value "raw"
        $routingRecord4 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $wsBash4 'routing-outcomes.json') -Encoding utf8
        $resBash4 = Invoke-CleanupSh @('--workspace', $wsBash4, '--status', 'success')
        Assert-True ($resBash4.ExitCode -ne 0) "bash-reject-duplicate-attempt: non-zero exit code"

        # 7.5 Reject invalid attempt number (Bash)
        $wsBash5 = New-TestWorkspace "bash-reject-invalid-attempt"
        $rec5b | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $wsBash5 'routing-outcomes.json') -Encoding utf8
        $resBash5 = Invoke-CleanupSh @('--workspace', $wsBash5, '--status', 'success')
        Assert-True ($resBash5.ExitCode -ne 0) "bash-reject-invalid-attempt: non-zero exit code"

        # 7.6 Accept unrunnable failure_class (Bash)
        $wsBash6 = New-TestWorkspace "bash-failure-class-unrunnable"
        Set-Content -LiteralPath (Join-Path $wsBash6 'final.md') -Value "final"
        $routingRecord7 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $wsBash6 'routing-outcomes.json') -Encoding utf8
        $resBash6 = Invoke-CleanupSh @('--workspace', $wsBash6, '--status', 'success')
        Assert-Equal $resBash6.ExitCode 0 "bash-failure-class-unrunnable: accepts unrunnable failure_class"

        # 7.7 Valid accepted_attempt in provenance.json (Bash)
        $wsBash7 = New-TestWorkspace "bash-valid-accepted-attempt"
        Set-Content -LiteralPath (Join-Path $wsBash7 'final.md') -Value "final"
        [System.IO.Directory]::CreateDirectory((Join-Path $wsBash7 'evidence')) | Out-Null
        Set-Content -LiteralPath (Join-Path $wsBash7 'evidence/w1.attempt2.json') -Value "att2"
        $routingRecord6a | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $wsBash7 'routing-outcomes.json') -Encoding utf8
        $prov6a | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $wsBash7 'provenance.json') -Encoding utf8
        $resBash7 = Invoke-CleanupSh @('--workspace', $wsBash7, '--status', 'success')
        Assert-Equal $resBash7.ExitCode 0 "bash-valid-accepted-attempt: resolves to verified artifact"

        # 7.8 Reject accepted_attempt whose verification failed (Bash)
        $wsBash8 = New-TestWorkspace "bash-reject-accepted-attempt-failed"
        Set-Content -LiteralPath (Join-Path $wsBash8 'raw.json') -Value "raw"
        [System.IO.Directory]::CreateDirectory((Join-Path $wsBash8 'evidence')) | Out-Null
        Set-Content -LiteralPath (Join-Path $wsBash8 'evidence/w1.attempt1.json') -Value "att1"
        $routingRecord6b | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $wsBash8 'routing-outcomes.json') -Encoding utf8
        $prov6b | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $wsBash8 'provenance.json') -Encoding utf8
        $resBash8 = Invoke-CleanupSh @('--workspace', $wsBash8, '--status', 'success')
        Assert-True ($resBash8.ExitCode -ne 0) "bash-reject-accepted-attempt-failed: rejects failed verification"

        # 7.9 Reject accepted_attempt whose artifact is missing (Bash)
        $wsBash9 = New-TestWorkspace "bash-reject-accepted-attempt-missing-art"
        Set-Content -LiteralPath (Join-Path $wsBash9 'raw.json') -Value "raw"
        $routingRecord6c | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $wsBash9 'routing-outcomes.json') -Encoding utf8
        $prov6c | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $wsBash9 'provenance.json') -Encoding utf8
        $resBash9 = Invoke-CleanupSh @('--workspace', $wsBash9, '--status', 'success')
        Assert-True ($resBash9.ExitCode -ne 0) "bash-reject-accepted-attempt-missing-art: rejects missing artifact"

        # 7.10 Nested routing in collect-provenance.sh if available
        $resProvShTest = Invoke-ProvenanceSh @('--validate', $provPath9a)
        if ($null -ne $resProvShTest) {
            Assert-Equal $resProvShTest.ExitCode 0 "bash-provenance-nested-routing: valid nested routing passes"

            $resProvShFail = Invoke-ProvenanceSh @('--validate', $provPath9b)
            Assert-True ($resProvShFail.ExitCode -ne 0) "bash-provenance-nested-routing: rejects worker with 3 attempts"

            $resProvShUnrun = Invoke-ProvenanceSh @('--validate', $provPath9c)
            Assert-Equal $resProvShUnrun.ExitCode 0 "bash-provenance-nested-routing: accepts unrunnable failure_class"
        }
    } else {
        [Console]::Out.WriteLine("# SKIP - Bash not available for Bash parity cleanup tests")
    }

} finally {
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -Recurse -Force -LiteralPath $TmpRoot -ErrorAction SilentlyContinue
    }
}

[Console]::Out.WriteLine("All $($script:TotalTests) tests passed.")
exit 0
