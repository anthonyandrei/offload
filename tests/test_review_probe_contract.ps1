#!/usr/bin/env pwsh
# tests/test_review_probe_contract.ps1
# Acceptance gate for offload compatibility review probe contracts.
# Enforces:
#   1. Native Bash probe implementation (no pwsh delegation, native argument parsing, native helpers)
#   2. Supported run-agy-json launcher usage (role, output, error, delimiter, no forbidden caller flags)
#   3. Independent per-arm result and error artifact paths and on-disk creation
#   4. Fake-runner report contract (schema, observations, sentinel checks, and fail-closed behavior)
# Strict constraints: Standalone PowerShell 7 / .NET only, no Pester, Python, jq, or live model calls.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# Test Assertion Harness
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
    if ($env:OFFLOAD_CONTINUE_ON_FAIL -ne '1' -and $env:OFFLOAD_TEST_CONTINUE_ON_FAIL -ne '1') {
        exit 1
    }
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

function Assert-NotEqual($actual, $expected, [string]$name) {
    if ($actual -ne $expected) {
        Pass $name
    } else {
        Fail $name "Expected not '$expected', but got '$actual'"
    }
}

# ---------------------------------------------------------------------------
# Paths and Target Discovery
# ---------------------------------------------------------------------------

$RootDir = Split-Path -Parent $PSScriptRoot
$ScriptsDir = Join-Path $RootDir 'scripts'

$ProbePs1 = Join-Path $ScriptsDir 'probe-agy-compatibility.ps1'
$ProbeSh  = Join-Path $ScriptsDir 'probe-agy-compatibility.sh'
$RunAgyPs1 = Join-Path $ScriptsDir 'run-agy-json.ps1'
$RunAgySh  = Join-Path $ScriptsDir 'run-agy-json.sh'
$RedactPs1 = Join-Path $ScriptsDir 'redact-publication-secrets.ps1'
$RedactSh  = Join-Path $ScriptsDir 'redact-publication-secrets.sh'

Assert-True (Test-Path -LiteralPath $ProbePs1 -PathType Leaf) "files: scripts/probe-agy-compatibility.ps1 exists" "Missing $ProbePs1"
Assert-True (Test-Path -LiteralPath $ProbeSh -PathType Leaf) "files: scripts/probe-agy-compatibility.sh exists" "Missing $ProbeSh"
Assert-True (Test-Path -LiteralPath $RunAgyPs1 -PathType Leaf) "files: scripts/run-agy-json.ps1 exists" "Missing $RunAgyPs1"
Assert-True (Test-Path -LiteralPath $RunAgySh -PathType Leaf) "files: scripts/run-agy-json.sh exists" "Missing $RunAgySh"

$probePsContent = Get-Content -LiteralPath $ProbePs1 -Raw
$probeShContent = Get-Content -LiteralPath $ProbeSh -Raw

# ---------------------------------------------------------------------------
# Helper: Extract Per-Arm Artifact Paths from Report Objects
# ---------------------------------------------------------------------------

function Get-ArmOutputArtifact($armObj) {
    if ($null -eq $armObj) { return $null }
    $props = $armObj.PSObject.Properties.Name
    foreach ($cand in @('output_artifact', 'result_artifact', 'output_path', 'result_path', 'output_file', 'result_file', 'output', 'result')) {
        if ($props -contains $cand -and -not [string]::IsNullOrWhiteSpace([string]$armObj.$cand)) {
            return [string]$armObj.$cand
        }
    }
    if ($props -contains 'artifacts' -and $null -ne $armObj.artifacts) {
        $subProps = $armObj.artifacts.PSObject.Properties.Name
        foreach ($cand in @('output', 'result', 'output_artifact', 'result_artifact', 'output_path', 'result_path')) {
            if ($subProps -contains $cand -and -not [string]::IsNullOrWhiteSpace([string]$armObj.artifacts.$cand)) {
                return [string]$armObj.artifacts.$cand
            }
        }
    }
    return $null
}

function Get-ArmErrorArtifact($armObj) {
    if ($null -eq $armObj) { return $null }
    $props = $armObj.PSObject.Properties.Name
    foreach ($cand in @('error_artifact', 'error_path', 'error_file', 'error_log', 'error')) {
        if ($props -contains $cand -and -not [string]::IsNullOrWhiteSpace([string]$armObj.$cand)) {
            return [string]$armObj.$cand
        }
    }
    if ($props -contains 'artifacts' -and $null -ne $armObj.artifacts) {
        $subProps = $armObj.artifacts.PSObject.Properties.Name
        foreach ($cand in @('error', 'error_artifact', 'error_path', 'error_file', 'error_log')) {
            if ($subProps -contains $cand -and -not [string]::IsNullOrWhiteSpace([string]$armObj.artifacts.$cand)) {
                return [string]$armObj.artifacts.$cand
            }
        }
    }
    return $null
}

# ===========================================================================
# 1. Native Bash Probe Contract (ADR 0001 Shell Parity)
# ===========================================================================

# 1.1 Bash shebang check
Assert-True ($probeShContent -match '^#!\s*(?:/usr/bin/env\s+bash|/bin/bash)') "probe-bash: has valid bash shebang" "Expected bash shebang in $ProbeSh"

# 1.2 Must NOT delegate to PowerShell / pwsh
Assert-False ($probeShContent -match '(?i)\b(?:exec\s+)?pwsh\b|\bpowershell\b') "probe-bash: does not delegate to pwsh or powershell" "probe-agy-compatibility.sh must be a native Bash script, not a pwsh wrapper"

# 1.3 Must NOT reference PowerShell .ps1 scripts
Assert-False ($probeShContent -match '\.ps1\b') "probe-bash: does not reference PowerShell .ps1 scripts" "probe-agy-compatibility.sh should not reference .ps1 files"

# 1.4 Native option parsing for --workspace and --output
Assert-True ($probeShContent -match '--workspace' -and $probeShContent -match '--output') "probe-bash: implements native argument parsing for --workspace and --output" "Native argument parsing missing in probe-agy-compatibility.sh"

# 1.5 Invokes native Bash launcher run-agy-json.sh
Assert-True ($probeShContent -match 'run-agy-json\.sh') "probe-bash: invokes native Bash launcher run-agy-json.sh" "Expected run-agy-json.sh invocation in probe-agy-compatibility.sh"

# 1.6 Invokes native Bash publication redactor
Assert-True ($probeShContent -match 'redact-publication-secrets\.sh') "probe-bash: invokes native Bash publication redactor redact-publication-secrets.sh" "Expected redact-publication-secrets.sh invocation in probe-agy-compatibility.sh"

# ===========================================================================
# 2. Supported run-agy-json Launcher Usage Contract
# ===========================================================================

# 2.1 probe-agy-compatibility.ps1 must reference and invoke run-agy-json.ps1
Assert-True ($probePsContent -match 'run-agy-json\.ps1') "launcher-usage: probe-ps1 references and invokes run-agy-json.ps1" "probe-agy-compatibility.ps1 must route worker calls through run-agy-json.ps1"

# 2.2 probe-agy-compatibility.ps1 passes required launcher arguments
Assert-True ($probePsContent -match '--role\b') "launcher-usage: probe-ps1 passes --role to launcher" "probe-agy-compatibility.ps1 must pass --role to launcher"
Assert-True ($probePsContent -match '--error\b') "launcher-usage: probe-ps1 passes --error to launcher" "probe-agy-compatibility.ps1 must pass --error to launcher"
Assert-True ($probePsContent -match "'--'" -or $probePsContent -match '"--"') "launcher-usage: probe-ps1 uses quoted delimiter for launcher" "probe-agy-compatibility.ps1 must use quoted delimiter '--' for run-agy-json.ps1"

# 2.3 Forwarded arguments after delimiter must NOT include forbidden caller flags
Assert-False ($probePsContent -match "(?:\.Add\('--model'\)|--model\s+\\\`$|\`$args?.*--model)") "launcher-usage: probe-ps1 does not pass prohibited --model argument to worker" "run-agy-json forbids caller --model flag"
Assert-False ($probePsContent -match "(?:\.Add\('--output'\)|--output\s+\\\`$|\`$args?.*--output\s+\`$result)") "launcher-usage: probe-ps1 does not pass prohibited --output argument to worker" "run-agy-json forbids passing --output to agy directly"

# 2.4 probe-agy-compatibility.sh passes required launcher arguments and delimiter
Assert-True ($probeShContent -match '--role\b') "launcher-usage: probe-bash passes --role to launcher" "probe-agy-compatibility.sh must pass --role to launcher"
Assert-True ($probeShContent -match '--error\b') "launcher-usage: probe-bash passes --error to launcher" "probe-agy-compatibility.sh must pass --error to launcher"
Assert-True ($probeShContent -match '\s+--\s+') "launcher-usage: probe-bash uses delimiter -- for launcher" "probe-agy-compatibility.sh must use -- delimiter"
Assert-False ($probeShContent -match '\b--model\b') "launcher-usage: probe-bash does not pass prohibited --model argument" "probe-agy-compatibility.sh must not pass --model"

# ===========================================================================
# 3. Dynamic Fake Runner Execution & Artifact Contract
# ===========================================================================

$TmpRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "offload-probe-gate-$([System.Guid]::NewGuid().ToString('N'))")
[System.IO.Directory]::CreateDirectory($TmpRoot) | Out-Null

$pwshBin = (Get-Process -Id $PID).Path

try {
    $fakeBin = Join-Path $TmpRoot 'bin'
    [System.IO.Directory]::CreateDirectory($fakeBin) | Out-Null
    $fakeAgyPs = Join-Path $fakeBin 'fake_agy.ps1'
    $invocationsLog = Join-Path $TmpRoot 'invocations.log'

    # Create the fake agy runner
    @'
param()

$invLog = $env:FAKE_AGY_INVOCATIONS_LOG
if ($invLog) {
    $argLine = ($args -join ' ')
    [System.IO.File]::AppendAllText($invLog, "$argLine`n", [System.Text.Encoding]::UTF8)
}

if ($args -contains '--version') {
    if ($env:FAKE_AGY_FAIL_VERSION -eq '1') {
        [Console]::Error.WriteLine("simulated version error")
        exit 1
    }
    [Console]::Out.WriteLine("agy 1.1.25")
    exit 0
}

if ($env:FAKE_AGY_SIMULATE_FAILURE -eq '1') {
    [Console]::Error.WriteLine("simulated agy failure")
    exit 1
}

if ($env:FAKE_AGY_SIMULATE_INVALID_JSON -eq '1') {
    [Console]::Out.WriteLine("corrupt non-json stdout")
    exit 0
}

$isPlan = ($args -contains '--mode' -and ($args[$args.IndexOf('--mode') + 1] -eq 'plan')) -or ($args -contains 'plan')
$armName = if ($isPlan) { "plan" } else { "default" }
$sentinelResult = if ($isPlan) { "blocked" } else { "succeeded" }

# In unconstrained default mode, perform the sentinel write
if ($env:FAKE_AGY_SENTINEL_TARGET -and -not $isPlan) {
    try {
        [System.IO.File]::WriteAllText($env:FAKE_AGY_SENTINEL_TARGET, "sentinel-ok", [System.Text.Encoding]::UTF8)
    } catch { }
}

$resObj = [ordered]@{
    status = "success"
    response = "probe observation for arm $armName"
    structured_output = [ordered]@{
        arm = $armName
        permission_mode = "always-proceed"
        tools = @("read_file", "write_file", "run_command")
        commands = @("agy", "git")
        sentinel_result = $sentinelResult
    }
    duration_seconds = 1
    usage = [ordered]@{
        prompt_tokens = 45
        completion_tokens = 22
    }
}

$jsonText = ConvertTo-Json -InputObject $resObj -Compress

# If --output was passed directly to agy (baseline anti-pattern), write to it
$outIdx = $args.IndexOf('--output')
if ($outIdx -ge 0 -and $outIdx + 1 -lt $args.Count) {
    $outputPath = $args[$outIdx + 1]
    [System.IO.File]::WriteAllText($outputPath, $jsonText, [System.Text.Encoding]::UTF8)
}

[Console]::Out.WriteLine($jsonText)
[Console]::Error.WriteLine("arm $armName stderr log")
exit 0
'@ | Set-Content -LiteralPath $fakeAgyPs -Encoding utf8

    if ($IsWindows) {
        $fakeAgyCmd = Join-Path $fakeBin 'agy.cmd'
        @("@echo off", "pwsh -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake_agy.ps1`" %*") | Set-Content -LiteralPath $fakeAgyCmd -Encoding ascii
        $fakeAgyBat = Join-Path $fakeBin 'agy.bat'
        @("@echo off", "pwsh -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake_agy.ps1`" %*") | Set-Content -LiteralPath $fakeAgyBat -Encoding ascii
    } else {
        $fakeAgyUnix = Join-Path $fakeBin 'agy'
        @("#!/usr/bin/env pwsh", "pwsh -NoProfile -ExecutionPolicy Bypass -File `"`$PSScriptRoot/fake_agy.ps1`" `"`$@`"") | Set-Content -LiteralPath $fakeAgyUnix -Encoding utf8
        [System.IO.File]::SetUnixFileMode($fakeAgyUnix, [System.IO.UnixFileMode]509)
    }

    $pathSep = [System.IO.Path]::PathSeparator
    $testEnv = @{
        'AGY_BIN'                    = $fakeAgyPs
        'PATH'                       = "$fakeBin$pathSep$env:PATH"
        'FAKE_AGY_INVOCATIONS_LOG'   = $invocationsLog
    }

    $probeWorkspace = Join-Path $TmpRoot 'probe-workspace'
    [System.IO.Directory]::CreateDirectory($probeWorkspace) | Out-Null
    $probeReport = Join-Path $TmpRoot 'probe-report.json'

    # Execute probe script in clean environment
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwshBin
    $psi.Arguments = "-NoProfile -NonInteractive -File `"$ProbePs1`" --workspace `"$probeWorkspace`" --output `"$probeReport`""
    $psi.WorkingDirectory = $probeWorkspace
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    foreach ($k in $testEnv.Keys) {
        $psi.Environment[$k] = $testEnv[$k]
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    Assert-Equal $proc.ExitCode 0 "execution: probe script succeeds with fake runner"

    # Verify that fake agy did not receive direct --output or --role flags
    if (Test-Path -LiteralPath $invocationsLog -PathType Leaf) {
        $allInvocations = Get-Content -LiteralPath $invocationsLog
        $workerInvocations = @($allInvocations | Where-Object { $_ -notmatch '--version' })
        foreach ($wInv in $workerInvocations) {
            $wTokens = $wInv -split '\s+'
            Assert-False ($wTokens -contains '--output') "launcher-usage: fake agy does not receive direct --output flag from caller" "Found --output in agy invocation: $wInv"
            Assert-False ($wTokens -contains '--role') "launcher-usage: fake agy does not receive direct --role flag from caller" "Found --role in agy invocation: $wInv"
        }
    }

    # =======================================================================
    # 4. Independent Per-Arm Result and Error Artifact Paths and Creation
    # =======================================================================

    $planDir = Join-Path $probeWorkspace 'plan'
    $defaultDir = Join-Path $probeWorkspace 'default'

    Assert-True (Test-Path -LiteralPath $planDir -PathType Container) "artifact-paths: plan arm directory exists" "Missing plan directory"
    Assert-True (Test-Path -LiteralPath $defaultDir -PathType Container) "artifact-paths: default arm directory exists" "Missing default directory"

    # Search for created output and error files in arm directories
    $planErrorFiles = @(Get-ChildItem -LiteralPath $planDir -Filter '*error*' -File -ErrorAction SilentlyContinue)
    $defaultErrorFiles = @(Get-ChildItem -LiteralPath $defaultDir -Filter '*error*' -File -ErrorAction SilentlyContinue)

    Assert-True ($planErrorFiles.Count -gt 0) "artifact-paths: plan error artifact created on disk" "No error artifact file found in $planDir"
    Assert-True ($defaultErrorFiles.Count -gt 0) "artifact-paths: default error artifact created on disk" "No error artifact file found in $defaultDir"

    # =======================================================================
    # 5. Fake-Runner Report Contract
    # =======================================================================

    Assert-True (Test-Path -LiteralPath $probeReport -PathType Leaf) "report-contract: output report file exists" "Report not created at $probeReport"

    $reportData = $null
    try {
        $reportData = Get-Content -LiteralPath $probeReport -Raw | ConvertFrom-Json
    } catch {
        Fail "report-contract: report is valid JSON" "Failed to parse JSON: $($_.Exception.Message)"
    }

    Assert-True ($null -ne $reportData) "report-contract: report data parsed successfully"
    Assert-Equal ([int]$reportData.schema_version) 1 "report-contract: schema_version is 1"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$reportData.observed_at)) "report-contract: observed_at timestamp is present"
    Assert-True ($reportData.version -match '1\.1\.25') "report-contract: version captures agy version"
    Assert-Equal ([int]$reportData.version_exit_code) 0 "report-contract: version_exit_code is 0"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$reportData.fixed_prompt)) "report-contract: fixed_prompt is recorded"
    Assert-Equal ([string]$reportData.role) 'researcher' "report-contract: role is researcher"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$reportData.model)) "report-contract: model is recorded"
    Assert-Equal (@($reportData.arms).Count) 2 "report-contract: report records exactly 2 arms"
    Assert-True (@($reportData.observations).Count -gt 0) "report-contract: observations array is populated"
    Assert-True (@($reportData.warnings).Count -gt 0) "report-contract: warnings array is populated"

    $planArm = @($reportData.arms | Where-Object { $_.arm -eq 'plan' })[0]
    $defaultArm = @($reportData.arms | Where-Object { $_.arm -eq 'default' })[0]

    Assert-True ($null -ne $planArm) "report-contract: plan arm record exists"
    Assert-True ($null -ne $defaultArm) "report-contract: default arm record exists"

    # Per-arm field checks
    foreach ($arm in @($planArm, $defaultArm)) {
        $mode = $arm.arm
        Assert-Equal ([int]$arm.exit_code) 0 "report-contract: $mode arm exit_code is 0"
        Assert-Equal ([string]$arm.parse_status) 'valid' "report-contract: $mode arm parse_status is valid"
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$arm.stdout)) "report-contract: $mode arm stdout is non-empty"
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$arm.permission_mode)) "report-contract: $mode arm permission_mode is present"
        Assert-True (@($arm.tools).Count -gt 0) "report-contract: $mode arm tools list is non-empty"
        Assert-True ($null -ne $arm.sentinel) "report-contract: $mode arm sentinel object is present"
        Assert-True ($arm.sentinel.attempted -eq $true) "report-contract: $mode arm sentinel was attempted"
        Assert-True ($arm.duration_seconds -ge 0) "report-contract: $mode arm duration_seconds is valid"
        Assert-True ($null -ne $arm.usage) "report-contract: $mode arm usage is recorded"
    }

    Assert-Equal ([string]$planArm.sentinel.reported) 'blocked' "report-contract: plan arm sentinel is reported blocked"
    Assert-Equal ([bool]$planArm.sentinel.exists) $false "report-contract: plan arm sentinel does not exist on disk"

    Assert-Equal ([string]$defaultArm.sentinel.reported) 'succeeded' "report-contract: default arm sentinel is reported succeeded"
    Assert-Equal ([bool]$defaultArm.sentinel.exists) $true "report-contract: default arm sentinel exists on disk"

    # Per-arm artifact paths recorded in report
    $planOutPath = Get-ArmOutputArtifact $planArm
    $planErrPath = Get-ArmErrorArtifact $planArm
    $defaultOutPath = Get-ArmOutputArtifact $defaultArm
    $defaultErrPath = Get-ArmErrorArtifact $defaultArm

    Assert-True (-not [string]::IsNullOrWhiteSpace($planOutPath)) "report-contract: plan arm records output artifact path" "Output artifact path missing in plan arm"
    Assert-True (-not [string]::IsNullOrWhiteSpace($planErrPath)) "report-contract: plan arm records error artifact path" "Error artifact path missing in plan arm"
    Assert-True (-not [string]::IsNullOrWhiteSpace($defaultOutPath)) "report-contract: default arm records output artifact path" "Output artifact path missing in default arm"
    Assert-True (-not [string]::IsNullOrWhiteSpace($defaultErrPath)) "report-contract: default arm records error artifact path" "Error artifact path missing in default arm"

    # Independence of artifact paths
    Assert-NotEqual $planOutPath $defaultOutPath "artifact-paths: plan and default output artifact paths are distinct"
    Assert-NotEqual $planErrPath $defaultErrPath "artifact-paths: plan and default error artifact paths are distinct"
    Assert-NotEqual $planOutPath $planErrPath "artifact-paths: plan output and error paths are distinct"
    Assert-NotEqual $defaultOutPath $defaultErrPath "artifact-paths: default output and error paths are distinct"

    # Recorded artifact files must exist on disk
    if ($planOutPath) { Assert-True (Test-Path -LiteralPath $planOutPath -PathType Leaf) "artifact-paths: recorded plan output file exists on disk" }
    if ($planErrPath) { Assert-True (Test-Path -LiteralPath $planErrPath -PathType Leaf) "artifact-paths: recorded plan error file exists on disk" }
    if ($defaultOutPath) { Assert-True (Test-Path -LiteralPath $defaultOutPath -PathType Leaf) "artifact-paths: recorded default output file exists on disk" }
    if ($defaultErrPath) { Assert-True (Test-Path -LiteralPath $defaultErrPath -PathType Leaf) "artifact-paths: recorded default error file exists on disk" }

    # =======================================================================
    # 6. Fail-Closed Behavior Verification
    # =======================================================================

    # 6.1 Runner failure causes probe failure
    $failWs = Join-Path $TmpRoot 'fail-ws'
    $failOut = Join-Path $TmpRoot 'fail-out.json'
    [System.IO.Directory]::CreateDirectory($failWs) | Out-Null
    $failPsi = [System.Diagnostics.ProcessStartInfo]::new()
    $failPsi.FileName = $pwshBin
    $failPsi.Arguments = "-NoProfile -NonInteractive -File `"$ProbePs1`" --workspace `"$failWs`" --output `"$failOut`""
    $failPsi.WorkingDirectory = $failWs
    $failPsi.RedirectStandardOutput = $true
    $failPsi.RedirectStandardError = $true
    $failPsi.UseShellExecute = $false
    foreach ($k in $testEnv.Keys) { $failPsi.Environment[$k] = $testEnv[$k] }
    $failPsi.Environment['FAKE_AGY_SIMULATE_FAILURE'] = '1'
    $failProc = [System.Diagnostics.Process]::Start($failPsi)
    $failProc.WaitForExit()
    Assert-NotEqual $failProc.ExitCode 0 "fail-closed: probe exits non-zero when worker execution fails"

    # 6.2 Corrupt / unparseable output causes probe failure
    $corruptWs = Join-Path $TmpRoot 'corrupt-ws'
    $corruptOut = Join-Path $TmpRoot 'corrupt-out.json'
    [System.IO.Directory]::CreateDirectory($corruptWs) | Out-Null
    $corruptPsi = [System.Diagnostics.ProcessStartInfo]::new()
    $corruptPsi.FileName = $pwshBin
    $corruptPsi.Arguments = "-NoProfile -NonInteractive -File `"$ProbePs1`" --workspace `"$corruptWs`" --output `"$corruptOut`""
    $corruptPsi.WorkingDirectory = $corruptWs
    $corruptPsi.RedirectStandardOutput = $true
    $corruptPsi.RedirectStandardError = $true
    $corruptPsi.UseShellExecute = $false
    foreach ($k in $testEnv.Keys) { $corruptPsi.Environment[$k] = $testEnv[$k] }
    $corruptPsi.Environment['FAKE_AGY_SIMULATE_INVALID_JSON'] = '1'
    $corruptProc = [System.Diagnostics.Process]::Start($corruptPsi)
    $corruptProc.WaitForExit()
    Assert-NotEqual $corruptProc.ExitCode 0 "fail-closed: probe exits non-zero when structured output is corrupt"

} finally {
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:FailedTests -gt 0) {
    [Console]::Error.WriteLine("Failed $script:FailedTests of $script:TotalTests review probe contract tests")
    exit 1
}

[Console]::Out.WriteLine("all review probe contract checks passed ($script:TotalTests tests)")
exit 0
