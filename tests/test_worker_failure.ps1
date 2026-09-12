#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:TotalTests = 0
function Pass([string]$Name) { [void]($script:TotalTests++); [Console]::Out.WriteLine("ok - $Name") }
function Assert-True([bool]$Condition, [string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; Pass $Name }
function Assert-False([bool]$Condition, [string]$Name) { Assert-True (-not $Condition) $Name }

$root = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $root 'tests/fixtures/fake-worker-failure.ps1'
$cleanup = Join-Path $root 'scripts/cleanup-research-workspace.ps1'
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

    $outcomes = @(
        [pscustomobject]@{ Name = 'successful-completion'; Mode = 'success'; ExitCode = 0 },
        [pscustomobject]@{ Name = 'launch-failure'; Mode = 'launch-failure'; ExitCode = 17 },
        [pscustomobject]@{ Name = 'timeout'; Mode = 'timeout'; ExitCode = 124 },
        [pscustomobject]@{ Name = 'quality-gate-failure'; Mode = 'quality-failure'; ExitCode = 20 },
        [pscustomobject]@{ Name = 'escalation-failure'; Mode = 'escalation-failure'; ExitCode = 30 },
        [pscustomobject]@{ Name = 'local-finish'; Mode = 'local-finish'; ExitCode = 0 }
    )
    foreach ($outcome in $outcomes) {
        $outcomeCounter = Join-Path $tempRoot ($outcome.Name + '-counter.txt')
        $lifecycleWorkspace = Join-Path $tempRoot ($outcome.Name + '-workspace')
        [IO.Directory]::CreateDirectory($lifecycleWorkspace) | Out-Null
        [IO.File]::WriteAllText((Join-Path $lifecycleWorkspace '.offload-research-workspace'), "offload-research-workspace-v2`n")
        & pwsh -NoProfile -NonInteractive -File $fixture $outcomeCounter $outcome.Mode $lifecycleWorkspace
        $outcomeExit = $LASTEXITCODE
        Assert-True ($outcomeExit -eq $outcome.ExitCode) "$($outcome.Name) has a deterministic terminal outcome"
        Assert-True ([IO.File]::ReadAllText($outcomeCounter).Trim() -eq '1') "$($outcome.Name) records one bounded run"
        $capturedResult = ''
        foreach ($artifact in @('deliverables', 'diffs', 'evidence', 'transient-run-facts')) {
            $artifactPath = Join-Path $lifecycleWorkspace ($artifact + '.txt')
            Assert-True (Test-Path -LiteralPath $artifactPath -PathType Leaf) "$($outcome.Name) captures $artifact before cleanup"
            $capturedValue = [IO.File]::ReadAllText($artifactPath).Trim()
            Assert-True (-not [string]::IsNullOrWhiteSpace($capturedValue)) "$($outcome.Name) captures non-empty $artifact"
            $capturedResult += $capturedValue
        }
        $cleanupOutput = & pwsh -NoProfile -NonInteractive -File $cleanup --workspace $lifecycleWorkspace 2>&1
        $cleanupExit = $LASTEXITCODE
        Assert-True ($cleanupExit -eq 0) "$($outcome.Name) cleanup succeeds"
        Assert-False (Test-Path -LiteralPath $lifecycleWorkspace) "$($outcome.Name) cleanup removes its workspace"
        Assert-True ($capturedResult.Contains($outcome.Mode)) "$($outcome.Name) retains the pre-cleanup capture"
    }

    foreach ($field in @('deliverables', 'diffs', 'evidence', 'transient run facts')) {
        Assert-True ($skill.Contains($field)) "lifecycle report captures $field"
    }
    Assert-True ($skill.Contains('before cleanup')) 'lifecycle report captures fields before cleanup'
    foreach ($outcome in @('success', 'launch failure', 'timeout', 'quality-gate failure', 'escalation failure', 'local finish')) {
        Assert-True ($skill.Contains($outcome)) "contract names terminal outcome: $outcome"
    }

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
