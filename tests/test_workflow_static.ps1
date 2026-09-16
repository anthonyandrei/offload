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
$context = [IO.File]::ReadAllText((Join-Path $root 'CONTEXT.md'))
$adr = [IO.File]::ReadAllText((Join-Path $root 'docs/adr/0015-prefer-quality-first-routing-within-a-reasonable-relative-price.md'))
$research = [IO.File]::ReadAllText((Join-Path $root 'docs/research/2026-09-07-benchmark-references-for-runtime-routing.md'))
$ciPath = Join-Path $root '.github/workflows/ci.yml'
$ci = [IO.File]::ReadAllText($ciPath)

foreach ($workClass in @(
    'repository reconnaissance', 'analysis', 'test investigation', 'implementation',
    'research', 'transformations', 'artifact-producing work',
    'independently executable long-running work'
)) {
    Assert-Contains $skill $workClass "SKILL.md names bounded work class: $workClass"
    Assert-Contains $readme $workClass "README.md names bounded work class: $workClass"
}
foreach ($phrase in @('bounded', 'runtime', 'acceptance criteria', 'launch', 'unfinished', 'orchestrator', 'disposable', 'citation', 'inference', 'nested', 'external vendor', 'quality', 'price', 'escalation', 'benchmark', 'usage')) {
    Assert-Contains $skill $phrase "SKILL.md states $phrase"
}
foreach ($phrase in @('runtime', 'benchmark', 'launch', 'unfinished', 'isolated', 'citation', 'inference', 'external vendor', 'quality', 'price', 'escalation', 'usage')) {
    Assert-Contains $readme $phrase "README.md states $phrase"
}
foreach ($phrase in @(
    'best matches the task', 'exact model and reasoning effort', 'most accurate candidate',
    'same benchmark context', 'price is a clear outlier', 'material quality advantage',
    'not a fixed multiplier', 'current runtime or published pricing',
    'benchmark cost is comparative evidence', 'If several benchmarks apply',
    'Do not combine incomparable benchmarks or scores into a synthetic ranking'
)) {
    Assert-Contains $skill $phrase "SKILL.md states routing rule: $phrase"
}
Assert-Contains $readme 'most accurate capable model and effort' 'README.md states quality-first routing'
Assert-Contains $readme 'clear price outlier' 'README.md states relative price guardrail'
Assert-NotContains $skill 'lightest model' 'SKILL.md omits superseded lightest-model preference'
Assert-NotContains $readme 'lightest capable model' 'README.md omits superseded lightest-model preference'
Assert-Contains $skill 'Open-ended, indefinite, or tightly interactive work stays local.' 'SKILL.md keeps open-ended and tightly interactive work local'
Assert-Contains $readme 'Open-ended or tightly interactive work stays local.' 'README.md keeps open-ended and tightly interactive work local'
Assert-Contains $skill 'Every assignment uses the same shape: objective, scope, acceptance criteria, deliverables, and authority.' 'SKILL.md defines the generic assignment shape'
Assert-Contains $readme 'objective, scope, acceptance criteria, deliverables, and authority' 'README.md repeats the generic assignment shape'
Assert-Contains $skill 'shared authority and acceptance criteria' 'SKILL.md permits shared-authority phases'
Assert-Contains $skill 'Genuinely independent work keeps separate boundaries' 'SKILL.md separates independent work'
Assert-True ($skill -match '(?is)version-matched official documentation.*installed version and native help.*real launch is the definitive admission check') 'SKILL.md states runtime discovery precedence'
Assert-True ($skill -match '(?is)opens the actual URL.*latest relevant result.*adjudicating candidates') 'SKILL.md requires benchmark-first routing'
Assert-Contains $skill 'benchmark-first routing' 'SKILL.md names benchmark-first routing'
Assert-Contains $skill 'primary quality evidence' 'SKILL.md makes benchmark results primary quality evidence'
Assert-Contains $skill 'Use judgment to interpret the benchmark result against runtime facts, not to bypass it' 'SKILL.md bases judgment on benchmark results'
Assert-Contains $skill 'explicit evidence gap' 'SKILL.md records benchmark evidence gaps'
Assert-Contains $skill 'benchmark URL' 'SKILL.md records the benchmark URL'
Assert-Contains $skill 'access date' 'SKILL.md records benchmark access date'
Assert-Contains $skill 'departure reason' 'SKILL.md records routing departures'
Assert-Contains $skill 'fully pinned vendor, model, and effort' 'SKILL.md exempts fully pinned choices'
Assert-Contains $skill 'transient launch record' 'SKILL.md keeps launch facts transient'
foreach ($launchFact in @('selected tool', 'installed version', 'documentation source', 'invocation shape', 'model or effort setting', 'usage observation', 'launch result')) {
    Assert-Contains $skill $launchFact "SKILL.md reports launch fact: $launchFact"
}
foreach ($secretTerm in @('credentials', 'tokens', 'secrets')) {
    Assert-Contains $skill $secretTerm "SKILL.md excludes $secretTerm from run records"
}
Assert-Contains $skill 'confirmed exhaustion removes a candidate' 'SKILL.md handles confirmed exhaustion'
Assert-Contains $skill 'unknown or stale evidence does not block launch' 'SKILL.md treats unknown evidence as non-blocking'
Assert-Contains $skill 'named vendor' 'SKILL.md honors named vendors'
Assert-Contains $skill 'exact model' 'SKILL.md honors exact models'
Assert-Contains $skill 'infrastructure failures' 'SKILL.md identifies infrastructure failures'
Assert-Contains $skill 'exactly one automatic escalation' 'SKILL.md limits quality escalation'
Assert-Contains $skill 'cleanup status' 'SKILL.md requires cleanup status in the final report'
Assert-Contains $skill 'every terminal path' 'SKILL.md requires cleanup on every terminal path'
Assert-Contains $skill 'exact path' 'SKILL.md reports the cleanup path on failure'
Assert-Contains $readme 'actual task-matched benchmark URL' 'README.md requires the actual benchmark URL'
Assert-Contains $readme 'every automatic initial selection and quality escalation' 'README.md applies benchmark-first routing to every automatic route'
Assert-Contains $context 'Benchmark-first routing' 'CONTEXT.md defines benchmark-first routing'
Assert-Contains $adr 'Clarified: 2026-09-16' 'ADR 0015 records the clarification date'
Assert-Contains $research 'every automatic initial selection and quality escalation' 'benchmark research requires every automatic route to check the URL'

$expectedDescription = 'Outsource bounded repository reconnaissance, analysis, test investigation, implementation, research, transformations, artifact-producing work, and independently executable long-running work to an external vendor. Use when the user explicitly asks to offload, names an external vendor or model, approves outsourcing after the orchestrator defines a bounded assignment, or a bounded task would otherwise be delegated to a native subagent and needs an external alternative.'
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
    'publication-compatibility', 'schema_version', 'vendor catalog', 'command table',
    'model matrix', 'provider interface',
    'persistent usage telemetry', 'performance ledger', 'quota protocol',
    'role matrix', 'routing algorithm'
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
