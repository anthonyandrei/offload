#!/usr/bin/env pwsh
# scripts/check-citation-audit.ps1
# Platform-agnostic citation audit coverage and verdict consistency verifier for PowerShell 7 / .NET.
# Verifies that every required (claim_id, citation_url) pair in the claim ledger
# has exact coverage and consistent verdicts in citation_audits before accepting synthesis.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Show-Usage {
    [Console]::Error.WriteLine(@"
Usage: check-citation-audit.ps1 --ledger <FILE|JSON> --auditor <FILE|JSON> [OPTIONS]

Options:
  --ledger, --claim-ledger <FILE|JSON>     Path to synthesizer JSON or raw claim_ledger JSON
  --auditor, --auditor-output <FILE|JSON>  Path to auditor JSON or raw auditor output JSON
  --require-citations                      Require at least one auditable citation pair (default)
  --allow-empty                            Allow zero auditable citation pairs if assignment permits
  --json                                   Output verification result as JSON to stdout
  -h, --help                               Show this help message

Exit codes:
  0 - Audit verified and passed automated acceptance (all pairs supported, final_status pass)
  1 - Valid revision required (complete coverage, final_status revise)
  2 - Invalid audit (missing coverage, duplicates, unknown pairs, contradictory verdicts, etc.)
"@)
}

$ledgerArg = ""
$auditorArg = ""
$requireCitations = $true
$jsonOutput = $false

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    switch -Regex ($arg) {
        '^(--ledger|--claim-ledger)$' {
            if ($i + 1 -ge $args.Count) {
                [Console]::Error.WriteLine("Error: $arg requires a value")
                exit 2
            }
            $ledgerArg = [string]$args[++$i]
        }
        '^(--ledger|--claim-ledger)=(.*)$' {
            $ledgerArg = $Matches[2]
        }
        '^(--auditor|--auditor-output)$' {
            if ($i + 1 -ge $args.Count) {
                [Console]::Error.WriteLine("Error: $arg requires a value")
                exit 2
            }
            $auditorArg = [string]$args[++$i]
        }
        '^(--auditor|--auditor-output)=(.*)$' {
            $auditorArg = $Matches[2]
        }
        '^--require-citations$' {
            $requireCitations = $true
        }
        '^--allow-empty$' {
            $requireCitations = $false
        }
        '^--json$' {
            $jsonOutput = $true
        }
        '^(-h|--help)$' {
            Show-Usage
            exit 0
        }
        default {
            [Console]::Error.WriteLine("Error: unrecognized option: $arg")
            Show-Usage
            exit 2
        }
    }
    $i++
}

if ([string]::IsNullOrWhiteSpace($ledgerArg)) {
    [Console]::Error.WriteLine("Error: missing required option --ledger")
    Show-Usage
    exit 2
}

if ([string]::IsNullOrWhiteSpace($auditorArg)) {
    [Console]::Error.WriteLine("Error: missing required option --auditor")
    Show-Usage
    exit 2
}

# Function to load and parse JSON input from file path or raw string
function Parse-JsonInput([string]$inputStr, [string]$label) {
    $rawText = $inputStr
    if (Test-Path -LiteralPath $inputStr -PathType Leaf) {
        $rawText = [System.IO.File]::ReadAllText($inputStr, [System.Text.Encoding]::UTF8)
    }
    try {
        return , [System.Text.Json.Nodes.JsonNode]::Parse($rawText)
    } catch {
        [Console]::Error.WriteLine("Error: $label input is not valid JSON: $($_.Exception.Message)")
        exit 2
    }
}

$ledgerNode = Parse-JsonInput $ledgerArg "ledger"
$auditorNode = Parse-JsonInput $auditorArg "auditor"

# 1. Normalize claim_ledger
$claimLedgerArray = $null
if ($ledgerNode -is [System.Text.Json.Nodes.JsonArray]) {
    $claimLedgerArray = $ledgerNode.AsArray()
} elseif ($ledgerNode -is [System.Array]) {
    $claimLedgerArray = $ledgerNode
} elseif ($ledgerNode -is [System.Text.Json.Nodes.JsonObject]) {
    $obj = $ledgerNode.AsObject()
    if ($obj.ContainsKey("structured_output") -and $obj["structured_output"] -is [System.Text.Json.Nodes.JsonObject]) {
        $so = $obj["structured_output"].AsObject()
        if ($so.ContainsKey("claim_ledger") -and $so["claim_ledger"] -is [System.Text.Json.Nodes.JsonArray]) {
            $claimLedgerArray = $so["claim_ledger"].AsArray()
        }
    }
    if ($null -eq $claimLedgerArray -and $obj.ContainsKey("claim_ledger") -and $obj["claim_ledger"] -is [System.Text.Json.Nodes.JsonArray]) {
        $claimLedgerArray = $obj["claim_ledger"].AsArray()
    }
}

if ($null -eq $claimLedgerArray) {
    [Console]::Error.WriteLine("Error: Invalid claim ledger: input must be an array or an object containing a 'claim_ledger' array")
    exit 2
}

# 2. Normalize auditor output
$auditorObj = $null
if ($auditorNode -is [System.Text.Json.Nodes.JsonObject]) {
    $obj = $auditorNode.AsObject()
    if ($obj.ContainsKey("structured_output") -and $obj["structured_output"] -is [System.Text.Json.Nodes.JsonObject]) {
        $so = $obj["structured_output"].AsObject()
        if ($so.ContainsKey("citation_audits") -and $so["citation_audits"] -is [System.Text.Json.Nodes.JsonArray]) {
            $auditorObj = $so
        }
    }
    if ($null -eq $auditorObj -and $obj.ContainsKey("citation_audits") -and $obj["citation_audits"] -is [System.Text.Json.Nodes.JsonArray]) {
        $auditorObj = $obj
    }
}

if ($null -eq $auditorObj) {
    [Console]::Error.WriteLine("Error: Invalid auditor output: input must be an object containing a 'citation_audits' array")
    exit 2
}

# Extract required pairs from claim ledger
$requiredPairsSet = [System.Collections.Generic.HashSet[string]]::new()
$requiredPairsList = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($claimItem in $claimLedgerArray) {
    if ($claimItem -is [System.Text.Json.Nodes.JsonObject]) {
        $cObj = $claimItem.AsObject()
        if ($cObj.ContainsKey("claim_id") -and $null -ne $cObj["claim_id"]) {
            $cid = $cObj["claim_id"].ToString().Trim()
            if ($cid.Length -gt 0 -and $cObj.ContainsKey("citations") -and $cObj["citations"] -is [System.Text.Json.Nodes.JsonArray]) {
                foreach ($citItem in $cObj["citations"].AsArray()) {
                    if ($null -ne $citItem) {
                        $u = $citItem.ToString().Trim()
                        if ($u.Length -gt 0) {
                            $pairKey = "$cid`t$u"
                            if ($requiredPairsSet.Add($pairKey)) {
                                $requiredPairsList.Add([pscustomobject]@{
                                    claim_id = $cid
                                    citation_url = $u
                                })
                            }
                        }
                    }
                }
            }
        }
    }
}

# Extract auditor items
$auditsArray = $auditorObj["citation_audits"].AsArray()
$finalStatus = if ($auditorObj.ContainsKey("final_status") -and $null -ne $auditorObj["final_status"]) {
    $auditorObj["final_status"].ToString().Trim()
} else {
    ""
}

$toRemove = [System.Collections.Generic.List[string]]::new()
if ($auditorObj.ContainsKey("claims_to_remove") -and $auditorObj["claims_to_remove"] -is [System.Text.Json.Nodes.JsonArray]) {
    foreach ($item in $auditorObj["claims_to_remove"].AsArray()) {
        if ($null -ne $item) { $toRemove.Add($item.ToString().Trim()) }
    }
}

$toNarrow = [System.Collections.Generic.List[string]]::new()
if ($auditorObj.ContainsKey("claims_to_narrow") -and $auditorObj["claims_to_narrow"] -is [System.Text.Json.Nodes.JsonArray]) {
    foreach ($item in $auditorObj["claims_to_narrow"].AsArray()) {
        if ($null -ne $item) { $toNarrow.Add($item.ToString().Trim()) }
    }
}

$unresolved = [System.Collections.Generic.List[string]]::new()
if ($auditorObj.ContainsKey("claims_unresolved") -and $auditorObj["claims_unresolved"] -is [System.Text.Json.Nodes.JsonArray]) {
    foreach ($item in $auditorObj["claims_unresolved"].AsArray()) {
        if ($null -ne $item) { $unresolved.Add($item.ToString().Trim()) }
    }
}

# Validation checks
$errors = [System.Collections.Generic.List[string]]::new()

# Check 1: Zero auditable pairs when citations required
if ($requiredPairsSet.Count -eq 0 -and $requireCitations) {
    $errors.Add("Ledger contains no auditable claim/citation pairs, but citations are required by the research assignment")
}

# Check 2: Audit pairs tracking, duplicates, and unknowns
$seenAuditedPairs = [System.Collections.Generic.HashSet[string]]::new()
$duplicatePairs = [System.Collections.Generic.HashSet[string]]::new()
$unknownPairs = [System.Collections.Generic.List[PSCustomObject]]::new()
$auditedPairsCount = $auditsArray.Count

foreach ($auditItem in $auditsArray) {
    if ($auditItem -is [System.Text.Json.Nodes.JsonObject]) {
        $aObj = $auditItem.AsObject()
        $cid = if ($aObj.ContainsKey("claim_id") -and $null -ne $aObj["claim_id"]) { $aObj["claim_id"].ToString().Trim() } else { "" }
        $u = if ($aObj.ContainsKey("citation_url") -and $null -ne $aObj["citation_url"]) { $aObj["citation_url"].ToString().Trim() } else { "" }
        $pairKey = "$cid`t$u"

        if (-not $seenAuditedPairs.Add($pairKey)) {
            $duplicatePairs.Add($pairKey) | Out-Null
        }

        if (-not $requiredPairsSet.Contains($pairKey)) {
            $unknownPairs.Add([pscustomobject]@{ claim_id = $cid; citation_url = $u })
        }
    } else {
        $errors.Add("Each element in citation_audits must be a JSON object")
    }
}

foreach ($dupKey in $duplicatePairs) {
    $parts = $dupKey.Split("`t")
    $errors.Add("Duplicate audit entry found for claim_id `"$($parts[0])`" and citation_url `"$($parts[1])`"")
}

foreach ($unk in $unknownPairs) {
    $errors.Add("Unknown audit entry for claim_id `"$($unk.claim_id)`" and citation_url `"$($unk.citation_url)`" not present in claim ledger")
}

# Check 3: Missing pairs
foreach ($reqPair in $requiredPairsList) {
    $pairKey = "$($reqPair.claim_id)`t$($reqPair.citation_url)"
    if (-not $seenAuditedPairs.Contains($pairKey)) {
        $errors.Add("Missing audit coverage for required pair: claim_id `"$($reqPair.claim_id)`", citation_url `"$($reqPair.citation_url)`"")
    }
}

# Check 4: final_status validity
$allowedStatuses = @("pass", "revise", "incomplete")
if (-not ($allowedStatuses -contains $finalStatus)) {
    $errors.Add("Invalid or missing final_status `"$finalStatus`"; must be pass, revise, or incomplete")
}

# Check 5: Verdict consistency for pass
if ($finalStatus -eq "pass") {
    foreach ($auditItem in $auditsArray) {
        if ($auditItem -is [System.Text.Json.Nodes.JsonObject]) {
            $aObj = $auditItem.AsObject()
            $cid = if ($aObj.ContainsKey("claim_id") -and $null -ne $aObj["claim_id"]) { $aObj["claim_id"].ToString().Trim() } else { "" }
            $u = if ($aObj.ContainsKey("citation_url") -and $null -ne $aObj["citation_url"]) { $aObj["citation_url"].ToString().Trim() } else { "" }

            $resolves = $false
            if ($aObj.ContainsKey("resolves") -and $null -ne $aObj["resolves"]) {
                try {
                    $resolves = [bool]$aObj["resolves"].GetValue([bool])
                } catch {
                    $resolves = ($aObj["resolves"].ToString().ToLowerInvariant() -eq "true")
                }
            }
            if (-not $resolves) {
                $errors.Add("Contradictory audit: final_status is `"pass`" but pair (claim_id `"$cid`", citation_url `"$u`") has resolves=false")
            }

            $verdict = if ($aObj.ContainsKey("support_verdict") -and $null -ne $aObj["support_verdict"]) { $aObj["support_verdict"].ToString().Trim() } else { "" }
            if ($verdict -ne "supports") {
                $errors.Add("Contradictory audit: final_status is `"pass`" but pair (claim_id `"$cid`", citation_url `"$u`") has non-supporting verdict `"$verdict`"")
            }
        }
    }

    if ($toRemove.Count -gt 0) {
        $errors.Add("Contradictory audit: final_status is `"pass`" but claims_to_remove is not empty")
    }
    if ($toNarrow.Count -gt 0) {
        $errors.Add("Contradictory audit: final_status is `"pass`" but claims_to_narrow is not empty")
    }
    if ($unresolved.Count -gt 0) {
        $errors.Add("Contradictory audit: final_status is `"pass`" but claims_unresolved is not empty")
    }
}

# Check 6: Verdict consistency for revise
if ($finalStatus -eq "revise") {
    $allSupported = $true
    foreach ($auditItem in $auditsArray) {
        if ($auditItem -is [System.Text.Json.Nodes.JsonObject]) {
            $aObj = $auditItem.AsObject()
            $resolves = $false
            if ($aObj.ContainsKey("resolves") -and $null -ne $aObj["resolves"]) {
                try {
                    $resolves = [bool]$aObj["resolves"].GetValue([bool])
                } catch {
                    $resolves = ($aObj["resolves"].ToString().ToLowerInvariant() -eq "true")
                }
            }
            $verdict = if ($aObj.ContainsKey("support_verdict") -and $null -ne $aObj["support_verdict"]) { $aObj["support_verdict"].ToString().Trim() } else { "" }
            if (-not $resolves -or $verdict -ne "supports") {
                $allSupported = $false
                break
            }
        }
    }

    if ($allSupported -and $toRemove.Count -eq 0 -and $toNarrow.Count -eq 0 -and $unresolved.Count -eq 0) {
        $errors.Add("Contradictory audit: final_status is `"revise`" but all citations are supported and no claims are marked to remove, narrow, or unresolved")
    }
}

# Check 7: incomplete status
if ($finalStatus -eq "incomplete") {
    $errors.Add("Audit final_status is incomplete")
}

# Determine status and exit code
$exitCode = 0
$statusStr = "pass"
$isValid = $true

if ($errors.Count -gt 0) {
    $isValid = $false
    $statusStr = "invalid"
    $exitCode = 2
} elseif ($finalStatus -eq "revise") {
    $isValid = $true
    $statusStr = "revise"
    $exitCode = 1
} else {
    $isValid = $true
    $statusStr = "pass"
    $exitCode = 0
}

$outputResult = [ordered]@{
    valid = $isValid
    status = $statusStr
    exit_code = $exitCode
    required_pairs_count = $requiredPairsSet.Count
    audited_pairs_count = $auditedPairsCount
    final_status = $finalStatus
    errors = $errors.ToArray()
}

if ($jsonOutput) {
    $jsonString = [System.Text.Json.JsonSerializer]::Serialize($outputResult, [System.Text.Json.JsonSerializerOptions]@{
        WriteIndented = $false
    })
    [Console]::Out.WriteLine($jsonString)
} else {
    if ($exitCode -eq 0) {
        [Console]::Out.WriteLine("ok: citation audit verified ($($requiredPairsSet.Count) required pair(s) covered with supported verdicts)")
    } elseif ($exitCode -eq 1) {
        [Console]::Error.WriteLine("revise: citation audit verified; revision required by auditor")
    } else {
        [Console]::Error.WriteLine("Error: citation audit verification failed:")
        foreach ($err in $errors) {
            [Console]::Error.WriteLine("  - $err")
        }
    }
}

exit $exitCode
