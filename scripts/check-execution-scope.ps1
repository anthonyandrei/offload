#!/usr/bin/env pwsh
# scripts/check-execution-scope.ps1
# Platform-agnostic execution scope checker for PowerShell 7 / .NET.
# Verifies that touched files in the Git worktree are owned and not frozen.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# 1. Validate that we are inside a Git worktree
$psiRev = [System.Diagnostics.ProcessStartInfo]::new()
$psiRev.FileName = 'git'
$psiRev.ArgumentList.Add('rev-parse')
$psiRev.ArgumentList.Add('--is-inside-work-tree')
$psiRev.RedirectStandardOutput = $true
$psiRev.RedirectStandardError = $true
$psiRev.UseShellExecute = $false
$psiRev.CreateNoWindow = $true

$procRev = [System.Diagnostics.Process]::Start($psiRev)
$stdoutRev = $procRev.StandardOutput.ReadToEnd().Trim()
$procRev.WaitForExit()

if ($procRev.ExitCode -ne 0 -or $stdoutRev -ne 'true') {
    [Console]::Error.WriteLine("Error: not inside a git worktree")
    exit 1
}

# 2. Parse CLI arguments
$rawOwned = [System.Collections.Generic.List[string]]::new()
$rawFrozen = [System.Collections.Generic.List[string]]::new()

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]

    if ($arg -eq '--owned' -or $arg -eq '-owned') {
        if ($i + 1 -ge $args.Count) {
            [Console]::Error.WriteLine("Error: --owned requires a value")
            exit 1
        }
        $val = [string]$args[$i + 1]
        if ([string]::IsNullOrEmpty($val) -or $val.StartsWith('-')) {
            [Console]::Error.WriteLine("Error: --owned requires a value")
            exit 1
        }
        $rawOwned.Add($val)
        $i += 2
    }
    elseif ($arg.StartsWith('--owned=') -or $arg.StartsWith('-owned=')) {
        $eqIdx = $arg.IndexOf('=')
        $val = $arg.Substring($eqIdx + 1)
        if ([string]::IsNullOrEmpty($val)) {
            [Console]::Error.WriteLine("Error: --owned requires a value")
            exit 1
        }
        $rawOwned.Add($val)
        $i += 1
    }
    elseif ($arg -eq '--frozen' -or $arg -eq '-frozen') {
        if ($i + 1 -ge $args.Count) {
            [Console]::Error.WriteLine("Error: --frozen requires a value")
            exit 1
        }
        $val = [string]$args[$i + 1]
        if ([string]::IsNullOrEmpty($val) -or $val.StartsWith('-')) {
            [Console]::Error.WriteLine("Error: --frozen requires a value")
            exit 1
        }
        $rawFrozen.Add($val)
        $i += 2
    }
    elseif ($arg.StartsWith('--frozen=') -or $arg.StartsWith('-frozen=')) {
        $eqIdx = $arg.IndexOf('=')
        $val = $arg.Substring($eqIdx + 1)
        if ([string]::IsNullOrEmpty($val)) {
            [Console]::Error.WriteLine("Error: --frozen requires a value")
            exit 1
        }
        $rawFrozen.Add($val)
        $i += 1
    }
    elseif ($arg -eq '-h' -or $arg -eq '--help' -or $arg -eq '-?') {
        [Console]::Error.WriteLine("Usage: check-execution-scope.ps1 --owned <path> [--owned <path> ...] [--frozen <path> ...]")
        exit 0
    }
    else {
        [Console]::Error.WriteLine("Error: unrecognized argument '$arg'")
        exit 1
    }
}

if ($rawOwned.Count -eq 0) {
    [Console]::Error.WriteLine("Error: at least one --owned path is required")
    exit 1
}

# 3. Path normalization helper
function Normalize-Path([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) {
        return ""
    }
    $norm = $p.Replace('\', '/')
    while ($norm.StartsWith("./")) {
        $norm = $norm.Substring(2)
    }
    while ($norm.StartsWith("/") -and $norm.Length -gt 1) {
        $norm = $norm.Substring(1)
    }
    while ($norm.EndsWith("/") -and $norm.Length -gt 1) {
        $norm = $norm.Substring(0, $norm.Length - 1)
    }
    if ($norm -eq "." -or $norm -eq "/") {
        return ""
    }
    return $norm
}

function Test-ScopeMatch([string]$candidate, [string]$target) {
    if ($target -eq "" -or $target -eq ".") {
        return $true
    }
    if ($candidate -eq $target) {
        return $true
    }
    if ($candidate.StartsWith($target + "/")) {
        return $true
    }
    return $false
}

$ownedTargets = [System.Collections.Generic.List[string]]::new()
foreach ($o in $rawOwned) {
    $ownedTargets.Add((Normalize-Path $o))
}

$frozenTargets = [System.Collections.Generic.List[string]]::new()
foreach ($f in $rawFrozen) {
    $frozenTargets.Add((Normalize-Path $f))
}

# 4. Discover touched files from Git
$psiStatus = [System.Diagnostics.ProcessStartInfo]::new()
$psiStatus.FileName = 'git'
$psiStatus.ArgumentList.Add('-c')
$psiStatus.ArgumentList.Add('core.quotepath=false')
$psiStatus.ArgumentList.Add('status')
$psiStatus.ArgumentList.Add('--porcelain=v1')
$psiStatus.ArgumentList.Add('-z')
$psiStatus.ArgumentList.Add('-uall')
$psiStatus.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psiStatus.StandardErrorEncoding = [System.Text.Encoding]::UTF8
$psiStatus.RedirectStandardOutput = $true
$psiStatus.RedirectStandardError = $true
$psiStatus.UseShellExecute = $false
$psiStatus.CreateNoWindow = $true

$procStatus = [System.Diagnostics.Process]::Start($psiStatus)
$rawOutput = $procStatus.StandardOutput.ReadToEnd()
$errOutput = $procStatus.StandardError.ReadToEnd()
$procStatus.WaitForExit()

if ($procStatus.ExitCode -ne 0) {
    [Console]::Error.WriteLine("Error: git status failed with exit code $($procStatus.ExitCode): $errOutput")
    exit $procStatus.ExitCode
}

# Parse NUL-delimited records
$touchedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

if (-not [string]::IsNullOrEmpty($rawOutput)) {
    $tokens = $rawOutput.Split([char]0)
    $k = 0
    while ($k -lt $tokens.Length) {
        $entry = $tokens[$k]
        if ([string]::IsNullOrEmpty($entry)) {
            $k++
            continue
        }

        if ($entry.Length -ge 3) {
            $statusX = $entry[0]
            $statusY = $entry[1]
            $path1 = $entry.Substring(3)
            $touchedPaths.Add($path1) | Out-Null

            # If rename or copy, next token is old path
            if ($statusX -eq 'R' -or $statusX -eq 'C' -or $statusY -eq 'R' -or $statusY -eq 'C') {
                $k++
                if ($k -lt $tokens.Length -and -not [string]::IsNullOrEmpty($tokens[$k])) {
                    $path2 = $tokens[$k]
                    $touchedPaths.Add($path2) | Out-Null
                }
            }
        }
        $k++
    }
}

# 5. Check for ownership and frozen violations
$violations = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

foreach ($p in $touchedPaths) {
    # Check frozen: fails if touched path matches any frozen target
    $isFrozen = $false
    foreach ($ft in $frozenTargets) {
        if (Test-ScopeMatch $p $ft) {
            $isFrozen = $true
            break
        }
    }
    if ($isFrozen) {
        $violations.Add($p) | Out-Null
        continue
    }

    # Check ownership: passes if touched path matches any owned target
    $isOwned = $false
    foreach ($ot in $ownedTargets) {
        if (Test-ScopeMatch $p $ot) {
            $isOwned = $true
            break
        }
    }
    if (-not $isOwned) {
        $violations.Add($p) | Out-Null
    }
}

if ($violations.Count -gt 0) {
    $sortedViolations = [System.Collections.Generic.List[string]]::new($violations)
    $sortedViolations.Sort([System.StringComparer]::Ordinal)
    foreach ($v in $sortedViolations) {
        [Console]::Out.WriteLine($v)
    }
    exit 1
}

exit 0
