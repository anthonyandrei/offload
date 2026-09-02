#!/usr/bin/env pwsh
# scripts/run-agy-json.ps1
# Offload worker launcher for PowerShell orchestrators.
# Runs agy with isolated stdout and stderr redirection.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Show-Usage {
    [Console]::Error.WriteLine("Usage: run-agy-json.ps1 --output FILE --error FILE -- agy-arguments...")
}

function Fail([string]$message, [int]$exitCode = 2) {
    [Console]::Error.WriteLine("ERROR: $message")
    exit $exitCode
}

$outputPath = ""
$errorPath = ""
$forwardedArgs = [System.Collections.Generic.List[string]]::new()
$seenDashDash = $false

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    if ($arg -eq '--') {
        $seenDashDash = $true
        $i++
        while ($i -lt $args.Count) {
            $forwardedArgs.Add([string]$args[$i])
            $i++
        }
        break
    } elseif ($arg -eq '--output') {
        $i++
        if ($i -ge $args.Count) {
            Show-Usage
            Fail "--output requires a path"
        }
        $outputPath = [string]$args[$i]
    } elseif ($arg.StartsWith('--output=')) {
        $outputPath = $arg.Substring(9)
    } elseif ($arg -eq '--error') {
        $i++
        if ($i -ge $args.Count) {
            Show-Usage
            Fail "--error requires a path"
        }
        $errorPath = [string]$args[$i]
    } elseif ($arg.StartsWith('--error=')) {
        $errorPath = $arg.Substring(8)
    } else {
        Show-Usage
        Fail "unknown launcher option: $arg"
    }
    $i++
}

if (-not $seenDashDash) {
    Show-Usage
    Fail "-- delimiter is required"
}
if ([string]::IsNullOrWhiteSpace($outputPath)) {
    Show-Usage
    Fail "--output is required"
}
if ([string]::IsNullOrWhiteSpace($errorPath)) {
    Show-Usage
    Fail "--error is required"
}
if ($forwardedArgs.Count -eq 0) {
    Show-Usage
    Fail "agy arguments are required after --"
}

foreach ($fa in $forwardedArgs) {
    if ($fa -eq '--output' -or $fa.StartsWith('--output=')) {
        Fail "do not pass --output to agy; use the launcher --output path instead"
    }
}

# Resolve agy executable
$resolvedAgy = $null

if ($env:AGY_BIN) {
    $explicit = $env:AGY_BIN.Trim()
    if ($explicit.Length -gt 0) {
        $cmd = Get-Command $explicit -ErrorAction SilentlyContinue
        if ($cmd) {
            $resolvedAgy = if ($cmd.Source) { $cmd.Source } else { $cmd.Name }
        } elseif (Test-Path -LiteralPath $explicit -PathType Leaf) {
            $resolvedAgy = (Resolve-Path -LiteralPath $explicit).Path
        } else {
            Fail "explicit AGY_BIN does not resolve to an executable file or command: $explicit" 1
        }
    }
}

if (-not $resolvedAgy) {
    $cmd = Get-Command agy -ErrorAction SilentlyContinue
    if ($cmd) {
        $resolvedAgy = if ($cmd.Source) { $cmd.Source } else { $cmd.Name }
    }
}

if (-not $resolvedAgy) {
    $userProfile = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    if ($userProfile) {
        $candidate1 = Join-Path $userProfile '.local\bin\agy.exe'
        $candidate2 = Join-Path $userProfile '.local/bin/agy'
        if (Test-Path -LiteralPath $candidate1 -PathType Leaf) {
            $resolvedAgy = $candidate1
        } elseif (Test-Path -LiteralPath $candidate2 -PathType Leaf) {
            $resolvedAgy = $candidate2
        }
    }
}

if (-not $resolvedAgy) {
    Fail "agy was not found (checked AGY_BIN, Get-Command agy, %USERPROFILE%\.local\bin\agy.exe)" 1
}

# Ensure parent directories exist
$resolvedOutputPath = [System.IO.Path]::GetFullPath($outputPath)
$resolvedErrorPath = [System.IO.Path]::GetFullPath($errorPath)

$outDir = [System.IO.Path]::GetDirectoryName($resolvedOutputPath)
if (-not [string]::IsNullOrEmpty($outDir) -and -not [System.IO.Directory]::Exists($outDir)) {
    [System.IO.Directory]::CreateDirectory($outDir) | Out-Null
}

$errDir = [System.IO.Path]::GetDirectoryName($resolvedErrorPath)
if (-not [string]::IsNullOrEmpty($errDir) -and -not [System.IO.Directory]::Exists($errDir)) {
    [System.IO.Directory]::CreateDirectory($errDir) | Out-Null
}

$psi = [System.Diagnostics.ProcessStartInfo]::new()
if ($resolvedAgy.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
    $pwshBin = (Get-Process -Id $PID).Path
    $psi.FileName = $pwshBin
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($resolvedAgy)
} else {
    $psi.FileName = $resolvedAgy
}

$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
foreach ($arg in $forwardedArgs) {
    $psi.ArgumentList.Add($arg)
}

$proc = $null
try {
    $proc = [System.Diagnostics.Process]::Start($psi)
} catch {
    Fail "failed to start agy: $($_.Exception.Message)" 1
}

$outFs = [System.IO.File]::Create($resolvedOutputPath)
$errFs = [System.IO.File]::Create($resolvedErrorPath)

try {
    $outTask = $proc.StandardOutput.BaseStream.CopyToAsync($outFs)
    $errTask = $proc.StandardError.BaseStream.CopyToAsync($errFs)
    $proc.WaitForExit()
    [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask))
} finally {
    $outFs.Dispose()
    $errFs.Dispose()
}

exit $proc.ExitCode
