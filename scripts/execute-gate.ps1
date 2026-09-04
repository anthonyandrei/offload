#!/usr/bin/env pwsh
# scripts/execute-gate.ps1
# Public shared gate execution and exit normalization helper for PowerShell.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Show-Usage {
    [Console]::Error.WriteLine(@'
Usage: execute-gate.ps1 --command <COMMAND> [--diagnostic-path <PATH>] [--workspace <DIR>]

Runs a machine gate command, preserves stdout/stderr diagnostics in an artifact file,
and normalizes gate exit codes to structured failure classes and verification statuses:
  Exit 0:         failure_class="none", verification_status="passed", allow_retry=false
  Exit 126, 127:  failure_class="unrunnable", verification_status="not_performed", allow_retry=false
  Other non-zero: failure_class="quality", verification_status="failed", allow_retry=true

Outputs JSON with command, exit_code, failure_class, verification_status, allow_retry,
and diagnostic_artifact_path.
'@)
}

function Fail([string]$message, [int]$exitCode = 2) {
    [Console]::Error.WriteLine("ERROR: $message")
    exit $exitCode
}

$command = ''
$diagnosticPath = ''
$workspace = ''

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    switch ($arg) {
        '--command' {
            $i++
            if ($i -ge $args.Count) { Show-Usage; Fail '--command requires a command string' }
            $command = [string]$args[$i]
        }
        { $_ -like '--command=*' } {
            $command = $arg.Substring(10)
        }
        '-c' {
            $i++
            if ($i -ge $args.Count) { Show-Usage; Fail '-c requires a command string' }
            $command = [string]$args[$i]
        }
        '--diagnostic-path' {
            $i++
            if ($i -ge $args.Count) { Show-Usage; Fail '--diagnostic-path requires a path' }
            $diagnosticPath = [string]$args[$i]
        }
        { $_ -like '--diagnostic-path=*' } {
            $diagnosticPath = $arg.Substring(18)
        }
        '--diagnostic-file' {
            $i++
            if ($i -ge $args.Count) { Show-Usage; Fail '--diagnostic-file requires a path' }
            $diagnosticPath = [string]$args[$i]
        }
        { $_ -like '--diagnostic-file=*' } {
            $diagnosticPath = $arg.Substring(18)
        }
        '--output' {
            $i++
            if ($i -ge $args.Count) { Show-Usage; Fail '--output requires a path' }
            $diagnosticPath = [string]$args[$i]
        }
        { $_ -like '--output=*' } {
            $diagnosticPath = $arg.Substring(9)
        }
        '--workspace' {
            $i++
            if ($i -ge $args.Count) { Show-Usage; Fail '--workspace requires a path' }
            $workspace = [string]$args[$i]
        }
        { $_ -like '--workspace=*' } {
            $workspace = $arg.Substring(12)
        }
        '--cwd' {
            $i++
            if ($i -ge $args.Count) { Show-Usage; Fail '--cwd requires a path' }
            $workspace = [string]$args[$i]
        }
        { $_ -like '--cwd=*' } {
            $workspace = $arg.Substring(6)
        }
        '-h' { Show-Usage; exit 0 }
        '--help' { Show-Usage; exit 0 }
        default { Show-Usage; Fail "unrecognized option: $arg" }
    }
    $i++
}

if ([string]::IsNullOrWhiteSpace($command)) {
    Show-Usage
    Fail 'missing required option --command'
}

if ([string]::IsNullOrWhiteSpace($diagnosticPath)) {
    $diagDir = Join-Path ([System.IO.Path]::GetTempPath()) "offload-gate-diagnostics"
    if (-not [System.IO.Directory]::Exists($diagDir)) {
        [System.IO.Directory]::CreateDirectory($diagDir) | Out-Null
    }
    $diagnosticPath = Join-Path $diagDir "gate-$([System.Guid]::NewGuid().ToString('N')).log"
} else {
    $parentDir = [System.IO.Path]::GetDirectoryName($diagnosticPath)
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not [System.IO.Directory]::Exists($parentDir)) {
        [System.IO.Directory]::CreateDirectory($parentDir) | Out-Null
    }
}

$PwshBin = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $PwshBin) {
    $PwshBin = (Get-Process -Id $PID).Path
}

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $PwshBin
$psi.ArgumentList.Add('-NoProfile')
$psi.ArgumentList.Add('-NonInteractive')
$psi.ArgumentList.Add('-Command')
$psi.ArgumentList.Add($command)
if (-not [string]::IsNullOrWhiteSpace($workspace)) {
    $psi.WorkingDirectory = $workspace
}
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true

$proc = [System.Diagnostics.Process]::Start($psi)
$stdoutTask = $proc.StandardOutput.ReadToEndAsync()
$stderrTask = $proc.StandardError.ReadToEndAsync()
$proc.WaitForExit()
$rawExit = $proc.ExitCode
$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderr = $stderrTask.GetAwaiter().GetResult()

$contentBuilder = [System.Text.StringBuilder]::new()
if (-not [string]::IsNullOrEmpty($stdout)) {
    [void]$contentBuilder.Append($stdout)
}
if (-not [string]::IsNullOrEmpty($stderr)) {
    [void]$contentBuilder.Append($stderr)
}
[System.IO.File]::WriteAllText($diagnosticPath, $contentBuilder.ToString(), [System.Text.UTF8Encoding]::new($false))

if ($rawExit -eq 0) {
    $failureClass = "none"
    $verificationStatus = "passed"
    $allowRetry = $false
} elseif ($rawExit -eq 126 -or $rawExit -eq 127) {
    $failureClass = "unrunnable"
    $verificationStatus = "not_performed"
    $allowRetry = $false
} else {
    $failureClass = "quality"
    $verificationStatus = "failed"
    $allowRetry = $true
}

$report = [ordered]@{
    command                  = $command
    exit_code                = $rawExit
    failure_class            = $failureClass
    verification_status      = $verificationStatus
    allow_retry              = $allowRetry
    diagnostic_artifact_path = $diagnosticPath
    stdout                   = $stdout
    stderr                   = $stderr
}

$jsonText = $report | ConvertTo-Json -Compress
[Console]::Out.WriteLine($jsonText)
exit 0
