#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

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
    exit 1
}

function Assert-True([bool]$condition, [string]$name, [string]$reason = "") {
    if ($condition) { Pass $name } else { Fail $name $(if ($reason) { $reason } else { "Condition false" }) }
}

function Assert-False([bool]$condition, [string]$name, [string]$reason = "") {
    if (-not $condition) { Pass $name } else { Fail $name $(if ($reason) { $reason } else { "Condition true" }) }
}

function Assert-Equal($actual, $expected, [string]$name) {
    if ($actual -eq $expected) { Pass $name } else { Fail $name "Expected '$expected', got '$actual'" }
}

$RootDir = Split-Path -Parent $PSScriptRoot
$SkillMd = Join-Path $RootDir 'SKILL.md'
$ExecMd = Join-Path $RootDir 'modes/execution.md'
$RepoMd = Join-Path $RootDir 'modes/repo-research.md'
$WebMd = Join-Path $RootDir 'modes/web-research.md'
$ReadmeMd = Join-Path $RootDir 'README.md'
$AgentsMd = Join-Path $RootDir 'AGENTS.md'
$PolicyJson = Join-Path $RootDir 'model-policy.json'

# 1. Line count check: SKILL.md must remain strictly under 500 lines
$skillLines = (Get-Content -LiteralPath $SkillMd).Count
Assert-True ($skillLines -lt 500) "line-count: SKILL.md is under 500 lines (actual: $skillLines)"

# 2. SKILL.md owns shared routing, launcher contract, preflight, recovery, quota handoff, routing-outcomes.json
$skillContent = Get-Content -LiteralPath $SkillMd -Raw
Assert-True ($skillContent -match 'Preflight model availability check') "skill: documents preflight model check"
Assert-True ($skillContent -match 'Policy installation, updates, and revert') "skill: documents policy lifecycle"
Assert-True ($skillContent -match 'Shared model routing and launcher contract') "skill: owns shared routing section"
Assert-True ($skillContent -match 'Shared recovery, retry accounting, and failure handling') "skill: owns shared recovery section"
Assert-True ($skillContent -match 'Stable worker IDs and retry ceiling') "skill: documents stable worker IDs and retry ceiling"
Assert-True ($skillContent -match 'Immediate quota handoff') "skill: documents immediate quota handoff"
Assert-True ($skillContent -match 'routing-outcomes\.json') "skill: documents routing-outcomes.json schema and fields"
Assert-True ($skillContent -match 'gemini-3.8-flash-low' -and $skillContent -match 'gemini-3.8-flash-high') "skill: specifies Gemini 3.8 Flash baseline defaults"

# 3. Every mode references SKILL.md shared section
foreach ($pair in @(
    @{ Path = $ExecMd; Name = "execution.md" },
    @{ Path = $RepoMd; Name = "repo-research.md" },
    @{ Path = $WebMd; Name = "web-research.md" }
)) {
    $content = Get-Content -LiteralPath $pair.Path -Raw
    Assert-True ($content -match 'SKILL\.md' -or $content -match '\.\./SKILL\.md') "$($pair.Name) references shared SKILL.md contract"
    Assert-True ($content -match 'preflight' -or $content -match 'Preflight') "$($pair.Name) mentions preflight check"
    Assert-True ($content -match 'routing-outcomes\.json') "$($pair.Name) mentions routing-outcomes.json"
}

# 4. Mode dispatches must use --role and must not pass --model or --effort in command blocks
foreach ($pair in @(
    @{ Path = $ExecMd; Name = "execution.md" },
    @{ Path = $RepoMd; Name = "repo-research.md" },
    @{ Path = $WebMd; Name = "web-research.md" }
)) {
    $content = Get-Content -LiteralPath $pair.Path -Raw
    $fencedMatches = [regex]::Matches($content, '```(?:bash|powershell)\r?\n((?:(?!```)[\s\S])*?)\r?\n```')
    foreach ($m in $fencedMatches) {
        $block = $m.Groups[1].Value
        if ($block -match 'run-agy-json') {
            Assert-True ($block -match '--role') "$($pair.Name) launcher block includes --role"
            Assert-False ($block -match '--model') "$($pair.Name) launcher block does not pass --model"
            Assert-False ($block -match '--effort') "$($pair.Name) launcher block does not pass --effort"
        }
    }
}

# 5. No active gemini-3.7-flash defaults; all 3.7 mentions are explicitly historical
foreach ($pair in @(
    @{ Path = $SkillMd; Name = "SKILL.md" },
    @{ Path = $ExecMd; Name = "execution.md" },
    @{ Path = $RepoMd; Name = "repo-research.md" },
    @{ Path = $WebMd; Name = "web-research.md" },
    @{ Path = $ReadmeMd; Name = "README.md" },
    @{ Path = $AgentsMd; Name = "AGENTS.md" }
)) {
    $lines = Get-Content -LiteralPath $pair.Path
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '3\.7') {
            Assert-True ($line -match 'historical|Historical|downgrade to 3\.7') "$($pair.Name): line $($i+1) 3.7 reference is historical or caution against downgrade: $line"
        }
    }
}

# 6. Absence of stale safety claims in agent-facing documentation
foreach ($pair in @(
    @{ Path = $SkillMd; Name = "SKILL.md" },
    @{ Path = $ExecMd; Name = "execution.md" },
    @{ Path = $RepoMd; Name = "repo-research.md" },
    @{ Path = $WebMd; Name = "web-research.md" },
    @{ Path = $ReadmeMd; Name = "README.md" },
    @{ Path = $AgentsMd; Name = "AGENTS.md" }
)) {
    $content = Get-Content -LiteralPath $pair.Path -Raw
    Assert-False ($content -match 'plan mode[^.]{0,80}(write barrier|prevents? writes?|cannot write)') "$($pair.Name): no plan mode write barrier myth"
    Assert-False ($content -match '--add-dir[^.]{0,80}(confines? writes?|sandboxes?|prevents? writes?)') "$($pair.Name): no add-dir confinement myth"
}

# 7. Model policy matches role definitions
$policy = Get-Content -LiteralPath $PolicyJson -Raw | ConvertFrom-Json
Assert-Equal $policy.schema_version 1 "policy: schema_version is 1"
Assert-Equal $policy.roles.scout.default_model "gemini-3.8-flash-low" "policy: scout default model"
Assert-Equal $policy.roles.'gate-author'.default_model "gemini-3.8-flash-high" "policy: gate-author default model"
Assert-Equal $policy.roles.implementer.default_model "gemini-3.8-flash-high" "policy: implementer default model"
Assert-Equal $policy.roles.reviewer.default_model "gemini-3.8-flash-high" "policy: reviewer default model"
Assert-Equal $policy.roles.researcher.default_model "gemini-3.8-flash-high" "policy: researcher default model"
Assert-Equal $policy.roles.synthesizer.default_model "gemini-3.8-flash-high" "policy: synthesizer default model"
Assert-Equal $policy.roles.auditor.default_model "gemini-3.8-flash-high" "policy: auditor default model"

# 8. Web research documents check-citation-audit helpers and exact coverage rules
$webContent = Get-Content -LiteralPath $WebMd -Raw
Assert-True ($webContent -match 'check-citation-audit\.sh') "web-research.md references check-citation-audit.sh"
Assert-True ($webContent -match 'check-citation-audit\.ps1') "web-research.md references check-citation-audit.ps1"
Assert-True ($webContent -match 'Audit verification and acceptance rules') "web-research.md documents audit verification rules"
Assert-True ($webContent -match 'Required claim/citation pair coverage') "web-research.md documents pair coverage requirement"
Assert-True ($webContent -match 'Ledger with no auditable pairs') "web-research.md documents zero-pair branch"

[Console]::Out.WriteLine("all workflow static checks passed ($script:TotalTests tests)")
exit 0
