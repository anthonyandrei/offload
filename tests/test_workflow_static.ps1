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

# 2a. Diff-gated reviews use one recorded artifact, not the live checkout
$executionContent = Get-Content -LiteralPath $ExecMd -Raw
Assert-True ($executionContent -match 'verify-export --manifest') "execution.md creates a recorded review artifact"
Assert-True ($executionContent -match 'patch_file') "execution.md passes the recorded artifact to the reviewer"
Assert-True ($executionContent -match 'patch_digest') "execution.md verifies the recorded artifact digest"
Assert-True ($executionContent -match 'sha256sum' -and $executionContent -match 'Get-FileHash') "execution.md rechecks the recorded artifact digest"
Assert-True ($executionContent -match 'review artifact export failed') "execution.md blocks failed artifact generation"
Assert-True ($executionContent -match 'add-dir "<patch parent>"') "execution.md grants reviewer access to the artifact"
Assert-False ($executionContent -match "Run 'git diff' in this repository") "execution.md reviewer does not inspect a bare git diff"
Assert-False ($executionContent -match 'git diff \| grep -F') "execution.md quote verifier does not inspect a bare git diff"

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

# 9. Execution mode documents isolated workspaces and baseline discipline
$execContent = Get-Content -LiteralPath $ExecMd -Raw
Assert-True ($execContent -match 'execution-workspace\.sh') "execution.md references execution-workspace.sh"
Assert-True ($execContent -match 'execution-workspace\.ps1') "execution.md references execution-workspace.ps1"
Assert-True ($execContent -match 'check-execution-scope\.sh') "execution.md references check-execution-scope.sh"
Assert-True ($execContent -match 'check-execution-scope\.ps1') "execution.md references check-execution-scope.ps1"
Assert-True ($execContent -match 'check-review-verdict\.sh') "execution.md references check-review-verdict.sh"
Assert-True ($execContent -match 'check-review-verdict\.ps1') "execution.md references check-review-verdict.ps1"
Assert-True ($execContent -match 'criterion_id') "execution.md assigns stable reviewer criterion IDs"
Assert-True ($execContent -match 'exactly one verdict object for every criterion') "execution.md requires exhaustive reviewer verdicts"

# All check-execution-scope examples in execution.md must supply --baseline
$execFencedMatches = [regex]::Matches($execContent, '```(?:bash|powershell)\r?\n((?:(?!```)[\s\S])*?)\r?\n```')
foreach ($em in $execFencedMatches) {
    $block = $em.Groups[1].Value
    if ($block -match 'check-execution-scope') {
        Assert-True ($block -match '--baseline') "execution.md check-execution-scope example supplies --baseline"
    }
    if ($block -match 'run-agy-json') {
        Assert-False ($block -match '--add-dir\s+["'']?<repo root>') "execution.md launcher block does not pass <repo root> to --add-dir"
    }
}

# Acceptance criteria rules documented in execution.md
Assert-True ($execContent -match 'rejected immediately before its output can become an implementation baseline') "execution.md documents gate-author unowned edit rejection"
Assert-True ($execContent -match 'approved frozen gates') "execution.md documents implementers receive approved frozen gates"
Assert-True ($execContent -match 'newly accepted baseline') "execution.md documents overlapping tasks serialized from newly accepted baseline"
Assert-True ($execContent -match 'retain the original verification baseline') "execution.md documents retries retain original verification baseline"
Assert-True ($execContent -match 'without waiting for sibling completion') "execution.md documents immediate quota handoff without waiting for siblings"
Assert-True ($execContent -match 'Final combined gate check') "execution.md documents final combined gate check"
Assert-True ($execContent -match 'Wait for active worker processes to terminate before calling cleanup') "execution.md documents cleanup waits for active workers"

# 10. Attempt-specific artifacts and explicit accepted-attempt selection (Issue #14)
$repoContent = Get-Content -LiteralPath $RepoMd -Raw
foreach ($mode in @(
    @{ Name = 'execution.md'; Content = $execContent; Retry = '<slug>\.attempt2' },
    @{ Name = 'repo-research.md'; Content = $repoContent; Retry = '<slug>\.attempt2\.research' },
    @{ Name = 'web-research.md'; Content = $webContent; Retry = 'researcher-<angle-id>\.attempt2' }
)) {
    Assert-True ($mode.Content -match 'attempt1') "$($mode.Name) uses attempt-specific initial artifact paths"
    Assert-True ($mode.Content -match $mode.Retry) "$($mode.Name) documents distinct attempt 2 artifact paths"
    Assert-True ($mode.Content -match 'accepted_attempt') "$($mode.Name) records an explicit accepted_attempt"
}
Assert-False ($webContent -match 'synthesizer\.json') "web-research.md does not reuse synthesizer.json"
Assert-False ($webContent -match 'auditor\.json') "web-research.md does not reuse auditor.json"

# 11. Routing provenance fixture and documentation alignment (Issue #13)
$FixtureJson = Join-Path $RootDir 'tests/fixtures/routing-worker.json'
Assert-True (Test-Path -LiteralPath $FixtureJson -PathType Leaf) "workflow-static: routing fixture exists"
Assert-True ($skillContent -match 'tests/fixtures/routing-worker\.json') "SKILL.md links to routing fixture"
Assert-True ($skillContent -match 'schema_version: 1, attempts:') "SKILL.md documents routing container contract"
Assert-True ($webContent -match 'tests/fixtures/routing-worker\.json') "web-research.md links to routing fixture"
Assert-True ($webContent -match 'schema_version: 1, attempts:') "web-research.md documents routing container contract"

# 12. Vendor-neutral worker adapter boundary (Issue #31)
$AdapterDoc = Join-Path $RootDir 'docs/worker-adapter-contract.md'
$AdapterCheckerPs = Join-Path $RootDir 'scripts/check-worker-adapter.ps1'
$AdapterCheckerSh = Join-Path $RootDir 'scripts/check-worker-adapter.sh'
Assert-True (Test-Path -LiteralPath $AdapterDoc -PathType Leaf) "adapter: contract document exists"
Assert-True (Test-Path -LiteralPath $AdapterCheckerPs -PathType Leaf) "adapter: PowerShell checker exists"
Assert-True (Test-Path -LiteralPath $AdapterCheckerSh -PathType Leaf) "adapter: Bash checker exists"
$adapterContent = Get-Content -LiteralPath $AdapterDoc -Raw
foreach ($term in @('orchestrator', 'worker', 'adapter', 'execution scope check')) {
    Assert-True ($adapterContent -match [regex]::Escape($term)) "adapter: contract uses '$term'"
}
foreach ($phrase in @(
    'discover-capabilities',
    'discover-models',
    'constraint_snapshot',
    'model_selection',
    'ownership',
    'unpublished',
    'cannot widen'
)) {
    Assert-True ($adapterContent -match [regex]::Escape($phrase)) "adapter: contract documents '$phrase'"
}
Assert-True ($skillContent -match 'worker-adapter-contract\.md') "skill: links to worker adapter contract"
Assert-True ($execContent -match 'check-worker-adapter\.ps1' -and $execContent -match 'check-worker-adapter\.sh') "execution.md validates normalized adapter results"
Assert-False ($adapterContent -match '(?i)grill-with-docs[^\n]*(agy|gemini|codex|claude)') "adapter: host skill guidance is vendor-neutral"

[Console]::Out.WriteLine("all workflow static checks passed ($script:TotalTests tests)")
exit 0
