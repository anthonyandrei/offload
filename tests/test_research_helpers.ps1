#!/usr/bin/env pwsh
# tests/test_research_helpers.ps1
# Self-contained acceptance test suite for the five PowerShell 7 research helpers.
# Implements contracts specified in docs/specs/0001-platform-agnostic-workflows.md.
# Strict constraints: PowerShell 7/.NET only, no Pester, Python, jq, Bash, or network.

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

function Assert-NotEqual($actual, $expected, [string]$name) {
    if ($actual -ne $expected) {
        Pass $name
    } else {
        Fail $name "Expected not '$expected', but got '$actual'"
    }
}

function Assert-StringArrayEqual([string[]]$actual, [string[]]$expected, [string]$name) {
    Assert-Equal $actual.Count $expected.Count "${name}: argument count"
    for ($i = 0; $i -lt $expected.Count; $i++) {
        Assert-Equal $actual[$i] $expected[$i] "${name}: argument $i"
    }
}

# ---------------------------------------------------------------------------
# Public Process Runner
# ---------------------------------------------------------------------------

$PwshBin = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $PwshBin) {
    $PwshBin = (Get-Process -Id $PID).Path
}

$RootDir = Split-Path -Parent $PSScriptRoot
$ScriptsDir = Join-Path $RootDir 'scripts'

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

function Invoke-Helper {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptName,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = $null
    )
    $scriptPath = Join-Path $ScriptsDir $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Fail "Helper existence check" "Script '$ScriptName' does not exist at '$scriptPath'"
    }
    $pwshArgs = @('-NoProfile', '-NonInteractive', '-File', $scriptPath) + $ArgumentList
    return Invoke-ToolProcess -FilePath $PwshBin -ArgumentList $pwshArgs -Environment $Environment -WorkingDirectory $WorkingDirectory
}

# ---------------------------------------------------------------------------
# Test Environment Setup
# ---------------------------------------------------------------------------

$TmpRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "offload-test-$([System.Guid]::NewGuid().ToString('N'))")
[System.IO.Directory]::CreateDirectory($TmpRoot) | Out-Null

try {
    # -----------------------------------------------------------------------
    # Setup Fake agy Executable / Scripts
    # -----------------------------------------------------------------------
    $fakeBin = Join-Path $TmpRoot 'bin'
    [System.IO.Directory]::CreateDirectory($fakeBin) | Out-Null

    $fakeAgyPs = Join-Path $fakeBin 'fake_agy.ps1'
    @'
param(
    [Alias('p')]
    [string]$ShortP,
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$ArgsList
)

if ($env:FAKE_AGY_ARGS) {
    $capturedArgs = @()
    if ($PSBoundParameters.ContainsKey('ShortP')) {
        $capturedArgs += '-p'
        $capturedArgs += $ShortP
    }
    $capturedArgs += @($ArgsList | ForEach-Object { [string]$_ })
    [System.IO.File]::WriteAllText(
        $env:FAKE_AGY_ARGS,
        (ConvertTo-Json -InputObject $capturedArgs -Compress),
        [System.Text.Encoding]::UTF8
    )
}

if ($env:FAKE_AGY_EXIT) {
    [Console]::Error.WriteLine("fake stderr")
    exit [int]$env:FAKE_AGY_EXIT
}

[Console]::Error.WriteLine("fake stderr")
[Console]::Out.WriteLine('{"status":"success","response":"verbose worker text","structured_output":{"ok":true}}')
exit 0
'@ | Set-Content -LiteralPath $fakeAgyPs -Encoding utf8

    if ($IsWindows) {
        $fakeAgyCmd = Join-Path $fakeBin 'agy.cmd'
        @("@echo off", "pwsh -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake_agy.ps1`" %*") | Set-Content -LiteralPath $fakeAgyCmd -Encoding ascii
        $fakeAgyBat = Join-Path $fakeBin 'agy.bat'
        @("@echo off", "pwsh -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake_agy.ps1`" %*") | Set-Content -LiteralPath $fakeAgyBat -Encoding ascii
    } else {
        $fakeAgyUnix = Join-Path $fakeBin 'agy'
        @("#!/usr/bin/env pwsh", "param([Parameter(ValueFromRemainingArguments)]`$ArgsList)", "pwsh -NoProfile -ExecutionPolicy Bypass -File `"`$PSScriptRoot/fake_agy.ps1`" @ArgsList") | Set-Content -LiteralPath $fakeAgyUnix -Encoding utf8
        [System.IO.File]::SetUnixFileMode($fakeAgyUnix, [System.IO.UnixFileMode]509) # 0o775
    }

    $pathSep = [System.IO.Path]::PathSeparator
    $basePath = "$fakeBin$pathSep$env:PATH"

    # =======================================================================
    # 1. run-agy-json.ps1
    #    - fake agy forwarding / output separation
    #    - parent directory creation
    #    - exit code propagation
    #    - forbidden --output argument rejection
    #    - AGY_BIN precedence / invalid explicit value
    # =======================================================================

    # 1.1 Launcher redirects output and preserves worker arguments
    $runOut = Join-Path $TmpRoot 'run.json'
    $runErr = Join-Path $TmpRoot 'run.err'
    $argsCapture = Join-Path $TmpRoot 'agy.args'
    $envRun = @{
        'PATH' = $basePath
        'FAKE_AGY_ARGS' = $argsCapture
    }
    $res = Invoke-Helper -ScriptName 'run-agy-json.ps1' -ArgumentList @(
        '--role', 'scout',
        '--output', $runOut,
        '--error', $runErr,
        '--',
        '--prompt', 'test prompt',
        '--output-format', 'json'
    ) -Environment $envRun

    Assert-Equal $res.ExitCode 0 "run-agy-json: exits with worker exit code 0"
    Assert-True (Test-Path -LiteralPath $runOut) "run-agy-json: created output file"
    Assert-True (Test-Path -LiteralPath $runErr) "run-agy-json: created error file"
    $outData = Get-Content -LiteralPath $runOut -Raw | ConvertFrom-Json
    Assert-True ($outData.structured_output.ok -eq $true) "run-agy-json: output file captured worker stdout JSON"
    $errData = (Get-Content -LiteralPath $runErr -Raw).Trim()
    Assert-Equal $errData 'fake stderr' "run-agy-json: error file captured worker stderr"
    Assert-Equal $res.Stdout.Trim() "" "run-agy-json: helper emits no worker stdout to its own stdout"
    $forwarded = @(Get-Content -LiteralPath $argsCapture -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
    Assert-StringArrayEqual $forwarded @('--model', 'gemini-3.8-flash-low', '--prompt', 'test prompt', '--output-format', 'json') "run-agy-json: preserves routed and forwarded argument boundaries"

    # 1.2 PowerShell command expressions use the quoted delimiter and preserve spaces
    $commandRoot = Join-Path $TmpRoot 'command expression paths'
    [System.IO.Directory]::CreateDirectory($commandRoot) | Out-Null
    $commandOut = Join-Path $commandRoot 'worker output.json'
    $commandErr = Join-Path $commandRoot 'worker error.log'
    $commandArgs = Join-Path $commandRoot 'worker arguments.json'
    $forwardedPath = Join-Path $commandRoot 'forwarded value.txt'
    $commandEnv = @{
        'AGY_BIN' = $fakeAgyPs
        'FAKE_AGY_ARGS' = $commandArgs
        'RUN_AGY_JSON' = (Join-Path $ScriptsDir 'run-agy-json.ps1')
        'RUN_OUTPUT' = $commandOut
        'RUN_ERROR' = $commandErr
        'WORKER_PROMPT' = 'prompt with several words'
        'FORWARDED_PATH' = $forwardedPath
    }
    $commandExpression = "& `$env:RUN_AGY_JSON --role scout --output `$env:RUN_OUTPUT --error `$env:RUN_ERROR '--' -p `$env:WORKER_PROMPT --path `$env:FORWARDED_PATH; exit `$LASTEXITCODE"
    $resCommand = Invoke-ToolProcess -FilePath $PwshBin -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-Command', $commandExpression
    ) -Environment $commandEnv

    Assert-Equal $resCommand.ExitCode 0 "run-agy-json: command expression exits 0"
    Assert-True (Test-Path -LiteralPath $commandOut) "run-agy-json: command expression creates output path containing spaces"
    Assert-True (Test-Path -LiteralPath $commandErr) "run-agy-json: command expression creates error path containing spaces"
    $commandOutData = Get-Content -LiteralPath $commandOut -Raw | ConvertFrom-Json
    Assert-True ($commandOutData.structured_output.ok -eq $true) "run-agy-json: command expression captures worker stdout"
    Assert-Equal (Get-Content -LiteralPath $commandErr -Raw).Trim() 'fake stderr' "run-agy-json: command expression captures worker stderr separately"
    $commandForwarded = @(Get-Content -LiteralPath $commandArgs -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
    Assert-StringArrayEqual $commandForwarded @('-p', 'prompt with several words', '--model', 'gemini-3.8-flash-low', '--path', $forwardedPath) "run-agy-json: command expression preserves routed and forwarded arguments"

    # 1.3 PowerShell command expressions propagate non-zero worker exits
    $exitOut = Join-Path $commandRoot 'nonzero worker output.json'
    $exitErr = Join-Path $commandRoot 'nonzero worker error.log'
    $exitArgs = Join-Path $commandRoot 'nonzero worker arguments.json'
    $exitEnv = @{
        'AGY_BIN' = $fakeAgyPs
        'FAKE_AGY_ARGS' = $exitArgs
        'FAKE_AGY_EXIT' = '37'
        'RUN_AGY_JSON' = (Join-Path $ScriptsDir 'run-agy-json.ps1')
        'RUN_OUTPUT' = $exitOut
        'RUN_ERROR' = $exitErr
        'WORKER_PROMPT' = 'nonzero prompt with spaces'
        'FORWARDED_PATH' = (Join-Path $commandRoot 'nonzero forwarded path.txt')
    }
    $resCommandExit = Invoke-ToolProcess -FilePath $PwshBin -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-Command', $commandExpression
    ) -Environment $exitEnv

    Assert-Equal $resCommandExit.ExitCode 37 "run-agy-json: command expression propagates non-zero worker exit"
    Assert-Equal (Get-Content -LiteralPath $exitErr -Raw).Trim() 'fake stderr' "run-agy-json: non-zero command expression preserves worker stderr"

    # 1.4 Command expressions reject a bare delimiter before launching a worker
    $bareArgs = Join-Path $commandRoot 'bare delimiter arguments.json'
    $bareEnv = @{
        'AGY_BIN' = $fakeAgyPs
        'FAKE_AGY_ARGS' = $bareArgs
        'RUN_AGY_JSON' = (Join-Path $ScriptsDir 'run-agy-json.ps1')
        'RUN_OUTPUT' = (Join-Path $commandRoot 'bare delimiter output.json')
        'RUN_ERROR' = (Join-Path $commandRoot 'bare delimiter error.log')
        'WORKER_PROMPT' = 'bare delimiter prompt'
        'FORWARDED_PATH' = (Join-Path $commandRoot 'bare delimiter path.txt')
    }
    $bareExpression = "& `$env:RUN_AGY_JSON --role scout --output `$env:RUN_OUTPUT --error `$env:RUN_ERROR -- -p `$env:WORKER_PROMPT; exit `$LASTEXITCODE"
    $resBare = Invoke-ToolProcess -FilePath $PwshBin -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-Command', $bareExpression
    ) -Environment $bareEnv

    Assert-True ($resBare.ExitCode -ne 0) "run-agy-json: command expression rejects bare delimiter"
    Assert-False (Test-Path -LiteralPath $bareArgs) "run-agy-json: bare delimiter does not launch worker"

    # 1.5 Command expressions reject an omitted delimiter before launching a worker
    $omittedArgs = Join-Path $commandRoot 'omitted delimiter arguments.json'
    $omittedEnv = @{
        'AGY_BIN' = $fakeAgyPs
        'FAKE_AGY_ARGS' = $omittedArgs
        'RUN_AGY_JSON' = (Join-Path $ScriptsDir 'run-agy-json.ps1')
        'RUN_OUTPUT' = (Join-Path $commandRoot 'omitted delimiter output.json')
        'RUN_ERROR' = (Join-Path $commandRoot 'omitted delimiter error.log')
        'WORKER_PROMPT' = 'omitted delimiter prompt'
        'FORWARDED_PATH' = (Join-Path $commandRoot 'omitted delimiter path.txt')
    }
    $omittedExpression = "& `$env:RUN_AGY_JSON --role scout --output `$env:RUN_OUTPUT --error `$env:RUN_ERROR -p `$env:WORKER_PROMPT; exit `$LASTEXITCODE"
    $resOmitted = Invoke-ToolProcess -FilePath $PwshBin -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-Command', $omittedExpression
    ) -Environment $omittedEnv

    Assert-True ($resOmitted.ExitCode -ne 0) "run-agy-json: command expression rejects omitted delimiter"
    Assert-False (Test-Path -LiteralPath $omittedArgs) "run-agy-json: omitted delimiter does not launch worker"

    # 1.6 Launcher creates parent directories automatically
    $nestedOut = Join-Path $TmpRoot 'nested/sub1/out.json'
    $nestedErr = Join-Path $TmpRoot 'nested/sub2/err.log'
    $res = Invoke-Helper -ScriptName 'run-agy-json.ps1' -ArgumentList @(
        '--role', 'scout',
        '--output', $nestedOut,
        '--error', $nestedErr,
        '--',
        '--prompt', 'parent dir test'
    ) -Environment $envRun
    Assert-Equal $res.ExitCode 0 "run-agy-json: creates parent directories for output and error"
    Assert-True (Test-Path -LiteralPath $nestedOut) "run-agy-json: nested output file exists"
    Assert-True (Test-Path -LiteralPath $nestedErr) "run-agy-json: nested error file exists"

    # 1.7 Worker exit code propagation
    $res = Invoke-Helper -ScriptName 'run-agy-json.ps1' -ArgumentList @(
        '--role', 'scout',
        '--output', (Join-Path $TmpRoot 'code.json'),
        '--error', (Join-Path $TmpRoot 'code.err'),
        '--',
        '--prompt', 'fail test'
    ) -Environment (@{
        'PATH' = $basePath
        'FAKE_AGY_EXIT' = '42'
    })
    Assert-Equal $res.ExitCode 42 "run-agy-json: propagates non-zero exit code 42"

    # 1.8 Rejection of --output and --output=<val> in forwarded arguments
    $resReject1 = Invoke-Helper -ScriptName 'run-agy-json.ps1' -ArgumentList @(
        '--role', 'scout',
        '--output', (Join-Path $TmpRoot 'rej1.json'),
        '--error', (Join-Path $TmpRoot 'rej1.err'),
        '--',
        '--output', 'sub-worker.json'
    ) -Environment $envRun
    Assert-True ($resReject1.ExitCode -ne 0) "run-agy-json: rejects forbidden --output in worker arguments"

    $resReject2 = Invoke-Helper -ScriptName 'run-agy-json.ps1' -ArgumentList @(
        '--role', 'scout',
        '--output', (Join-Path $TmpRoot 'rej2.json'),
        '--error', (Join-Path $TmpRoot 'rej2.err'),
        '--',
        '--output=sub-worker.json'
    ) -Environment $envRun
    Assert-True ($resReject2.ExitCode -ne 0) "run-agy-json: rejects forbidden --output=value in worker arguments"

    # 1.9 AGY_BIN precedence over PATH
    $customAgyDir = Join-Path $TmpRoot 'custom-agy-bin'
    [System.IO.Directory]::CreateDirectory($customAgyDir) | Out-Null
    $customAgyPs = Join-Path $customAgyDir 'custom_agy.ps1'
    @'
param([Parameter(ValueFromRemainingArguments)]$ArgsList)
[Console]::Out.WriteLine('{"status":"success","response":"custom","structured_output":{"from_custom":true}}')
exit 0
'@ | Set-Content -LiteralPath $customAgyPs -Encoding utf8

    if ($IsWindows) {
        $customAgyBin = Join-Path $customAgyDir 'custom-agy.cmd'
        @("@echo off", "pwsh -NoProfile -ExecutionPolicy Bypass -File `"%~dp0custom_agy.ps1`" %*") | Set-Content -LiteralPath $customAgyBin -Encoding ascii
    } else {
        $customAgyBin = Join-Path $customAgyDir 'custom-agy'
        @("#!/usr/bin/env pwsh", "param([Parameter(ValueFromRemainingArguments)]`$ArgsList)", "pwsh -NoProfile -ExecutionPolicy Bypass -File `"`$PSScriptRoot/custom_agy.ps1`" @ArgsList") | Set-Content -LiteralPath $customAgyBin -Encoding utf8
        [System.IO.File]::SetUnixFileMode($customAgyBin, [System.IO.UnixFileMode]509)
    }

    $customOut = Join-Path $TmpRoot 'custom.json'
    $customErr = Join-Path $TmpRoot 'custom.err'
    $res = Invoke-Helper -ScriptName 'run-agy-json.ps1' -ArgumentList @(
        '--role', 'scout',
        '--output', $customOut,
        '--error', $customErr,
        '--',
        '--prompt', 'test custom'
    ) -Environment @{
        'PATH' = $basePath
        'AGY_BIN' = $customAgyBin
    }
    Assert-Equal $res.ExitCode 0 "run-agy-json: succeeds with AGY_BIN override"
    $customJson = Get-Content -LiteralPath $customOut -Raw | ConvertFrom-Json
    Assert-True ($customJson.structured_output.from_custom -eq $true) "run-agy-json: AGY_BIN took precedence over PATH"

    # 1.10 Invalid explicit AGY_BIN fails immediately without fallback
    $invalidOut = Join-Path $TmpRoot 'invalid-bin.json'
    $invalidErr = Join-Path $TmpRoot 'invalid-bin.err'
    $res = Invoke-Helper -ScriptName 'run-agy-json.ps1' -ArgumentList @(
        '--role', 'scout',
        '--output', $invalidOut,
        '--error', $invalidErr,
        '--',
        '--prompt', 'test invalid'
    ) -Environment @{
        'PATH' = $basePath
        'AGY_BIN' = (Join-Path $TmpRoot 'non-existent-agy-binary.exe')
    }
    Assert-True ($res.ExitCode -ne 0) "run-agy-json: invalid AGY_BIN fails immediately with non-zero exit code"
    Assert-False (Test-Path -LiteralPath $invalidOut) "run-agy-json: invalid AGY_BIN did not run fallback worker"

    # =======================================================================
    # 2. extract-structured-output.ps1
    #    - extractor scalar mode
    #    - extractor array mode
    #    - verbose response omission
    #    - malformed JSON rejection
    #    - non-object JSON rejection
    #    - missing structured_output rejection
    #    - missing input file rejection
    # =======================================================================

    $worker1 = Join-Path $TmpRoot 'worker-one.json'
    '{"response":"long worker prose 1","structured_output":{"angle":"one","findings":[1]}}' | Set-Content -LiteralPath $worker1 -Encoding utf8

    $worker2 = Join-Path $TmpRoot 'worker-two.json'
    '{"response":"another long worker prose 2","structured_output":{"angle":"two","findings":[2]}}' | Set-Content -LiteralPath $worker2 -Encoding utf8

    # 2.0 Documented PowerShell pipeline assignment and native invocation
    $extractScript = Join-Path $ScriptsDir 'extract-structured-output.ps1'
    $directExtractCommand = '$researcherFiles = @($env:WORKER_ONE, $env:WORKER_TWO); $mergedResearchFindings = & $env:EXTRACT_SCRIPT --array @researcherFiles; if ([string]::IsNullOrWhiteSpace($mergedResearchFindings)) { exit 1 }; $mergedResearchFindings'
    $resDirectExtract = Invoke-ToolProcess -FilePath $PwshBin -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-Command', $directExtractCommand
    ) -Environment @{
        'EXTRACT_SCRIPT' = $extractScript
        'WORKER_ONE' = $worker1
        'WORKER_TWO' = $worker2
    }
    Assert-Equal $resDirectExtract.ExitCode 0 "extract-structured-output: documented in-process assignment exits 0"
    Assert-Equal $resDirectExtract.Stderr.Trim() '' "extract-structured-output: documented in-process assignment keeps diagnostics off stderr for valid input"
    $parsedDirectExtract = $resDirectExtract.Stdout | ConvertFrom-Json
    Assert-Equal $parsedDirectExtract.Count 2 "extract-structured-output: documented in-process assignment returns both findings"
    Assert-Equal $parsedDirectExtract[0].angle 'one' "extract-structured-output: documented in-process assignment preserves finding 1"
    Assert-Equal $parsedDirectExtract[1].angle 'two' "extract-structured-output: documented in-process assignment preserves finding 2"

    $resNativeExtract = Invoke-Helper -ScriptName 'extract-structured-output.ps1' -ArgumentList @('--array', $worker1, $worker2)
    Assert-Equal $resNativeExtract.ExitCode 0 "extract-structured-output: native pwsh -File invocation exits 0"
    Assert-Equal $resNativeExtract.Stderr.Trim() '' "extract-structured-output: native pwsh -File invocation keeps diagnostics off stderr for valid input"
    $parsedNativeExtract = $resNativeExtract.Stdout | ConvertFrom-Json
    Assert-Equal ($parsedNativeExtract | ConvertTo-Json -Compress) ($parsedDirectExtract | ConvertTo-Json -Compress) "extract-structured-output: direct and native invocations return the same payload"

    # 2.1 Scalar extraction
    $resScalar = Invoke-Helper -ScriptName 'extract-structured-output.ps1' -ArgumentList @($worker1)
    Assert-Equal $resScalar.ExitCode 0 "extract-structured-output: scalar mode exits 0"
    $parsedScalar = $resScalar.Stdout | ConvertFrom-Json
    Assert-Equal $parsedScalar.angle 'one' "extract-structured-output: scalar mode extracts structured properties"
    Assert-Equal $parsedScalar.findings[0] 1 "extract-structured-output: scalar mode extracts array elements"
    Assert-False ($resScalar.Stdout.Contains("long worker prose 1")) "extract-structured-output: scalar mode omits worker response"
    Assert-False ($resScalar.Stdout.Contains('"response"')) "extract-structured-output: scalar mode omits response key"

    # 2.2 Array extraction (--array)
    $resArray = Invoke-Helper -ScriptName 'extract-structured-output.ps1' -ArgumentList @('--array', $worker1, $worker2)
    Assert-Equal $resArray.ExitCode 0 "extract-structured-output: array mode exits 0"
    $parsedArray = $resArray.Stdout | ConvertFrom-Json
    Assert-Equal $parsedArray.Count 2 "extract-structured-output: array mode returns 2 items"
    Assert-Equal $parsedArray[0].angle 'one' "extract-structured-output: array mode preserves argument order item 1"
    Assert-Equal $parsedArray[1].angle 'two' "extract-structured-output: array mode preserves argument order item 2"
    Assert-False ($resArray.Stdout.Contains("long worker prose")) "extract-structured-output: array mode omits worker response"

    # 2.3 Malformed JSON rejection
    $malformedJson = Join-Path $TmpRoot 'malformed.json'
    '{not-valid-json: 42' | Set-Content -LiteralPath $malformedJson -Encoding utf8
    $resMalformed = Invoke-Helper -ScriptName 'extract-structured-output.ps1' -ArgumentList @($malformedJson)
    Assert-True ($resMalformed.ExitCode -ne 0) "extract-structured-output: rejects malformed JSON"

    # 2.4 Non-object top level rejection
    $nonObjectJson = Join-Path $TmpRoot 'non-object.json'
    '[{"structured_output":{"ok":true}}]' | Set-Content -LiteralPath $nonObjectJson -Encoding utf8
    $resNonObj = Invoke-Helper -ScriptName 'extract-structured-output.ps1' -ArgumentList @($nonObjectJson)
    Assert-True ($resNonObj.ExitCode -ne 0) "extract-structured-output: rejects non-object top-level JSON"

    # 2.5 Missing structured_output field rejection
    $missingStruct = Join-Path $TmpRoot 'missing-struct.json'
    '{"response":"only prose without structured output"}' | Set-Content -LiteralPath $missingStruct -Encoding utf8
    $resMissing = Invoke-Helper -ScriptName 'extract-structured-output.ps1' -ArgumentList @($missingStruct)
    Assert-True ($resMissing.ExitCode -ne 0) "extract-structured-output: rejects missing structured_output field"

    $resMissingArray = Invoke-Helper -ScriptName 'extract-structured-output.ps1' -ArgumentList @('--array', $worker1, $missingStruct)
    Assert-True ($resMissingArray.ExitCode -ne 0) "extract-structured-output: array mode rejects when any file lacks structured_output"

    # 2.6 Missing file rejection
    $resMissingFile = Invoke-Helper -ScriptName 'extract-structured-output.ps1' -ArgumentList @((Join-Path $TmpRoot 'nonexistent.json'))
    Assert-True ($resMissingFile.ExitCode -ne 0) "extract-structured-output: rejects non-existent input file"

    # =======================================================================
    # 3. make-research-workspace.ps1
    #    - workspace marker creation and exact content
    #    - scoped copying of declared paths
    #    - missing path warning and continuation
    #    - traversal path rejection
    #    - rooted/absolute path rejection
    #    - symlink / junction rejection
    # =======================================================================

    # 3.0 Documented PowerShell pipeline assignment and native invocation
    $makeWorkspaceScript = Join-Path $ScriptsDir 'make-research-workspace.ps1'
    $directWorkspaceCommand = '$workspace = (& $env:MAKE_WORKSPACE_SCRIPT --source-repo (Get-Location).Path --path scripts).Trim(); if ([string]::IsNullOrWhiteSpace($workspace) -or -not (Test-Path -LiteralPath $workspace -PathType Container)) { exit 1 }; $workspace'
    $resDirectWorkspace = Invoke-ToolProcess -FilePath $PwshBin -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-Command', $directWorkspaceCommand
    ) -Environment @{
        'MAKE_WORKSPACE_SCRIPT' = $makeWorkspaceScript
    } -WorkingDirectory $RootDir
    Assert-Equal $resDirectWorkspace.ExitCode 0 "make-research-workspace: documented in-process assignment exits 0"
    Assert-Equal $resDirectWorkspace.Stderr.Trim() '' "make-research-workspace: documented in-process assignment keeps diagnostics off stderr for valid input"
    $directWorkspacePath = $resDirectWorkspace.Stdout.Trim()
    Assert-True (Test-Path -LiteralPath $directWorkspacePath -PathType Container) "make-research-workspace: documented in-process assignment returns an existing workspace path"

    $resNativeWorkspace = Invoke-Helper -ScriptName 'make-research-workspace.ps1' -ArgumentList @(
        '--source-repo', $RootDir,
        '--path', 'scripts'
    )
    Assert-Equal $resNativeWorkspace.ExitCode 0 "make-research-workspace: native pwsh -File invocation exits 0"
    Assert-Equal $resNativeWorkspace.Stderr.Trim() '' "make-research-workspace: native pwsh -File invocation keeps diagnostics off stderr for valid input"
    $nativeWorkspacePath = $resNativeWorkspace.Stdout.Trim()
    Assert-True (Test-Path -LiteralPath $nativeWorkspacePath -PathType Container) "make-research-workspace: native pwsh -File invocation returns an existing workspace path"
    Assert-True (Test-Path -LiteralPath (Join-Path $directWorkspacePath '.offload-research-workspace') -PathType Leaf) "make-research-workspace: direct invocation returns a marked workspace"
    Assert-True (Test-Path -LiteralPath (Join-Path $nativeWorkspacePath '.offload-research-workspace') -PathType Leaf) "make-research-workspace: native invocation returns a marked workspace"
    Assert-True (Test-Path -LiteralPath (Join-Path $directWorkspacePath 'repo/scripts') -PathType Container) "make-research-workspace: direct invocation copies the declared scope"
    Assert-True (Test-Path -LiteralPath (Join-Path $nativeWorkspacePath 'repo/scripts') -PathType Container) "make-research-workspace: native invocation copies the declared scope"

    # 3.1 Workspace marker creation
    $resWs = Invoke-Helper -ScriptName 'make-research-workspace.ps1' -ArgumentList @()
    Assert-Equal $resWs.ExitCode 0 "make-research-workspace: creates workspace with exit code 0"
    $wsPath = $resWs.Stdout.Trim()
    Assert-True (Test-Path -LiteralPath $wsPath -PathType Container) "make-research-workspace: prints valid directory path"
    $wsMarker = Join-Path $wsPath '.offload-research-workspace'
    Assert-True (Test-Path -LiteralPath $wsMarker -PathType Leaf) "make-research-workspace: writes marker file"
    $markerRaw = [System.IO.File]::ReadAllText($wsMarker, [System.Text.Encoding]::UTF8)
    Assert-Equal $markerRaw.Trim() 'offload-research-workspace-v1' "make-research-workspace: marker contains exact version string"
    Assert-True ($markerRaw.EndsWith("`n")) "make-research-workspace: marker ends with a newline"

    # 3.2 Scoped copy
    $fixtureRepo = Join-Path $TmpRoot 'fixture-repo'
    [System.IO.Directory]::CreateDirectory((Join-Path $fixtureRepo 'declared/nested')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $fixtureRepo 'secret')) | Out-Null
    'keep-content' | Set-Content -LiteralPath (Join-Path $fixtureRepo 'declared/keep.txt') -Encoding utf8
    'nested-data' | Set-Content -LiteralPath (Join-Path $fixtureRepo 'declared/nested/data.txt') -Encoding utf8
    'secret-content' | Set-Content -LiteralPath (Join-Path $fixtureRepo 'secret/exclude.txt') -Encoding utf8

    $resScoped = Invoke-Helper -ScriptName 'make-research-workspace.ps1' -ArgumentList @(
        '--source-repo', $fixtureRepo,
        '--path', 'declared/keep.txt',
        '--path', 'declared/nested/data.txt'
    )
    Assert-Equal $resScoped.ExitCode 0 "make-research-workspace: scoped copy exits 0"
    $scopedPath = $resScoped.Stdout.Trim()
    Assert-True (Test-Path -LiteralPath (Join-Path $scopedPath 'repo/declared/keep.txt')) "make-research-workspace: copies declared file"
    Assert-Equal (Get-Content -LiteralPath (Join-Path $scopedPath 'repo/declared/keep.txt') -Raw).Trim() 'keep-content' "make-research-workspace: preserves file contents"
    Assert-True (Test-Path -LiteralPath (Join-Path $scopedPath 'repo/declared/nested/data.txt')) "make-research-workspace: copies declared nested file"
    Assert-False (Test-Path -LiteralPath (Join-Path $scopedPath 'repo/secret/exclude.txt')) "make-research-workspace: excludes undeclared files"
    Assert-NotEqual $scopedPath $fixtureRepo "make-research-workspace: creates isolated workspace path"

    # 3.3 Missing declared path warning
    $resMissingWarn = Invoke-Helper -ScriptName 'make-research-workspace.ps1' -ArgumentList @(
        '--source-repo', $fixtureRepo,
        '--path', 'declared/keep.txt',
        '--path', 'declared/nonexistent.txt'
    )
    Assert-Equal $resMissingWarn.ExitCode 0 "make-research-workspace: missing declared path continues with exit code 0"
    $missingWarnWs = $resMissingWarn.Stdout.Trim()
    Assert-True (Test-Path -LiteralPath (Join-Path $missingWarnWs 'repo/declared/keep.txt')) "make-research-workspace: existing declared path was copied"
    Assert-True ($resMissingWarn.Stderr.Length -gt 0) "make-research-workspace: missing path emits warning on stderr"

    # 3.4 Traversal rejection
    $resTrav1 = Invoke-Helper -ScriptName 'make-research-workspace.ps1' -ArgumentList @(
        '--source-repo', $fixtureRepo,
        '--path', '../outside.txt'
    )
    Assert-True ($resTrav1.ExitCode -ne 0) "make-research-workspace: rejects parent traversal .."

    $resTrav2 = Invoke-Helper -ScriptName 'make-research-workspace.ps1' -ArgumentList @(
        '--source-repo', $fixtureRepo,
        '--path', 'declared/../../outside.txt'
    )
    Assert-True ($resTrav2.ExitCode -ne 0) "make-research-workspace: rejects embedded parent traversal"

    # 3.5 Absolute / rooted path rejection
    $rootedTestPath = if ($IsWindows) { "C:\Windows\System32" } else { "/etc/passwd" }
    $resRooted = Invoke-Helper -ScriptName 'make-research-workspace.ps1' -ArgumentList @(
        '--source-repo', $fixtureRepo,
        '--path', $rootedTestPath
    )
    Assert-True ($resRooted.ExitCode -ne 0) "make-research-workspace: rejects rooted/absolute path"

    # 3.6 Symlink / junction rejection
    $linkDir = Join-Path $fixtureRepo 'linked_dir'
    if ($IsWindows) {
        New-Item -ItemType Junction -Path $linkDir -Target (Join-Path $fixtureRepo 'declared') | Out-Null
    } else {
        New-Item -ItemType SymbolicLink -Path $linkDir -Target (Join-Path $fixtureRepo 'declared') | Out-Null
    }
    $resLink = Invoke-Helper -ScriptName 'make-research-workspace.ps1' -ArgumentList @(
        '--source-repo', $fixtureRepo,
        '--path', 'linked_dir'
    )
    Assert-True ($resLink.ExitCode -ne 0) "make-research-workspace: rejects link/junction declared path"

    # =======================================================================
    # 4. collect-provenance.ps1
    #    - valid build with required fields
    #    - deep_trigger null preservation
    #    - duration_seconds numeric parsing
    #    - JSON array from file path
    #    - validation mode (--validate)
    #    - invalid field rejections (mode, profile, status, negative duration)
    # =======================================================================

    # 4.1 Valid build and field verification
    $provOut = Join-Path $TmpRoot 'provenance-built.json'
    $resProv = Invoke-Helper -ScriptName 'collect-provenance.ps1' -ArgumentList @(
        '--run-id', 'run-test-1',
        '--request-summary', 'Summary of investigation',
        '--selected-mode', 'web-research',
        '--profile', 'standard',
        '--start-time', '2026-01-01T00:00:00Z',
        '--end-time', '2026-01-01T00:00:10Z',
        '--duration-seconds', '10.5',
        '--scratch-path', '/tmp/scratch-test',
        '--final-status', 'success',
        '--workers', '[]',
        '--snapshot-paths', '[]',
        '--final-citations', '[]',
        '--audit-verdicts', '[]',
        '--incomplete-stage-reasons', '[]',
        '--output', $provOut
    )
    Assert-Equal $resProv.ExitCode 0 "collect-provenance: builds valid provenance with exit code 0"
    Assert-True (Test-Path -LiteralPath $provOut) "collect-provenance: output file created"
    $provRaw = [System.IO.File]::ReadAllText($provOut, [System.Text.Encoding]::UTF8)
    Assert-True ($provRaw.EndsWith("`n")) "collect-provenance: output ends with trailing newline"
    $provObj = $provRaw | ConvertFrom-Json
    Assert-Equal $provObj.run_id 'run-test-1' "collect-provenance: run_id preserved"
    Assert-Equal $provObj.request_summary 'Summary of investigation' "collect-provenance: request_summary preserved"
    Assert-Equal $provObj.selected_mode 'web-research' "collect-provenance: selected_mode preserved"
    Assert-Equal $provObj.profile 'standard' "collect-provenance: profile preserved"
    Assert-True ($null -eq $provObj.deep_trigger) "collect-provenance: deep_trigger is null when absent"
    Assert-Equal $provObj.duration_seconds 10.5 "collect-provenance: duration_seconds parsed as number"
    Assert-Equal $provObj.final_status 'success' "collect-provenance: final_status preserved"

    $requiredProvKeys = @(
        'run_id', 'request_summary', 'selected_mode', 'profile', 'deep_trigger',
        'start_time', 'end_time', 'duration_seconds', 'scratch_path', 'workers',
        'repository_snapshot_paths', 'final_citations', 'audit_verdicts',
        'final_status', 'incomplete_stage_reasons'
    )
    foreach ($key in $requiredProvKeys) {
        Assert-True ($provObj.PSObject.Properties.Match($key).Count -gt 0) "collect-provenance: contains required field '$key'"
    }

    # 4.2 Array from file path & deep_trigger explicit string
    $citsFile = Join-Path $TmpRoot 'citations-input.json'
    '[{"url":"https://example.com","title":"Example Citation"}]' | Set-Content -LiteralPath $citsFile -Encoding utf8
    $provFileArray = Join-Path $TmpRoot 'prov-file-array.json'
    $resProvArray = Invoke-Helper -ScriptName 'collect-provenance.ps1' -ArgumentList @(
        '--run-id', 'run-array-test',
        '--request-summary', 'Array test summary',
        '--selected-mode', 'repo-research',
        '--profile', 'deep',
        '--deep-trigger', 'threshold_exceeded',
        '--start-time', '2026-01-01T00:00:00Z',
        '--end-time', '2026-01-01T00:00:05Z',
        '--duration-seconds', '5',
        '--scratch-path', '/tmp/scratch',
        '--final-status', 'partial',
        '--final-citations', $citsFile,
        '--output', $provFileArray
    )
    Assert-Equal $resProvArray.ExitCode 0 "collect-provenance: builds with JSON array from file path"
    $provArrayObj = Get-Content -LiteralPath $provFileArray -Raw | ConvertFrom-Json
    Assert-Equal $provArrayObj.final_citations.Count 1 "collect-provenance: loaded array has 1 element"
    Assert-Equal $provArrayObj.final_citations[0].url 'https://example.com' "collect-provenance: preserved array file element content"
    Assert-Equal $provArrayObj.deep_trigger 'threshold_exceeded' "collect-provenance: preserved explicit deep_trigger string"

    # 4.3 Validation mode (--validate)
    $resValidate = Invoke-Helper -ScriptName 'collect-provenance.ps1' -ArgumentList @(
        '--validate', $provOut
    )
    Assert-Equal $resValidate.ExitCode 0 "collect-provenance: --validate passes for valid record"

    # 4.4 Invalid selected_mode
    $resBadMode = Invoke-Helper -ScriptName 'collect-provenance.ps1' -ArgumentList @(
        '--run-id', 'r1', '--request-summary', 's', '--start-time', 't1', '--end-time', 't2',
        '--duration-seconds', '1', '--scratch-path', 'p', '--final-status', 'success',
        '--selected-mode', 'invalid-mode'
    )
    Assert-True ($resBadMode.ExitCode -ne 0) "collect-provenance: rejects invalid selected_mode"

    # 4.5 Invalid profile
    $resBadProfile = Invoke-Helper -ScriptName 'collect-provenance.ps1' -ArgumentList @(
        '--run-id', 'r1', '--request-summary', 's', '--start-time', 't1', '--end-time', 't2',
        '--duration-seconds', '1', '--scratch-path', 'p', '--final-status', 'success',
        '--profile', 'invalid-profile'
    )
    Assert-True ($resBadProfile.ExitCode -ne 0) "collect-provenance: rejects invalid profile"

    # 4.6 Invalid final_status
    $resBadStatus = Invoke-Helper -ScriptName 'collect-provenance.ps1' -ArgumentList @(
        '--run-id', 'r1', '--request-summary', 's', '--start-time', 't1', '--end-time', 't2',
        '--duration-seconds', '1', '--scratch-path', 'p',
        '--final-status', 'invalid-status'
    )
    Assert-True ($resBadStatus.ExitCode -ne 0) "collect-provenance: rejects invalid final_status"

    # 4.7 Negative duration_seconds
    $resBadDuration = Invoke-Helper -ScriptName 'collect-provenance.ps1' -ArgumentList @(
        '--run-id', 'r1', '--request-summary', 's', '--start-time', 't1', '--end-time', 't2',
        '--scratch-path', 'p', '--final-status', 'success',
        '--duration-seconds', '-5'
    )
    Assert-True ($resBadDuration.ExitCode -ne 0) "collect-provenance: rejects negative duration_seconds"

    # 4.8 Missing required field in validation
    $badProvJson = Join-Path $TmpRoot 'bad-prov.json'
    '{"run_id":"r1","profile":"standard"}' | Set-Content -LiteralPath $badProvJson -Encoding utf8
    $resValidateBad = Invoke-Helper -ScriptName 'collect-provenance.ps1' -ArgumentList @(
        '--validate', $badProvJson
    )
    Assert-True ($resValidateBad.ExitCode -ne 0) "collect-provenance: --validate rejects record missing required fields"

    # =======================================================================
    # 5. cleanup-research-workspace.ps1
    #    - cleanup success retention
    #    - cleanup partial/failed retention
    #    - unmarked directory refusal
    #    - invalid marker version refusal
    #    - root refusal
    #    - current directory refusal
    #    - home directory refusal
    #    - git worktree refusal
    # =======================================================================

    # 5.1 Success cleanup retention
    $cleanSuccessWs = Join-Path $TmpRoot 'clean-success-ws'
    [System.IO.Directory]::CreateDirectory((Join-Path $cleanSuccessWs 'repo/sub')) | Out-Null
    Set-Content -LiteralPath (Join-Path $cleanSuccessWs '.offload-research-workspace') -Value "offload-research-workspace-v1`n" -NoNewline
    Set-Content -LiteralPath (Join-Path $cleanSuccessWs 'final.md') -Value "final report content"
    Set-Content -LiteralPath (Join-Path $cleanSuccessWs 'provenance.json') -Value "{}`n"
    Set-Content -LiteralPath (Join-Path $cleanSuccessWs 'raw-worker.json') -Value "raw worker content"
    Set-Content -LiteralPath (Join-Path $cleanSuccessWs 'repo/sub/data.txt') -Value "data"
    Set-Content -LiteralPath (Join-Path $cleanSuccessWs 'temp.log') -Value "log"

    $resCleanSuccess = Invoke-Helper -ScriptName 'cleanup-research-workspace.ps1' -ArgumentList @(
        '--workspace', $cleanSuccessWs,
        '--status', 'success'
    )
    Assert-Equal $resCleanSuccess.ExitCode 0 "cleanup-research-workspace: success status exits 0"
    Assert-True (Test-Path -LiteralPath (Join-Path $cleanSuccessWs '.offload-research-workspace')) "cleanup-research-workspace: success retains marker"
    Assert-True (Test-Path -LiteralPath (Join-Path $cleanSuccessWs 'final.md')) "cleanup-research-workspace: success retains final.md"
    Assert-True (Test-Path -LiteralPath (Join-Path $cleanSuccessWs 'provenance.json')) "cleanup-research-workspace: success retains provenance.json"
    Assert-False (Test-Path -LiteralPath (Join-Path $cleanSuccessWs 'raw-worker.json')) "cleanup-research-workspace: success removes raw-worker.json"
    Assert-False (Test-Path -LiteralPath (Join-Path $cleanSuccessWs 'repo')) "cleanup-research-workspace: success removes repo directory"
    Assert-False (Test-Path -LiteralPath (Join-Path $cleanSuccessWs 'temp.log')) "cleanup-research-workspace: success removes temp files"

    # 5.2 Partial cleanup retention
    $cleanPartialWs = Join-Path $TmpRoot 'clean-partial-ws'
    [System.IO.Directory]::CreateDirectory((Join-Path $cleanPartialWs 'repo')) | Out-Null
    Set-Content -LiteralPath (Join-Path $cleanPartialWs '.offload-research-workspace') -Value "offload-research-workspace-v1`n" -NoNewline
    Set-Content -LiteralPath (Join-Path $cleanPartialWs 'raw-worker.json') -Value "raw data"
    Set-Content -LiteralPath (Join-Path $cleanPartialWs 'repo/file.txt') -Value "repo data"

    $resCleanPartial = Invoke-Helper -ScriptName 'cleanup-research-workspace.ps1' -ArgumentList @(
        '--workspace', $cleanPartialWs,
        '--status', 'partial'
    )
    Assert-Equal $resCleanPartial.ExitCode 0 "cleanup-research-workspace: partial status exits 0"
    Assert-True (Test-Path -LiteralPath (Join-Path $cleanPartialWs 'raw-worker.json')) "cleanup-research-workspace: partial retains raw files"
    Assert-True (Test-Path -LiteralPath (Join-Path $cleanPartialWs 'repo/file.txt')) "cleanup-research-workspace: partial retains repo directory"

    # 5.3 Failed cleanup retention
    $cleanFailedWs = Join-Path $TmpRoot 'clean-failed-ws'
    [System.IO.Directory]::CreateDirectory($cleanFailedWs) | Out-Null
    Set-Content -LiteralPath (Join-Path $cleanFailedWs '.offload-research-workspace') -Value "offload-research-workspace-v1`n" -NoNewline
    Set-Content -LiteralPath (Join-Path $cleanFailedWs 'raw-worker.json') -Value "raw data"

    $resCleanFailed = Invoke-Helper -ScriptName 'cleanup-research-workspace.ps1' -ArgumentList @(
        '--workspace', $cleanFailedWs,
        '--status', 'failed'
    )
    Assert-Equal $resCleanFailed.ExitCode 0 "cleanup-research-workspace: failed status exits 0"
    Assert-True (Test-Path -LiteralPath (Join-Path $cleanFailedWs 'raw-worker.json')) "cleanup-research-workspace: failed retains raw files"

    # 5.4 Unmarked directory refusal
    $unmarkedWs = Join-Path $TmpRoot 'unmarked-dir'
    [System.IO.Directory]::CreateDirectory($unmarkedWs) | Out-Null
    Set-Content -LiteralPath (Join-Path $unmarkedWs 'keep-safe.txt') -Value "safe"
    $resUnmarked = Invoke-Helper -ScriptName 'cleanup-research-workspace.ps1' -ArgumentList @(
        '--workspace', $unmarkedWs,
        '--status', 'success'
    )
    Assert-True ($resUnmarked.ExitCode -ne 0) "cleanup-research-workspace: refuses unmarked directory"
    Assert-True (Test-Path -LiteralPath (Join-Path $unmarkedWs 'keep-safe.txt')) "cleanup-research-workspace: unmarked files remain untouched"

    # 5.5 Invalid marker version refusal
    $invalidMarkerWs = Join-Path $TmpRoot 'invalid-marker-dir'
    [System.IO.Directory]::CreateDirectory($invalidMarkerWs) | Out-Null
    Set-Content -LiteralPath (Join-Path $invalidMarkerWs '.offload-research-workspace') -Value "wrong-marker-version`n" -NoNewline
    Set-Content -LiteralPath (Join-Path $invalidMarkerWs 'keep-safe.txt') -Value "safe"
    $resInvalidMarker = Invoke-Helper -ScriptName 'cleanup-research-workspace.ps1' -ArgumentList @(
        '--workspace', $invalidMarkerWs,
        '--status', 'success'
    )
    Assert-True ($resInvalidMarker.ExitCode -ne 0) "cleanup-research-workspace: refuses invalid marker version"
    Assert-True (Test-Path -LiteralPath (Join-Path $invalidMarkerWs 'keep-safe.txt')) "cleanup-research-workspace: invalid marker files remain untouched"

    # 5.6 Filesystem root refusal
    $fsRoot = [System.IO.Path]::GetPathRoot((Get-Location).Path)
    $resRoot = Invoke-Helper -ScriptName 'cleanup-research-workspace.ps1' -ArgumentList @(
        '--workspace', $fsRoot,
        '--status', 'success'
    )
    Assert-True ($resRoot.ExitCode -ne 0) "cleanup-research-workspace: refuses filesystem root"

    # 5.7 Current working directory refusal
    $resCurDir = Invoke-Helper -ScriptName 'cleanup-research-workspace.ps1' -ArgumentList @(
        '--workspace', '.',
        '--status', 'success'
    )
    Assert-True ($resCurDir.ExitCode -ne 0) "cleanup-research-workspace: refuses process current directory"

    # 5.8 Home directory refusal
    $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    $resHome = Invoke-Helper -ScriptName 'cleanup-research-workspace.ps1' -ArgumentList @(
        '--workspace', $userHome,
        '--status', 'success'
    )
    Assert-True ($resHome.ExitCode -ne 0) "cleanup-research-workspace: refuses user home directory"

    # 5.9 Git worktree refusal
    $gitWorktree = Join-Path $TmpRoot 'git-worktree-target'
    [System.IO.Directory]::CreateDirectory((Join-Path $gitWorktree '.git')) | Out-Null
    Set-Content -LiteralPath (Join-Path $gitWorktree '.offload-research-workspace') -Value "offload-research-workspace-v1`n" -NoNewline
    Set-Content -LiteralPath (Join-Path $gitWorktree 'repo-file.txt') -Value "tracked"
    $resGitWorktree = Invoke-Helper -ScriptName 'cleanup-research-workspace.ps1' -ArgumentList @(
        '--workspace', $gitWorktree,
        '--status', 'success'
    )
    Assert-True ($resGitWorktree.ExitCode -ne 0) "cleanup-research-workspace: refuses git worktree root"
    Assert-True (Test-Path -LiteralPath (Join-Path $gitWorktree 'repo-file.txt')) "cleanup-research-workspace: git worktree files remain untouched"

    # -----------------------------------------------------------------------
    # All Checks Completed
    # -----------------------------------------------------------------------
    [Console]::Out.WriteLine("all powershell research helper checks passed ($script:TotalTests tests)")
    exit 0
}
finally {
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
