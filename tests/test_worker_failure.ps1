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
    $launchCounter = Join-Path $tempRoot 'launch-counter.txt'
    & pwsh -NoProfile -NonInteractive -File $fixture $launchCounter 'launch'
    $exitCode = $LASTEXITCODE
    Assert-True ($exitCode -eq 17) 'failed worker returns its launch failure'
    Assert-True ([IO.File]::ReadAllText($launchCounter).Trim() -eq '1') 'failed worker is invoked once without provider switch'

    $qualityCounter = Join-Path $tempRoot 'quality-counter.txt'
    & pwsh -NoProfile -NonInteractive -File $fixture $qualityCounter 'quality-escalate'
    $attempt1Exit = $LASTEXITCODE
    Assert-True ($attempt1Exit -eq 20) 'initial worker failure reports quality-gate failure'
    Assert-True ([IO.File]::ReadAllText($qualityCounter).Trim() -eq '1') 'initial worker invoked once'

    & pwsh -NoProfile -NonInteractive -File $fixture $qualityCounter 'quality-escalate'
    $attempt2Exit = $LASTEXITCODE
    Assert-True ($attempt2Exit -eq 20) 'escalation worker reports quality-gate failure'
    Assert-True ([IO.File]::ReadAllText($qualityCounter).Trim() -eq '2') 'escalation worker invoked on quality failure'

    Assert-True ($skill.Contains('unfinished assignment')) 'contract returns unfinished work to the orchestrator'
    Assert-True ($skill.Contains('without automatic provider switching')) 'contract forbids automatic provider switching on infrastructure failure'
    Assert-True ($skill.Contains('quality-gate failure') -and $skill.Contains('exactly one automatic escalation')) 'contract permits one automatic escalation on quality-gate failure'
    Assert-True ($skill.Contains('smallest credible improvement')) 'escalation chooses smallest credible improvement'
    Assert-True ($skill.Contains('cross-vendor escalation')) 'generic approval permits cross-vendor escalation'
    Assert-True ($skill.Contains('constrains escalation to that vendor')) 'named vendor constrains escalation'
    Assert-True ($skill.Contains('exact model remains pinned')) 'named exact model remains pinned'
    Assert-True ($skill.Contains('No third automatic attempt is permitted')) 'contract forbids a third automatic attempt'
    Assert-True ($skill.Contains('Finish the assignment locally when safe')) 'orchestrator finishes locally when safe'
    Assert-True ($skill.Contains('usable partial result') -and $skill.Contains('precise blocker')) 'orchestrator reports partial result and blocker when local completion is unsafe'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

[Console]::Out.WriteLine("all powershell worker failure checks passed ($($script:TotalTests) tests)")
