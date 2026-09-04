#!/usr/bin/env pwsh
# tests/test_review_gate_normalization.ps1
# Acceptance gate for execution mode gate execution and outcome normalization.
# Covers the public shared gate execution path by invoking scripts/execute-gate.ps1
# and scripts/execute-gate.sh with commands exiting 0, 1, 126, and 127.
# Asserts JSON records the exact command, exit code, diagnostic artifact path,
# and maps 126 and 127 to unrunnable, not_performed, and no retry;
# asserts 1 remains quality failed retryable and 0 remains none passed nonretryable.
# Also asserts execution docs state 126 and 127 are not quality retries.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# Assertion Harness
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
    if ($env:OFFLOAD_CONTINUE_ON_FAIL -ne "1" -and $env:OFFLOAD_TEST_CONTINUE_ON_FAIL -ne "1") {
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
# Path Resolution & Environment
# ---------------------------------------------------------------------------

$PwshBin = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $PwshBin) {
    $PwshBin = (Get-Process -Id $PID).Path
}

$RootDir = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
$ScriptsDir = Join-Path $RootDir "scripts"
$GatePs1 = Join-Path $ScriptsDir "execute-gate.ps1"
$GateSh = Join-Path $ScriptsDir "execute-gate.sh"
$ExecDoc = Join-Path $RootDir "modes/execution.md"

$TmpRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "offload-gate-norm-test-$([System.Guid]::NewGuid().ToString('N'))")
[System.IO.Directory]::CreateDirectory($TmpRoot) | Out-Null

function Find-BashBin {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $pathBash = (Get-Command bash -ErrorAction SilentlyContinue)?.Source
    if ($pathBash -and (-not $IsWindows -or -not $pathBash.StartsWith($env:SystemRoot, [System.StringComparison]::OrdinalIgnoreCase))) {
        $candidates.Add($pathBash)
    }
    if ($IsWindows) {
        $candidates.Add("C:\Program Files\Git\bin\bash.exe")
        $candidates.Add("C:\Program Files\Git\usr\bin\bash.exe")
    }
    if ($pathBash) {
        $candidates.Add($pathBash)
    }
    foreach ($c in $candidates) {
        if ([System.IO.File]::Exists($c)) {
            try {
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName = $c
                $psi.ArgumentList.Add("-c")
                $psi.ArgumentList.Add("exit 0")
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $p = [System.Diagnostics.Process]::Start($psi)
                $p.WaitForExit()
                if ($p.ExitCode -eq 0) {
                    return $c
                }
            } catch {}
        }
    }
    return $null
}

$BashBin = Find-BashBin

function Resolve-PathForHost([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return "" }
    if (Test-Path -LiteralPath $path) { return $path }
    if ($IsWindows) {
        if ($path -match "^/([a-zA-Z])/(.*)$") {
            $drive = $Matches[1].ToUpper()
            $rest = $Matches[2].Replace("/", "\")
            $cand = "$drive`:\$rest"
            if (Test-Path -LiteralPath $cand) { return $cand }
        }
        if ($path -like "/tmp/*") {
            $sub = $path.Substring(5).Replace("/", "\")
            $candTemp = Join-Path ([System.IO.Path]::GetTempPath()) $sub
            if (Test-Path -LiteralPath $candTemp) { return $candTemp }
        }
        if ($BashBin) {
            try {
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName = $BashBin
                $psi.ArgumentList.Add("-c")
                $psi.ArgumentList.Add("cygpath -w '$path'")
                $psi.RedirectStandardOutput = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $proc = [System.Diagnostics.Process]::Start($psi)
                $w = $proc.StandardOutput.ReadToEnd().Trim()
                $proc.WaitForExit()
                if ($proc.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($w) -and (Test-Path -LiteralPath $w)) {
                    return $w
                }
            } catch {}
        }
    }
    return $path
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

function Invoke-GateHelper {
    param(
        [Parameter(Mandatory=$true)][string]$HelperName,
        [Parameter(Mandatory=$true)][string]$GateCommand,
        [string[]]$ExtraArgs = @(),
        [string]$WorkingDirectory = $null
    )
    if ($HelperName -eq "execute-gate.ps1") {
        $scriptPath = $GatePs1
        $pwshArgs = @("-NoProfile", "-NonInteractive", "-File", $scriptPath, "--command", $GateCommand) + $ExtraArgs
        return Invoke-ToolProcess -FilePath $PwshBin -ArgumentList $pwshArgs -WorkingDirectory $WorkingDirectory
    } elseif ($HelperName -eq "execute-gate.sh") {
        if (-not $BashBin) {
            Fail "bash runner" "Bash binary not found for execute-gate.sh"
        }
        $bashScriptPath = $GateSh.Replace("\", "/")
        $normalizedArgs = @()
        foreach ($a in $ExtraArgs) {
            $normalizedArgs += $a.Replace("\", "/")
        }
        $bashArgs = @($bashScriptPath, "--command", $GateCommand) + $normalizedArgs
        return Invoke-ToolProcess -FilePath $BashBin -ArgumentList $bashArgs -WorkingDirectory $WorkingDirectory
    } else {
        Fail "Invoke-GateHelper" "Unknown helper $HelperName"
    }
}

function Parse-GateOutputJson([string]$stdout) {
    if ([string]::IsNullOrWhiteSpace($stdout)) {
        return $null
    }
    try {
        return ($stdout.Trim() | ConvertFrom-Json)
    } catch {}

    $firstBrace = $stdout.IndexOf('{')
    $lastBrace = $stdout.LastIndexOf('}')
    if ($firstBrace -ge 0 -and $lastBrace -gt $firstBrace) {
        $candidate = $stdout.Substring($firstBrace, $lastBrace - $firstBrace + 1)
        try {
            return ($candidate | ConvertFrom-Json)
        } catch {}
    }
    return $null
}

function Get-RecordedCommand($jsonObj) {
    if ($jsonObj.PSObject.Properties.Name -contains "command" -and -not [string]::IsNullOrWhiteSpace([string]$jsonObj.command)) {
        return [string]$jsonObj.command
    }
    if ($jsonObj.PSObject.Properties.Name -contains "gate_command" -and -not [string]::IsNullOrWhiteSpace([string]$jsonObj.gate_command)) {
        return [string]$jsonObj.gate_command
    }
    return $null
}

function Get-RecordedDiagnosticPath($jsonObj) {
    if ($jsonObj.PSObject.Properties.Name -contains "diagnostic_artifact_path" -and -not [string]::IsNullOrWhiteSpace([string]$jsonObj.diagnostic_artifact_path)) {
        return [string]$jsonObj.diagnostic_artifact_path
    }
    if ($jsonObj.PSObject.Properties.Name -contains "diagnostic_artifact" -and -not [string]::IsNullOrWhiteSpace([string]$jsonObj.diagnostic_artifact)) {
        return [string]$jsonObj.diagnostic_artifact
    }
    if ($jsonObj.PSObject.Properties.Name -contains "diagnostic_path" -and -not [string]::IsNullOrWhiteSpace([string]$jsonObj.diagnostic_path)) {
        return [string]$jsonObj.diagnostic_path
    }
    if ($jsonObj.PSObject.Properties.Name -contains "diagnostic_file" -and -not [string]::IsNullOrWhiteSpace([string]$jsonObj.diagnostic_file)) {
        return [string]$jsonObj.diagnostic_file
    }
    if ($jsonObj.PSObject.Properties.Name -contains "evidence_paths" -and $jsonObj.evidence_paths.Count -gt 0) {
        return [string]$jsonObj.evidence_paths[0]
    }
    return $null
}

function Get-RecordedRetry($jsonObj) {
    if ($jsonObj.PSObject.Properties.Name -contains "allow_retry" -and $null -ne $jsonObj.allow_retry) {
        return [bool]$jsonObj.allow_retry
    }
    if ($jsonObj.PSObject.Properties.Name -contains "retryable" -and $null -ne $jsonObj.retryable) {
        return [bool]$jsonObj.retryable
    }
    if ($jsonObj.PSObject.Properties.Name -contains "retry" -and $null -ne $jsonObj.retry) {
        return [bool]$jsonObj.retry
    }
    return $null
}

try {
    # =======================================================================
    # 1. Execution Documentation Assertions
    # Spec: Execution docs state 126 and 127 are unrunnable and not quality retries.
    # =======================================================================
    Assert-True (Test-Path -LiteralPath $ExecDoc -PathType Leaf) "docs: modes/execution.md exists"
    $execContent = Get-Content -LiteralPath $ExecDoc -Raw

    $docsStateNotQualityRetries = (
        ($execContent -match "(?i)(?:126|127)[^.\r\n]*(?:not\s+(?:schedule\s+a\s+)?quality\s+retr|not\s+quality\s+retr)") -or
        ($execContent -match "(?i)(?:126\s+and\s+127|126\s+or\s+127)[^.\r\n]*not\s+quality\s+retr")
    )
    Assert-True $docsStateNotQualityRetries "docs: execution docs state 126 and 127 are not quality retries"

    Assert-True ($execContent -match "unrunnable") "docs: execution docs mention unrunnable failure class"
    Assert-True ($execContent -match "not_performed") "docs: execution docs mention verification not_performed"

    # =======================================================================
    # 2. Public Shared Gate Execution Helper Existence
    # Spec: scripts/execute-gate.ps1 and scripts/execute-gate.sh exist.
    # On baseline, neither exists, establishing a strict failing baseline.
    # =======================================================================
    Assert-True (Test-Path -LiteralPath $GatePs1 -PathType Leaf) "helper existence: scripts/execute-gate.ps1 exists" "execute-gate.ps1 not found in scripts/"
    Assert-True (Test-Path -LiteralPath $GateSh -PathType Leaf) "helper existence: scripts/execute-gate.sh exists" "execute-gate.sh not found in scripts/"

    # =======================================================================
    # 3. PowerShell Gate Execution: scripts/execute-gate.ps1
    # Spec:
    #   - Cover public shared gate execution path with commands exiting 0, 1, 126, 127.
    #   - Assert JSON records exact command, exit code, diagnostic artifact path.
    #   - Exit 0: failure_class = "none", verification_status = "passed", allow_retry = false (none passed nonretryable).
    #   - Exit 1: failure_class = "quality", verification_status = "failed", allow_retry = true (quality failed retryable).
    #   - Exit 126: failure_class = "unrunnable", verification_status = "not_performed", allow_retry = false (no retry).
    #   - Exit 127: failure_class = "unrunnable", verification_status = "not_performed", allow_retry = false (no retry).
    # =======================================================================

    $testCases = @(
        @{
            ExitCode       = 0
            Command        = "exit 0"
            ExpectedClass  = "none"
            ExpectedStatus = "passed"
            ExpectedRetry  = $false
            Label          = "exit 0 none passed nonretryable"
        },
        @{
            ExitCode       = 1
            Command        = "exit 1"
            ExpectedClass  = "quality"
            ExpectedStatus = "failed"
            ExpectedRetry  = $true
            Label          = "exit 1 quality failed retryable"
        },
        @{
            ExitCode       = 126
            Command        = "exit 126"
            ExpectedClass  = "unrunnable"
            ExpectedStatus = "not_performed"
            ExpectedRetry  = $false
            Label          = "exit 126 unrunnable not_performed no retry"
        },
        @{
            ExitCode       = 127
            Command        = "exit 127"
            ExpectedClass  = "unrunnable"
            ExpectedStatus = "not_performed"
            ExpectedRetry  = $false
            Label          = "exit 127 unrunnable not_performed no retry"
        }
    )

    foreach ($tc in $testCases) {
        $resPs = Invoke-GateHelper -HelperName "execute-gate.ps1" -GateCommand $tc.Command -WorkingDirectory $TmpRoot
        $jsonPs = Parse-GateOutputJson $resPs.Stdout
        Assert-True ($null -ne $jsonPs) "ps1: $($tc.Label) produces valid JSON output" "Stdout: $($resPs.Stdout), Stderr: $($resPs.Stderr)"

        # Assert exact command recorded
        $recCmd = Get-RecordedCommand $jsonPs
        Assert-Equal $recCmd $tc.Command "ps1: $($tc.Label) JSON records exact command"

        # Assert exact exit code recorded
        Assert-Equal $jsonPs.exit_code $tc.ExitCode "ps1: $($tc.Label) JSON records exit code"

        # Assert diagnostic artifact path recorded and exists on disk
        $diagPath = Get-RecordedDiagnosticPath $jsonPs
        Assert-True (-not [string]::IsNullOrWhiteSpace($diagPath)) "ps1: $($tc.Label) JSON records diagnostic artifact path"
        $resolvedDiagPath = Resolve-PathForHost $diagPath
        Assert-True (Test-Path -LiteralPath $resolvedDiagPath -PathType Leaf) "ps1: $($tc.Label) diagnostic artifact exists on disk at '$resolvedDiagPath'"

        # Assert normalization fields
        Assert-Equal $jsonPs.failure_class $tc.ExpectedClass "ps1: $($tc.Label) maps failure_class"
        Assert-Equal $jsonPs.verification_status $tc.ExpectedStatus "ps1: $($tc.Label) maps verification_status"
        $recRetry = Get-RecordedRetry $jsonPs
        Assert-Equal $recRetry $tc.ExpectedRetry "ps1: $($tc.Label) maps retry permission"
    }

    # Diagnostic artifact content preservation check (PowerShell)
    $diagSentinel = "DIAGNOSTIC_OUTPUT_SENTINEL_$([System.Guid]::NewGuid().ToString('N'))"
    $diagCmdPs = "[Console]::Error.WriteLine('$diagSentinel'); exit 126"
    $resDiagPs = Invoke-GateHelper -HelperName "execute-gate.ps1" -GateCommand $diagCmdPs -WorkingDirectory $TmpRoot
    $jsonDiagPs = Parse-GateOutputJson $resDiagPs.Stdout
    Assert-True ($null -ne $jsonDiagPs) "ps1: diagnostic preservation produces valid JSON"
    $diagPathPs = Resolve-PathForHost (Get-RecordedDiagnosticPath $jsonDiagPs)
    Assert-True (Test-Path -LiteralPath $diagPathPs -PathType Leaf) "ps1: diagnostic file exists on disk"
    $diagContentPs = Get-Content -LiteralPath $diagPathPs -Raw
    Assert-True ($diagContentPs.Contains($diagSentinel)) "ps1: diagnostic artifact preserves command diagnostic output"

    # =======================================================================
    # 4. Bash Gate Execution Parity: scripts/execute-gate.sh
    # Spec:
    #   - Cover public shared gate execution path with commands exiting 0, 1, 126, 127 in Bash.
    #   - Assert JSON records exact command, exit code, diagnostic artifact path.
    #   - Same normalization rules apply across platforms.
    # =======================================================================

    foreach ($tc in $testCases) {
        $resSh = Invoke-GateHelper -HelperName "execute-gate.sh" -GateCommand $tc.Command -WorkingDirectory $TmpRoot
        $jsonSh = Parse-GateOutputJson $resSh.Stdout
        Assert-True ($null -ne $jsonSh) "sh: $($tc.Label) produces valid JSON output" "Stdout: $($resSh.Stdout), Stderr: $($resSh.Stderr)"

        # Assert exact command recorded
        $recCmdSh = Get-RecordedCommand $jsonSh
        Assert-Equal $recCmdSh $tc.Command "sh: $($tc.Label) JSON records exact command"

        # Assert exact exit code recorded
        Assert-Equal $jsonSh.exit_code $tc.ExitCode "sh: $($tc.Label) JSON records exit code"

        # Assert diagnostic artifact path recorded and exists on disk
        $diagPathSh = Get-RecordedDiagnosticPath $jsonSh
        Assert-True (-not [string]::IsNullOrWhiteSpace($diagPathSh)) "sh: $($tc.Label) JSON records diagnostic artifact path"
        $resolvedDiagPathSh = Resolve-PathForHost $diagPathSh
        Assert-True (Test-Path -LiteralPath $resolvedDiagPathSh -PathType Leaf) "sh: $($tc.Label) diagnostic artifact exists on disk at '$resolvedDiagPathSh'"

        # Assert normalization fields
        Assert-Equal $jsonSh.failure_class $tc.ExpectedClass "sh: $($tc.Label) maps failure_class"
        Assert-Equal $jsonSh.verification_status $tc.ExpectedStatus "sh: $($tc.Label) maps verification_status"
        $recRetrySh = Get-RecordedRetry $jsonSh
        Assert-Equal $recRetrySh $tc.ExpectedRetry "sh: $($tc.Label) maps retry permission"
    }

    # Diagnostic artifact content preservation check (Bash)
    $diagSentinelSh = "DIAGNOSTIC_BASH_SENTINEL_$([System.Guid]::NewGuid().ToString('N'))"
    $diagCmdSh = "echo '$diagSentinelSh' >&2; exit 127"
    $resDiagSh = Invoke-GateHelper -HelperName "execute-gate.sh" -GateCommand $diagCmdSh -WorkingDirectory $TmpRoot
    $jsonDiagSh = Parse-GateOutputJson $resDiagSh.Stdout
    Assert-True ($null -ne $jsonDiagSh) "sh: diagnostic preservation produces valid JSON"
    $diagPathSh = Resolve-PathForHost (Get-RecordedDiagnosticPath $jsonDiagSh)
    Assert-True (Test-Path -LiteralPath $diagPathSh -PathType Leaf) "sh: diagnostic file exists on disk"
    $diagContentSh = Get-Content -LiteralPath $diagPathSh -Raw
    Assert-True ($diagContentSh.Contains($diagSentinelSh)) "sh: diagnostic artifact preserves command diagnostic output"

} finally {
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -Recurse -Force -LiteralPath $TmpRoot -ErrorAction SilentlyContinue
    }
}

if ($script:FailedTests -gt 0) {
    [Console]::Error.WriteLine("FAILED: $($script:FailedTests) of $($script:TotalTests) tests failed.")
    exit 1
}

[Console]::Out.WriteLine("All $($script:TotalTests) tests passed.")
exit 0
