#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:TotalTests = 0
function Pass([string]$Name) { [void]($script:TotalTests++); [Console]::Out.WriteLine("ok - $Name") }
function Assert-True([bool]$Condition, [string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; Pass $Name }
function Assert-False([bool]$Condition, [string]$Name) { Assert-True (-not $Condition) $Name }

$root = Split-Path -Parent $PSScriptRoot
$skill = [IO.File]::ReadAllText((Join-Path $root 'SKILL.md'))

Assert-True ($skill.Contains('Reject broken citations')) 'broken citations are rejected'
Assert-True ($skill.Contains('claims not supported by their cited sources')) 'unsupported claims are rejected'
Assert-True ($skill.Contains('claims they support')) 'supported claims are accepted only after review'
Assert-True ($skill.Contains('Mark inference, uncertainty, disagreement, missing evidence, and stale evidence plainly')) 'inference, uncertainty, disagreement, and stale evidence remain visible'
Assert-True ($skill.Contains('Do not require a universal result envelope')) 'research acceptance needs no universal result envelope'
Assert-False ($skill -match '(?i)(routing-outcomes|provenance|schema_version|check-citation-audit)') 'research acceptance has no routing or provenance schema'

[Console]::Out.WriteLine("all powershell research acceptance checks passed ($($script:TotalTests) tests)")
