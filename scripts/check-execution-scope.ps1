#!/usr/bin/env pwsh
# scripts/check-execution-scope.ps1
# Platform-agnostic execution scope checker for PowerShell 7 / .NET.
# Verifies that touched files in the Git worktree are owned and not frozen.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Invoke-Git([string[]]$GitArguments) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $gitWrapper = [Environment]::GetEnvironmentVariable('OFFLOAD_GIT_WRAPPER')
    if ([string]::IsNullOrEmpty($gitWrapper)) {
        $psi.FileName = 'git'
    } else {
        $psi.FileName = 'pwsh'
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-NonInteractive')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add($gitWrapper)
    }
    foreach ($argument in $GitArguments) {
        $psi.ArgumentList.Add($argument)
    }
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
    } catch {
        [Console]::Error.WriteLine("Error: failed to run git: $($_.Exception.Message)")
        exit 1
    }
}

function Write-GitFailure([string]$operation, $result) {
    $detail = ([string]$result.Stderr).Trim()
    if ($detail) {
        [Console]::Error.WriteLine("Error: git $operation failed with exit code $($result.ExitCode): $detail")
    } else {
        [Console]::Error.WriteLine("Error: git $operation failed with exit code $($result.ExitCode)")
    }
}

# 1. Parse CLI arguments
$rawOwned = [System.Collections.Generic.List[string]]::new()
$rawFrozen = [System.Collections.Generic.List[string]]::new()
$baseline = $null

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
    elseif ($arg -eq '--baseline' -or $arg -eq '-baseline') {
        if ($null -ne $baseline -or $i + 1 -ge $args.Count) {
            [Console]::Error.WriteLine("Error: --baseline requires exactly one value")
            exit 1
        }
        $val = [string]$args[$i + 1]
        if ([string]::IsNullOrEmpty($val) -or $val.StartsWith('-')) {
            [Console]::Error.WriteLine("Error: --baseline requires a value")
            exit 1
        }
        $baseline = $val
        $i += 2
    }
    elseif ($arg.StartsWith('--baseline=') -or $arg.StartsWith('-baseline=')) {
        if ($null -ne $baseline) {
            [Console]::Error.WriteLine("Error: --baseline requires exactly one value")
            exit 1
        }
        $val = $arg.Substring($arg.IndexOf('=') + 1)
        if ([string]::IsNullOrEmpty($val)) {
            [Console]::Error.WriteLine("Error: --baseline requires a value")
            exit 1
        }
        $baseline = $val
        $i += 1
    }
    elseif ($arg -eq '-h' -or $arg -eq '--help' -or $arg -eq '-?') {
        [Console]::Error.WriteLine("Usage: check-execution-scope.ps1 --owned <path> [--owned <path> ...] [--frozen <path> ...] --baseline <revision>")
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

if ([string]::IsNullOrWhiteSpace($baseline)) {
    [Console]::Error.WriteLine("Error: --baseline is required")
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

# 4. Discover the complete final delta from Git
$insideWorkTree = Invoke-Git @('rev-parse', '--is-inside-work-tree')
if ($insideWorkTree.ExitCode -ne 0 -or $insideWorkTree.Stdout.Trim() -ne 'true') {
    Write-GitFailure 'rev-parse --is-inside-work-tree' $insideWorkTree
    exit 1
}

$resolvedBaseline = $null
if ($null -ne $baseline) {
    $baselineResult = Invoke-Git @('rev-parse', '--verify', ("{0}^{{commit}}" -f $baseline))
    $resolvedBaseline = $baselineResult.Stdout.Trim()
    if ($baselineResult.ExitCode -ne 0 -or $resolvedBaseline -notmatch '^[0-9a-fA-F]{40,64}$') {
        Write-GitFailure "rev-parse --verify $baseline" $baselineResult
        if ($baselineResult.ExitCode -eq 0) {
            [Console]::Error.WriteLine('Error: supplied baseline did not resolve to a commit')
        }
        exit 1
    }
}

$statusResult = Invoke-Git @('-c', 'core.quotepath=false', 'status', '--porcelain=v1', '-z', '-uall')
if ($statusResult.ExitCode -ne 0) {
    Write-GitFailure 'status --porcelain=v1 -z -uall' $statusResult
    exit $statusResult.ExitCode
}

function Add-TouchedPath($paths, [string]$path) {
    $normalized = Normalize-Path $path
    if ($normalized) {
        $paths.Add($normalized) | Out-Null
    }
}

function Add-StatusPaths($paths, [string]$rawOutput) {
    if ([string]::IsNullOrEmpty($rawOutput)) { return }
    $tokens = $rawOutput.Split([char]0)
    $index = 0
    while ($index -lt $tokens.Length) {
        $entry = $tokens[$index]
        if ([string]::IsNullOrEmpty($entry)) { $index++; continue }
        if ($entry.Length -lt 4) { throw 'Malformed NUL-delimited git status output' }
        $statusX = $entry[0]
        $statusY = $entry[1]
        Add-TouchedPath $paths $entry.Substring(3)
        if ($statusX -eq 'R' -or $statusX -eq 'C' -or $statusY -eq 'R' -or $statusY -eq 'C') {
            $index++
            if ($index -ge $tokens.Length -or [string]::IsNullOrEmpty($tokens[$index])) {
                throw 'Malformed NUL-delimited git status rename output'
            }
            Add-TouchedPath $paths $tokens[$index]
        }
        $index++
    }
}

function Add-DiffPaths($paths, [string]$rawOutput) {
    if ([string]::IsNullOrEmpty($rawOutput)) { return }
    $tokens = $rawOutput.Split([char]0)
    $index = 0
    while ($index -lt $tokens.Length) {
        $status = $tokens[$index]
        if ([string]::IsNullOrEmpty($status)) { $index++; continue }
        if ($index + 1 -ge $tokens.Length -or [string]::IsNullOrEmpty($tokens[$index + 1])) {
            throw 'Malformed NUL-delimited git diff output'
        }
        Add-TouchedPath $paths $tokens[$index + 1]
        if ($status[0] -eq 'R' -or $status[0] -eq 'C') {
            if ($index + 2 -ge $tokens.Length -or [string]::IsNullOrEmpty($tokens[$index + 2])) {
                throw 'Malformed NUL-delimited git diff rename output'
            }
            Add-TouchedPath $paths $tokens[$index + 2]
            $index += 3
        } else {
            $index += 2
        }
    }
}

$touchedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
try {
    Add-StatusPaths $touchedPaths $statusResult.Stdout
    if ($null -ne $resolvedBaseline) {
        $diffResult = Invoke-Git @('-c', 'core.quotepath=false', 'diff', '--name-status', '-z', '--find-renames', $resolvedBaseline)
        if ($diffResult.ExitCode -ne 0) {
            Write-GitFailure "diff --name-status -z --find-renames $resolvedBaseline" $diffResult
            exit $diffResult.ExitCode
        }
        Add-DiffPaths $touchedPaths $diffResult.Stdout
    }
} catch {
    [Console]::Error.WriteLine("Error: $($_.Exception.Message)")
    exit 1
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
