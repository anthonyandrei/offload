#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:TotalTests = 0
function Pass([string]$Name) { [void]($script:TotalTests++); [Console]::Out.WriteLine("ok - $Name") }
function Assert-True([bool]$Condition, [string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; Pass $Name }
function Assert-False([bool]$Condition, [string]$Name) { Assert-True (-not $Condition) $Name }

$root = Split-Path -Parent $PSScriptRoot
$activeRelative = @(
    'SKILL.md', 'README.md', '.github/workflows/ci.yml'
)
$activeContent = foreach ($relative in $activeRelative) {
    $path = Join-Path $root $relative
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "active repository file exists: $relative"
    [IO.File]::ReadAllText($path)
}

$removedReferences = @(
    'model-policy.json', 'modes/execution.md', 'modes/repo-research.md', 'modes/web-research.md',
    'scripts/dispatch-worker.ps1', 'scripts/dispatch-worker.sh', 'scripts/run-agy-json.ps1',
    'scripts/run-agy-json.sh', 'scripts/run-claude-json.ps1', 'scripts/run-claude-json.sh',
    'scripts/run-codex-json.ps1', 'scripts/run-codex-json.sh', 'scripts/select-compatible-worker.ps1',
    'scripts/select-compatible-worker.sh', 'scripts/capacity-ledger.ps1', 'scripts/resource-ledger.ps1',
    'docs/worker-adapter-contract.md', 'docs/contracts/publication-compatibility.md'
)
$staleArchitecture = @(
    'vendor catalog', 'command table', 'model matrix', 'provider interface',
    'persistent usage telemetry', 'performance ledger',
    'quota protocol', 'role matrix', 'routing algorithm'
)
foreach ($content in $activeContent) {
    foreach ($reference in $removedReferences) {
        Assert-False ($content.Contains($reference)) "active docs omit removed reference: $reference"
    }
    foreach ($term in $staleArchitecture) {
        Assert-False ($content.Contains($term)) "active docs omit stale architecture: $term"
    }
}

foreach ($relative in @(
    'SKILL.md', 'README.md',
    'scripts/check-execution-scope.ps1', 'scripts/check-execution-scope.sh',
    'scripts/execution-workspace.ps1', 'scripts/execution-workspace.sh',
    'scripts/make-research-workspace.ps1', 'scripts/make-research-workspace.sh',
    'scripts/cleanup-research-workspace.ps1', 'scripts/cleanup-research-workspace.sh'
)) {
    Assert-True (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf) "skill package includes $relative"
}

foreach ($relative in @(
    'scripts/agy-adapter.ps1', 'scripts/capacity-ledger.ps1', 'scripts/check-worker-adapter.ps1',
    'scripts/dispatch-worker.ps1', 'scripts/run-agy-json.ps1', 'scripts/select-compatible-worker.ps1',
    'docs/specs/0001-platform-agnostic-workflows.md', 'docs/worker-adapter-contract.md'
)) {
    Assert-False (Test-Path -LiteralPath (Join-Path $root $relative)) "removed package path is absent: $relative"
}

$skill = [IO.File]::ReadAllText((Join-Path $root 'SKILL.md'))
$readme = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
foreach ($link in @('scripts/check-execution-scope.sh', 'scripts/execution-workspace.sh')) {
    Assert-True ($skill.Contains($link) -or $readme.Contains($link)) "active docs retain link: $link"
}

foreach ($source in @(
    'https://deepswe.datacurve.ai/', 'https://livebench.ai/',
    'https://drb.futuresearch.ai/', 'https://deepresearch-bench.github.io/',
    'https://artificialanalysis.ai/models'
)) {
    Assert-True $skill.Contains($source) "SKILL.md retains benchmark source: $source"
}

foreach ($stale in @('CONTEXT.md', 'docs/adr/', 'docs/research/')) {
    Assert-False ($skill.Contains($stale) -or $readme.Contains($stale)) "active docs omit local artifact path: $stale"
}

[Console]::Out.WriteLine("all repository consistency checks passed ($($script:TotalTests) tests)")
