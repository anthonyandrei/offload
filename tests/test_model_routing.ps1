#!/usr/bin/env pwsh
# Acceptance tests for runtime model selection, adapter boundaries, and pinning.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$script:TotalTests = 0
$script:FailedTests = 0

function Pass([string]$name) { $script:TotalTests++; [Console]::Out.WriteLine("ok - $name") }
function Fail([string]$name, [string]$reason = '') { $script:TotalTests++; $script:FailedTests++; [Console]::Error.WriteLine("FAIL: $name$(if ($reason) { " - $reason" })"); exit 1 }
function Assert-True([bool]$condition, [string]$name, [string]$reason = '') { if ($condition) { Pass $name } else { Fail $name $(if ($reason) { $reason } else { 'condition was false' }) } }
function Assert-False([bool]$condition, [string]$name, [string]$reason = '') { Assert-True (-not $condition) $name $(if ($reason) { $reason } else { 'condition was true' }) }
function Assert-Equal($actual, $expected, [string]$name, [string]$reason = '') { if ($actual -eq $expected) { Pass $name } else { Fail $name $(if ($reason) { $reason } else { "expected '$expected', got '$actual'" }) } }

$root = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $root 'scripts/run-agy-json.ps1'
$adapter = Join-Path $root 'tests/fixtures/fake-worker-adapter.ps1'
$policy = Get-Content -Raw (Join-Path $root 'model-policy.json') | ConvertFrom-Json
$pwsh = (Get-Command pwsh).Source
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("offload-routing-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function New-Catalog([string]$path, [string]$revision, [object[]]$models) {
    [ordered]@{ protocol_version = 1; adapter = 'fake'; adapter_revision = 'fake-1'; vendor = 'test-vendor'; catalog_revision = $revision; models = $models } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
}
function New-Model([string]$id, [bool]$available, [string[]]$efforts, [int]$fast, [int]$balanced, [int]$deep, [string[]]$capabilities = @(), [string]$family = '') {
    [ordered]@{ id = $id; family_hint = $family; available = $available; quota_available = $true; supported_efforts = $efforts; capabilities = $capabilities; scores = [ordered]@{ fast = $fast; balanced = $balanced; deep = $deep } }
}
function Invoke-Launcher([string[]]$arguments, [hashtable]$environment) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwsh
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($argument in (@('-NoProfile', '-NonInteractive', '-File', $launcher) + $arguments)) { [void]$psi.ArgumentList.Add($argument) }
    foreach ($key in $environment.Keys) { $psi.Environment[$key] = [string]$environment[$key] }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout.Result; Stderr = $stderr.Result }
}
function Common-Args([string]$output, [string]$error, [string]$selection, [string]$catalog, [string]$role = 'implementer') {
    return @('--role', $role, '--adapter', $adapter, '--selection-output', $selection, '--output', $output, '--error', $error, '--', '--prompt', 'preserve this value: model and effort belong to policy')
}

try {
    Assert-Equal $policy.schema_version 2 'policy uses adapter-selection schema'
    Assert-False ($policy.PSObject.Properties.Name -contains 'vendor') 'policy has no vendor contract'
    foreach ($roleName in @('scout', 'gate-author', 'implementer', 'reviewer', 'researcher', 'synthesizer', 'auditor')) {
        Assert-True ($policy.roles.$roleName.preference -in @('fast', 'balanced', 'deep')) "policy $roleName has internal preference"
        Assert-True ($policy.roles.$roleName.effort -in @('low', 'medium', 'high')) "policy $roleName keeps effort separate"
        Assert-False ($policy.roles.$roleName.PSObject.Properties.Name -contains 'default_model') "policy $roleName has no fixed model"
    }

    $catalogA = Join-Path $testRoot 'catalog-a.json'
    $capture = Join-Path $testRoot 'adapter-capture.json'
    $output = Join-Path $testRoot 'worker.json'
    $errorPath = Join-Path $testRoot 'worker.err'
    $selection = Join-Path $testRoot 'selection.json'
    New-Catalog $catalogA 'catalog-a' @(
        (New-Model 'unavailable' $false @('high') 0 0 0),
        (New-Model 'balanced-best' $true @('high') 9 1 9),
        (New-Model 'balanced-later' $true @('high') 9 1 9),
        (New-Model 'wrong-effort' $true @('low') 0 0 0)
    )
    $env = @{ FAKE_ADAPTER_CATALOG = $catalogA; FAKE_ADAPTER_CAPTURE = $capture }
    $result = Invoke-Launcher (Common-Args $output $errorPath $selection $catalogA) $env
    Assert-Equal $result.ExitCode 0 'catalog selection launches worker' $result.Stderr
    $chosen = Get-Content -Raw $selection | ConvertFrom-Json
    Assert-Equal $chosen.model_id 'balanced-best' 'selection is deterministic across equal scores'
    Assert-Equal $chosen.vendor 'test-vendor' 'selection records vendor'
    Assert-Equal $chosen.adapter 'fake' 'selection records adapter'
    Assert-Equal $chosen.family_hint '' 'family hint remains metadata'
    Assert-Equal $chosen.preference 'balanced' 'selection records preference'
    Assert-Equal $chosen.effort 'high' 'selection records separate effort'
    Assert-Equal $chosen.catalog_revision 'catalog-a' 'selection records catalog revision'
    Assert-True ($chosen.selection_reason -match 'filtered unavailable') 'selection records filtering reason'
    $captured = Get-Content -Raw $capture | ConvertFrom-Json
    Assert-Equal $captured.selection.model_id 'balanced-best' 'adapter receives exact selected model'
    Assert-Equal $captured.selection.required_capabilities.Count 0 'adapter receives capability constraints'
    Assert-Equal ($captured.worker_args -join '|') '--prompt|preserve this value: model and effort belong to policy' 'worker argument value is preserved'
    Assert-Equal (Get-Content -Raw $output | ConvertFrom-Json).model_id 'balanced-best' 'worker output is captured'

    $catalogB = Join-Path $testRoot 'catalog-b.json'
    New-Catalog $catalogB 'catalog-b-changed' @(
        (New-Model 'balanced-best' $true @('high') 9 99 9),
        (New-Model 'newly-ranked-first' $true @('high') 9 0 9)
    )
    $pinnedRun = Join-Path $testRoot 'pinned-worker.json'
    $pinnedErr = Join-Path $testRoot 'pinned-worker.err'
    $pinnedSelection = Join-Path $testRoot 'pinned-selection.json'
    $pinResult = Invoke-Launcher (@('--pin', $selection) + (Common-Args $pinnedRun $pinnedErr $pinnedSelection $catalogB)) @{ FAKE_ADAPTER_CATALOG = $catalogB; FAKE_ADAPTER_CAPTURE = $capture }
    Assert-Equal $pinResult.ExitCode 0 'pinned retry survives changed catalog ranking'
    Assert-Equal (Get-Content -Raw $pinnedSelection | ConvertFrom-Json).model_id 'balanced-best' 'pinned retry keeps exact model'
    Assert-True ((Get-Content -Raw $pinnedSelection | ConvertFrom-Json).selection_reason -match 'pinned selection') 'pinned retry records reason'

    $missingCatalog = Join-Path $testRoot 'catalog-missing.json'
    New-Catalog $missingCatalog 'catalog-missing-pin' @((New-Model 'newly-ranked-first' $true @('high') 9 0 9))
    $missingResult = Invoke-Launcher (@('--pin', $selection) + (Common-Args (Join-Path $testRoot 'missing.json') (Join-Path $testRoot 'missing.err') (Join-Path $testRoot 'missing-selection.json') $missingCatalog)) @{ FAKE_ADAPTER_CATALOG = $missingCatalog }
    Assert-Equal $missingResult.ExitCode 3 'missing pinned model requires explicit fallback or handoff'
    Assert-True ($missingResult.Stderr -match 'explicit fallback or handoff') 'missing pin explains required action'
    $qualityResult = Invoke-Launcher (@('--route', 'quality-retry') + (Common-Args (Join-Path $testRoot 'quality.json') (Join-Path $testRoot 'quality.err') (Join-Path $testRoot 'quality-selection.json') $catalogA)) @{ FAKE_ADAPTER_CATALOG = $catalogA }
    Assert-Equal $qualityResult.ExitCode 3 'quality retry cannot select a new model silently'

    $unsupportedCatalog = Join-Path $testRoot 'unsupported.json'
    New-Catalog $unsupportedCatalog 'unsupported-effort' @((New-Model 'low-only' $true @('low') 1 1 1))
    $unsupported = Invoke-Launcher (Common-Args (Join-Path $testRoot 'unsupported.json.out') (Join-Path $testRoot 'unsupported.err') (Join-Path $testRoot 'unsupported.selection') $unsupportedCatalog) @{ FAKE_ADAPTER_CATALOG = $unsupportedCatalog }
    Assert-Equal $unsupported.ExitCode 4 'unsupported effort produces no candidate'

    $familyCatalog = Join-Path $testRoot 'family.json'
    New-Catalog $familyCatalog 'family-hint' @((New-Model 'hinted-but-incompatible' $true @('high') 0 0 0 @() 'trusted'))
    $familyResult = Invoke-Launcher (@('--require-capability', 'structured-output') + (Common-Args (Join-Path $testRoot 'family.out') (Join-Path $testRoot 'family.err') (Join-Path $testRoot 'family.selection') $familyCatalog)) @{ FAKE_ADAPTER_CATALOG = $familyCatalog }
    Assert-Equal $familyResult.ExitCode 4 'family hint cannot bypass capability constraints'

    Write-Output "all adapter model selection checks passed ($($script:TotalTests) tests)"
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
