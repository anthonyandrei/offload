#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$scriptRoot = Split-Path -Parent $PSScriptRoot
$checker = Join-Path $scriptRoot 'scripts/check-publication-compatibility.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("offload-publication-" + [Guid]::NewGuid().ToString('N'))

function Write-JsonFile([string]$path, $value) {
    $value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
}

function Invoke-Checker([string]$skillRoot, [string]$catalogPath) {
    $output = & pwsh -NoProfile -File $checker --skill-root $skillRoot --catalog $catalogPath 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw "FAIL: $message" }
    Write-Output "ok - $message"
}

New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $catalogPath = Join-Path $tempRoot 'catalog.json'
    Write-JsonFile $catalogPath @{
        schema_version = 1
        adapter_contract_version = 1
        adapters = @(
            @{
                name = 'offload'
                version = '1.2.0'
                capabilities = @('worker-delegation', 'structured-results')
                vendor_features = @('agy-launch')
            }
        )
    }

    $validSkill = Join-Path $tempRoot 'valid-skill'
    New-Item -ItemType Directory -Path $validSkill -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $validSkill 'SKILL.md') -Value '# grill-with-docs`n`nInterview and documentation workflow.' -Encoding utf8NoBOM
    Write-JsonFile (Join-Path $validSkill 'publication.json') @{
        schema_version = 1
        publication_contract_version = 1
        skill = 'grill-with-docs'
        contract = 'vendor-neutral'
        imports = @()
        optional_adapters = @(@{ name = 'offload'; min_version = '1.0.0' })
        required_capabilities = @()
        vendor_features = @()
    }
    $result = Invoke-Checker $validSkill $catalogPath
    Assert-True ($result.ExitCode -eq 0) 'vendor-neutral skill with optional adapter passes'

    $emptyCatalogPath = Join-Path $tempRoot 'empty-catalog.json'
    Write-JsonFile $emptyCatalogPath @{
        schema_version = 1
        adapter_contract_version = 1
        adapters = @()
    }
    $result = Invoke-Checker $validSkill $emptyCatalogPath
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'optional adapter.*unavailable') 'skill runs without optional adapter'

    $missingSkill = Join-Path $tempRoot 'missing-skill'
    Copy-Item -Recurse $validSkill $missingSkill
    Write-JsonFile (Join-Path $missingSkill 'publication.json') @{
        schema_version = 1
        publication_contract_version = 1
        skill = 'grill-with-docs'
        contract = 'vendor-neutral'
        imports = @(@{ name = 'missing-adapter'; min_version = '1.0.0' })
        optional_adapters = @()
        required_capabilities = @()
        vendor_features = @()
    }
    $result = Invoke-Checker $missingSkill $catalogPath
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'missing-adapter.*unavailable') 'required unavailable adapter fails'

    $featureSkill = Join-Path $tempRoot 'feature-skill'
    Copy-Item -Recurse $validSkill $featureSkill
    Write-JsonFile (Join-Path $featureSkill 'publication.json') @{
        schema_version = 1
        publication_contract_version = 1
        skill = 'grill-with-docs'
        contract = 'vendor-neutral'
        imports = @()
        optional_adapters = @()
        required_capabilities = @()
        vendor_features = @('agy-launch')
    }
    $result = Invoke-Checker $featureSkill $catalogPath
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'vendor-specific feature') 'vendor-specific feature declaration fails'

    $textSkill = Join-Path $tempRoot 'text-skill'
    Copy-Item -Recurse $validSkill $textSkill
    Set-Content -LiteralPath (Join-Path $textSkill 'SKILL.md') -Value '# grill-with-docs`n`nRequires Gemini model routing.' -Encoding utf8NoBOM
    $result = Invoke-Checker $textSkill $catalogPath
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'vendor-specific reference') 'vendor-specific text reference fails'

    $capabilitySkill = Join-Path $tempRoot 'capability-skill'
    Copy-Item -Recurse $validSkill $capabilitySkill
    Write-JsonFile (Join-Path $capabilitySkill 'publication.json') @{
        schema_version = 1
        publication_contract_version = 1
        skill = 'grill-with-docs'
        contract = 'vendor-neutral'
        imports = @(@{ name = 'offload'; min_version = '1.0.0' })
        optional_adapters = @()
        required_capabilities = @(@{ adapter = 'offload'; name = 'missing-capability' })
        vendor_features = @()
    }
    $result = Invoke-Checker $capabilitySkill $catalogPath
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'capability.*missing-capability') 'missing adapter capability fails'

    Write-Output 'all publication compatibility checks passed'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
