#!/usr/bin/env pwsh
# scripts/check-review-verdict.ps1
# Verify exhaustive reviewer coverage and evidence against one immutable artifact.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Show-Usage {
    [Console]::Error.WriteLine(@'
Usage: check-review-verdict.ps1 --criteria <FILE|JSON> --review <FILE|JSON> --artifact FILE [--json]

The criteria input is an array of objects with stable criterion_id values.
The review input is an object containing criteria, or an agy envelope whose
structured_output contains criteria.

Exit codes:
  0 - Every requested criterion has one passing verdict with matching evidence
  1 - Complete review requires direct orchestrator review (fail or hedge)
  2 - Invalid, incomplete, duplicate, unknown, or forged review
'@)
}

function Fail([string]$Message) {
    [Console]::Error.WriteLine("Error: $Message")
    exit 2
}

$criteriaArg = ''
$reviewArg = ''
$artifactPath = ''
$jsonOutput = $false

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    switch ($arg) {
        '--criteria' {
            if ($i + 1 -ge $args.Count) { Fail '--criteria requires a value' }
            $criteriaArg = [string]$args[++$i]
        }
        { $_ -like '--criteria=*' } { $criteriaArg = $arg.Substring(11) }
        '--review' {
            if ($i + 1 -ge $args.Count) { Fail '--review requires a value' }
            $reviewArg = [string]$args[++$i]
        }
        { $_ -like '--review=*' } { $reviewArg = $arg.Substring(9) }
        '--artifact' {
            if ($i + 1 -ge $args.Count) { Fail '--artifact requires a path' }
            $artifactPath = [string]$args[++$i]
        }
        { $_ -like '--artifact=*' } { $artifactPath = $arg.Substring(11) }
        '--json' { $jsonOutput = $true }
        '-h' { Show-Usage; exit 0 }
        '--help' { Show-Usage; exit 0 }
        default { Show-Usage; Fail "unrecognized option: $arg" }
    }
    $i++
}

if ([string]::IsNullOrWhiteSpace($criteriaArg)) { Show-Usage; Fail 'missing required option --criteria' }
if ([string]::IsNullOrWhiteSpace($reviewArg)) { Show-Usage; Fail 'missing required option --review' }
if ([string]::IsNullOrWhiteSpace($artifactPath)) { Show-Usage; Fail 'missing required option --artifact' }
if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { Fail "artifact file not found: $artifactPath" }

function Read-JsonInput([string]$InputValue, [string]$Label) {
    $raw = $InputValue
    if (Test-Path -LiteralPath $InputValue -PathType Leaf) {
        $raw = [System.IO.File]::ReadAllText($InputValue, [System.Text.Encoding]::UTF8)
    }
    try {
        $parsed = ConvertFrom-Json -InputObject $raw -AsHashtable -Depth 100 -NoEnumerate
        return ,$parsed
    } catch {
        Fail "$Label input is not valid JSON: $($_.Exception.Message)"
    }
}

function Get-CriteriaArray($InputObject) {
    if ($InputObject -is [System.Collections.IList]) { return @($InputObject) }
    if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains('criteria') -and $InputObject['criteria'] -is [System.Collections.IList]) {
        return @($InputObject['criteria'])
    }
    return $null
}

function Get-ReviewArray($InputObject) {
    if ($InputObject -is [System.Collections.IList]) { return @($InputObject) }
    if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains('structured_output')) {
        $structured = $InputObject['structured_output']
        if ($structured -is [System.Collections.IDictionary] -and $structured.Contains('criteria') -and $structured['criteria'] -is [System.Collections.IList]) {
            return @($structured['criteria'])
        }
    }
    if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains('criteria') -and $InputObject['criteria'] -is [System.Collections.IList]) {
        return @($InputObject['criteria'])
    }
    return $null
}

$requestedInput = Read-JsonInput $criteriaArg 'criteria'
$reviewInput = Read-JsonInput $reviewArg 'review'
$requested = Get-CriteriaArray $requestedInput
$reviewItems = Get-ReviewArray $reviewInput

if ($null -eq $requested) { Fail "Criteria input must be an array or an object containing a criteria array" }
if ($requested.Count -eq 0) { Fail 'At least one requested criterion is required' }
if ($null -eq $reviewItems) { Fail 'Review input must contain a criteria array' }

$errors = [System.Collections.Generic.List[string]]::new()
$requestedIds = [System.Collections.Generic.List[string]]::new()
$returnedIds = [System.Collections.Generic.List[string]]::new()
$validReviewItems = [System.Collections.Generic.List[object]]::new()

foreach ($item in $requested) {
    if ($item -isnot [System.Collections.IDictionary] -or -not $item.Contains('criterion_id') -or $item['criterion_id'] -isnot [string] -or [string]::IsNullOrWhiteSpace($item['criterion_id'])) {
        $errors.Add('Criteria contains an item without a non-empty string criterion_id')
        continue
    }
    $requestedIds.Add($item['criterion_id'])
}

foreach ($item in $reviewItems) {
    $valid = $item -is [System.Collections.IDictionary] -and $item.Contains('criterion_id') -and $item['criterion_id'] -is [string] -and -not [string]::IsNullOrWhiteSpace($item['criterion_id']) -and $item.Contains('verdict') -and $item['verdict'] -is [string] -and @('pass', 'fail', 'hedge') -contains $item['verdict'] -and $item.Contains('quote') -and $item['quote'] -is [string]
    if (-not $valid) {
        $errors.Add('Review contains an item with an invalid criterion_id, verdict, or quote')
        continue
    }
    $returnedIds.Add($item['criterion_id'])
    $validReviewItems.Add($item)
}

foreach ($group in ($requestedIds | Group-Object)) {
    if ($group.Count -gt 1) { $errors.Add("Duplicate requested criterion_id `"$($group.Name)`"") }
}
foreach ($group in ($returnedIds | Group-Object)) {
    if ($group.Count -gt 1) { $errors.Add("Duplicate reviewer verdict for criterion_id `"$($group.Name)`"") }
}

$requestedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$requestedIds | ForEach-Object { [void]$requestedSet.Add($_) }
$returnedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$returnedIds | ForEach-Object { [void]$returnedSet.Add($_) }

foreach ($id in $returnedSet) {
    if (-not $requestedSet.Contains($id)) { $errors.Add("Unknown reviewer criterion_id `"$id`"") }
}
foreach ($id in $requestedSet) {
    if (-not $returnedSet.Contains($id)) { $errors.Add("Missing reviewer verdict for criterion_id `"$id`"") }
}

if ($errors.Count -eq 0) {
    $artifactText = [System.IO.File]::ReadAllText($artifactPath, [System.Text.Encoding]::UTF8)
    $artifactLines = [System.Text.RegularExpressions.Regex]::Split($artifactText, "`n")
    foreach ($item in $validReviewItems) {
        if ($item['verdict'] -ne 'pass') { continue }
        $quote = [string]$item['quote']
        if ([string]::IsNullOrEmpty($quote) -or $quote.Contains("`n") -or $quote.Contains("`r")) {
            $errors.Add("Passing criterion `"$($item['criterion_id'])`" must quote one literal artifact line")
            continue
        }
        $found = $false
        foreach ($line in $artifactLines) {
            if ($line.TrimEnd("`r") -ceq $quote) { $found = $true; break }
        }
        if (-not $found) { $errors.Add("Evidence quote for criterion `"$($item['criterion_id'])`" does not match a literal artifact line") }
    }
}

if ($errors.Count -gt 0) {
    $result = [ordered]@{ valid = $false; status = 'invalid'; exit_code = 2; requested_count = $requestedIds.Count; returned_count = $returnedIds.Count; errors = @($errors) }
} elseif (@($validReviewItems | Where-Object { $_['verdict'] -ne 'pass' }).Count -gt 0) {
    $result = [ordered]@{ valid = $true; status = 'review'; exit_code = 1; requested_count = $requestedIds.Count; returned_count = $returnedIds.Count; errors = @() }
} else {
    $result = [ordered]@{ valid = $true; status = 'pass'; exit_code = 0; requested_count = $requestedIds.Count; returned_count = $returnedIds.Count; errors = @() }
}

$exitCode = [int]$result.exit_code
if ($jsonOutput) {
    $result | ConvertTo-Json -Compress -Depth 10
} elseif ($exitCode -eq 0) {
    "ok: reviewer verdict verified ($($result.requested_count) criterion(s) covered with matching evidence)"
} elseif ($exitCode -eq 1) {
    [Console]::Error.WriteLine('review: complete reviewer coverage requires direct orchestrator review')
} else {
    [Console]::Error.WriteLine('Error: reviewer verdict verification failed:')
    foreach ($errorMessage in $result.errors) { [Console]::Error.WriteLine("  - $errorMessage") }
}

exit $exitCode
