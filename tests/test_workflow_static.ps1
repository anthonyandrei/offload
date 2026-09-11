#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:TotalTests = 0

function Pass([string]$Name) {
    [void]($script:TotalTests++)
    [Console]::Out.WriteLine("ok - $Name")
}

function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    Pass $Name
}

function Assert-False([bool]$Condition, [string]$Name) {
    Assert-True (-not $Condition) $Name
}

function Assert-Contains([string]$Content, [string]$Needle, [string]$Name) {
    Assert-True ($Content.ToLowerInvariant().Contains($Needle.ToLowerInvariant())) $Name
}

function Assert-NotContains([string]$Content, [string]$Needle, [string]$Name) {
    Assert-False ($Content.Contains($Needle)) $Name
}

$root = Split-Path -Parent $PSScriptRoot
$activePaths = @(
    (Join-Path $root 'SKILL.md'),
    (Join-Path $root 'README.md')
)
$activeContent = @{}
foreach ($path in $activePaths) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "active file exists: $([IO.Path]::GetFileName($path))"
    $activeContent[$path] = [IO.File]::ReadAllText($path)
}

$skill = $activeContent[$activePaths[0]]
$readme = $activeContent[$activePaths[1]]
$ciPath = Join-Path $root '.github/workflows/ci.yml'
$ci = [IO.File]::ReadAllText($ciPath)

foreach ($phrase in @('bounded', 'runtime', 'acceptance criteria', 'launch', 'unfinished', 'orchestrator', 'disposable', 'citation', 'inference', 'nested', 'external vendor', 'lightest', 'escalation', 'benchmark', 'usage')) {
    Assert-Contains $skill $phrase "SKILL.md states $phrase"
}
foreach ($phrase in @('runtime', 'benchmark', 'launch', 'unfinished', 'isolated', 'citation', 'inference', 'external vendor', 'lightest', 'escalation', 'usage')) {
    Assert-Contains $readme $phrase "README.md states $phrase"
}

$expectedDescription = 'Outsource bounded implementation or research work to an external vendor. Use when the user explicitly asks to offload, names an external vendor or model, approves outsourcing after the orchestrator defines a bounded assignment, or a bounded task would otherwise be delegated to a native subagent and needs an external alternative.'
Assert-Contains $skill "description: $expectedDescription" 'SKILL.md uses exact settled frontmatter description'

$frontmatterMatch = [regex]::Match($skill, '(?s)^---\r?\n(.*?)\r?\n---')
Assert-True $frontmatterMatch.Success 'SKILL.md has YAML frontmatter'
Assert-False ($frontmatterMatch.Groups[1].Value.Contains('Do NOT')) 'SKILL.md frontmatter omits negative Do NOT sentence'

foreach ($stalePhrase in @('native multi-agent workflow', 'two or more', 'delegation lanes', 'proactive offer gate', 'two-lane', 'host instructions', 'host-approved', 'three independently gated', 'at least three', 'silent provider switch', 'second automatic attempt')) {
    Assert-NotContains $skill $stalePhrase "SKILL.md omits stale offer phrase: $stalePhrase"
    Assert-NotContains $readme $stalePhrase "README.md omits stale offer phrase: $stalePhrase"
}

foreach ($content in @($skill, $readme)) {
    Assert-NotContains $content '```' 'active contract has no copied command blocks'
}

$removedConcepts = @(
    'model-policy.json', 'modes/', 'modes\', 'dispatch-worker', 'run-agy-json',
    'run-claude-json', 'run-codex-json', 'select-compatible-worker',
    'capacity-ledger', 'resource-ledger', 'routing-outcomes', 'worker-adapter',
    'publication-compatibility', 'schema_version'
)
foreach ($pair in $activeContent.GetEnumerator()) {
    foreach ($term in $removedConcepts) {
        Assert-NotContains $pair.Value $term "$([IO.Path]::GetFileName($pair.Key)) omits $term"
    }
    Assert-False ($pair.Value -match '(?i)(^|[^a-z])(agy|claude|codex|gemini)([^a-z]|$)') "$([IO.Path]::GetFileName($pair.Key)) omits copied vendor names"
}

foreach ($source in @(
    'https://deepswe.datacurve.ai/', 'https://livebench.ai/',
    'https://drb.futuresearch.ai/', 'https://deepresearch-bench.github.io/',
    'https://artificialanalysis.ai/models'
)) {
    Assert-Contains $skill $source "SKILL.md retains benchmark source: $source"
}

$removedPaths = @(
    'model-policy.json', 'modes/execution.md', 'modes/repo-research.md', 'modes/web-research.md',
    'scripts/dispatch-worker.ps1', 'scripts/run-agy-json.ps1', 'scripts/run-claude-json.ps1',
    'scripts/run-codex-json.ps1', 'scripts/select-compatible-worker.ps1',
    'scripts/capacity-ledger.ps1', 'scripts/resource-ledger.ps1', 'docs/specs/0001-platform-agnostic-workflows.md'
)
foreach ($relative in $removedPaths) {
    Assert-False (Test-Path -LiteralPath (Join-Path $root $relative)) "removed path is absent: $relative"
}

foreach ($relative in @(
    'scripts/check-execution-scope.ps1', 'scripts/check-execution-scope.sh',
    'scripts/execution-workspace.ps1', 'scripts/execution-workspace.sh',
    'scripts/make-research-workspace.ps1', 'scripts/make-research-workspace.sh',
    'scripts/cleanup-research-workspace.ps1', 'scripts/cleanup-research-workspace.sh',
    'tests/test_execution_scope.ps1', 'tests/test_execution_scope.sh',
    'tests/test_execution_workspace.ps1', 'tests/test_execution_workspace.sh',
    'tests/test_research_workspace.ps1', 'tests/test_research_workspace.sh',
    'tests/test_research_acceptance.ps1', 'tests/test_research_acceptance.sh',
    'tests/test_worker_failure.ps1', 'tests/test_worker_failure.sh',
    'tests/test_repository_consistency.ps1', 'tests/test_repository_consistency.sh'
)) {
    Assert-True (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf) "required package path exists: $relative"
}

foreach ($oldTest in @('test_model_routing', 'test_agy_preflight', 'test_worker_adapter_contract', 'test_research_modes', 'test_resource_ledger')) {
    Assert-NotContains $ci $oldTest "CI omits removed test: $oldTest"
}
foreach ($testName in @('test_workflow_static', 'test_execution_scope', 'test_execution_workspace', 'test_research_workspace', 'test_research_acceptance', 'test_worker_failure', 'test_repository_consistency')) {
    Assert-Contains $ci $testName "CI runs current test: $testName"
}

[Console]::Out.WriteLine("all workflow static checks passed ($($script:TotalTests) tests)")
