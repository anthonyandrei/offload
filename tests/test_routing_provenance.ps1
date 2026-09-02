#!/usr/bin/env pwsh
# tests/test_routing_provenance.ps1
# Self-contained acceptance test suite for provenance routing validation.
# Implements contracts specified in docs/specs/0003-gemini-model-routing.md.
# Strict constraints: Standalone PowerShell 7 / .NET only, no Pester, Python, jq, Bash, or network.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

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
        Fail $name (if ($reason) { $reason } else { "Condition was false" })
    }
}

function Assert-False([bool]$condition, [string]$name, [string]$reason = "") {
    if (-not $condition) {
        Pass $name
    } else {
        Fail $name (if ($reason) { $reason } else { "Condition was true" })
    }
}

function Assert-Equal($actual, $expected, [string]$name) {
    if ($actual -eq $expected) {
        Pass $name
    } else {
        Fail $name "Expected '$expected', got '$actual'"
    }
}

$PwshBin = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $PwshBin) {
    $PwshBin = (Get-Process -Id $PID).Path
}

$RootDir = Split-Path -Parent $PSScriptRoot
$ScriptsDir = Join-Path $RootDir 'scripts'
$ProvHelper = Join-Path $ScriptsDir 'collect-provenance.ps1'

if (-not (Test-Path -LiteralPath $ProvHelper -PathType Leaf)) {
    Fail "init" "Script '$ProvHelper' not found"
}

function Invoke-Provenance {
    param(
        [string[]]$ArgumentList = @()
    )
    $pwshArgs = @('-NoProfile', '-NonInteractive', '-File', $ProvHelper) + $ArgumentList
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $PwshBin
    foreach ($arg in $pwshArgs) {
        $psi.ArgumentList.Add($arg)
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

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

$TmpRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "offload-prov-test-$([System.Guid]::NewGuid().ToString('N'))")
[System.IO.Directory]::CreateDirectory($TmpRoot) | Out-Null

try {
    function New-BaseProvenance([hashtable]$overrides = @{}) {
        $base = [ordered]@{
            run_id = "test-run-001"
            request_summary = "Test summary for model routing provenance"
            selected_mode = "web-research"
            profile = "standard"
            deep_trigger = $null
            start_time = "2026-09-03T00:00:00Z"
            end_time = "2026-09-03T00:05:00Z"
            duration_seconds = 300.0
            scratch_path = (Join-Path $TmpRoot 'scratch')
            workers = @()
            repository_snapshot_paths = @()
            final_citations = @("https://example.com/source")
            audit_verdicts = @()
            final_status = "success"
            incomplete_stage_reasons = @()
        }
        foreach ($k in $overrides.Keys) {
            $base[$k] = $overrides[$k]
        }
        return $base
    }

    function New-BaseAttempt([hashtable]$overrides = @{}) {
        $att = [ordered]@{
            worker_id = "researcher-web-1"
            role = "researcher"
            mode = "web-research"
            attempt = 1
            policy_revision = "2026-09-03.1"
            route = "default"
            model = "gemini-3.8-flash-high"
            effort = "high"
            reason = "Initial default dispatch"
            started_at = "2026-09-03T00:00:00Z"
            ended_at = "2026-09-03T00:01:30Z"
            duration_seconds = 90.0
            exit_code = 0
            state = "completed"
            failure_class = "none"
            verification_status = "passed"
            evidence_paths = @("evidence/researcher-web-1.json")
            usage = [ordered]@{
                prompt_tokens = 1000
                candidates_tokens = 250
                unit = "tokens"
            }
        }
        foreach ($k in $overrides.Keys) {
            $att[$k] = $overrides[$k]
        }
        return $att
    }

    function Write-ProvJson([hashtable]$provData, [string]$fileName) {
        $path = Join-Path $TmpRoot $fileName
        $json = $provData | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($path, $json, [System.Text.Encoding]::UTF8)
        return $path
    }

    # =========================================================================
    # Group 1: Valid routing data
    # =========================================================================

    # 1.1: Single worker with valid routing
    $att1 = New-BaseAttempt
    $worker1 = [ordered]@{
        id = "researcher-web-1"
        role = "researcher"
        status = "completed"
        output = "workspace/researcher-web-1.json"
        routing = [ordered]@{
            schema_version = 1
            attempts = @($att1)
        }
    }
    $prov1 = New-BaseProvenance @{ workers = @($worker1) }
    $file1 = Write-ProvJson $prov1 'prov-valid-single.json'
    $res1 = Invoke-Provenance @('--validate', $file1)
    Assert-Equal $res1.ExitCode 0 "valid-routing: single worker with valid routing passes validation"

    # 1.2: Multiple workers with valid routing across roles
    $attSynth = New-BaseAttempt @{
        worker_id = "synthesizer-1"
        role = "synthesizer"
        started_at = "2026-09-03T00:02:00Z"
        ended_at = "2026-09-03T00:03:00Z"
        duration_seconds = 60.0
        evidence_paths = @("workspace/synthesizer-1.json")
    }
    $workerSynth = [ordered]@{
        id = "synthesizer-1"
        role = "synthesizer"
        status = "completed"
        output = "workspace/synthesizer-1.json"
        routing = [ordered]@{
            schema_version = 1
            attempts = @($attSynth)
        }
    }
    $provMulti = New-BaseProvenance @{ workers = @($worker1, $workerSynth) }
    $fileMulti = Write-ProvJson $provMulti 'prov-valid-multi.json'
    $resMulti = Invoke-Provenance @('--validate', $fileMulti)
    Assert-Equal $resMulti.ExitCode 0 "valid-routing: multiple workers with valid routing pass validation"

    # 1.3: Worker with 2 attempts (retry)
    $attRetry1 = New-BaseAttempt @{
        attempt = 1
        state = "failed"
        failure_class = "quality"
        verification_status = "failed"
        duration_seconds = 45.0
        reason = "Initial default dispatch"
    }
    $attRetry2 = New-BaseAttempt @{
        attempt = 2
        route = "quality-retry"
        state = "completed"
        failure_class = "none"
        verification_status = "passed"
        duration_seconds = 55.0
        reason = "Retry authorized after quality gate failure on attempt 1"
    }
    $workerRetry = [ordered]@{
        id = "researcher-web-1"
        role = "researcher"
        status = "completed"
        output = "workspace/researcher-web-1.json"
        routing = [ordered]@{
            schema_version = 1
            attempts = @($attRetry1, $attRetry2)
        }
    }
    $provRetry = New-BaseProvenance @{ workers = @($workerRetry) }
    $fileRetry = Write-ProvJson $provRetry 'prov-valid-retry.json'
    $resRetry = Invoke-Provenance @('--validate', $fileRetry)
    Assert-Equal $resRetry.ExitCode 0 "valid-routing: worker with two attempts passes validation"

    # 1.4: Worker with 'verification' property instead of 'verification_status'
    $attVerAlt = New-BaseAttempt
    $attVerAlt.Remove('verification_status')
    $attVerAlt['verification'] = 'passed'
    $workerVerAlt = [ordered]@{
        id = "researcher-web-1"
        role = "researcher"
        status = "completed"
        output = "workspace/researcher-web-1.json"
        routing = [ordered]@{
            schema_version = 1
            attempts = @($attVerAlt)
        }
    }
    $provVerAlt = New-BaseProvenance @{ workers = @($workerVerAlt) }
    $fileVerAlt = Write-ProvJson $provVerAlt 'prov-valid-ver-alt.json'
    $resVerAlt = Invoke-Provenance @('--validate', $fileVerAlt)
    Assert-Equal $resVerAlt.ExitCode 0 "valid-routing: accepts 'verification' synonym for 'verification_status'"

    # 1.5: Valid low-effort worker (e.g. scout with low effort)
    $attScout = New-BaseAttempt @{
        worker_id = "scout-1"
        role = "scout"
        mode = "execution"
        model = "gemini-3.8-flash-low"
        effort = "low"
    }
    $workerScout = [ordered]@{
        id = "scout-1"
        role = "scout"
        status = "completed"
        routing = [ordered]@{
            schema_version = 1
            attempts = @($attScout)
        }
    }
    $provScout = New-BaseProvenance @{ workers = @($workerScout) }
    $fileScout = Write-ProvJson $provScout 'prov-valid-scout-low.json'
    $resScout = Invoke-Provenance @('--validate', $fileScout)
    Assert-Equal $resScout.ExitCode 0 "valid-routing: accepts scout with gemini-3.8-flash-low and low effort"

    # 1.6: Build mode with valid routing workers
    $workersJson = @($worker1) | ConvertTo-Json -AsArray -Depth 20 -Compress
    $buildOut = Join-Path $TmpRoot 'built-provenance.json'
    $resBuild = Invoke-Provenance @(
        '--run-id', 'build-run-001',
        '--request-summary', 'Build mode test',
        '--selected-mode', 'web-research',
        '--profile', 'standard',
        '--start-time', '2026-09-03T00:00:00Z',
        '--end-time', '2026-09-03T00:05:00Z',
        '--duration-seconds', '300',
        '--scratch-path', (Join-Path $TmpRoot 'build-scratch'),
        '--workers', $workersJson,
        '--final-status', 'success',
        '--output', $buildOut
    )
    Assert-Equal $resBuild.ExitCode 0 "valid-routing: builds provenance with routing workers"
    Assert-True (Test-Path -LiteralPath $buildOut -PathType Leaf) "valid-routing: build output file created"

    # =========================================================================
    # Group 2: Legacy worker compatibility
    # =========================================================================

    # 2.1: Legacy historical worker without routing property
    $legacyWorker1 = [ordered]@{
        id = "researcher-gemini"
        role = "researcher"
        status = "completed"
        model = "gemini-3.7-flash-high"
        output = "workspace/researcher-gemini.json"
    }
    $provLegacy1 = New-BaseProvenance @{ workers = @($legacyWorker1) }
    $fileLegacy1 = Write-ProvJson $provLegacy1 'prov-legacy-single.json'
    $resLegacy1 = Invoke-Provenance @('--validate', $fileLegacy1)
    Assert-Equal $resLegacy1.ExitCode 0 "legacy-worker: accepts worker without routing property"

    # 2.2: Legacy worker with explicit routing: null
    $legacyWorkerNull = [ordered]@{
        id = "researcher-gemini"
        role = "researcher"
        status = "completed"
        output = "workspace/researcher.json"
        routing = $null
    }
    $provLegacyNull = New-BaseProvenance @{ workers = @($legacyWorkerNull) }
    $fileLegacyNull = Write-ProvJson $provLegacyNull 'prov-legacy-null.json'
    $resLegacyNull = Invoke-Provenance @('--validate', $fileLegacyNull)
    Assert-Equal $resLegacyNull.ExitCode 0 "legacy-worker: accepts worker with routing explicitly null"

    # 2.3: Empty workers array
    $provEmptyWorkers = New-BaseProvenance @{ workers = @() }
    $fileEmptyWorkers = Write-ProvJson $provEmptyWorkers 'prov-empty-workers.json'
    $resEmptyWorkers = Invoke-Provenance @('--validate', $fileEmptyWorkers)
    Assert-Equal $resEmptyWorkers.ExitCode 0 "legacy-worker: accepts empty workers array"

    # 2.4: Mixed workers: one legacy worker, one modern worker with routing
    $provMixed = New-BaseProvenance @{ workers = @($legacyWorker1, $worker1) }
    $fileMixed = Write-ProvJson $provMixed 'prov-mixed-workers.json'
    $resMixed = Invoke-Provenance @('--validate', $fileMixed)
    Assert-Equal $resMixed.ExitCode 0 "legacy-worker: accepts mixture of legacy and routing workers"

    # =========================================================================
    # Group 3: Pending endings and null usage
    # =========================================================================

    # 3.1: Pending attempt (still running, ending values null)
    $attPending = New-BaseAttempt @{
        ended_at = $null
        duration_seconds = $null
        exit_code = $null
        state = "running"
        failure_class = "none"
        verification_status = "pending"
        evidence_paths = @()
        usage = $null
    }
    $workerPending = [ordered]@{
        id = "researcher-web-1"
        role = "researcher"
        status = "running"
        routing = [ordered]@{
            schema_version = 1
            attempts = @($attPending)
        }
    }
    $provPending = New-BaseProvenance @{ workers = @($workerPending) }
    $filePending = Write-ProvJson $provPending 'prov-pending-attempt.json'
    $resPending = Invoke-Provenance @('--validate', $filePending)
    Assert-Equal $resPending.ExitCode 0 "pending/null: accepts pending attempt with null endings and null usage"

    # 3.2: Completed attempt with null usage
    $attNullUsage = New-BaseAttempt @{
        usage = $null
    }
    $workerNullUsage = [ordered]@{
        id = "researcher-web-1"
        role = "researcher"
        status = "completed"
        routing = [ordered]@{
            schema_version = 1
            attempts = @($attNullUsage)
        }
    }
    $provNullUsage = New-BaseProvenance @{ workers = @($workerNullUsage) }
    $fileNullUsage = Write-ProvJson $provNullUsage 'prov-null-usage.json'
    $resNullUsage = Invoke-Provenance @('--validate', $fileNullUsage)
    Assert-Equal $resNullUsage.ExitCode 0 "pending/null: accepts completed attempt with null usage"

    # 3.3: Interrupted attempt with null exit_code and null usage
    $attInterrupted = New-BaseAttempt @{
        state = "interrupted"
        failure_class = "quota"
        exit_code = $null
        verification_status = "not_performed"
        usage = $null
    }
    $workerInterrupted = [ordered]@{
        id = "researcher-web-1"
        role = "researcher"
        status = "interrupted"
        routing = [ordered]@{
            schema_version = 1
            attempts = @($attInterrupted)
        }
    }
    $provInterrupted = New-BaseProvenance @{ workers = @($workerInterrupted) }
    $fileInterrupted = Write-ProvJson $provInterrupted 'prov-interrupted.json'
    $resInterrupted = Invoke-Provenance @('--validate', $fileInterrupted)
    Assert-Equal $resInterrupted.ExitCode 0 "pending/null: accepts interrupted attempt with quota failure and null exit_code"

    # =========================================================================
    # Group 4: Invalid attempt number / structure
    # =========================================================================

    # 4.1: Attempt number is 0
    $attBadZero = New-BaseAttempt @{ attempt = 0 }
    $wBadZero = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attBadZero) } }
    $fBadZero = Write-ProvJson (New-BaseProvenance @{ workers = @($wBadZero) }) 'prov-bad-att-0.json'
    $rBadZero = Invoke-Provenance @('--validate', $fBadZero)
    Assert-True ($rBadZero.ExitCode -ne 0) "invalid-attempt: rejects attempt number 0"

    # 4.2: Attempt number is 3
    $attBadThree = New-BaseAttempt @{ attempt = 3 }
    $wBadThree = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attBadThree) } }
    $fBadThree = Write-ProvJson (New-BaseProvenance @{ workers = @($wBadThree) }) 'prov-bad-att-3.json'
    $rBadThree = Invoke-Provenance @('--validate', $fBadThree)
    Assert-True ($rBadThree.ExitCode -ne 0) "invalid-attempt: rejects attempt number 3"

    # 4.3: Attempt number is string "1"
    $attBadStr = New-BaseAttempt @{ attempt = "1" }
    $wBadStr = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attBadStr) } }
    $fBadStr = Write-ProvJson (New-BaseProvenance @{ workers = @($wBadStr) }) 'prov-bad-att-str.json'
    $rBadStr = Invoke-Provenance @('--validate', $fBadStr)
    Assert-True ($rBadStr.ExitCode -ne 0) "invalid-attempt: rejects string attempt number"

    # 4.4: Duplicate attempt numbers
    $attDup1 = New-BaseAttempt @{ attempt = 1 }
    $attDup2 = New-BaseAttempt @{ attempt = 1 }
    $wDup = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attDup1, $attDup2) } }
    $fDup = Write-ProvJson (New-BaseProvenance @{ workers = @($wDup) }) 'prov-dup-att.json'
    $rDup = Invoke-Provenance @('--validate', $fDup)
    Assert-True ($rDup.ExitCode -ne 0) "invalid-attempt: rejects duplicate attempt number in attempts array"

    # 4.5: More than 2 attempts in array
    $attM1 = New-BaseAttempt @{ attempt = 1 }
    $attM2 = New-BaseAttempt @{ attempt = 2 }
    $attM3 = New-BaseAttempt @{ attempt = 1 }
    $wTooMany = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attM1, $attM2, $attM3) } }
    $fTooMany = Write-ProvJson (New-BaseProvenance @{ workers = @($wTooMany) }) 'prov-too-many-att.json'
    $rTooMany = Invoke-Provenance @('--validate', $fTooMany)
    Assert-True ($rTooMany.ExitCode -ne 0) "invalid-attempt: rejects attempts array with more than 2 attempts"

    # =========================================================================
    # Group 5: Invalid role
    # =========================================================================

    # 5.1: Unknown role
    $attBadRole = New-BaseAttempt @{ role = "unknown-role" }
    $wBadRole = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attBadRole) } }
    $fBadRole = Write-ProvJson (New-BaseProvenance @{ workers = @($wBadRole) }) 'prov-bad-role.json'
    $rBadRole = Invoke-Provenance @('--validate', $fBadRole)
    Assert-True ($rBadRole.ExitCode -ne 0) "invalid-role: rejects unknown role"

    # 5.2: Role is empty string
    $attEmptyRole = New-BaseAttempt @{ role = "" }
    $wEmptyRole = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attEmptyRole) } }
    $fEmptyRole = Write-ProvJson (New-BaseProvenance @{ workers = @($wEmptyRole) }) 'prov-empty-role.json'
    $rEmptyRole = Invoke-Provenance @('--validate', $fEmptyRole)
    Assert-True ($rEmptyRole.ExitCode -ne 0) "invalid-role: rejects empty role"

    # =========================================================================
    # Group 6: Invalid effort
    # =========================================================================

    # 6.1: Effort is unknown ("ultra")
    $attBadEffort = New-BaseAttempt @{ effort = "ultra"; model = "gemini-3.8-flash-high" }
    $wBadEffort = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attBadEffort) } }
    $fBadEffort = Write-ProvJson (New-BaseProvenance @{ workers = @($wBadEffort) }) 'prov-bad-effort-ultra.json'
    $rBadEffort = Invoke-Provenance @('--validate', $fBadEffort)
    Assert-True ($rBadEffort.ExitCode -ne 0) "invalid-effort: rejects effort 'ultra'"

    # 6.2: Effort ceiling violation ("max")
    $attMaxEffort = New-BaseAttempt @{ effort = "max"; model = "gemini-3.8-flash-high" }
    $wMaxEffort = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attMaxEffort) } }
    $fMaxEffort = Write-ProvJson (New-BaseProvenance @{ workers = @($wMaxEffort) }) 'prov-bad-effort-max.json'
    $rMaxEffort = Invoke-Provenance @('--validate', $fMaxEffort)
    Assert-True ($rMaxEffort.ExitCode -ne 0) "invalid-effort: rejects effort 'max'"

    # 6.3: Effort mismatch with model suffix
    $attMismatch = New-BaseAttempt @{ effort = "low"; model = "gemini-3.8-flash-high" }
    $wMismatch = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attMismatch) } }
    $fMismatch = Write-ProvJson (New-BaseProvenance @{ workers = @($wMismatch) }) 'prov-effort-mismatch.json'
    $rMismatch = Invoke-Provenance @('--validate', $fMismatch)
    Assert-True ($rMismatch.ExitCode -ne 0) "invalid-effort: rejects effort mismatching model suffix"

    # =========================================================================
    # Group 7: Invalid duration
    # =========================================================================

    # 7.1: Negative duration integer
    $attNegDur = New-BaseAttempt @{ duration_seconds = -10 }
    $wNegDur = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attNegDur) } }
    $fNegDur = Write-ProvJson (New-BaseProvenance @{ workers = @($wNegDur) }) 'prov-neg-dur-int.json'
    $rNegDur = Invoke-Provenance @('--validate', $fNegDur)
    Assert-True ($rNegDur.ExitCode -ne 0) "invalid-duration: rejects negative integer duration"

    # 7.2: Negative duration float
    $attNegFloat = New-BaseAttempt @{ duration_seconds = -0.5 }
    $wNegFloat = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attNegFloat) } }
    $fNegFloat = Write-ProvJson (New-BaseProvenance @{ workers = @($wNegFloat) }) 'prov-neg-dur-float.json'
    $rNegFloat = Invoke-Provenance @('--validate', $fNegFloat)
    Assert-True ($rNegFloat.ExitCode -ne 0) "invalid-duration: rejects negative float duration"

    # 7.3: String duration
    $attStrDur = New-BaseAttempt @{ duration_seconds = "fast" }
    $wStrDur = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attStrDur) } }
    $fStrDur = Write-ProvJson (New-BaseProvenance @{ workers = @($wStrDur) }) 'prov-str-dur.json'
    $rStrDur = Invoke-Provenance @('--validate', $fStrDur)
    Assert-True ($rStrDur.ExitCode -ne 0) "invalid-duration: rejects string duration"

    # =========================================================================
    # Group 8: Additional schema validations
    # =========================================================================

    # 8.1: Unsupported schema_version
    $wBadSv = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 2; attempts = @($att1) } }
    $fBadSv = Write-ProvJson (New-BaseProvenance @{ workers = @($wBadSv) }) 'prov-bad-sv.json'
    $rBadSv = Invoke-Provenance @('--validate', $fBadSv)
    Assert-True ($rBadSv.ExitCode -ne 0) "invalid-schema: rejects schema_version 2"

    # 8.2: String schema_version
    $wStrSv = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = "1"; attempts = @($att1) } }
    $fStrSv = Write-ProvJson (New-BaseProvenance @{ workers = @($wStrSv) }) 'prov-str-sv.json'
    $rStrSv = Invoke-Provenance @('--validate', $fStrSv)
    Assert-True ($rStrSv.ExitCode -ne 0) "invalid-schema: rejects string schema_version"

    # 8.3: Non-array attempts
    $wNotArrAtt = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = "not-an-array" } }
    $fNotArrAtt = Write-ProvJson (New-BaseProvenance @{ workers = @($wNotArrAtt) }) 'prov-not-arr-att.json'
    $rNotArrAtt = Invoke-Provenance @('--validate', $fNotArrAtt)
    Assert-True ($rNotArrAtt.ExitCode -ne 0) "invalid-schema: rejects non-array attempts"

    # 8.4: Non-Gemini model ID
    $attNonGemini = New-BaseAttempt @{ model = "claude-3-5-sonnet-high" }
    $wNonGemini = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attNonGemini) } }
    $fNonGemini = Write-ProvJson (New-BaseProvenance @{ workers = @($wNonGemini) }) 'prov-non-gemini.json'
    $rNonGemini = Invoke-Provenance @('--validate', $fNonGemini)
    Assert-True ($rNonGemini.ExitCode -ne 0) "invalid-model: rejects non-Gemini model ID"

    # 8.5: Missing effort suffix on model
    $attNoEffort = New-BaseAttempt @{ model = "gemini-3.8-flash"; effort = "high" }
    $wNoEffort = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attNoEffort) } }
    $fNoEffort = Write-ProvJson (New-BaseProvenance @{ workers = @($wNoEffort) }) 'prov-no-effort-suffix.json'
    $rNoEffort = Invoke-Provenance @('--validate', $fNoEffort)
    Assert-True ($rNoEffort.ExitCode -ne 0) "invalid-model: rejects model missing effort suffix"

    # 8.6: Invalid route
    $attBadRoute = New-BaseAttempt @{ route = "fast-track" }
    $wBadRoute = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attBadRoute) } }
    $fBadRoute = Write-ProvJson (New-BaseProvenance @{ workers = @($wBadRoute) }) 'prov-bad-route.json'
    $rBadRoute = Invoke-Provenance @('--validate', $fBadRoute)
    Assert-True ($rBadRoute.ExitCode -ne 0) "invalid-route: rejects route other than default or quality-retry"

    # 8.7: Invalid state
    $attBadState = New-BaseAttempt @{ state = "paused" }
    $wBadState = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attBadState) } }
    $fBadState = Write-ProvJson (New-BaseProvenance @{ workers = @($wBadState) }) 'prov-bad-state.json'
    $rBadState = Invoke-Provenance @('--validate', $fBadState)
    Assert-True ($rBadState.ExitCode -ne 0) "invalid-state: rejects unknown process state"

    # 8.8: Invalid failure_class
    $attBadFc = New-BaseAttempt @{ failure_class = "internal_error" }
    $wBadFc = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attBadFc) } }
    $fBadFc = Write-ProvJson (New-BaseProvenance @{ workers = @($wBadFc) }) 'prov-bad-fc.json'
    $rBadFc = Invoke-Provenance @('--validate', $fBadFc)
    Assert-True ($rBadFc.ExitCode -ne 0) "invalid-failure-class: rejects unknown failure_class"

    # 8.9: Invalid verification_status
    $attBadVs = New-BaseAttempt @{ verification_status = "maybe" }
    $wBadVs = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attBadVs) } }
    $fBadVs = Write-ProvJson (New-BaseProvenance @{ workers = @($wBadVs) }) 'prov-bad-vs.json'
    $rBadVs = Invoke-Provenance @('--validate', $fBadVs)
    Assert-True ($rBadVs.ExitCode -ne 0) "invalid-verification: rejects unknown verification_status"

    # 8.10: String evidence_paths instead of array
    $attBadEp = New-BaseAttempt @{ evidence_paths = "evidence.json" }
    $wBadEp = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attBadEp) } }
    $fBadEp = Write-ProvJson (New-BaseProvenance @{ workers = @($wBadEp) }) 'prov-bad-ep.json'
    $rBadEp = Invoke-Provenance @('--validate', $fBadEp)
    Assert-True ($rBadEp.ExitCode -ne 0) "invalid-evidence: rejects string evidence_paths"

    # 8.11: String usage instead of object/null
    $attBadUsage = New-BaseAttempt @{ usage = "100 tokens" }
    $wBadUsage = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attBadUsage) } }
    $fBadUsage = Write-ProvJson (New-BaseProvenance @{ workers = @($wBadUsage) }) 'prov-bad-usage.json'
    $rBadUsage = Invoke-Provenance @('--validate', $fBadUsage)
    Assert-True ($rBadUsage.ExitCode -ne 0) "invalid-usage: rejects string usage value"

    # 8.12: Missing required attempt field (e.g. policy_revision missing)
    $attNoRev = New-BaseAttempt
    $attNoRev.Remove('policy_revision')
    $wNoRev = [ordered]@{ id = "w1"; routing = [ordered]@{ schema_version = 1; attempts = @($attNoRev) } }
    $fNoRev = Write-ProvJson (New-BaseProvenance @{ workers = @($wNoRev) }) 'prov-no-rev.json'
    $rNoRev = Invoke-Provenance @('--validate', $fNoRev)
    Assert-True ($rNoRev.ExitCode -ne 0) "invalid-schema: rejects attempt missing required policy_revision"

    # 8.13: Routing is string instead of object
    $wStrRouting = [ordered]@{ id = "w1"; routing = "not-an-object" }
    $fStrRouting = Write-ProvJson (New-BaseProvenance @{ workers = @($wStrRouting) }) 'prov-str-routing.json'
    $rStrRouting = Invoke-Provenance @('--validate', $fStrRouting)
    Assert-True ($rStrRouting.ExitCode -ne 0) "invalid-routing: rejects non-object routing field"

} finally {
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

[Console]::Out.WriteLine("all provenance routing tests passed ($script:TotalTests tests)")
exit 0
