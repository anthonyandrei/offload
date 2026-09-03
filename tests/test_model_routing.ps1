#!/usr/bin/env pwsh
# tests/test_model_routing.ps1
# Self-contained acceptance test suite for Gemini model routing in run-agy-json.ps1.
# Implements contracts specified in docs/specs/0003-gemini-model-routing.md.
# Strict constraints: Standalone PowerShell 7 / .NET only, no Pester, Python, jq, Bash, or network.

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
        Fail $name $(if ($reason) { $reason } else { "Condition was false" })
    }
}

function Assert-False([bool]$condition, [string]$name, [string]$reason = "") {
    if (-not $condition) {
        Pass $name
    } else {
        Fail $name $(if ($reason) { $reason } else { "Condition was true" })
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

function Assert-ForwardedModelAndArgs(
    [string[]]$capturedArgs,
    [string]$expectedModel,
    [string[]]$expectedCallerArgs,
    [string]$name
) {
    $modelIndices = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $capturedArgs.Count; $i++) {
        if ($capturedArgs[$i] -eq '--model') {
            $modelIndices.Add($i)
        } elseif ($capturedArgs[$i].StartsWith('--model=')) {
            Fail $name "Launcher forwarded combined '--model=...' instead of separated '--model' and model ID"
        }
    }

    Assert-Equal $modelIndices.Count 1 "${name}: exactly one --model argument forwarded"
    $modelIdx = $modelIndices[0]
    Assert-True ($modelIdx + 1 -lt $capturedArgs.Count) "${name}: --model has accompanying value"
    $actualModel = $capturedArgs[$modelIdx + 1]
    Assert-Equal $actualModel $expectedModel "${name}: forwarded model ID matches expected"

    for ($i = 0; $i -lt $capturedArgs.Count; $i++) {
        if ($capturedArgs[$i] -eq '--effort' -or $capturedArgs[$i].StartsWith('--effort=')) {
            Fail $name "Launcher forwarded forbidden '--effort' option to agy: $($capturedArgs[$i])"
        }
    }

    if ($null -ne $expectedCallerArgs) {
        $nonModelArgs = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $capturedArgs.Count; $i++) {
            if ($i -eq $modelIdx -or $i -eq ($modelIdx + 1)) {
                continue
            }
            $nonModelArgs.Add($capturedArgs[$i])
        }
        Assert-StringArrayEqual $nonModelArgs.ToArray() $expectedCallerArgs "${name}: caller arguments preserved"
    }
}

# ---------------------------------------------------------------------------
# Public Process Runners
# ---------------------------------------------------------------------------

$PwshBin = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $PwshBin) {
    $PwshBin = (Get-Process -Id $PID).Path
}

$RootDir = Split-Path -Parent $PSScriptRoot
$ScriptsDir = Join-Path $RootDir 'scripts'
$ProdLauncher = Join-Path $ScriptsDir 'run-agy-json.ps1'

if (-not (Test-Path -LiteralPath $ProdLauncher)) {
    Fail "Launcher script existence check" "run-agy-json.ps1 not found at '$ProdLauncher'"
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

function Invoke-Launcher {
    param(
        [string]$LauncherPath = $ProdLauncher,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = $null
    )
    $pwshArgs = @('-NoProfile', '-NonInteractive', '-File', $LauncherPath) + $ArgumentList
    return Invoke-ToolProcess -FilePath $PwshBin -ArgumentList $pwshArgs -Environment $Environment -WorkingDirectory $WorkingDirectory
}

function Invoke-LauncherCommand {
    param(
        [Parameter(Mandatory=$true)][string]$CommandExpression,
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = $null
    )
    $pwshArgs = @('-NoProfile', '-NonInteractive', '-Command', $CommandExpression)
    return Invoke-ToolProcess -FilePath $PwshBin -ArgumentList $pwshArgs -Environment $Environment -WorkingDirectory $WorkingDirectory
}

# ---------------------------------------------------------------------------
# Test Environment Setup
# ---------------------------------------------------------------------------

$TmpRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "offload-model-routing-$([System.Guid]::NewGuid().ToString('N'))")
[System.IO.Directory]::CreateDirectory($TmpRoot) | Out-Null

try {
    # -----------------------------------------------------------------------
    # Fake AGY Executable Harness
    # -----------------------------------------------------------------------
    $fakeBin = Join-Path $TmpRoot 'bin'
    [System.IO.Directory]::CreateDirectory($fakeBin) | Out-Null

    $fakeAgyPs = Join-Path $fakeBin 'fake_agy.ps1'
    @'
if ($env:FAKE_AGY_ARGS) {
    $capturedArgs = @($args | ForEach-Object { [string]$_ })
    [System.IO.File]::WriteAllText(
        $env:FAKE_AGY_ARGS,
        (ConvertTo-Json -InputObject $capturedArgs -Compress),
        [System.Text.Encoding]::UTF8
    )
}
if ($env:FAKE_AGY_STARTED_MARKER) {
    [System.IO.File]::WriteAllText($env:FAKE_AGY_STARTED_MARKER, "started", [System.Text.Encoding]::UTF8)
}
if ($env:FAKE_AGY_DELAY_MS) {
    [System.Threading.Thread]::Sleep([int]$env:FAKE_AGY_DELAY_MS)
}
if ($env:FAKE_AGY_COMPLETED_MARKER) {
    [System.IO.File]::WriteAllText($env:FAKE_AGY_COMPLETED_MARKER, "completed", [System.Text.Encoding]::UTF8)
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
        @("#!/usr/bin/env pwsh", "pwsh -NoProfile -ExecutionPolicy Bypass -File `"`$PSScriptRoot/fake_agy.ps1`" `"`$@`"") | Set-Content -LiteralPath $fakeAgyUnix -Encoding utf8
        [System.IO.File]::SetUnixFileMode($fakeAgyUnix, [System.IO.UnixFileMode]509)
    }

    $pathSep = [System.IO.Path]::PathSeparator
    $basePath = "$fakeBin$pathSep$env:PATH"

    # Fixture helper for invalid-policy and escalation testing
    function New-PolicyFixture {
        param(
            [Parameter(Mandatory=$true)][string]$FixtureName,
            [string]$PolicyJsonContent = $null,
            [hashtable]$AdditionalFiles = @{}
        )
        $fixtureDir = Join-Path $TmpRoot "fixtures/$FixtureName"
        $fixtureScripts = Join-Path $fixtureDir 'scripts'
        [System.IO.Directory]::CreateDirectory($fixtureScripts) | Out-Null
        Copy-Item -LiteralPath $ProdLauncher -Destination (Join-Path $fixtureScripts 'run-agy-json.ps1')

        if ($null -ne $PolicyJsonContent) {
            $policyPath = Join-Path $fixtureDir 'model-policy.json'
            [System.IO.File]::WriteAllText($policyPath, $PolicyJsonContent, [System.Text.Encoding]::UTF8)
        }

        foreach ($relPath in $AdditionalFiles.Keys) {
            $targetPath = Join-Path $fixtureDir $relPath
            $targetDir = [System.IO.Path]::GetDirectoryName($targetPath)
            if (-not [string]::IsNullOrEmpty($targetDir) -and -not [System.IO.Directory]::Exists($targetDir)) {
                [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null
            }
            [System.IO.File]::WriteAllText($targetPath, [string]$AdditionalFiles[$relPath], [System.Text.Encoding]::UTF8)
        }

        return (Join-Path $fixtureScripts 'run-agy-json.ps1')
    }

    function Get-BaselinePolicyJson {
        return @'
{
  "schema_version": 1,
  "policy_revision": "2026-09-03.1",
  "max_effort": "high",
  "max_retries_per_worker": 1,
  "quota_action": "handoff",
  "roles": {
    "scout": {
      "default_model": "gemini-3.8-flash-low",
      "quality_escalation": null
    },
    "gate-author": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": null
    },
    "implementer": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": null
    },
    "reviewer": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": null
    },
    "researcher": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": null
    },
    "synthesizer": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": null
    },
    "auditor": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": null
    }
  }
}
'@
    }

    # =======================================================================
    # 1. Exact Initial Models for Every Role (Default Route)
    # =======================================================================
    $roleModelMap = [ordered]@{
        'scout'       = 'gemini-3.8-flash-low'
        'gate-author' = 'gemini-3.8-flash-high'
        'implementer' = 'gemini-3.8-flash-high'
        'reviewer'    = 'gemini-3.8-flash-high'
        'researcher'  = 'gemini-3.8-flash-high'
        'synthesizer' = 'gemini-3.8-flash-high'
        'auditor'     = 'gemini-3.8-flash-high'
    }

    # 1.1 Every role resolves to exact initial model (implicit default route, -File invocation)
    foreach ($role in $roleModelMap.Keys) {
        $expectedModel = $roleModelMap[$role]
        $argsCapture = Join-Path $TmpRoot "args-$role-implicit.json"
        $outPath = Join-Path $TmpRoot "out-$role-implicit.json"
        $errPath = Join-Path $TmpRoot "err-$role-implicit.err"
        $env = @{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $argsCapture
        }

        $res = Invoke-Launcher -ArgumentList @(
            '--role', $role,
            '--output', $outPath,
            '--error', $errPath,
            '--',
            '-p', "prompt for $role",
            '--output-format', 'json'
        ) -Environment $env

        Assert-Equal $res.ExitCode 0 "role '$role' implicit default: exits 0"
        Assert-True (Test-Path -LiteralPath $argsCapture) "role '$role' implicit default: worker was launched"
        $captured = @(Get-Content -LiteralPath $argsCapture -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
        Assert-ForwardedModelAndArgs $captured $expectedModel @('-p', "prompt for $role", '--output-format', 'json') "role '$role' implicit default"
        Assert-True (Test-Path -LiteralPath $outPath) "role '$role' implicit default: created output file"
        Assert-True (Test-Path -LiteralPath $errPath) "role '$role' implicit default: created error file"
        Assert-Equal $res.Stdout.Trim() "" "role '$role' implicit default: launcher leaked no stdout"
    }

    # 1.2 Every role with explicit default route (--route default)
    foreach ($role in $roleModelMap.Keys) {
        $expectedModel = $roleModelMap[$role]
        $argsCapture = Join-Path $TmpRoot "args-$role-explicit.json"
        $env = @{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $argsCapture
        }

        $res = Invoke-Launcher -ArgumentList @(
            '--role', $role,
            '--route', 'default',
            '--output', (Join-Path $TmpRoot "out-$role-explicit.json"),
            '--error', (Join-Path $TmpRoot "err-$role-explicit.err"),
            '--',
            '-p', "explicit route prompt for $role"
        ) -Environment $env

        Assert-Equal $res.ExitCode 0 "role '$role' explicit default: exits 0"
        Assert-True (Test-Path -LiteralPath $argsCapture) "role '$role' explicit default: worker was launched"
        $captured = @(Get-Content -LiteralPath $argsCapture -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
        Assert-ForwardedModelAndArgs $captured $expectedModel @('-p', "explicit route prompt for $role") "role '$role' explicit default"
    }

    # 1.3 Equals forms: --role=<role> and --route=default
    & {
        $argsCapture = Join-Path $TmpRoot "args-equals-form.json"
        $env = @{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $argsCapture
        }
        $res = Invoke-Launcher -ArgumentList @(
            '--role=scout',
            '--route=default',
            '--output', (Join-Path $TmpRoot "out-equals.json"),
            '--error', (Join-Path $TmpRoot "err-equals.err"),
            '--',
            '-p', 'equals form prompt'
        ) -Environment $env

        Assert-Equal $res.ExitCode 0 "equals form options (--role=scout --route=default): exits 0"
        Assert-True (Test-Path -LiteralPath $argsCapture) "equals form options: worker launched"
        $captured = @(Get-Content -LiteralPath $argsCapture -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
        Assert-ForwardedModelAndArgs $captured 'gemini-3.8-flash-low' @('-p', 'equals form prompt') "equals form options"
    }

    # =======================================================================
    # 2. Actual Command-Expression Invocation using Quoted '--'
    # =======================================================================
    $cmdDir = Join-Path $TmpRoot 'cmd-expressions'
    [System.IO.Directory]::CreateDirectory($cmdDir) | Out-Null

    # 2.1 Scout via command expression with quoted delimiter and spaces
    & {
        $cmdArgs = Join-Path $cmdDir 'scout-args.json'
        $cmdOut = Join-Path $cmdDir 'scout-out.json'
        $cmdErr = Join-Path $cmdDir 'scout-err.log'
        $cmdEnv = @{
            'AGY_BIN'        = $fakeAgyPs
            'FAKE_AGY_ARGS'  = $cmdArgs
            'RUN_AGY_JSON'   = $ProdLauncher
            'RUN_OUTPUT'     = $cmdOut
            'RUN_ERROR'      = $cmdErr
            'WORKER_PROMPT'  = 'command expr prompt with spaces'
            'FORWARDED_PATH' = (Join-Path $cmdDir 'some nested/path with spaces.txt')
        }
        $expr = "& `$env:RUN_AGY_JSON --role scout --output `$env:RUN_OUTPUT --error `$env:RUN_ERROR '--' -p `$env:WORKER_PROMPT --path `$env:FORWARDED_PATH; exit `$LASTEXITCODE"
        $resCmd = Invoke-LauncherCommand -CommandExpression $expr -Environment $cmdEnv

        Assert-Equal $resCmd.ExitCode 0 "command-expression (scout): exits 0"
        Assert-True (Test-Path -LiteralPath $cmdArgs) "command-expression (scout): worker launched"
        Assert-True (Test-Path -LiteralPath $cmdOut) "command-expression (scout): output file created"
        Assert-True (Test-Path -LiteralPath $cmdErr) "command-expression (scout): error file created"
        $captured = @(Get-Content -LiteralPath $cmdArgs -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
        Assert-ForwardedModelAndArgs $captured 'gemini-3.8-flash-low' @('-p', 'command expr prompt with spaces', '--path', (Join-Path $cmdDir 'some nested/path with spaces.txt')) "command-expression (scout)"
    }

    # 2.2 Implementer with explicit --route default via command expression
    & {
        $cmdArgs = Join-Path $cmdDir 'impl-args.json'
        $cmdOut = Join-Path $cmdDir 'impl-out.json'
        $cmdErr = Join-Path $cmdDir 'impl-err.log'
        $cmdEnv = @{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $cmdArgs
            'RUN_AGY_JSON'  = $ProdLauncher
            'RUN_OUTPUT'    = $cmdOut
            'RUN_ERROR'     = $cmdErr
            'WORKER_PROMPT' = 'implementer prompt'
        }
        $expr = "& `$env:RUN_AGY_JSON --role implementer --route default --output `$env:RUN_OUTPUT --error `$env:RUN_ERROR '--' -p `$env:WORKER_PROMPT; exit `$LASTEXITCODE"
        $resCmd = Invoke-LauncherCommand -CommandExpression $expr -Environment $cmdEnv

        Assert-Equal $resCmd.ExitCode 0 "command-expression (implementer explicit default): exits 0"
        Assert-True (Test-Path -LiteralPath $cmdArgs) "command-expression (implementer): worker launched"
        $captured = @(Get-Content -LiteralPath $cmdArgs -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
        Assert-ForwardedModelAndArgs $captured 'gemini-3.8-flash-high' @('-p', 'implementer prompt') "command-expression (implementer)"
    }

    # 2.3 Researcher identical default model across invocation modes
    & {
        $cmdArgs = Join-Path $cmdDir 'researcher-args.json'
        $cmdEnv = @{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $cmdArgs
            'RUN_AGY_JSON'  = $ProdLauncher
            'RUN_OUTPUT'    = (Join-Path $cmdDir 'researcher-out.json')
            'RUN_ERROR'     = (Join-Path $cmdDir 'researcher-err.log')
            'WORKER_PROMPT' = 'researcher investigation prompt'
        }
        $expr = "& `$env:RUN_AGY_JSON --role researcher --output `$env:RUN_OUTPUT --error `$env:RUN_ERROR '--' -p `$env:WORKER_PROMPT; exit `$LASTEXITCODE"
        $resCmd = Invoke-LauncherCommand -CommandExpression $expr -Environment $cmdEnv

        Assert-Equal $resCmd.ExitCode 0 "command-expression (researcher): exits 0"
        Assert-True (Test-Path -LiteralPath $cmdArgs) "command-expression (researcher): worker launched"
        $captured = @(Get-Content -LiteralPath $cmdArgs -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
        Assert-ForwardedModelAndArgs $captured 'gemini-3.8-flash-high' @('-p', 'researcher investigation prompt') "command-expression (researcher)"
    }

    # =======================================================================
    # 3. Prompt and Path Argument Preservation (including --model and --effort text)
    # =======================================================================

    # 3.1 Prompt text containing '--model' and '--effort'
    & {
        $argsCapture = Join-Path $TmpRoot "args-prompt-with-model-strings.json"
        $env = @{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $argsCapture
        }
        $promptText = "Review changes considering --model gemini-3.7-flash and --effort high inside prompt text"
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot "out-prompt-strings.json"),
            '--error', (Join-Path $TmpRoot "err-prompt-strings.err"),
            '--',
            '-p', $promptText
        ) -Environment $env

        Assert-Equal $res.ExitCode 0 "prompt containing '--model' and '--effort' text: exits 0"
        Assert-True (Test-Path -LiteralPath $argsCapture) "prompt containing '--model' and '--effort': worker launched"
        $captured = @(Get-Content -LiteralPath $argsCapture -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
        Assert-ForwardedModelAndArgs $captured 'gemini-3.8-flash-low' @('-p', $promptText) "prompt containing '--model' and '--effort' text"
    }

    # 3.2 Prompt and path containing equals and option substrings
    & {
        $argsCapture = Join-Path $TmpRoot "args-prompt-with-equals-strings.json"
        $env = @{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $argsCapture
        }
        $promptText = "Do not use --model=gemini-ultra or --effort=low in worker configs"
        $customPath = 'path with spaces/--model-folder/file.txt'
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'reviewer',
            '--output', (Join-Path $TmpRoot "out-prompt-equals.json"),
            '--error', (Join-Path $TmpRoot "err-prompt-equals.err"),
            '--',
            '--prompt', $promptText,
            '--path', $customPath
        ) -Environment $env

        Assert-Equal $res.ExitCode 0 "prompt and path containing equals and option substrings: exits 0"
        Assert-True (Test-Path -LiteralPath $argsCapture) "prompt/path with option substrings: worker launched"
        $captured = @(Get-Content -LiteralPath $argsCapture -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
        Assert-ForwardedModelAndArgs $captured 'gemini-3.8-flash-high' @('--prompt', $promptText, '--path', $customPath) "prompt and path with option substrings"
    }

    # 3.3 Command-expression preserving prompt with --model and --effort
    & {
        $cmdArgs = Join-Path $cmdDir 'cmd-prompt-strings-args.json'
        $cmdEnv = @{
            'AGY_BIN'        = $fakeAgyPs
            'FAKE_AGY_ARGS'  = $cmdArgs
            'RUN_AGY_JSON'   = $ProdLauncher
            'RUN_OUTPUT'     = (Join-Path $cmdDir 'cmd-prompt-out.json')
            'RUN_ERROR'      = (Join-Path $cmdDir 'cmd-prompt-err.log')
            'WORKER_PROMPT'  = 'evaluate --model and --effort flags'
            'FORWARDED_PATH' = (Join-Path $cmdDir 'folder --effort/file.txt')
        }
        $expr = "& `$env:RUN_AGY_JSON --role scout --output `$env:RUN_OUTPUT --error `$env:RUN_ERROR '--' -p `$env:WORKER_PROMPT --path `$env:FORWARDED_PATH; exit `$LASTEXITCODE"
        $resCmd = Invoke-LauncherCommand -CommandExpression $expr -Environment $cmdEnv

        Assert-Equal $resCmd.ExitCode 0 "command-expression prompt with '--model'/'--effort': exits 0"
        Assert-True (Test-Path -LiteralPath $cmdArgs) "command-expression prompt with '--model'/'--effort': worker launched"
        $captured = @(Get-Content -LiteralPath $cmdArgs -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
        Assert-ForwardedModelAndArgs $captured 'gemini-3.8-flash-low' @('-p', 'evaluate --model and --effort flags', '--path', (Join-Path $cmdDir 'folder --effort/file.txt')) "command-expression prompt with option text"
    }

    # =======================================================================
    # 4. Caller Model and Effort Rejection Before Worker Start
    # =======================================================================

    # 4.1 Caller --model separated form
    & {
        $argsCapture = Join-Path $TmpRoot "args-reject-model.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot "out-rej-model.json"),
            '--error', (Join-Path $TmpRoot "err-rej-model.err"),
            '--',
            '--model', 'gemini-3.8-flash-high',
            '-p', 'test prompt'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "caller --model rejected before start: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "caller --model rejected: worker not launched"
        Assert-True ($res.Stderr -match '(?i)model') "caller --model rejected: actionable stderr mentions model"
    }

    # 4.2 Caller --model=value equals form
    & {
        $argsCapture = Join-Path $TmpRoot "args-reject-model-equals.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot "out-rej-model-eq.json"),
            '--error', (Join-Path $TmpRoot "err-rej-model-eq.err"),
            '--',
            '--model=gemini-3.8-flash-high',
            '-p', 'test prompt'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "caller --model=value rejected before start: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "caller --model=value rejected: worker not launched"
        Assert-True ($res.Stderr -match '(?i)model') "caller --model=value rejected: actionable stderr mentions model"
    }

    # 4.3 Caller --effort separated form
    & {
        $argsCapture = Join-Path $TmpRoot "args-reject-effort.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot "out-rej-effort.json"),
            '--error', (Join-Path $TmpRoot "err-rej-effort.err"),
            '--',
            '--effort', 'high',
            '-p', 'test prompt'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "caller --effort rejected before start: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "caller --effort rejected: worker not launched"
        Assert-True ($res.Stderr -match '(?i)effort') "caller --effort rejected: actionable stderr mentions effort"
    }

    # 4.4 Caller --effort=value equals form
    & {
        $argsCapture = Join-Path $TmpRoot "args-reject-effort-equals.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot "out-rej-effort-eq.json"),
            '--error', (Join-Path $TmpRoot "err-rej-effort-eq.err"),
            '--',
            '--effort=high',
            '-p', 'test prompt'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "caller --effort=value rejected before start: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "caller --effort=value rejected: worker not launched"
        Assert-True ($res.Stderr -match '(?i)effort') "caller --effort=value rejected: actionable stderr mentions effort"
    }

    # 4.5 Caller --model rejection in command-expression
    & {
        $cmdArgs = Join-Path $cmdDir 'cmd-reject-model.json'
        $cmdEnv = @{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $cmdArgs
            'RUN_AGY_JSON'  = $ProdLauncher
            'RUN_OUTPUT'    = (Join-Path $cmdDir 'cmd-rej-model-out.json')
            'RUN_ERROR'     = (Join-Path $cmdDir 'cmd-rej-model-err.log')
        }
        $expr = "& `$env:RUN_AGY_JSON --role scout --output `$env:RUN_OUTPUT --error `$env:RUN_ERROR '--' --model gemini-3.8-flash-high -p test; exit `$LASTEXITCODE"
        $resCmd = Invoke-LauncherCommand -CommandExpression $expr -Environment $cmdEnv

        Assert-Equal $resCmd.ExitCode 2 "command-expression caller --model rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $cmdArgs) "command-expression caller --model rejected: worker not launched"
    }

    # 4.6 Caller --effort rejection in command-expression
    & {
        $cmdArgs = Join-Path $cmdDir 'cmd-reject-effort.json'
        $cmdEnv = @{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $cmdArgs
            'RUN_AGY_JSON'  = $ProdLauncher
            'RUN_OUTPUT'    = (Join-Path $cmdDir 'cmd-rej-effort-out.json')
            'RUN_ERROR'     = (Join-Path $cmdDir 'cmd-rej-effort-err.log')
        }
        $expr = "& `$env:RUN_AGY_JSON --role scout --output `$env:RUN_OUTPUT --error `$env:RUN_ERROR '--' --effort=high -p test; exit `$LASTEXITCODE"
        $resCmd = Invoke-LauncherCommand -CommandExpression $expr -Environment $cmdEnv

        Assert-Equal $resCmd.ExitCode 2 "command-expression caller --effort rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $cmdArgs) "command-expression caller --effort rejected: worker not launched"
    }

    # =======================================================================
    # 5. Rejection Before Worker Start for Missing/Unknown Role/Route and Duplicates
    # =======================================================================

    # 5.1 Missing --role option
    & {
        $argsCapture = Join-Path $TmpRoot "args-reject-missing-role.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -ArgumentList @(
            '--output', (Join-Path $TmpRoot "out-missing-role.json"),
            '--error', (Join-Path $TmpRoot "err-missing-role.err"),
            '--',
            '-p', 'prompt without role'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "missing --role rejected before start: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "missing --role rejected: worker not launched"
        Assert-True ($res.Stderr -match '(?i)role') "missing --role rejected: actionable stderr mentions role"
    }

    # 5.2 Missing --role in command-expression
    & {
        $cmdArgs = Join-Path $cmdDir 'cmd-missing-role.json'
        $cmdEnv = @{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $cmdArgs
            'RUN_AGY_JSON'  = $ProdLauncher
            'RUN_OUTPUT'    = (Join-Path $cmdDir 'cmd-missing-role-out.json')
            'RUN_ERROR'     = (Join-Path $cmdDir 'cmd-missing-role-err.log')
        }
        $expr = "& `$env:RUN_AGY_JSON --output `$env:RUN_OUTPUT --error `$env:RUN_ERROR '--' -p test; exit `$LASTEXITCODE"
        $resCmd = Invoke-LauncherCommand -CommandExpression $expr -Environment $cmdEnv

        Assert-Equal $resCmd.ExitCode 2 "command-expression missing --role rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $cmdArgs) "command-expression missing --role: worker not launched"
    }

    # 5.3 Unknown role (separated form)
    & {
        $argsCapture = Join-Path $TmpRoot "args-unknown-role.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'nonexistent-role',
            '--output', (Join-Path $TmpRoot "out-unknown-role.json"),
            '--error', (Join-Path $TmpRoot "err-unknown-role.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "unknown role rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "unknown role rejected: worker not launched"
        Assert-True ($res.Stderr -match '(?i)role') "unknown role: actionable stderr mentions role"
    }

    # 5.4 Unknown role (equals form)
    & {
        $argsCapture = Join-Path $TmpRoot "args-unknown-role-eq.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -ArgumentList @(
            '--role=bogus-role',
            '--output', (Join-Path $TmpRoot "out-unknown-role-eq.json"),
            '--error', (Join-Path $TmpRoot "err-unknown-role-eq.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "unknown role=value rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "unknown role=value rejected: worker not launched"
    }

    # 5.5 Unknown route (separated form)
    & {
        $argsCapture = Join-Path $TmpRoot "args-unknown-route.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--route', 'speculative-route',
            '--output', (Join-Path $TmpRoot "out-unknown-route.json"),
            '--error', (Join-Path $TmpRoot "err-unknown-route.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "unknown route rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "unknown route rejected: worker not launched"
        Assert-True ($res.Stderr -match '(?i)route') "unknown route: actionable stderr mentions route"
    }

    # 5.6 Unknown route (equals form)
    & {
        $argsCapture = Join-Path $TmpRoot "args-unknown-route-eq.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--route=bogus-route',
            '--output', (Join-Path $TmpRoot "out-unknown-route-eq.json"),
            '--error', (Join-Path $TmpRoot "err-unknown-route-eq.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "unknown route=value rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "unknown route=value rejected: worker not launched"
    }

    # 5.7 Duplicate --role options
    & {
        $argsCapture = Join-Path $TmpRoot "args-dup-role.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--role', 'gate-author',
            '--output', (Join-Path $TmpRoot "out-dup-role.json"),
            '--error', (Join-Path $TmpRoot "err-dup-role.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "duplicate --role rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "duplicate --role: worker not launched"
        Assert-True ($res.Stderr -match '(?i)duplicate|role') "duplicate --role: actionable stderr"
    }

    # 5.8 Duplicate --role options (equals form)
    & {
        $argsCapture = Join-Path $TmpRoot "args-dup-role-eq.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -ArgumentList @(
            '--role=scout',
            '--role=implementer',
            '--output', (Join-Path $TmpRoot "out-dup-role-eq.json"),
            '--error', (Join-Path $TmpRoot "err-dup-role-eq.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "duplicate --role=value rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "duplicate --role=value: worker not launched"
    }

    # 5.9 Duplicate --route options
    & {
        $argsCapture = Join-Path $TmpRoot "args-dup-route.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--route', 'default',
            '--route', 'quality-retry',
            '--output', (Join-Path $TmpRoot "out-dup-route.json"),
            '--error', (Join-Path $TmpRoot "err-dup-route.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "duplicate --route rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "duplicate --route: worker not launched"
        Assert-True ($res.Stderr -match '(?i)duplicate|route') "duplicate --route: actionable stderr"
    }

    # 5.10 Duplicate --route options (equals form)
    & {
        $argsCapture = Join-Path $TmpRoot "args-dup-route-eq.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--route=default',
            '--route=quality-retry',
            '--output', (Join-Path $TmpRoot "out-dup-route-eq.json"),
            '--error', (Join-Path $TmpRoot "err-dup-route-eq.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "duplicate --route=value rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "duplicate --route=value: worker not launched"
    }

    # =======================================================================
    # 6. Null Quality-Retry Target Rejection Before Worker Start
    # =======================================================================

    # 6.1 scout with null quality_escalation on baseline policy
    & {
        $argsCapture = Join-Path $TmpRoot "args-null-retry-scout.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--route', 'quality-retry',
            '--output', (Join-Path $TmpRoot "out-null-retry-scout.json"),
            '--error', (Join-Path $TmpRoot "err-null-retry-scout.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "null quality-retry target (scout) rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "null quality-retry target: worker not launched"
        Assert-True ($res.Stderr -match '(?i)escalation|quality-retry|target|route') "null quality-retry target: actionable stderr"
    }

    # 6.2 implementer with null quality_escalation in command-expression
    & {
        $cmdArgs = Join-Path $cmdDir 'cmd-null-retry-impl.json'
        $cmdEnv = @{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $cmdArgs
            'RUN_AGY_JSON'  = $ProdLauncher
            'RUN_OUTPUT'    = (Join-Path $cmdDir 'cmd-null-retry-out.json')
            'RUN_ERROR'     = (Join-Path $cmdDir 'cmd-null-retry-err.log')
        }
        $expr = "& `$env:RUN_AGY_JSON --role implementer --route quality-retry --output `$env:RUN_OUTPUT --error `$env:RUN_ERROR '--' -p test; exit `$LASTEXITCODE"
        $resCmd = Invoke-LauncherCommand -CommandExpression $expr -Environment $cmdEnv

        Assert-Equal $resCmd.ExitCode 2 "command-expression null quality-retry target rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $cmdArgs) "command-expression null quality-retry: worker not launched"
    }

    # =======================================================================
    # 7. Fixture Policy Validation: Missing, Malformed, and Invalid Policies
    # =======================================================================

    # 7.1 Missing model-policy.json in fixture directory
    & {
        $fixtureLauncher = New-PolicyFixture -FixtureName 'missing-policy'
        $argsCapture = Join-Path $TmpRoot "args-fixture-missing.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot "out-fixture-missing.json"),
            '--error', (Join-Path $TmpRoot "err-fixture-missing.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "missing model-policy.json rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "missing model-policy.json: worker not launched"
        Assert-True ($res.Stderr -match '(?i)policy') "missing model-policy.json: actionable stderr"
    }

    # 7.2 Malformed model-policy.json (invalid JSON syntax)
    & {
        $fixtureLauncher = New-PolicyFixture -FixtureName 'malformed-policy' -PolicyJsonContent '{ "schema_version": 1, invalid json'
        $argsCapture = Join-Path $TmpRoot "args-fixture-malformed.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot "out-fixture-malformed.json"),
            '--error', (Join-Path $TmpRoot "err-fixture-malformed.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "malformed model-policy.json rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "malformed model-policy.json: worker not launched"
        Assert-True ($res.Stderr -match '(?i)policy|json') "malformed model-policy.json: actionable stderr"
    }

    # 7.3 Unsupported schema_version (e.g. 2)
    & {
        $badSchema = (Get-BaselinePolicyJson) -replace '"schema_version": 1', '"schema_version": 2'
        $fixtureLauncher = New-PolicyFixture -FixtureName 'bad-schema' -PolicyJsonContent $badSchema
        $argsCapture = Join-Path $TmpRoot "args-fixture-bad-schema.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot "out-fixture-bad-schema.json"),
            '--error', (Join-Path $TmpRoot "err-fixture-bad-schema.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "unsupported schema_version (2) rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "unsupported schema_version: worker not launched"
    }

    # 7.4 Empty policy_revision
    & {
        $badRev = (Get-BaselinePolicyJson) -replace '"policy_revision": "2026-09-03.1"', '"policy_revision": ""'
        $fixtureLauncher = New-PolicyFixture -FixtureName 'empty-rev' -PolicyJsonContent $badRev
        $argsCapture = Join-Path $TmpRoot "args-fixture-empty-rev.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot "out-fixture-empty-rev.json"),
            '--error', (Join-Path $TmpRoot "err-fixture-empty-rev.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "empty policy_revision rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "empty policy_revision: worker not launched"
    }

    # 7.5 Unsupported max_effort (not 'high')
    & {
        $badEffort = (Get-BaselinePolicyJson) -replace '"max_effort": "high"', '"max_effort": "ultra"'
        $fixtureLauncher = New-PolicyFixture -FixtureName 'bad-effort' -PolicyJsonContent $badEffort
        $argsCapture = Join-Path $TmpRoot "args-fixture-bad-effort.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot "out-fixture-bad-effort.json"),
            '--error', (Join-Path $TmpRoot "err-fixture-bad-effort.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "unsupported max_effort rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "unsupported max_effort: worker not launched"
    }

    # 7.6 Unsupported max_retries_per_worker (not 1)
    & {
        $badRetries = (Get-BaselinePolicyJson) -replace '"max_retries_per_worker": 1', '"max_retries_per_worker": 2'
        $fixtureLauncher = New-PolicyFixture -FixtureName 'bad-retries' -PolicyJsonContent $badRetries
        $argsCapture = Join-Path $TmpRoot "args-fixture-bad-retries.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot "out-fixture-bad-retries.json"),
            '--error', (Join-Path $TmpRoot "err-fixture-bad-retries.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "unsupported max_retries_per_worker rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "unsupported max_retries_per_worker: worker not launched"
    }

    # 7.7 Unsupported quota_action (not 'handoff')
    & {
        $badQuota = (Get-BaselinePolicyJson) -replace '"quota_action": "handoff"', '"quota_action": "retry"'
        $fixtureLauncher = New-PolicyFixture -FixtureName 'bad-quota' -PolicyJsonContent $badQuota
        $argsCapture = Join-Path $TmpRoot "args-fixture-bad-quota.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot "out-fixture-bad-quota.json"),
            '--error', (Join-Path $TmpRoot "err-fixture-bad-quota.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "unsupported quota_action rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "unsupported quota_action: worker not launched"
    }

    # 7.8 Missing required role in roles map (missing 'auditor')
    & {
        $parsed = ConvertFrom-Json (Get-BaselinePolicyJson)
        $parsed.roles.PSObject.Properties.Remove('auditor')
        $missingRoleJson = ConvertTo-Json -InputObject $parsed -Depth 10
        $fixtureLauncher = New-PolicyFixture -FixtureName 'missing-role-policy' -PolicyJsonContent $missingRoleJson
        $argsCapture = Join-Path $TmpRoot "args-fixture-missing-role.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot "out-fixture-missing-role.json"),
            '--error', (Join-Path $TmpRoot "err-fixture-missing-role.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "policy with missing role rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "policy with missing role: worker not launched"
    }

    # 7.9 Non-Gemini model ID in a role
    & {
        $badModel = (Get-BaselinePolicyJson) -replace '"gemini-3.8-flash-low"', '"claude-3-5-sonnet-low"'
        $fixtureLauncher = New-PolicyFixture -FixtureName 'non-gemini' -PolicyJsonContent $badModel
        $argsCapture = Join-Path $TmpRoot "args-fixture-non-gemini.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot "out-fixture-non-gemini.json"),
            '--error', (Join-Path $TmpRoot "err-fixture-non-gemini.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "non-Gemini model ID rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "non-Gemini model ID: worker not launched"
    }

    # 7.10 Invalid effort suffix in default_model (missing suffix or invalid suffix)
    & {
        $badSuffix = (Get-BaselinePolicyJson) -replace '"gemini-3.8-flash-low"', '"gemini-3.8-flash-turbo"'
        $fixtureLauncher = New-PolicyFixture -FixtureName 'bad-suffix' -PolicyJsonContent $badSuffix
        $argsCapture = Join-Path $TmpRoot "args-fixture-bad-suffix.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot "out-fixture-bad-suffix.json"),
            '--error', (Join-Path $TmpRoot "err-fixture-bad-suffix.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "model ID with invalid effort suffix rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "invalid effort suffix: worker not launched"
    }

    # 7.11 Escalation entry with missing evidence file
    & {
        $escalationJson = @'
{
  "schema_version": 1,
  "policy_revision": "2026-09-03.1",
  "max_effort": "high",
  "max_retries_per_worker": 1,
  "quota_action": "handoff",
  "roles": {
    "scout": { "default_model": "gemini-3.8-flash-low", "quality_escalation": null },
    "gate-author": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "implementer": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": {
        "model": "gemini-3.8-pro-high",
        "evidence_path": "docs/research/nonexistent-evidence.md"
      }
    },
    "reviewer": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "researcher": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "synthesizer": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "auditor": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null }
  }
}
'@
        $fixtureLauncher = New-PolicyFixture -FixtureName 'missing-evidence' -PolicyJsonContent $escalationJson
        $argsCapture = Join-Path $TmpRoot "args-fixture-missing-evidence.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'implementer',
            '--output', (Join-Path $TmpRoot "out-fixture-missing-evidence.json"),
            '--error', (Join-Path $TmpRoot "err-fixture-missing-evidence.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "escalation with nonexistent evidence file rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "missing evidence file: worker not launched"
    }

    # 7.12 Escalation entry with escaping evidence path
    & {
        $escapingJson = @'
{
  "schema_version": 1,
  "policy_revision": "2026-09-03.1",
  "max_effort": "high",
  "max_retries_per_worker": 1,
  "quota_action": "handoff",
  "roles": {
    "scout": { "default_model": "gemini-3.8-flash-low", "quality_escalation": null },
    "gate-author": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "implementer": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": {
        "model": "gemini-3.8-pro-high",
        "evidence_path": "../outside.md"
      }
    },
    "reviewer": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "researcher": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "synthesizer": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "auditor": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null }
  }
}
'@
        $fixtureLauncher = New-PolicyFixture -FixtureName 'escaping-evidence' -PolicyJsonContent $escapingJson
        $argsCapture = Join-Path $TmpRoot "args-fixture-escaping-evidence.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'implementer',
            '--output', (Join-Path $TmpRoot "out-fixture-escaping-evidence.json"),
            '--error', (Join-Path $TmpRoot "err-fixture-escaping-evidence.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "escalation with escaping evidence path rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "escaping evidence path: worker not launched"
    }

    # 7.13 Escalation entry where escalation model is identical to default model
    & {
        $identicalJson = @'
{
  "schema_version": 1,
  "policy_revision": "2026-09-03.1",
  "max_effort": "high",
  "max_retries_per_worker": 1,
  "quota_action": "handoff",
  "roles": {
    "scout": { "default_model": "gemini-3.8-flash-low", "quality_escalation": null },
    "gate-author": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "implementer": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": {
        "model": "gemini-3.8-flash-high",
        "evidence_path": "docs/research/evidence.md"
      }
    },
    "reviewer": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "researcher": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "synthesizer": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "auditor": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null }
  }
}
'@
        $fixtureLauncher = New-PolicyFixture -FixtureName 'identical-escalation' `
            -PolicyJsonContent $identicalJson `
            -AdditionalFiles @{ 'docs/research/evidence.md' = '# Evaluation evidence' }
        $argsCapture = Join-Path $TmpRoot "args-fixture-identical.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'implementer',
            '--output', (Join-Path $TmpRoot "out-fixture-identical.json"),
            '--error', (Join-Path $TmpRoot "err-fixture-identical.err"),
            '--',
            '-p', 'test'
        ) -Environment $env

        Assert-Equal $res.ExitCode 2 "escalation model identical to default model rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsCapture) "identical escalation model: worker not launched"
    }

    # =======================================================================
    # 8. Fixture Policy with a Valid Evidence-Backed Escalation Target
    # =======================================================================
    & {
        $validEscalationJson = @'
{
  "schema_version": 1,
  "policy_revision": "2026-09-03.1",
  "max_effort": "high",
  "max_retries_per_worker": 1,
  "quota_action": "handoff",
  "roles": {
    "scout": { "default_model": "gemini-3.8-flash-low", "quality_escalation": null },
    "gate-author": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "implementer": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": {
        "model": "gemini-3.8-pro-high",
        "evidence_path": "docs/research/implementer-evaluation.md"
      }
    },
    "reviewer": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "researcher": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "synthesizer": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null },
    "auditor": { "default_model": "gemini-3.8-flash-high", "quality_escalation": null }
  }
}
'@
        $fixtureLauncher = New-PolicyFixture -FixtureName 'valid-escalation' `
            -PolicyJsonContent $validEscalationJson `
            -AdditionalFiles @{
                'docs/research/implementer-evaluation.md' = "# Implementer Pro Evaluation`n`nBaseline: gemini-3.8-flash-high`nCandidate: gemini-3.8-pro-high`nDecision: Approved for escalation retry."
            }

        # 8.1 Quality-retry route dispatches the escalation model
        $argsCapture = Join-Path $TmpRoot "args-valid-escalation-retry.json"
        $env = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsCapture }
        $res = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'implementer',
            '--route', 'quality-retry',
            '--output', (Join-Path $TmpRoot "out-valid-escalation.json"),
            '--error', (Join-Path $TmpRoot "err-valid-escalation.err"),
            '--',
            '-p', 'retry with escalated model'
        ) -Environment $env

        Assert-Equal $res.ExitCode 0 "valid evidence-backed escalation route quality-retry: exits 0"
        Assert-True (Test-Path -LiteralPath $argsCapture) "valid escalation: worker launched"
        $captured = @(Get-Content -LiteralPath $argsCapture -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
        Assert-ForwardedModelAndArgs $captured 'gemini-3.8-pro-high' @('-p', 'retry with escalated model') "valid escalation quality-retry route"

        # 8.2 Default route on the same fixture resolves the default model
        $argsDefault = Join-Path $TmpRoot "args-valid-escalation-default.json"
        $envDefault = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsDefault }
        $resDefault = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'implementer',
            '--route', 'default',
            '--output', (Join-Path $TmpRoot "out-valid-default.json"),
            '--error', (Join-Path $TmpRoot "err-valid-default.err"),
            '--',
            '-p', 'standard route with same policy'
        ) -Environment $envDefault

        Assert-Equal $resDefault.ExitCode 0 "valid evidence policy on default route: exits 0"
        Assert-True (Test-Path -LiteralPath $argsDefault) "valid evidence default route: worker launched"
        $capturedDefault = @(Get-Content -LiteralPath $argsDefault -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
        Assert-ForwardedModelAndArgs $capturedDefault 'gemini-3.8-flash-high' @('-p', 'standard route with same policy') "valid evidence policy default route"

        # 8.3 Quality-retry on a role in the same fixture whose escalation is null fails
        $argsScoutRetry = Join-Path $TmpRoot "args-valid-fixture-scout-retry.json"
        $envScoutRetry = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsScoutRetry }
        $resScoutRetry = Invoke-Launcher -LauncherPath $fixtureLauncher -ArgumentList @(
            '--role', 'scout',
            '--route', 'quality-retry',
            '--output', (Join-Path $TmpRoot "out-scout-retry.json"),
            '--error', (Join-Path $TmpRoot "err-scout-retry.err"),
            '--',
            '-p', 'test'
        ) -Environment $envScoutRetry

        Assert-Equal $resScoutRetry.ExitCode 2 "null escalation role in mixed policy rejected: exit code 2"
        Assert-False (Test-Path -LiteralPath $argsScoutRetry) "null escalation role: worker not launched"
    }

    # =======================================================================
    # 9. Preserved Launcher Contracts
    # =======================================================================

    # 9.1 Output capture separation
    & {
        $runOut = Join-Path $TmpRoot 'contract-run.json'
        $runErr = Join-Path $TmpRoot 'contract-run.err'
        $argsCapture = Join-Path $TmpRoot 'contract-run.args'
        $env = @{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $argsCapture
        }
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', $runOut,
            '--error', $runErr,
            '--',
            '-p', 'output capture test',
            '--output-format', 'json'
        ) -Environment $env

        Assert-Equal $res.ExitCode 0 "contract: exits 0 on worker success"
        Assert-True (Test-Path -LiteralPath $runOut) "contract: output file created"
        Assert-True (Test-Path -LiteralPath $runErr) "contract: error file created"
        $outData = Get-Content -LiteralPath $runOut -Raw | ConvertFrom-Json
        Assert-True ($outData.structured_output.ok -eq $true) "contract: output captured worker stdout JSON"
        $errData = (Get-Content -LiteralPath $runErr -Raw).Trim()
        Assert-Equal $errData 'fake stderr' "contract: error file captured worker stderr"
        Assert-Equal $res.Stdout.Trim() "" "contract: launcher leaks no worker stdout to its stdout"
    }

    # 9.2 Parent directory creation
    & {
        $nestedOut = Join-Path $TmpRoot 'nested/sub1/deep/run.json'
        $nestedErr = Join-Path $TmpRoot 'nested/sub2/deep/run.err'
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'gate-author',
            '--output', $nestedOut,
            '--error', $nestedErr,
            '--',
            '-p', 'parent dir test'
        ) -Environment (@{ 'AGY_BIN' = $fakeAgyPs })

        Assert-Equal $res.ExitCode 0 "contract: parent directory creation exits 0"
        Assert-True (Test-Path -LiteralPath $nestedOut) "contract: created deep nested output file"
        Assert-True (Test-Path -LiteralPath $nestedErr) "contract: created deep nested error file"
    }

    # 9.3 Worker exit code propagation (exit code 42 via -File)
    & {
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'implementer',
            '--output', (Join-Path $TmpRoot 'exit42.json'),
            '--error', (Join-Path $TmpRoot 'exit42.err'),
            '--',
            '-p', 'fail test'
        ) -Environment (@{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_EXIT' = '42'
        })

        Assert-Equal $res.ExitCode 42 "contract: propagates worker exit code 42"
    }

    # 9.4 Worker exit code propagation in command-expression (exit code 37)
    & {
        $cmdEnv = @{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_EXIT' = '37'
            'RUN_AGY_JSON'  = $ProdLauncher
            'RUN_OUTPUT'    = (Join-Path $cmdDir 'exit37-out.json')
            'RUN_ERROR'     = (Join-Path $cmdDir 'exit37-err.log')
        }
        $expr = "& `$env:RUN_AGY_JSON --role reviewer --output `$env:RUN_OUTPUT --error `$env:RUN_ERROR '--' -p fail; exit `$LASTEXITCODE"
        $resCmd = Invoke-LauncherCommand -CommandExpression $expr -Environment $cmdEnv

        Assert-Equal $resCmd.ExitCode 37 "contract: command-expression propagates worker exit code 37"
    }

    # 9.5 Bare delimiter rejection in command-expression
    & {
        $bareArgs = Join-Path $cmdDir 'bare-delimiter-args.json'
        $bareEnv = @{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $bareArgs
            'RUN_AGY_JSON'  = $ProdLauncher
            'RUN_OUTPUT'    = (Join-Path $cmdDir 'bare-delimiter-out.json')
            'RUN_ERROR'     = (Join-Path $cmdDir 'bare-delimiter-err.log')
        }
        $expr = "& `$env:RUN_AGY_JSON --role scout --output `$env:RUN_OUTPUT --error `$env:RUN_ERROR -- -p test; exit `$LASTEXITCODE"
        $resBare = Invoke-LauncherCommand -CommandExpression $expr -Environment $bareEnv

        Assert-True ($resBare.ExitCode -ne 0) "contract: command-expression rejects bare delimiter"
        Assert-False (Test-Path -LiteralPath $bareArgs) "contract: bare delimiter does not launch worker"
    }

    # 9.6 Omitted delimiter rejection in command-expression
    & {
        $omittedArgs = Join-Path $cmdDir 'omitted-delimiter-args.json'
        $omittedEnv = @{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $omittedArgs
            'RUN_AGY_JSON'  = $ProdLauncher
            'RUN_OUTPUT'    = (Join-Path $cmdDir 'omitted-delimiter-out.json')
            'RUN_ERROR'     = (Join-Path $cmdDir 'omitted-delimiter-err.log')
        }
        $expr = "& `$env:RUN_AGY_JSON --role scout --output `$env:RUN_OUTPUT --error `$env:RUN_ERROR -p test; exit `$LASTEXITCODE"
        $resOmitted = Invoke-LauncherCommand -CommandExpression $expr -Environment $omittedEnv

        Assert-True ($resOmitted.ExitCode -ne 0) "contract: command-expression rejects omitted delimiter"
        Assert-False (Test-Path -LiteralPath $omittedArgs) "contract: omitted delimiter does not launch worker"
    }

    # 9.7 Missing delimiter in -File invocation
    & {
        $missingDelimArgs = Join-Path $TmpRoot 'missing-delim-args.json'
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot 'missing-delim-out.json'),
            '--error', (Join-Path $TmpRoot 'missing-delim-err.log'),
            '-p', 'test'
        ) -Environment (@{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $missingDelimArgs })

        Assert-True ($res.ExitCode -ne 0) "contract: -File invocation rejects missing delimiter"
        Assert-False (Test-Path -LiteralPath $missingDelimArgs) "contract: missing delimiter does not launch worker"
    }

    # 9.8 Rejection of caller --output in worker arguments
    & {
        $resRejOut1 = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot 'rej-out1.json'),
            '--error', (Join-Path $TmpRoot 'rej-out1.err'),
            '--',
            '--output', 'worker-output.json'
        ) -Environment (@{ 'AGY_BIN' = $fakeAgyPs })

        Assert-True ($resRejOut1.ExitCode -ne 0) "contract: rejects forwarded --output"
    }

    # 9.9 Rejection of caller --output=value in worker arguments
    & {
        $resRejOut2 = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot 'rej-out2.json'),
            '--error', (Join-Path $TmpRoot 'rej-out2.err'),
            '--',
            '--output=worker-output.json'
        ) -Environment (@{ 'AGY_BIN' = $fakeAgyPs })

        Assert-True ($resRejOut2.ExitCode -ne 0) "contract: rejects forwarded --output=value"
    }

    # 9.10 AGY_BIN precedence over PATH
    & {
        $customBin = Join-Path $TmpRoot 'custom-bin'
        [System.IO.Directory]::CreateDirectory($customBin) | Out-Null
        $customAgyPs = Join-Path $customBin 'custom_agy.ps1'
        @'
if ($env:FAKE_AGY_ARGS) {
    [System.IO.File]::WriteAllText($env:FAKE_AGY_ARGS, '["from_custom"]', [System.Text.Encoding]::UTF8)
}
[Console]::Error.WriteLine("custom stderr")
[Console]::Out.WriteLine('{"status":"success","response":"custom","structured_output":{"from_custom":true}}')
exit 0
'@ | Set-Content -LiteralPath $customAgyPs -Encoding utf8

        $customArgs = Join-Path $TmpRoot 'custom-args.json'
        $customOut = Join-Path $TmpRoot 'custom-out.json'
        $resCustom = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', $customOut,
            '--error', (Join-Path $TmpRoot 'custom-err.err'),
            '--',
            '-p', 'custom agy test'
        ) -Environment (@{
            'AGY_BIN'       = $customAgyPs
            'FAKE_AGY_ARGS' = $customArgs
            'PATH'          = $basePath
        })

        Assert-Equal $resCustom.ExitCode 0 "contract: custom AGY_BIN exits 0"
        $customData = Get-Content -LiteralPath $customOut -Raw | ConvertFrom-Json
        Assert-True ($customData.structured_output.from_custom -eq $true) "contract: AGY_BIN takes precedence over PATH discovery"
    }

    # 9.11 Explicit AGY_BIN invalid failure without fallback
    & {
        $invalidOut = Join-Path $TmpRoot 'invalid-bin-out.json'
        $resInvalid = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', $invalidOut,
            '--error', (Join-Path $TmpRoot 'invalid-bin-err.err'),
            '--',
            '-p', 'invalid bin test'
        ) -Environment (@{
            'AGY_BIN' = (Join-Path $TmpRoot 'nonexistent-bin/agy.exe')
            'PATH'    = $basePath
        })

        Assert-True ($resInvalid.ExitCode -ne 0) "contract: invalid explicit AGY_BIN fails"
        Assert-False (Test-Path -LiteralPath $invalidOut) "contract: invalid explicit AGY_BIN does not run fallback worker"
    }

    # -----------------------------------------------------------------------
    # 10. Output Destination Validation, Stream Disposal, and Cleanup Contracts (Issue #11)
    # -----------------------------------------------------------------------

    # 10.1 Identical output and error paths fail before worker starts
    & {
        $samePath = Join-Path $TmpRoot 'identical-out-err.json'
        $argsFile = Join-Path $TmpRoot 'identical-out-err-args.json'
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', $samePath,
            '--error', $samePath,
            '--',
            '-p', 'identical path test'
        ) -Environment (@{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $argsFile
        })

        Assert-True ($res.ExitCode -ne 0) "contract: identical output/error paths fail"
        Assert-False (Test-Path -LiteralPath $argsFile) "contract: worker not launched on identical output/error paths"
        Assert-True ($res.Stderr.Contains('must not be identical')) "contract: actionable error for identical output/error paths"
    }

    # 10.2 Case-variant identical output and error paths fail before worker starts
    & {
        $path1 = Join-Path $TmpRoot 'identical-case-test.json'
        $path2 = Join-Path $TmpRoot 'IDENTICAL-CASE-TEST.JSON'
        $argsFile = Join-Path $TmpRoot 'identical-case-args.json'
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', $path1,
            '--error', $path2,
            '--',
            '-p', 'identical case test'
        ) -Environment (@{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $argsFile
        })

        Assert-True ($res.ExitCode -ne 0) "contract: case-variant identical paths fail"
        Assert-False (Test-Path -LiteralPath $argsFile) "contract: worker not launched on case-variant identical paths"
    }

    # 10.3 Locked output destination fails before worker starts
    & {
        $lockedOut = Join-Path $TmpRoot 'locked-out.json'
        $lockedStream = [System.IO.File]::Open($lockedOut, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $argsFile = Join-Path $TmpRoot 'locked-out-args.json'
        try {
            $res = Invoke-Launcher -ArgumentList @(
                '--role', 'scout',
                '--output', $lockedOut,
                '--error', (Join-Path $TmpRoot 'locked-out-err.err'),
                '--',
                '-p', 'locked out test'
            ) -Environment (@{
                'AGY_BIN'       = $fakeAgyPs
                'FAKE_AGY_ARGS' = $argsFile
            })

            Assert-True ($res.ExitCode -ne 0) "contract: locked output destination fails"
            Assert-False (Test-Path -LiteralPath $argsFile) "contract: worker not launched on locked output destination"
        } finally {
            $lockedStream.Dispose()
        }
    }

    # 10.4 Locked error destination fails before worker starts and disposes output stream
    & {
        $lockedErr = Join-Path $TmpRoot 'locked-err.err'
        $lockedErrStream = [System.IO.File]::Open($lockedErr, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $unlockedOut = Join-Path $TmpRoot 'unlocked-out-for-locked-err.json'
        $argsFile = Join-Path $TmpRoot 'locked-err-args.json'
        try {
            $res = Invoke-Launcher -ArgumentList @(
                '--role', 'scout',
                '--output', $unlockedOut,
                '--error', $lockedErr,
                '--',
                '-p', 'locked err test'
            ) -Environment (@{
                'AGY_BIN'       = $fakeAgyPs
                'FAKE_AGY_ARGS' = $argsFile
            })

            Assert-True ($res.ExitCode -ne 0) "contract: locked error destination fails"
            Assert-False (Test-Path -LiteralPath $argsFile) "contract: worker not launched on locked error destination"
        } finally {
            $lockedErrStream.Dispose()
        }

        # Verify output file was cleanly disposed and can be reopened exclusively
        $reopenedOut = [System.IO.File]::Open($unlockedOut, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $reopenedOut.Dispose()
        Assert-True ($true) "contract: output stream was disposed when error stream failed"
    }

    # 10.5 Existing directory as output destination fails before worker starts
    & {
        $dirOut = Join-Path $TmpRoot 'dir-destination-test'
        [System.IO.Directory]::CreateDirectory($dirOut) | Out-Null
        $argsFile = Join-Path $TmpRoot 'dir-out-args.json'
        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', $dirOut,
            '--error', (Join-Path $TmpRoot 'dir-destination-err.err'),
            '--',
            '-p', 'dir dest test'
        ) -Environment (@{
            'AGY_BIN'       = $fakeAgyPs
            'FAKE_AGY_ARGS' = $argsFile
        })

        Assert-True ($res.ExitCode -ne 0) "contract: existing directory output destination fails"
        Assert-False (Test-Path -LiteralPath $argsFile) "contract: worker not launched on directory output destination"
    }

    # 10.6 Controlled post-start failure terminates child process and disposes streams
    & {
        $startedMarker = Join-Path $TmpRoot 'post-fail-started.txt'
        $completedMarker = Join-Path $TmpRoot 'post-fail-completed.txt'
        $postOut = Join-Path $TmpRoot 'post-fail-out.json'
        $postErr = Join-Path $TmpRoot 'post-fail-err.err'

        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', $postOut,
            '--error', $postErr,
            '--',
            '-p', 'post-start failure test'
        ) -Environment (@{
            'AGY_BIN'                       = $fakeAgyPs
            'FAKE_LAUNCHER_FAIL_POST_START' = '1'
            'FAKE_AGY_STARTED_MARKER'       = $startedMarker
            'FAKE_AGY_DELAY_MS'             = '2000'
            'FAKE_AGY_COMPLETED_MARKER'     = $completedMarker
        })

        Assert-True ($res.ExitCode -ne 0) "contract: launcher exits nonzero on post-start failure"
        Assert-True (Test-Path -LiteralPath $startedMarker) "contract: worker was launched before failure"
        Assert-False (Test-Path -LiteralPath $completedMarker) "contract: worker was stopped before launcher returned"

        # Wait longer than the worker delay to ensure child was terminated and not running asynchronously
        Start-Sleep -Milliseconds 2200
        Assert-False (Test-Path -LiteralPath $completedMarker) "contract: worker did not complete asynchronously after launcher returned"

        # Verify output and error streams were disposed and can be opened exclusively
        $reopenedOut = [System.IO.File]::Open($postOut, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $reopenedOut.Dispose()
        $reopenedErr = [System.IO.File]::Open($postErr, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $reopenedErr.Dispose()
        Assert-True ($true) "contract: output and error streams disposed on post-launch failure"
    }

    # 10.7 Successful launch disposes streams so output and error files can be reopened
    & {
        $succOut = Join-Path $TmpRoot 'succ-cleanup-out.json'
        $succErr = Join-Path $TmpRoot 'succ-cleanup-err.err'

        $res = Invoke-Launcher -ArgumentList @(
            '--role', 'scout',
            '--output', $succOut,
            '--error', $succErr,
            '--',
            '-p', 'succ cleanup test'
        ) -Environment (@{
            'AGY_BIN' = $fakeAgyPs
        })

        Assert-Equal $res.ExitCode 0 "contract: successful launch exits 0"
        $reopenedSuccOut = [System.IO.File]::Open($succOut, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $reopenedSuccOut.Dispose()
        $reopenedSuccErr = [System.IO.File]::Open($succErr, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $reopenedSuccErr.Dispose()
        Assert-True ($true) "contract: output and error streams disposed on success"
    }

    # -----------------------------------------------------------------------
    # All Checks Completed
    # -----------------------------------------------------------------------
    [Console]::Out.WriteLine("all model routing checks passed ($script:TotalTests tests)")
    exit 0
}
finally {
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
