#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:TotalTests = 0
function Pass([string]$Name) { [void]($script:TotalTests++); [Console]::Out.WriteLine("ok - $Name") }
function Assert-True([bool]$Condition, [string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; Pass $Name }
function Assert-False([bool]$Condition, [string]$Name) { Assert-True (-not $Condition) $Name }

$root = Split-Path -Parent $PSScriptRoot
$checker = Join-Path $root 'scripts/check-execution-scope.ps1'
$pwsh = (Get-Command pwsh).Source
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('offload-scope-ps-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null

function Invoke-Checker([string]$Repo, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.WorkingDirectory = $Repo
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $checker) + $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

try {
    $repo = Join-Path $tempRoot 'repo'
    [IO.Directory]::CreateDirectory($repo) | Out-Null
    & git -C $repo init -q
    & git -C $repo config user.name 'Test User'
    & git -C $repo config user.email 'test@example.com'
    [IO.File]::WriteAllText((Join-Path $repo 'owned.txt'), "owned`n")
    [IO.File]::WriteAllText((Join-Path $repo 'unowned.txt'), "unowned`n")
    [IO.File]::WriteAllText((Join-Path $repo 'frozen.txt'), "frozen`n")
    & git -C $repo add .
    & git -C $repo commit -q -m initial
    $baseline = (& git -C $repo rev-parse HEAD).Trim()

    $clean = Invoke-Checker $repo @('--baseline', $baseline, '--owned', 'owned.txt')
    Assert-True ($clean.ExitCode -eq 0) 'clean worktree passes'

    [IO.File]::WriteAllText((Join-Path $repo 'owned.txt'), "owned changed`n")
    $owned = Invoke-Checker $repo @('--baseline', $baseline, '--owned', 'owned.txt')
    Assert-True ($owned.ExitCode -eq 0) 'owned change passes'

    [IO.File]::WriteAllText((Join-Path $repo 'unowned.txt'), "unowned changed`n")
    $unowned = Invoke-Checker $repo @('--baseline', $baseline, '--owned', 'owned.txt')
    Assert-False ($unowned.ExitCode -eq 0) 'unowned change fails'
    Assert-True ($unowned.Stdout.Contains('unowned.txt')) 'unowned path is reported'

    [IO.File]::WriteAllText((Join-Path $repo 'unowned.txt'), "unowned`n")
    [IO.File]::WriteAllText((Join-Path $repo 'frozen.txt'), "frozen changed`n")
    $frozen = Invoke-Checker $repo @('--baseline', $baseline, '--owned', 'owned.txt', '--frozen', 'frozen.txt')
    Assert-False ($frozen.ExitCode -eq 0) 'frozen change fails'
    Assert-True ($frozen.Stdout.Contains('frozen.txt')) 'frozen path is reported'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

[Console]::Out.WriteLine("all powershell execution scope checks passed ($($script:TotalTests) tests)")
