#!/usr/bin/env pwsh
# Acceptance coverage for the vendor-neutral worker adapter contract.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$root = Split-Path -Parent $PSScriptRoot
$contract = Join-Path $root 'docs/worker-adapter-contract.md'
$checker = Join-Path $root 'scripts/check-worker-adapter.ps1'

if (-not (Test-Path -LiteralPath $contract -PathType Leaf)) {
    throw 'worker adapter contract document is missing'
}
if (-not (Test-Path -LiteralPath $checker -PathType Leaf)) {
    throw 'worker adapter result checker is missing'
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('offload-adapter-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $artifactRoot = Join-Path $scratch 'artifacts'
    New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
    $artifact = Join-Path $artifactRoot 'result.json'
    [IO.File]::WriteAllText($artifact, '{"ok":true}')

    $assignmentPath = Join-Path $scratch 'assignment.json'
    $resultPath = Join-Path $scratch 'result.json'
    @{
        contract_version = 1
        assignment_id = 'fake-success'
        request = @{ prompt = 'return the fixture' }
        constraints = @{
            tools = @('read')
            permissions = @('repo.read')
            owned_paths = @('src')
            frozen_paths = @('tests/test_worker_adapter_contract.ps1')
            worktree = @{ id = 'fake-worktree'; path = $scratch }
            artifact_root = $artifactRoot
            cleanup_resource_ids = @('process:fake-success', 'worktree:fake-worktree')
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $assignmentPath
    @{
        contract_version = 1
        assignment_id = 'fake-success'
        status = 'succeeded'
        artifacts = @(@{ path = $artifact; kind = 'result'; sha256 = 'not-checked-by-adapter'; verified = $false })
        resources = @(
            @{ type = 'process'; id = 'process:fake-success' }
            @{ type = 'worktree'; id = 'worktree:fake-worktree'; path = $scratch }
        )
        ownership = @{ resource_ids = @('process:fake-success', 'worktree:fake-worktree') }
        model_selection = @{ provider = 'fake'; model_id = 'fake-model'; selection_reason = 'fixture' }
        constraint_snapshot = @{
            tools = @('read')
            permissions = @('repo.read')
            owned_paths = @('src')
            frozen_paths = @('tests/test_worker_adapter_contract.ps1')
            worktree = @{ id = 'fake-worktree'; path = $scratch }
            artifact_root = $artifactRoot
            cleanup_resource_ids = @('process:fake-success', 'worktree:fake-worktree')
        }
        exit = @{ code = 0; signal = $null }
        publication = @{ status = 'unpublished' }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath

    function Invoke-Case([string]$name, [scriptblock]$writeResult, [bool]$expectedPass) {
        & $writeResult
        & pwsh -NoProfile -NonInteractive -File $checker --assignment $assignmentPath --result $resultPath *> $null
        $actualPass = $LASTEXITCODE -eq 0
        if ($actualPass -ne $expectedPass) {
            throw "$name expected pass=$expectedPass, got pass=$actualPass"
        }
        Write-Output "ok - $name"
    }

    $valid = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    Invoke-Case 'fake adapter success result satisfies the contract' {
        $valid | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath
    } $true

    foreach ($status in @('failed', 'cancelled', 'malformed')) {
        Invoke-Case "fake adapter $status result is normalized" {
            $case = $valid | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            $case.status = $status
            $case | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath
        } $true
    }

    Invoke-Case 'empty result collections are valid' {
        $case = $valid | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $case.status = 'failed'
        $case.artifacts = @()
        $case.resources = @()
        $case.ownership.resource_ids = @()
        $case.constraint_snapshot.tools = @()
        $case.constraint_snapshot.permissions = @()
        $case.constraint_snapshot.owned_paths = @()
        $case.constraint_snapshot.frozen_paths = @()
        $case.constraint_snapshot.cleanup_resource_ids = @()
        $case | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath
    } $true

    Invoke-Case 'scalar result collection is rejected' {
        $case = $valid | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $case.constraint_snapshot.tools = 'read'
        $case | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath
    } $false

    Invoke-Case 'malformed adapter output is rejected' {
        Set-Content -LiteralPath $resultPath -Value '{not-json'
    } $false

    Invoke-Case 'execution-scope artifact violation is rejected' {
        $case = $valid | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $case.artifacts[0].path = Join-Path $scratch 'outside.json'
        Set-Content -LiteralPath $case.artifacts[0].path -Value 'outside'
        $case | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath
    } $false

    Invoke-Case 'tool widening is rejected' {
        $case = $valid | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $case.constraint_snapshot.tools = @('read', 'execute')
        $case | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath
    } $false

    Invoke-Case 'unowned resource is rejected' {
        $case = $valid | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $case.resources[0].id = 'process:outside'
        $case | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath
    } $false

    Invoke-Case 'resource outside worktree is rejected' {
        $case = $valid | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $case.resources[1].path = Join-Path ([IO.Path]::GetTempPath()) 'outside-worktree'
        $case | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath
    } $false

    Invoke-Case 'verified artifact claim is rejected' {
        $case = $valid | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $case.artifacts[0].verified = $true
        $case | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath
    } $false

    Invoke-Case 'adapter publication claim is rejected' {
        $case = $valid | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $case.publication.status = 'published'
        $case | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath
    } $false
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
