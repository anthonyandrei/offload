#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Stop-Check([string]$message) {
    [Console]::Error.WriteLine("compatibility error: $message")
    exit 1
}

function Get-RequiredProperty($object, [string]$name, [string]$location) {
    $property = $object.PSObject.Properties[$name]
    if ($null -eq $property -or $null -eq $property.Value) {
        Stop-Check "$location is missing '$name'"
    }
    return $property.Value
}

function Get-Items($object, [string]$name) {
    $property = $object.PSObject.Properties[$name]
    if ($null -eq $property -or $null -eq $property.Value) { return @() }
    return @($property.Value)
}

function Compare-Version([string]$left, [string]$right) {
    $leftMatch = [regex]::Match($left, '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$')
    $rightMatch = [regex]::Match($right, '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$')
    if (-not $leftMatch.Success -or -not $rightMatch.Success) {
        Stop-Check "versions must use MAJOR.MINOR.PATCH, got '$left' and '$right'"
    }

    foreach ($part in @('major', 'minor', 'patch')) {
        $leftNumber = [int]$leftMatch.Groups[$part].Value
        $rightNumber = [int]$rightMatch.Groups[$part].Value
        if ($leftNumber -lt $rightNumber) { return -1 }
        if ($leftNumber -gt $rightNumber) { return 1 }
    }
    return 0
}

$SkillRoot = ''
$Catalog = ''
$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    if ($arg -eq '--skill-root' -or $arg -eq '-skill-root') {
        if ($i + 1 -ge $args.Count) { Stop-Check '--skill-root requires a value' }
        $SkillRoot = [string]$args[$i + 1]
        $i += 2
        continue
    }
    if ($arg -eq '--catalog' -or $arg -eq '-catalog') {
        if ($i + 1 -ge $args.Count) { Stop-Check '--catalog requires a value' }
        $Catalog = [string]$args[$i + 1]
        $i += 2
        continue
    }
    Stop-Check "unknown argument '$arg'"
}
if ([string]::IsNullOrWhiteSpace($SkillRoot) -or [string]::IsNullOrWhiteSpace($Catalog)) {
    Stop-Check 'usage: check-publication-compatibility.ps1 --skill-root DIR --catalog FILE'
}

if (-not (Test-Path -LiteralPath $SkillRoot -PathType Container)) {
    Stop-Check "skill root does not exist: $SkillRoot"
}
if (-not (Test-Path -LiteralPath $Catalog -PathType Leaf)) {
    Stop-Check "adapter catalog does not exist: $Catalog"
}

$manifestPath = Join-Path $SkillRoot 'publication.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Stop-Check 'published skill is missing publication.json'
}
if (-not (Test-Path -LiteralPath (Join-Path $SkillRoot 'SKILL.md') -PathType Leaf)) {
    Stop-Check 'published skill is missing SKILL.md'
}

try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $catalogData = Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json
} catch {
    Stop-Check "invalid JSON: $($_.Exception.Message)"
}

if ((Get-RequiredProperty $manifest 'schema_version' 'publication.json') -ne 1) {
    Stop-Check 'publication.json schema_version must be 1'
}
if ((Get-RequiredProperty $manifest 'publication_contract_version' 'publication.json') -ne 1) {
    Stop-Check 'publication contract version 1 is required'
}
if ((Get-RequiredProperty $manifest 'contract' 'publication.json') -ne 'vendor-neutral') {
    Stop-Check 'published skills must use the vendor-neutral contract'
}
if ((Get-RequiredProperty $catalogData 'schema_version' 'adapter catalog') -ne 1) {
    Stop-Check 'adapter catalog schema_version must be 1'
}
if ((Get-RequiredProperty $catalogData 'adapter_contract_version' 'adapter catalog') -ne 1) {
    Stop-Check 'adapter contract version 1 is required'
}

$adapters = @{}
foreach ($adapter in (Get-Items $catalogData 'adapters')) {
    $name = [string](Get-RequiredProperty $adapter 'name' 'adapter catalog entry')
    if ($adapters.ContainsKey($name)) { Stop-Check "adapter catalog repeats '$name'" }
    $adapters[$name] = $adapter
}

$requiredImports = @(Get-Items $manifest 'imports')
$optionalImports = @(Get-Items $manifest 'optional_adapters')
$importNames = @{}

foreach ($import in $requiredImports) {
    $name = [string](Get-RequiredProperty $import 'name' 'publication import')
    if ($importNames.ContainsKey($name)) { Stop-Check "publication imports repeat '$name'" }
    $importNames[$name] = $true
    if (-not $adapters.ContainsKey($name)) {
        Stop-Check "required adapter '$name' is unavailable"
    }
    $adapter = $adapters[$name]
    $minimum = [string](Get-RequiredProperty $import 'min_version' "publication import '$name'")
    $available = [string](Get-RequiredProperty $adapter 'version' "adapter '$name'")
    if ((Compare-Version $available $minimum) -lt 0) {
        Stop-Check "adapter '$name' version '$available' does not satisfy minimum '$minimum'"
    }
}

foreach ($import in $optionalImports) {
    $name = [string](Get-RequiredProperty $import 'name' 'optional adapter')
    if ($importNames.ContainsKey($name)) { Stop-Check "adapter '$name' is both required and optional" }
    $importNames[$name] = $true
    if (-not $adapters.ContainsKey($name)) {
        Write-Output "warning: optional adapter '$name' is unavailable"
        continue
    }
    $adapter = $adapters[$name]
    $minimum = [string](Get-RequiredProperty $import 'min_version' "optional adapter '$name'")
    $available = [string](Get-RequiredProperty $adapter 'version' "adapter '$name'")
    if ((Compare-Version $available $minimum) -lt 0) {
        Stop-Check "optional adapter '$name' version '$available' does not satisfy minimum '$minimum'"
    }
}

foreach ($requirement in (Get-Items $manifest 'required_capabilities')) {
    $adapterName = [string](Get-RequiredProperty $requirement 'adapter' 'capability requirement')
    $capability = [string](Get-RequiredProperty $requirement 'name' 'capability requirement')
    if (-not $adapters.ContainsKey($adapterName)) {
        Stop-Check "capability '$capability' requires unavailable adapter '$adapterName'"
    }
    $availableCapabilities = @((Get-Items $adapters[$adapterName] 'capabilities') | ForEach-Object { [string]$_ })
    if ($availableCapabilities -notcontains $capability) {
        Stop-Check "adapter '$adapterName' does not provide capability '$capability'"
    }
}

$vendorFeatures = @(Get-Items $manifest 'vendor_features')
if ($vendorFeatures.Count -gt 0) {
    Stop-Check "vendor-specific feature declarations are not allowed in a published skill: $($vendorFeatures -join ', ')"
}

$vendorPattern = '(?i)(?<![A-Za-z0-9_-])(AGY|Gemini|Antigravity|Codex|Claude)(?![A-Za-z0-9_-])'
$markdownFiles = Get-ChildItem -LiteralPath $SkillRoot -Recurse -File -Filter '*.md'
foreach ($file in $markdownFiles) {
    $matches = Select-String -LiteralPath $file.FullName -Pattern $vendorPattern
    if ($null -ne $matches) {
        $relative = [System.IO.Path]::GetRelativePath((Resolve-Path $SkillRoot), $file.FullName)
        Stop-Check "vendor-specific reference in published skill '$relative' at line $($matches[0].LineNumber)"
    }
}

Write-Output 'publication compatibility: pass'
