#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:TotalTests = 0
function Pass([string]$Name) { [void]($script:TotalTests++); [Console]::Out.WriteLine("ok - $Name") }
function Assert-True([bool]$Condition, [string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; Pass $Name }

$root = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $root 'tests/fixtures/fake-worker-failure.ps1'
$skill = [IO.File]::ReadAllText((Join-Path $root 'SKILL.md'))
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('offload-failure-ps-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null

try {
    $counter = Join-Path $tempRoot 'counter.txt'
    & pwsh -NoProfile -NonInteractive -File $fixture $counter
    $exitCode = $LASTEXITCODE
    Assert-True ($exitCode -eq 17) 'failed worker returns its launch failure'
    Assert-True ([IO.File]::ReadAllText($counter).Trim() -eq '1') 'failed worker is invoked once'
    Assert-True ($skill.Contains('unfinished assignment')) 'contract returns unfinished work to the orchestrator'
    Assert-True ($skill.Contains('silent provider switch')) 'contract forbids silent provider switching'
    Assert-True ($skill.Contains('second automatic attempt')) 'contract forbids an automatic second attempt'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

[Console]::Out.WriteLine("all powershell worker failure checks passed ($($script:TotalTests) tests)")
