#!/usr/bin/env pwsh
# tests/test_verification_hardening_launcher.ps1
# Acceptance gate for offload launcher working directory and provider resolution.
# Implements contracts specified in spec.md (Functional requirement 1: PowerShell child working directory).
# Strict constraints: Standalone PowerShell 7 / .NET only, no Pester, Python, jq, or live Gemini calls.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

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
    if ($env:OFFLOAD_CONTINUE_ON_FAIL -ne '1') {
        exit 1
    }
}

function Assert-True([bool]$condition, [string]$name, [string]$reason = "") {
    if ($condition) {
        Pass $name
    } else {
        $failureReason = if ($reason) { $reason } else { "Condition was false" }
        Fail $name $failureReason
    }
}

function Assert-False([bool]$condition, [string]$name, [string]$reason = "") {
    if (-not $condition) {
        Pass $name
    } else {
        $failureReason = if ($reason) { $reason } else { "Condition was true" }
        Fail $name $failureReason
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

function Normalize-Path([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return "" }
    $full = [System.IO.Path]::GetFullPath($path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if ($IsWindows) {
        return $full.ToLowerInvariant()
    }
    return $full
}

# ---------------------------------------------------------------------------
# Process Execution Helpers
# ---------------------------------------------------------------------------

$PwshBin = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $PwshBin) {
    $PwshBin = (Get-Process -Id $PID).Path
}

$RootDir = Split-Path -Parent $PSScriptRoot
$ScriptsDir = Join-Path $RootDir 'scripts'
$ProdLauncher = Join-Path $ScriptsDir 'run-agy-json.ps1'
$ShLauncher = Join-Path $ScriptsDir 'run-agy-json.sh'

if (-not (Test-Path -LiteralPath $ProdLauncher -PathType Leaf)) {
    Fail "Launcher existence check" "run-agy-json.ps1 not found at '$ProdLauncher'"
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

function Invoke-LauncherCommand {
    param(
        [Parameter(Mandatory=$true)][string]$CommandExpression,
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = $null
    )
    $pwshArgs = @('-NoProfile', '-NonInteractive', '-Command', $CommandExpression)
    return Invoke-ToolProcess -FilePath $PwshBin -ArgumentList $pwshArgs -Environment $Environment -WorkingDirectory $WorkingDirectory
}

function Invoke-LauncherInSession {
    param(
        [Parameter(Mandatory=$true)][string]$SessionLocation,
        [string[]]$LauncherArgs = @(),
        [hashtable]$Environment = @{},
        [string]$ProcessWorkingDir = $null,
        [string]$PreSetupCode = "",
        [string]$PreInvocationCode = ""
    )
    $escapedLocation = $SessionLocation.Replace("'", "''")
    $escapedLauncher = $ProdLauncher.Replace("'", "''")

    $argParts = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $LauncherArgs) {
        $escapedA = $a.Replace("'", "''")
        $argParts.Add("'$escapedA'")
    }
    $joinedArgs = $argParts -join ' '

    $scriptBlock = @"
$PreSetupCode
Set-Location -LiteralPath '$escapedLocation'
$PreInvocationCode
& '$escapedLauncher' $joinedArgs
exit `$LASTEXITCODE
"@
    return Invoke-LauncherCommand -CommandExpression $scriptBlock -Environment $Environment -WorkingDirectory $ProcessWorkingDir
}

# ---------------------------------------------------------------------------
# Test Environment and Fake AGY Harness
# ---------------------------------------------------------------------------

$TmpRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "offload-launcher-gate-$([System.Guid]::NewGuid().ToString('N'))")
[System.IO.Directory]::CreateDirectory($TmpRoot) | Out-Null

try {
    $fakeBin = Join-Path $TmpRoot 'bin'
    [System.IO.Directory]::CreateDirectory($fakeBin) | Out-Null

    $fakeAgyPs = Join-Path $fakeBin 'fake_agy.ps1'
    @'
$observedCwd = [System.IO.Directory]::GetCurrentDirectory()

if ($env:FAKE_AGY_RECORD_CWD) {
    [System.IO.File]::WriteAllText($env:FAKE_AGY_RECORD_CWD, $observedCwd, [System.Text.Encoding]::UTF8)
}

if ($env:FAKE_AGY_STARTED_MARKER) {
    [System.IO.File]::WriteAllText($env:FAKE_AGY_STARTED_MARKER, "started in $observedCwd", [System.Text.Encoding]::UTF8)
}

if ($env:FAKE_AGY_WRITE_RELATIVE) {
    [System.IO.File]::WriteAllText($env:FAKE_AGY_WRITE_RELATIVE, "created in $observedCwd", [System.Text.Encoding]::UTF8)
}

if ($env:FAKE_AGY_ARGS) {
    $capturedArgs = @($args | ForEach-Object { [string]$_ })
    [System.IO.File]::WriteAllText(
        $env:FAKE_AGY_ARGS,
        (ConvertTo-Json -InputObject $capturedArgs -Compress),
        [System.Text.Encoding]::UTF8
    )
}

if ($env:FAKE_AGY_EXIT) {
    [Console]::Error.WriteLine("fake worker error output")
    exit [int]$env:FAKE_AGY_EXIT
}

[Console]::Error.WriteLine("fake worker stderr")
$outputObj = [ordered]@{
    status = 'success'
    response = "fake worker response in $observedCwd"
    structured_output = [ordered]@{
        ok = $true
        observed_cwd = $observedCwd
    }
}
[Console]::Out.WriteLine(($outputObj | ConvertTo-Json -Compress))
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

    $fakeAdapter = Join-Path $RootDir 'tests/fixtures/fake-worker-adapter.ps1'
    $fakeCatalog = Join-Path $TmpRoot 'fake-adapter-catalog.json'
    @'
{
  "protocol_version": 2,
  "adapter": "fake",
  "adapter_revision": "fake-adapter-2",
  "vendor": "fake-vendor",
  "catalog_revision": "test-catalog-1",
  "models": [
    { "id": "scout-model", "family_hint": "fast", "available": true, "quota_available": true, "supported_efforts": ["low"], "capabilities": [], "scores": { "fast": 0 }, "preflight": { "access": { "state": "verified", "account_ref": "test-account" }, "entitlement": { "state": "active", "billing_route": "test-subscription" }, "usage": { "state": "known", "source": "test", "observed_at": "2026-09-05T00:00:00Z", "scopes": [{ "scope_id": "test-window", "remaining_units": 20, "reserved_units": 0 }] } } },
    { "id": "worker-model", "family_hint": "balanced", "available": true, "quota_available": true, "supported_efforts": ["high"], "capabilities": [], "scores": { "balanced": 0, "deep": 1 }, "preflight": { "access": { "state": "verified", "account_ref": "test-account" }, "entitlement": { "state": "active", "billing_route": "test-subscription" }, "usage": { "state": "known", "source": "test", "observed_at": "2026-09-05T00:00:00Z", "scopes": [{ "scope_id": "test-window", "remaining_units": 20, "reserved_units": 0 }] } } }
  ]
}
'@ | Set-Content -LiteralPath $fakeCatalog -Encoding utf8
    $catalogText = [System.IO.File]::ReadAllText($fakeCatalog).Replace('2026-09-05T00:00:00Z', [DateTime]::UtcNow.ToString('o'))
    [System.IO.File]::WriteAllText($fakeCatalog, $catalogText, [System.Text.Encoding]::UTF8)
    $savedAdapterBin = $env:OFFLOAD_ADAPTER_BIN
    $savedAdapterCatalog = $env:FAKE_ADAPTER_CATALOG
    $savedAgyBin = $env:AGY_BIN
    $env:OFFLOAD_ADAPTER_BIN = $fakeAdapter
    $env:FAKE_ADAPTER_CATALOG = $fakeCatalog
    $env:AGY_BIN = $fakeAgyPs

    # =======================================================================
    # 1. Existing Launcher Contracts (Regression Suite)
    #    Assert adapter-selected model forwarding, delimiter, output/error paths, exit code,
    #    caller flag rejection, and no caller-facing --cwd option.
    # =======================================================================

    # 1.1 Adapter selection for scout and implementer
    & {
        $argsScout = Join-Path $TmpRoot 'scout-args.json'
        $envScout = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsScout }
        $resScout = Invoke-ToolProcess -FilePath $PwshBin -ArgumentList @(
            '-NoProfile', '-File', $ProdLauncher,
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot 'scout-out.json'),
            '--error', (Join-Path $TmpRoot 'scout-err.err'),
            '--',
            '-p', 'test prompt scout'
        ) -Environment $envScout
        Assert-Equal $resScout.ExitCode 0 "regression: role 'scout' exits 0"
        $scoutCaptured = @(Get-Content -LiteralPath $argsScout -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
        Assert-True ($scoutCaptured -contains '--model' -and $scoutCaptured -contains 'scout-model' -and $scoutCaptured -contains '--effort' -and $scoutCaptured -contains 'low') "regression: scout forwards adapter-selected model and policy effort"

        $argsImpl = Join-Path $TmpRoot 'impl-args.json'
        $envImpl = @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_ARGS' = $argsImpl }
        $resImpl = Invoke-ToolProcess -FilePath $PwshBin -ArgumentList @(
            '-NoProfile', '-File', $ProdLauncher,
            '--role', 'implementer',
            '--output', (Join-Path $TmpRoot 'impl-out.json'),
            '--error', (Join-Path $TmpRoot 'impl-err.err'),
            '--',
            '-p', 'test prompt implementer'
        ) -Environment $envImpl
        Assert-Equal $resImpl.ExitCode 0 "regression: role 'implementer' exits 0"
        $implCaptured = @(Get-Content -LiteralPath $argsImpl -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
        Assert-True ($implCaptured -contains '--model' -and $implCaptured -contains 'worker-model' -and $implCaptured -contains '--effort' -and $implCaptured -contains 'high') "regression: implementer forwards adapter-selected model and policy effort"
    }

    # 1.2 Delimiter enforcement
    & {
        $resNoDelim = Invoke-ToolProcess -FilePath $PwshBin -ArgumentList @(
            '-NoProfile', '-File', $ProdLauncher,
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot 'nodelim.json'),
            '--error', (Join-Path $TmpRoot 'nodelim.err'),
            '-p', 'prompt without delimiter'
        ) -Environment @{ 'AGY_BIN' = $fakeAgyPs }
        Assert-Equal $resNoDelim.ExitCode 2 "regression: missing '--' delimiter exits 2"
        Assert-True ($resNoDelim.Stderr -match '(?i)(delimiter|unknown launcher option)') "regression: missing delimiter is rejected" $resNoDelim.Stderr
    }

    # 1.3 Output and error redirection & parent directory creation
    & {
        $nestedOut = Join-Path $TmpRoot 'nested/sub1/out.json'
        $nestedErr = Join-Path $TmpRoot 'nested/sub2/err.log'
        $resRedir = Invoke-ToolProcess -FilePath $PwshBin -ArgumentList @(
            '-NoProfile', '-File', $ProdLauncher,
            '--role', 'scout',
            '--output', $nestedOut,
            '--error', $nestedErr,
            '--',
            '-p', 'redirection test'
        ) -Environment @{ 'AGY_BIN' = $fakeAgyPs }
        Assert-Equal $resRedir.ExitCode 0 "regression: redirection exits 0"
        Assert-True (Test-Path -LiteralPath $nestedOut -PathType Leaf) "regression: output file created in nested directory"
        Assert-True (Test-Path -LiteralPath $nestedErr -PathType Leaf) "regression: error file created in nested directory"
        Assert-Equal $resRedir.Stdout.Trim() "" "regression: launcher leaks no worker stdout"
        $errContent = (Get-Content -LiteralPath $nestedErr -Raw).Trim()
        Assert-Equal $errContent 'fake worker stderr' "regression: worker stderr captured in error destination"
    }

    # 1.4 Exit code propagation
    & {
        $resExit42 = Invoke-ToolProcess -FilePath $PwshBin -ArgumentList @(
            '-NoProfile', '-File', $ProdLauncher,
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot 'exit42.json'),
            '--error', (Join-Path $TmpRoot 'exit42.err'),
            '--',
            '-p', 'exit test'
        ) -Environment @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_EXIT' = '42' }
        Assert-Equal $resExit42.ExitCode 42 "regression: propagates worker exit code 42"
    }

    # 1.5 Caller flag rejection (--model and --effort)
    & {
        $startMarker = Join-Path $TmpRoot 'start-reject-model.marker'
        $resRejModel = Invoke-ToolProcess -FilePath $PwshBin -ArgumentList @(
            '-NoProfile', '-File', $ProdLauncher,
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot 'rej-model.json'),
            '--error', (Join-Path $TmpRoot 'rej-model.err'),
            '--',
            '--model', 'gemini-3.8-flash-high',
            '-p', 'test'
        ) -Environment @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_STARTED_MARKER' = $startMarker }
        Assert-Equal $resRejModel.ExitCode 2 "regression: caller --model rejected with exit 2"
        Assert-False (Test-Path -LiteralPath $startMarker) "regression: worker not started on caller --model"

        $resRejEffort = Invoke-ToolProcess -FilePath $PwshBin -ArgumentList @(
            '-NoProfile', '-File', $ProdLauncher,
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot 'rej-effort.json'),
            '--error', (Join-Path $TmpRoot 'rej-effort.err'),
            '--',
            '--effort', 'high',
            '-p', 'test'
        ) -Environment @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_STARTED_MARKER' = $startMarker }
        Assert-Equal $resRejEffort.ExitCode 2 "regression: caller --effort rejected with exit 2"
        Assert-False (Test-Path -LiteralPath $startMarker) "regression: worker not started on caller --effort"
    }

    # 1.6 Rejection of caller-facing --cwd option (spec: no new caller-facing --cwd option)
    & {
        $startMarker = Join-Path $TmpRoot 'start-reject-cwd.marker'
        $resRejCwd = Invoke-ToolProcess -FilePath $PwshBin -ArgumentList @(
            '-NoProfile', '-File', $ProdLauncher,
            '--cwd', $TmpRoot,
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot 'rej-cwd.json'),
            '--error', (Join-Path $TmpRoot 'rej-cwd.err'),
            '--',
            '-p', 'test'
        ) -Environment @{ 'AGY_BIN' = $fakeAgyPs; 'FAKE_AGY_STARTED_MARKER' = $startMarker }
        Assert-Equal $resRejCwd.ExitCode 2 "contract: launcher rejects caller-facing --cwd option"
        Assert-True ($resRejCwd.Stderr -match '(?i)unknown launcher option: --cwd') "contract: stderr indicates unknown launcher option --cwd"
        Assert-False (Test-Path -LiteralPath $startMarker) "contract: worker not started on caller --cwd"
    }

    # =======================================================================
    # 2. Cross-Platform Parity: Bash Launcher Directory Inheritance
    #    "The Bash launcher already inherits the invoking shell's directory.
    #     Add a parity test rather than changing its behavior..."
    # =======================================================================
    & {
        $bashCmd = $null
        if ($IsWindows) {
            if (Test-Path -LiteralPath 'C:\Program Files\Git\bin\bash.exe' -PathType Leaf) {
                $bashCmd = 'C:\Program Files\Git\bin\bash.exe'
            } elseif (Test-Path -LiteralPath 'C:\Program Files\Git\usr\bin\bash.exe' -PathType Leaf) {
                $bashCmd = 'C:\Program Files\Git\usr\bin\bash.exe'
            }
        }
        if (-not $bashCmd) {
            $cmd = Get-Command bash -ErrorAction SilentlyContinue
            if ($cmd) {
                $src = if ($cmd.Source) { $cmd.Source } else { $cmd.Name }
                if (-not $IsWindows -or -not $src.StartsWith($env:SystemRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $bashCmd = $src
                }
            }
        }

        if ($bashCmd -and (Test-Path -LiteralPath $ShLauncher -PathType Leaf)) {
            $bashWs = Join-Path $TmpRoot 'bash workspace with spaces'
            [System.IO.Directory]::CreateDirectory($bashWs) | Out-Null

            $bashBinDir = Join-Path $TmpRoot 'bash-bin'
            [System.IO.Directory]::CreateDirectory($bashBinDir) | Out-Null
            $fakeBashAgy = Join-Path $bashBinDir 'agy'
            @'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${FAKE_AGY_RECORD_CWD:-}" ]; then
  if pwd -W >/dev/null 2>&1; then
    pwd -W > "$FAKE_AGY_RECORD_CWD"
  else
    pwd -P > "$FAKE_AGY_RECORD_CWD"
  fi
fi
printf 'fake bash stderr\n' >&2
printf '{"status":"success","response":"bash worker","structured_output":{"ok":true}}\n'
exit 0
'@ | Set-Content -LiteralPath $fakeBashAgy -Encoding utf8
            if (-not $IsWindows) {
                [System.IO.File]::SetUnixFileMode($fakeBashAgy, [System.IO.UnixFileMode]509)
            }

            $bashCwdRecord = Join-Path $TmpRoot 'bash-observed-cwd.txt'
            $bashOut = Join-Path $TmpRoot 'bash-out.json'
            $bashErr = Join-Path $TmpRoot 'bash-err.err'

            $runnerSh = Join-Path $TmpRoot 'run-bash-test.sh'
            @'
#!/usr/bin/env bash
set -euo pipefail
target_ws="$1"
agy_bin="$2"
sh_launcher="$3"
out_file="$4"
err_file="$5"
cwd_file="$6"
adapter_bin="$7"
catalog_file="$8"
if command -v cygpath >/dev/null 2>&1; then
  adapter_bin="$(cygpath -u "$adapter_bin")"
  catalog_file="$(cygpath -u "$catalog_file")"
fi

chmod +x "$agy_bin"
chmod +x "$adapter_bin"
export AGY_BIN="$agy_bin"
export OFFLOAD_ADAPTER_BIN="$adapter_bin"
export FAKE_ADAPTER_CATALOG="$catalog_file"
export FAKE_AGY_RECORD_CWD="$cwd_file"

cd "$target_ws"
"$sh_launcher" --role scout --output "$out_file" --error "$err_file" -- -p 'bash test prompt'
'@ | Set-Content -LiteralPath $runnerSh -Encoding utf8
            if (-not $IsWindows) {
                [System.IO.File]::SetUnixFileMode($runnerSh, [System.IO.UnixFileMode]509)
            }

            $resBash = Invoke-ToolProcess -FilePath $bashCmd -ArgumentList @(
                ($runnerSh -replace '\\', '/'),
                ($bashWs -replace '\\', '/'),
                ($fakeBashAgy -replace '\\', '/'),
                ($ShLauncher -replace '\\', '/'),
                ($bashOut -replace '\\', '/'),
                ($bashErr -replace '\\', '/'),
                ($bashCwdRecord -replace '\\', '/'),
                ((Join-Path $RootDir 'tests/fixtures/fake-worker-adapter.sh') -replace '\\', '/'),
                ($fakeCatalog -replace '\\', '/')
            )
            Assert-True ($resBash.ExitCode -eq 0) "bash parity: run-agy-json.sh exits 0" $resBash.Stderr
            Assert-True (Test-Path -LiteralPath $bashCwdRecord) "bash parity: worker recorded observed working directory"
            $observedBashCwd = (Get-Content -LiteralPath $bashCwdRecord -Raw).Trim()
            Assert-Equal (Normalize-Path $observedBashCwd) (Normalize-Path $bashWs) "bash parity: bash worker inherits invoking shell working directory"
        } else {
            [Console]::Out.WriteLine("skip - bash not found on host; skipping bash inheritance parity test")
        }
    }

    # =======================================================================
    # 3. PowerShell Child Working Directory in Directory with Spaces
    #    "run-agy-json.ps1 MUST set System.Diagnostics.ProcessStartInfo.WorkingDirectory
    #     before starting agy. The value MUST be the caller's current filesystem
    #     location at the time the launcher is invoked."
    # =======================================================================

    # 3.1 Caller session in temporary directory containing spaces
    & {
        $wsWithSpaces = Join-Path $TmpRoot 'candidate workspace with spaces'
        [System.IO.Directory]::CreateDirectory($wsWithSpaces) | Out-Null

        $cwdRecord = Join-Path $TmpRoot 'observed-cwd-spaces.txt'
        $outPath = Join-Path $TmpRoot 'out-spaces.json'
        $errPath = Join-Path $TmpRoot 'err-spaces.err'
        $envTest = @{
            'AGY_BIN'              = $fakeAgyPs
            'FAKE_AGY_RECORD_CWD'  = $cwdRecord
        }

        # Parent process starts in $TmpRoot (a different directory than the workspace)
        $res = Invoke-LauncherInSession -SessionLocation $wsWithSpaces -LauncherArgs @(
            '--role', 'scout',
            '--output', $outPath,
            '--error', $errPath,
            '--',
            '-p', 'test prompt in workspace with spaces'
        ) -Environment $envTest -ProcessWorkingDir $TmpRoot

        Assert-Equal $res.ExitCode 0 "pwsh launcher: exits 0 when called from directory with spaces"
        Assert-True (Test-Path -LiteralPath $cwdRecord) "pwsh launcher: worker executed and recorded current working directory"
        $observedCwd = (Get-Content -LiteralPath $cwdRecord -Raw).Trim()
        Assert-Equal (Normalize-Path $observedCwd) (Normalize-Path $wsWithSpaces) "pwsh launcher: worker observes caller filesystem directory with spaces as working directory"
    }

    # 3.2 Decoupling from process-inherited .NET directory and repository root
    #     "The launcher MUST NOT silently use $PSScriptRoot, the repository root,
    #      or the process's inherited .NET directory."
    & {
        $callerWs = Join-Path $TmpRoot 'caller active workspace'
        [System.IO.Directory]::CreateDirectory($callerWs) | Out-Null

        $decoupledNetDir = Join-Path $TmpRoot 'decoupled net directory'
        [System.IO.Directory]::CreateDirectory($decoupledNetDir) | Out-Null

        $cwdRecord = Join-Path $TmpRoot 'observed-cwd-decoupled.txt'
        $envTest = @{
            'AGY_BIN'             = $fakeAgyPs
            'FAKE_AGY_RECORD_CWD' = $cwdRecord
        }

        # Explicitly set [System.IO.Directory]::SetCurrentDirectory to a different directory
        # while PowerShell's provider location is $callerWs
        $preCode = "[System.IO.Directory]::SetCurrentDirectory('$($decoupledNetDir.Replace("'", "''"))')"
        $res = Invoke-LauncherInSession -SessionLocation $callerWs -LauncherArgs @(
            '--role', 'reviewer',
            '--output', (Join-Path $TmpRoot 'out-decoupled.json'),
            '--error', (Join-Path $TmpRoot 'err-decoupled.err'),
            '--',
            '-p', 'test prompt decoupled'
        ) -Environment $envTest -ProcessWorkingDir $TmpRoot -PreInvocationCode $preCode

        Assert-Equal $res.ExitCode 0 "pwsh launcher: decoupled invocation exits 0"
        Assert-True (Test-Path -LiteralPath $cwdRecord) "pwsh launcher: decoupled worker recorded directory"
        $observedCwd = (Get-Content -LiteralPath $cwdRecord -Raw).Trim()
        Assert-Equal (Normalize-Path $observedCwd) (Normalize-Path $callerWs) "pwsh launcher: worker uses caller PowerShell location, not inherited .NET directory"
        Assert-NotEqual (Normalize-Path $observedCwd) (Normalize-Path $decoupledNetDir) "pwsh launcher: worker does not use process .NET directory"
        Assert-NotEqual (Normalize-Path $observedCwd) (Normalize-Path $RootDir) "pwsh launcher: worker does not use repository root"
        Assert-NotEqual (Normalize-Path $observedCwd) (Normalize-Path $ScriptsDir) "pwsh launcher: worker does not use `$PSScriptRoot"
    }

    # 3.3 Worker relative path resolution resolves in caller workspace
    #     "Relative paths in a worker prompt can therefore resolve against the
    #      launcher repository instead of the isolated research workspace."
    & {
        $relativeProbeWs = Join-Path $TmpRoot 'relative probe workspace'
        [System.IO.Directory]::CreateDirectory($relativeProbeWs) | Out-Null

        $probeFileName = "worker-probe-$([System.Guid]::NewGuid().ToString('N')).txt"
        $envTest = @{
            'AGY_BIN'                 = $fakeAgyPs
            'FAKE_AGY_WRITE_RELATIVE' = $probeFileName
        }

        $res = Invoke-LauncherInSession -SessionLocation $relativeProbeWs -LauncherArgs @(
            '--role', 'researcher',
            '--output', (Join-Path $TmpRoot 'out-rel.json'),
            '--error', (Join-Path $TmpRoot 'err-rel.err'),
            '--',
            '-p', 'test relative probe creation'
        ) -Environment $envTest -ProcessWorkingDir $RootDir

        Assert-Equal $res.ExitCode 0 "pwsh launcher: relative probe invocation exits 0"
        $expectedProbePath = Join-Path $relativeProbeWs $probeFileName
        $repoEscapeProbePath = Join-Path $RootDir $probeFileName
        Assert-True (Test-Path -LiteralPath $expectedProbePath) "pwsh launcher: worker relative path writes inside caller workspace"
        Assert-False (Test-Path -LiteralPath $repoEscapeProbePath) "pwsh launcher: worker relative path does not escape into repository root"
        if (Test-Path -LiteralPath $repoEscapeProbePath) {
            Remove-Item -LiteralPath $repoEscapeProbePath -Force -ErrorAction SilentlyContinue
        }
    }

    # 3.4 Caller session in directory with special characters (brackets)
    & {
        $wsWithBrackets = Join-Path $TmpRoot 'candidate workspace [build-1]'
        [System.IO.Directory]::CreateDirectory($wsWithBrackets) | Out-Null

        $cwdRecord = Join-Path $TmpRoot 'observed-cwd-brackets.txt'
        $outPath = Join-Path $TmpRoot 'out-brackets.json'
        $errPath = Join-Path $TmpRoot 'err-brackets.err'
        $envTest = @{
            'AGY_BIN'              = $fakeAgyPs
            'FAKE_AGY_RECORD_CWD'  = $cwdRecord
        }

        $res = Invoke-LauncherInSession -SessionLocation $wsWithBrackets -LauncherArgs @(
            '--role', 'scout',
            '--output', $outPath,
            '--error', $errPath,
            '--',
            '-p', 'test prompt in workspace with brackets'
        ) -Environment $envTest -ProcessWorkingDir $TmpRoot

        Assert-Equal $res.ExitCode 0 "pwsh launcher: exits 0 when called from directory with brackets"
        Assert-True (Test-Path -LiteralPath $cwdRecord) "pwsh launcher: worker executed from directory with brackets"
        $observedCwd = (Get-Content -LiteralPath $cwdRecord -Raw).Trim()
        Assert-Equal (Normalize-Path $observedCwd) (Normalize-Path $wsWithBrackets) "pwsh launcher: worker observes caller directory with brackets as working directory"
    }

    # 3.5 PATH-resolved agy executable observes caller working directory
    & {
        $wsPathResolved = Join-Path $TmpRoot 'candidate workspace path-resolved'
        [System.IO.Directory]::CreateDirectory($wsPathResolved) | Out-Null

        $cwdRecord = Join-Path $TmpRoot 'observed-cwd-path-resolved.txt'
        $outPath = Join-Path $TmpRoot 'out-path-resolved.json'
        $errPath = Join-Path $TmpRoot 'err-path-resolved.err'
        $envTest = @{
            'PATH'                = $basePath
            'FAKE_AGY_RECORD_CWD' = $cwdRecord
        }

        $res = Invoke-LauncherInSession -SessionLocation $wsPathResolved -LauncherArgs @(
            '--role', 'scout',
            '--output', $outPath,
            '--error', $errPath,
            '--',
            '-p', 'test prompt with PATH-resolved agy'
        ) -Environment $envTest -ProcessWorkingDir $TmpRoot

        Assert-Equal $res.ExitCode 0 "pwsh launcher: PATH-resolved agy exits 0"
        Assert-True (Test-Path -LiteralPath $cwdRecord) "pwsh launcher: PATH-resolved worker executed and recorded directory"
        $observedCwd = (Get-Content -LiteralPath $cwdRecord -Raw).Trim()
        Assert-Equal (Normalize-Path $observedCwd) (Normalize-Path $wsPathResolved) "pwsh launcher: PATH-resolved worker observes caller directory as working directory"
    }

    # =======================================================================
    # 4. PowerShell Provider Resolution & Non-Filesystem Location Rejection
    #    "The launcher MUST resolve the location through the PowerShell provider
    #     and reject non-filesystem locations with a clear configuration error
    #     before starting agy."
    # =======================================================================

    # 4.1 Rejection when current location is in Environment provider (Env:\)
    & {
        $startMarkerEnv = Join-Path $TmpRoot 'marker-env-provider.txt'
        $envTest = @{
            'AGY_BIN'                 = $fakeAgyPs
            'FAKE_AGY_STARTED_MARKER' = $startMarkerEnv
        }

        $resEnv = Invoke-LauncherInSession -SessionLocation 'Env:\' -LauncherArgs @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot 'out-env-prov.json'),
            '--error', (Join-Path $TmpRoot 'err-env-prov.err'),
            '--',
            '-p', 'prompt from Env drive'
        ) -Environment $envTest -ProcessWorkingDir $TmpRoot

        Assert-NotEqual $resEnv.ExitCode 0 "pwsh launcher: rejects non-filesystem location 'Env:\' with non-zero exit code"
        Assert-True ($resEnv.Stderr -match '(?i)filesystem') "pwsh launcher: stderr mentions filesystem requirement for location"
        Assert-False (Test-Path -LiteralPath $startMarkerEnv) "pwsh launcher: worker not started from non-filesystem location 'Env:\'"
    }

    # 4.2 Rejection when current location is in Certificate provider (Cert:\ on Windows) or Variable provider
    & {
        $nonFsLocation = if ($IsWindows -and (Get-PSDrive -Name Cert -ErrorAction SilentlyContinue)) { 'Cert:\' } else { 'Variable:\' }
        $startMarkerNonFs = Join-Path $TmpRoot 'marker-nonfs-provider.txt'
        $envTest = @{
            'AGY_BIN'                 = $fakeAgyPs
            'FAKE_AGY_STARTED_MARKER' = $startMarkerNonFs
        }

        $resNonFs = Invoke-LauncherInSession -SessionLocation $nonFsLocation -LauncherArgs @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot 'out-nonfs-prov.json'),
            '--error', (Join-Path $TmpRoot 'err-nonfs-prov.err'),
            '--',
            '-p', "prompt from $nonFsLocation drive"
        ) -Environment $envTest -ProcessWorkingDir $TmpRoot

        Assert-NotEqual $resNonFs.ExitCode 0 "pwsh launcher: rejects non-filesystem location '$nonFsLocation' with non-zero exit code"
        Assert-True ($resNonFs.Stderr -match '(?i)filesystem') "pwsh launcher: stderr mentions filesystem requirement for location '$nonFsLocation'"
        Assert-False (Test-Path -LiteralPath $startMarkerNonFs) "pwsh launcher: worker not started from non-filesystem location '$nonFsLocation'"
    }

    # 4.3 Provider resolution: mapped FileSystem PSDrive resolves to physical filesystem directory
    & {
        $customDriveWs = Join-Path $TmpRoot 'custom psdrive workspace'
        [System.IO.Directory]::CreateDirectory($customDriveWs) | Out-Null

        $driveName = 'OffloadWs'
        $cwdRecord = Join-Path $TmpRoot 'observed-cwd-psdrive.txt'
        $envTest = @{
            'AGY_BIN'             = $fakeAgyPs
            'FAKE_AGY_RECORD_CWD' = $cwdRecord
        }

        $preSetup = "New-PSDrive -Name '$driveName' -PSProvider 'FileSystem' -Root '$($customDriveWs.Replace("'", "''"))' | Out-Null"
        $res = Invoke-LauncherInSession -SessionLocation "$driveName`:\" -LauncherArgs @(
            '--role', 'scout',
            '--output', (Join-Path $TmpRoot 'out-psdrive.json'),
            '--error', (Join-Path $TmpRoot 'err-psdrive.err'),
            '--',
            '-p', 'test prompt in custom psdrive'
        ) -Environment $envTest -ProcessWorkingDir $TmpRoot -PreSetupCode $preSetup

        Assert-Equal $res.ExitCode 0 "pwsh launcher: exits 0 when called from custom FileSystem PSDrive"
        Assert-True (Test-Path -LiteralPath $cwdRecord) "pwsh launcher: worker executed from custom FileSystem PSDrive"
        $observedCwd = (Get-Content -LiteralPath $cwdRecord -Raw).Trim()
        Assert-Equal (Normalize-Path $observedCwd) (Normalize-Path $customDriveWs) "pwsh launcher: provider resolves custom PSDrive to physical filesystem directory"
    }

    # -----------------------------------------------------------------------
    # Final Result
    # -----------------------------------------------------------------------
    if ($script:FailedTests -gt 0) {
        [Console]::Error.WriteLine("FAIL: $script:FailedTests test(s) failed out of $script:TotalTests")
        exit 1
    }

    [Console]::Out.WriteLine("all launcher-cwd checks passed ($script:TotalTests tests)")
    exit 0
}
finally {
    if ($null -eq $savedAdapterBin) { Remove-Item Env:OFFLOAD_ADAPTER_BIN -ErrorAction SilentlyContinue } else { $env:OFFLOAD_ADAPTER_BIN = $savedAdapterBin }
    if ($null -eq $savedAdapterCatalog) { Remove-Item Env:FAKE_ADAPTER_CATALOG -ErrorAction SilentlyContinue } else { $env:FAKE_ADAPTER_CATALOG = $savedAdapterCatalog }
    if ($null -eq $savedAgyBin) { Remove-Item Env:AGY_BIN -ErrorAction SilentlyContinue } else { $env:AGY_BIN = $savedAgyBin }
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
