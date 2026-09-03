#!/usr/bin/env pwsh
# tests/test_citation_audit.ps1
# Self-contained acceptance test suite for citation audit coverage and verdict consistency.
# Implements acceptance criteria specified in Issue #10.
# Strict constraints: Standalone PowerShell 7 / .NET only, no Pester, Python, jq, Bash, or network.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:TotalTests = 0
$script:FailedTests = 0

function Pass([string]$name) {
    $script:TotalTests++
    [Console]::Out.WriteLine("ok - $name")
}

function Fail([string]$name, [string]$reason = "") {
    $script:TotalTests++
    $script:FailedTests++
    $msg = if ($reason) { "FAIL: $name - $reason" } else { "FAIL: $name" }
    [Console]::Error.WriteLine($msg)
    exit 1
}

function Assert-True([bool]$condition, [string]$name, [string]$reason = "") {
    if ($condition) {
        Pass $name
    } else {
        $r = if ($reason) { $reason } else { "Condition was false" }
        Fail $name $r
    }
}

function Assert-False([bool]$condition, [string]$name, [string]$reason = "") {
    if (-not $condition) {
        Pass $name
    } else {
        $r = if ($reason) { $reason } else { "Condition was true" }
        Fail $name $r
    }
}

function Assert-Equal($actual, $expected, [string]$name) {
    if ($actual -eq $expected) {
        Pass $name
    } else {
        Fail $name "Expected '$expected', got '$actual'"
    }
}

$PwshBin = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $PwshBin) {
    $PwshBin = (Get-Process -Id $PID).Path
}

$RootDir = Split-Path -Parent $PSScriptRoot
$ScriptsDir = Join-Path $RootDir 'scripts'
$AuditHelper = Join-Path $ScriptsDir 'check-citation-audit.ps1'

if (-not (Test-Path -LiteralPath $AuditHelper -PathType Leaf)) {
    Fail "init" "Script '$AuditHelper' not found"
}

function Invoke-AuditCheck {
    param(
        [string[]]$ArgumentList = @()
    )
    $pwshArgs = @('-NoProfile', '-NonInteractive', '-File', $AuditHelper) + $ArgumentList
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $PwshBin
    foreach ($arg in $pwshArgs) {
        $psi.ArgumentList.Add($arg)
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Stdout   = $stdoutTask.GetAwaiter().GetResult()
        Stderr   = $stderrTask.GetAwaiter().GetResult()
    }
}

$TmpRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "offload-audit-test-$([System.Guid]::NewGuid().ToString('N'))")
[System.IO.Directory]::CreateDirectory($TmpRoot) | Out-Null

try {
    # Test 1: Missing arguments
    $res = Invoke-AuditCheck @()
    Assert-Equal $res.ExitCode 2 "missing arguments exits 2"
    Assert-True ($res.Stderr -match "missing required option") "missing arguments writes error"

    # Test 2: Help flag
    $res = Invoke-AuditCheck @('--help')
    Assert-Equal $res.ExitCode 0 "help flag exits 0"
    Assert-True ($res.Stderr -match "Usage:") "help flag shows usage"

    # Test 3: Malformed JSON ledger
    $res = Invoke-AuditCheck @('--ledger', '{not-json', '--auditor', '{"citation_audits":[]}')
    Assert-Equal $res.ExitCode 2 "malformed ledger JSON exits 2"
    Assert-True ($res.Stderr -match "ledger input is not valid JSON") "malformed ledger reports error"

    # Test 4: Malformed JSON auditor
    $res = Invoke-AuditCheck @('--ledger', '[]', '--auditor', '{not-json')
    Assert-Equal $res.ExitCode 2 "malformed auditor JSON exits 2"
    Assert-True ($res.Stderr -match "auditor input is not valid JSON") "malformed auditor reports error"

    # Fixtures setup
    $standardLedger = '[{"claim_id":"c1","claim":"Claim 1","citations":["https://example.com/1","https://example.com/2"],"decision_relevance":"critical","status":"supported"},{"claim_id":"c2","claim":"Claim 2","citations":["https://example.com/3"],"decision_relevance":"supporting","status":"supported"}]'

    # Test 5: Empty citation_audits rejected when required pairs exist even when final_status is pass (Criterion 1)
    $emptyAuditsPass = '{"citation_audits":[],"final_status":"pass"}'
    $res = Invoke-AuditCheck @('--ledger', $standardLedger, '--auditor', $emptyAuditsPass)
    Assert-Equal $res.ExitCode 2 "empty audits with required pairs exits 2"
    Assert-True ($res.Stderr -match "Missing audit coverage") "empty audits reports missing coverage"

    # Test 6: Partial citation_audits rejected when missing one pair even when final_status is pass (Criterion 1)
    $partialAuditsPass = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
    $res = Invoke-AuditCheck @('--ledger', $standardLedger, '--auditor', $partialAuditsPass)
    Assert-Equal $res.ExitCode 2 "partial audits missing c2 pair exits 2"
    Assert-True ($res.Stderr -match "Missing audit coverage for required pair: claim_id `"c2`"") "partial audits identifies missing c2 pair"

    # Test 7: Duplicate claim/citation pairs rejected (Criterion 2)
    $duplicateAudits = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
    $res = Invoke-AuditCheck @('--ledger', $standardLedger, '--auditor', $duplicateAudits)
    Assert-Equal $res.ExitCode 2 "duplicate audits pair exits 2"
    Assert-True ($res.Stderr -match "Duplicate audit entry found") "duplicate audits identified in error"

    # Test 8: Unknown claim/citation pair rejected (Criterion 2)
    $unknownAudits = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/unknown","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
    $res = Invoke-AuditCheck @('--ledger', $standardLedger, '--auditor', $unknownAudits)
    Assert-Equal $res.ExitCode 2 "unknown audit pair exits 2"
    Assert-True ($res.Stderr -match "Unknown audit entry") "unknown audit identified in error"

    # Test 9: Two citations for one claim require separate coverage (Criterion 2)
    $singleClaimTwoCitations = '[{"claim_id":"c1","claim":"Claim 1","citations":["https://example.com/a","https://example.com/b"],"decision_relevance":"critical","status":"supported"}]'
    $singleCoverageOnly = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/a","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
    $res = Invoke-AuditCheck @('--ledger', $singleClaimTwoCitations, '--auditor', $singleCoverageOnly)
    Assert-Equal $res.ExitCode 2 "only one of two citations audited exits 2"
    Assert-True ($res.Stderr -match "Missing audit coverage for required pair: claim_id `"c1`", citation_url `"https://example.com/b`"") "reports second citation missing"

    # Test 10: Every required pair must have supported verdict before automated acceptance: resolves=false rejected (Criterion 3)
    $resolvesFalse = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":false,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
    $res = Invoke-AuditCheck @('--ledger', $standardLedger, '--auditor', $resolvesFalse)
    Assert-Equal $res.ExitCode 2 "resolves=false with final_status pass exits 2"
    Assert-True ($res.Stderr -match "has resolves=false") "resolves=false identified as contradiction"

    # Test 11: Non-supporting verdict (refutes) cannot coexist with pass (Criterion 3)
    $refutesVerdict = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"refutes","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
    $res = Invoke-AuditCheck @('--ledger', $standardLedger, '--auditor', $refutesVerdict)
    Assert-Equal $res.ExitCode 2 "refutes verdict with final_status pass exits 2"
    Assert-True ($res.Stderr -match "has non-supporting verdict `"refutes`"") "refutes verdict identified"

    # Test 12: Non-supporting verdict (partially_supports) cannot coexist with pass (Criterion 3)
    $partiallySupports = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"partially_supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
    $res = Invoke-AuditCheck @('--ledger', $standardLedger, '--auditor', $partiallySupports)
    Assert-Equal $res.ExitCode 2 "partially_supports verdict with final_status pass exits 2"
    Assert-True ($res.Stderr -match "has non-supporting verdict `"partially_supports`"") "partially_supports verdict identified"

    # Test 13: Non-supporting verdict (unsupported) cannot coexist with pass (Criterion 3)
    $unsupportedVerdict = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"unsupported","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
    $res = Invoke-AuditCheck @('--ledger', $standardLedger, '--auditor', $unsupportedVerdict)
    Assert-Equal $res.ExitCode 2 "unsupported verdict with final_status pass exits 2"
    Assert-True ($res.Stderr -match "has non-supporting verdict `"unsupported`"") "unsupported verdict identified"

    # Test 14: claims_to_remove cannot coexist with pass (Criterion 3)
    $claimsToRemoveWithPass = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass","claims_to_remove":["c1"]}'
    $res = Invoke-AuditCheck @('--ledger', $standardLedger, '--auditor', $claimsToRemoveWithPass)
    Assert-Equal $res.ExitCode 2 "claims_to_remove with pass exits 2"
    Assert-True ($res.Stderr -match "claims_to_remove is not empty") "claims_to_remove identified"

    # Test 15: claims_to_narrow cannot coexist with pass (Criterion 3)
    $claimsToNarrowWithPass = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass","claims_to_narrow":["c1"]}'
    $res = Invoke-AuditCheck @('--ledger', $standardLedger, '--auditor', $claimsToNarrowWithPass)
    Assert-Equal $res.ExitCode 2 "claims_to_narrow with pass exits 2"
    Assert-True ($res.Stderr -match "claims_to_narrow is not empty") "claims_to_narrow identified"

    # Test 16: claims_unresolved cannot coexist with pass (Criterion 3)
    $claimsUnresolvedWithPass = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass","claims_unresolved":["c1"]}'
    $res = Invoke-AuditCheck @('--ledger', $standardLedger, '--auditor', $claimsUnresolvedWithPass)
    Assert-Equal $res.ExitCode 2 "claims_unresolved with pass exits 2"
    Assert-True ($res.Stderr -match "claims_unresolved is not empty") "claims_unresolved identified"

    # Test 17: Zero auditable pairs rejected by default when citations required (Criterion 4)
    $emptyLedger = '[]'
    $emptyAuditor = '{"citation_audits":[],"final_status":"pass"}'
    $res = Invoke-AuditCheck @('--ledger', $emptyLedger, '--auditor', $emptyAuditor)
    Assert-Equal $res.ExitCode 2 "empty ledger rejected by default exits 2"
    Assert-True ($res.Stderr -match "Ledger contains no auditable claim/citation pairs, but citations are required") "zero pairs rejected when citations required"

    # Test 18: Zero auditable pairs accepted with explicit --allow-empty branch (Criterion 4)
    $res = Invoke-AuditCheck @('--ledger', $emptyLedger, '--auditor', $emptyAuditor, '--allow-empty')
    Assert-Equal $res.ExitCode 0 "empty ledger accepted under --allow-empty branch exits 0"
    Assert-True ($res.Stdout -match "ok: citation audit verified \(0 required pair") "zero pairs verified with --allow-empty"

    # Test 19: Zero auditable pairs with --allow-empty rejects unexpected audits (Criterion 4)
    $res = Invoke-AuditCheck @('--ledger', $emptyLedger, '--auditor', $singleCoverageOnly, '--allow-empty')
    Assert-Equal $res.ExitCode 2 "empty ledger with unexpected audits exits 2"
    Assert-True ($res.Stderr -match "Unknown audit entry") "unexpected audits detected on empty ledger"

    # Test 20: Complete valid coverage passes automated acceptance with exit 0 (Criterion 5)
    $completeValidPass = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
    $res = Invoke-AuditCheck @('--ledger', $standardLedger, '--auditor', $completeValidPass)
    Assert-Equal $res.ExitCode 0 "complete valid coverage exits 0"
    Assert-True ($res.Stdout -match "ok: citation audit verified \(3 required pair\(s\) covered with supported verdicts\)") "reports successful verification"

    # Test 21: Complete valid coverage with legitimate revise verdict returns exit 1 (Criterion 5)
    $completeValidRevise = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"refutes","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"revise","claims_to_remove":["c1"]}'
    $res = Invoke-AuditCheck @('--ledger', $standardLedger, '--auditor', $completeValidRevise)
    Assert-Equal $res.ExitCode 1 "legitimate revise verdict returns exit 1"
    Assert-True ($res.Stderr -match "revise: citation audit verified; revision required by auditor") "reports revision required"

    # Test 22: Contradictory revise (all supported, no claims marked) returns exit 2 (Criterion 5)
    $contradictoryRevise = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"revise"}'
    $res = Invoke-AuditCheck @('--ledger', $standardLedger, '--auditor', $contradictoryRevise)
    Assert-Equal $res.ExitCode 2 "contradictory revise exits 2"
    Assert-True ($res.Stderr -match "all citations are supported and no claims are marked to remove") "identifies contradictory revise"

    # Test 23: Incomplete final_status returns exit 2
    $incompleteAudits = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"incomplete"}'
    $res = Invoke-AuditCheck @('--ledger', $standardLedger, '--auditor', $incompleteAudits)
    Assert-Equal $res.ExitCode 2 "incomplete final_status exits 2"
    Assert-True ($res.Stderr -match "Audit final_status is incomplete") "incomplete status identified"

    # Test 24: File path inputs and structured_output wrappers
    $synthWrapper = [ordered]@{
        response = "Some LLM response"
        structured_output = [ordered]@{
            claim_ledger = @(
                [ordered]@{
                    claim_id = "c1"
                    claim = "Claim 1"
                    citations = @("https://example.com/1")
                    decision_relevance = "critical"
                    status = "supported"
                }
            )
            proposed_answer = "Answer text"
            profile_used = "standard"
        }
    }
    $synthPath = Join-Path $TmpRoot "synthesizer.json"
    [System.IO.File]::WriteAllText($synthPath, ($synthWrapper | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $auditorWrapper = [ordered]@{
        response = "Some LLM response"
        structured_output = [ordered]@{
            citation_audits = @(
                [ordered]@{
                    claim_id = "c1"
                    citation_url = "https://example.com/1"
                    resolves = $true
                    support_verdict = "supports"
                    source_classification = "primary"
                }
            )
            final_status = "pass"
        }
    }
    $auditorPath = Join-Path $TmpRoot "auditor.json"
    [System.IO.File]::WriteAllText($auditorPath, ($auditorWrapper | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $res = Invoke-AuditCheck @('--ledger', $synthPath, '--auditor', $auditorPath)
    Assert-Equal $res.ExitCode 0 "wrapper files pass verification with exit 0"
    Assert-True ($res.Stdout -match "ok: citation audit verified") "file wrapper succeeds"

    # Test 25: --json output format
    $res = Invoke-AuditCheck @('--ledger', $synthPath, '--auditor', $auditorPath, '--json')
    Assert-Equal $res.ExitCode 0 "--json flag exits 0 for valid audit"
    $jsonObj = $null
    try {
        $jsonObj = [System.Text.Json.Nodes.JsonNode]::Parse($res.Stdout).AsObject()
    } catch {
        Fail "json-parsing" "Failed to parse json output: $($res.Stdout)"
    }
    $validVal = ($jsonObj["valid"].ToString().ToLowerInvariant() -eq "true")
    Assert-Equal $validVal $true "json output valid is true"
    Assert-Equal ($jsonObj["status"].ToString()) "pass" "json output status is pass"
    Assert-Equal ([int]$jsonObj["required_pairs_count"].ToString()) 1 "json output required_pairs_count is 1"
    Assert-Equal ([int]$jsonObj["audited_pairs_count"].ToString()) 1 "json output audited_pairs_count is 1"

    [Console]::Out.WriteLine("all citation audit checks passed ($script:TotalTests tests)")
} finally {
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
