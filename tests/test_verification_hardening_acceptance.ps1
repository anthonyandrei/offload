#!/usr/bin/env pwsh
# tests/test_verification_hardening_acceptance.ps1
# Self-contained acceptance test suite for worker result acceptance and unrunnable gates.
# Implements contracts specified in offload-verification-hardening/spec.md (Sections 4, 5, and Test Strategy).
# Constraints: Standalone PowerShell 7 / .NET only, no Pester, Python, jq, Bash, or network.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# Compact Self-Contained Assertion Harness
# ---------------------------------------------------------------------------

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
    if ($env:OFFLOAD_CONTINUE_ON_FAIL -ne '1' -and $env:OFFLOAD_TEST_CONTINUE_ON_FAIL -ne '1') {
        exit 1
    }
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

function Assert-NotEqual($actual, $expected, [string]$name) {
    if ($actual -ne $expected) {
        Pass $name
    } else {
        Fail $name "Expected not '$expected', but got '$actual'"
    }
}

# ---------------------------------------------------------------------------
# Public Process Runners and Helpers
# ---------------------------------------------------------------------------

$PwshBin = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $PwshBin) {
    $PwshBin = (Get-Process -Id $PID).Path
}

$RootDir = Split-Path -Parent $PSScriptRoot
$ScriptsDir = Join-Path $RootDir 'scripts'

function Invoke-Helper {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptName,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = $null
    )
    $scriptPath = Join-Path $ScriptsDir $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Fail "Helper existence check" "Script '$ScriptName' does not exist at '$scriptPath'"
    }
    $pwshArgs = @('-NoProfile', '-NonInteractive', '-File', $scriptPath) + $ArgumentList
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $PwshBin
    foreach ($arg in $pwshArgs) {
        $psi.ArgumentList.Add($arg)
    }
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    foreach ($key in $Environment.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$Environment[$key]
    }
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

# ---------------------------------------------------------------------------
# Test Environment Setup
# ---------------------------------------------------------------------------

$TmpRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "offload-accept-test-$([System.Guid]::NewGuid().ToString('N'))")
[System.IO.Directory]::CreateDirectory($TmpRoot) | Out-Null

function Write-TestFile([string]$relativePath, [string]$content) {
    $target = Join-Path $TmpRoot $relativePath
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [System.IO.File]::WriteAllText($target, $content, [System.Text.Encoding]::UTF8)
    return $target
}

function Write-TestJson([string]$relativePath, $object) {
    $json = $object | ConvertTo-Json -Depth 20 -Compress
    return Write-TestFile $relativePath $json
}

try {
    # =======================================================================
    # 1. Extractor Seam: extract-structured-output.ps1
    # Spec: Reject exit 0 with missing structured output.
    #       Reject missing, invalid, scalar, or otherwise unparsable structured output.
    #       Keep worker prose out of downstream structured prompts.
    #       Exit 0, top-level status, or nonempty prose alone MUST NOT establish acceptance.
    # =======================================================================

    # 1.1: Reject exit 0 worker response where structured_output is missing entirely
    $missingSoFile = Write-TestJson "worker-missing-so.json" ([ordered]@{
        status = "SUCCESS"
        response = "Task executed successfully, but structured_output was not provided."
    })
    $resMissingSo = Invoke-Helper -ScriptName "extract-structured-output.ps1" -ArgumentList @($missingSoFile)
    Assert-NotEqual $resMissingSo.ExitCode 0 "extract: rejects exit 0 worker response missing structured_output"

    # 1.2: Reject malformed JSON input
    $malformedJsonFile = Write-TestFile "worker-malformed.json" "{ unclosed json status: SUCCESS "
    $resMalformed = Invoke-Helper -ScriptName "extract-structured-output.ps1" -ArgumentList @($malformedJsonFile)
    Assert-NotEqual $resMalformed.ExitCode 0 "extract: rejects malformed JSON"

    # 1.3: Reject non-object top-level JSON
    $nonObjectFile = Write-TestFile "worker-non-object.json" '["array", "of", "values"]'
    $resNonObject = Invoke-Helper -ScriptName "extract-structured-output.ps1" -ArgumentList @($nonObjectFile)
    Assert-NotEqual $resNonObject.ExitCode 0 "extract: rejects non-object top-level JSON"

    # 1.4: Valid structured_output extraction extracts structured fields and omits worker prose
    $validWorkerFile = Write-TestJson "worker-valid-so.json" ([ordered]@{
        status = "SUCCESS"
        response = "Long rambling prose response from model..."
        structured_output = [ordered]@{
            run_id = "run-1"
            angle_id = "angle-a"
            status = "success"
            findings = @("finding 1", "finding 2")
        }
    })
    $resValidExtract = Invoke-Helper -ScriptName "extract-structured-output.ps1" -ArgumentList @($validWorkerFile)
    Assert-Equal $resValidExtract.ExitCode 0 "extract: valid object structured_output exits 0"
    Assert-False ($resValidExtract.Stdout.Contains("Long rambling prose response")) "extract: omits top-level prose response"
    Assert-False ($resValidExtract.Stdout.Contains('"response"')) "extract: omits response property key"

    # 1.5: Hardening: Reject structured_output that is null
    $nullSoFile = Write-TestJson "worker-null-so.json" ([ordered]@{
        status = "SUCCESS"
        response = "Done"
        structured_output = $null
    })
    $resNullSo = Invoke-Helper -ScriptName "extract-structured-output.ps1" -ArgumentList @($nullSoFile)
    Assert-NotEqual $resNullSo.ExitCode 0 "extract: rejects null structured_output"

    # 1.6: Hardening: Reject scalar string structured_output
    $scalarStringFile = Write-TestJson "worker-scalar-str.json" ([ordered]@{
        status = "SUCCESS"
        response = "Done"
        structured_output = "just a plain string, not structured data"
    })
    $resScalarStr = Invoke-Helper -ScriptName "extract-structured-output.ps1" -ArgumentList @($scalarStringFile)
    Assert-NotEqual $resScalarStr.ExitCode 0 "extract: rejects scalar string structured_output"

    # 1.7: Hardening: Reject scalar integer structured_output
    $scalarIntFile = Write-TestJson "worker-scalar-int.json" ([ordered]@{
        status = "SUCCESS"
        response = "Done"
        structured_output = 42
    })
    $resScalarInt = Invoke-Helper -ScriptName "extract-structured-output.ps1" -ArgumentList @($scalarIntFile)
    Assert-NotEqual $resScalarInt.ExitCode 0 "extract: rejects scalar integer structured_output"

    # 1.8: Hardening: Reject scalar boolean structured_output
    $scalarBoolFile = Write-TestJson "worker-scalar-bool.json" ([ordered]@{
        status = "SUCCESS"
        response = "Done"
        structured_output = $true
    })
    $resScalarBool = Invoke-Helper -ScriptName "extract-structured-output.ps1" -ArgumentList @($scalarBoolFile)
    Assert-NotEqual $resScalarBool.ExitCode 0 "extract: rejects scalar boolean structured_output"

    # 1.9: Hardening: Array mode (--array) rejects when any input file has scalar or null structured_output
    $resArrayScalar = Invoke-Helper -ScriptName "extract-structured-output.ps1" -ArgumentList @("--array", $validWorkerFile, $scalarStringFile)
    Assert-NotEqual $resArrayScalar.ExitCode 0 "extract: array mode rejects if any file has scalar structured_output"

    $resArrayNull = Invoke-Helper -ScriptName "extract-structured-output.ps1" -ArgumentList @("--array", $validWorkerFile, $nullSoFile)
    Assert-NotEqual $resArrayNull.ExitCode 0 "extract: array mode rejects if any file has null structured_output"

    # =======================================================================
    # 2. Selector Seam: select-research-outputs.ps1
    # Spec: Require mode-specific success status and nonempty fields named by assignment schema.
    #       Require evidence paths or equivalent result references where mode calls for them.
    #       Reject valid JSON with missing or empty mode-required fields.
    #       Preserve explicit accepted-attempt selection; never select by wildcard.
    # =======================================================================

    $researchBaseDir = Join-Path $TmpRoot "research-workspace"
    [System.IO.Directory]::CreateDirectory($researchBaseDir) | Out-Null

    function New-ResearcherArtifact([hashtable]$soOverrides = @{}) {
        $so = [ordered]@{
            run_id = "test-run"
            angle_id = "angle-docs"
            status = "success"
            question = "What is the timeout default?"
            evidence_angle = "Official documentation"
            findings = @(
                [ordered]@{
                    claim = "Worker timeout is 20m"
                    source_urls = @("https://example.com/docs/timeout")
                    source_type = "primary"
                }
            )
        }
        foreach ($k in $soOverrides.Keys) {
            $so[$k] = $soOverrides[$k]
        }
        return [ordered]@{
            response = "Worker prose explanation..."
            structured_output = $so
        }
    }

    function New-WorkerRoutingRecord([string]$workerId, [string]$outputPath, [hashtable]$attemptOverrides = @{}) {
        $att = [ordered]@{
            worker_id = $workerId
            role = "researcher"
            mode = "web-research"
            attempt = 1
            policy_revision = "2026-09-03.1"
            route = "default"
            model = "gemini-3.8-flash-high"
            effort = "high"
            reason = "Initial default dispatch"
            started_at = "2026-09-03T00:00:00Z"
            ended_at = "2026-09-03T00:01:00Z"
            duration_seconds = 60.0
            exit_code = 0
            state = "completed"
            failure_class = "none"
            verification_status = "passed"
            evidence_paths = @($outputPath)
            usage = $null
        }
        foreach ($k in $attemptOverrides.Keys) {
            $att[$k] = $attemptOverrides[$k]
        }
        return [ordered]@{
            schema_version = 1
            attempts = @($att)
        }
    }

    # 2.1: Valid researcher artifact with complete substantive fields is accepted
    $artValidPath = Join-Path $researchBaseDir "researcher-valid.json"
    [System.IO.File]::WriteAllText($artValidPath, ((New-ResearcherArtifact) | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $manifestValidPath = Join-Path $researchBaseDir "manifest-valid.json"
    $manifestValid = [ordered]@{
        workers = @(
            [ordered]@{
                id = "worker-valid"
                role = "researcher"
                status = "completed"
                accepted_attempt = 1
                output = "researcher-valid.json"
                routing = New-WorkerRoutingRecord "worker-valid" "researcher-valid.json"
            }
        )
    }
    [System.IO.File]::WriteAllText($manifestValidPath, ($manifestValid | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $resValidSelect = Invoke-Helper -ScriptName "select-research-outputs.ps1" -ArgumentList @("--workers", $manifestValidPath, "--base-dir", $researchBaseDir)
    Assert-Equal $resValidSelect.ExitCode 0 "selector: valid researcher artifact exits 0"
    $parsedValidSelect = $resValidSelect.Stdout | ConvertFrom-Json
    Assert-Equal $parsedValidSelect.selected_files.Count 1 "selector: selects 1 file for valid researcher"
    Assert-Equal $parsedValidSelect.independent_angles.Count 1 "selector: reports 1 independent angle"
    Assert-Equal $parsedValidSelect.omitted_workers.Count 0 "selector: no omitted workers for valid researcher"

    # 2.2: Hardening: Reject artifact with missing mode-required field 'findings'
    $artMissingFindingsPath = Join-Path $researchBaseDir "researcher-no-findings.json"
    $artNoFindingsObj = New-ResearcherArtifact
    $artNoFindingsObj.structured_output.Remove("findings")
    [System.IO.File]::WriteAllText($artMissingFindingsPath, ($artNoFindingsObj | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $manifestNoFindingsPath = Join-Path $researchBaseDir "manifest-no-findings.json"
    $manifestNoFindings = [ordered]@{
        workers = @(
            [ordered]@{
                id = "worker-no-findings"
                role = "researcher"
                status = "completed"
                accepted_attempt = 1
                output = "researcher-no-findings.json"
                routing = New-WorkerRoutingRecord "worker-no-findings" "researcher-no-findings.json"
            }
        )
    }
    [System.IO.File]::WriteAllText($manifestNoFindingsPath, ($manifestNoFindings | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $resNoFindings = Invoke-Helper -ScriptName "select-research-outputs.ps1" -ArgumentList @("--workers", $manifestNoFindingsPath, "--base-dir", $researchBaseDir)
    Assert-Equal $resNoFindings.ExitCode 0 "selector: executes and omits invalid artifact"
    $parsedNoFindings = $resNoFindings.Stdout | ConvertFrom-Json
    Assert-Equal $parsedNoFindings.selected_files.Count 0 "selector: rejects artifact missing mode-required findings field"
    Assert-Equal $parsedNoFindings.omitted_workers.Count 1 "selector: records omission for artifact missing findings"

    # 2.3: Hardening: Reject artifact with empty findings array 'findings: []'
    $artEmptyFindingsPath = Join-Path $researchBaseDir "researcher-empty-findings.json"
    $artEmptyFindingsObj = New-ResearcherArtifact @{ findings = @() }
    [System.IO.File]::WriteAllText($artEmptyFindingsPath, ($artEmptyFindingsObj | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $manifestEmptyFindingsPath = Join-Path $researchBaseDir "manifest-empty-findings.json"
    $manifestEmptyFindings = [ordered]@{
        workers = @(
            [ordered]@{
                id = "worker-empty-findings"
                role = "researcher"
                status = "completed"
                accepted_attempt = 1
                output = "researcher-empty-findings.json"
                routing = New-WorkerRoutingRecord "worker-empty-findings" "researcher-empty-findings.json"
            }
        )
    }
    [System.IO.File]::WriteAllText($manifestEmptyFindingsPath, ($manifestEmptyFindings | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $resEmptyFindings = Invoke-Helper -ScriptName "select-research-outputs.ps1" -ArgumentList @("--workers", $manifestEmptyFindingsPath, "--base-dir", $researchBaseDir)
    $parsedEmptyFindings = $resEmptyFindings.Stdout | ConvertFrom-Json
    Assert-Equal $parsedEmptyFindings.selected_files.Count 0 "selector: rejects artifact with empty findings array"
    Assert-Equal $parsedEmptyFindings.omitted_workers.Count 1 "selector: records omission for artifact with empty findings"

    # 2.4: Hardening: Reject artifact with missing or whitespace-only 'question'
    $artEmptyQuestionPath = Join-Path $researchBaseDir "researcher-empty-question.json"
    $artEmptyQuestionObj = New-ResearcherArtifact @{ question = "   " }
    [System.IO.File]::WriteAllText($artEmptyQuestionPath, ($artEmptyQuestionObj | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $manifestEmptyQuestionPath = Join-Path $researchBaseDir "manifest-empty-question.json"
    $manifestEmptyQuestion = [ordered]@{
        workers = @(
            [ordered]@{
                id = "worker-empty-question"
                role = "researcher"
                status = "completed"
                accepted_attempt = 1
                output = "researcher-empty-question.json"
                routing = New-WorkerRoutingRecord "worker-empty-question" "researcher-empty-question.json"
            }
        )
    }
    [System.IO.File]::WriteAllText($manifestEmptyQuestionPath, ($manifestEmptyQuestion | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $resEmptyQuestion = Invoke-Helper -ScriptName "select-research-outputs.ps1" -ArgumentList @("--workers", $manifestEmptyQuestionPath, "--base-dir", $researchBaseDir)
    $parsedEmptyQuestion = $resEmptyQuestion.Stdout | ConvertFrom-Json
    Assert-Equal $parsedEmptyQuestion.selected_files.Count 0 "selector: rejects artifact with empty question"
    Assert-Equal $parsedEmptyQuestion.omitted_workers.Count 1 "selector: records omission for empty question"

    # 2.5: Hardening: Reject artifact where findings lack evidence references (source_urls empty or missing)
    $artNoSourcesPath = Join-Path $researchBaseDir "researcher-no-sources.json"
    $artNoSourcesObj = New-ResearcherArtifact @{
        findings = @(
            [ordered]@{
                claim = "Unsupported assertion without citations"
                source_urls = @()
                source_type = "primary"
            }
        )
    }
    [System.IO.File]::WriteAllText($artNoSourcesPath, ($artNoSourcesObj | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $manifestNoSourcesPath = Join-Path $researchBaseDir "manifest-no-sources.json"
    $manifestNoSources = [ordered]@{
        workers = @(
            [ordered]@{
                id = "worker-no-sources"
                role = "researcher"
                status = "completed"
                accepted_attempt = 1
                output = "researcher-no-sources.json"
                routing = New-WorkerRoutingRecord "worker-no-sources" "researcher-no-sources.json"
            }
        )
    }
    [System.IO.File]::WriteAllText($manifestNoSourcesPath, ($manifestNoSources | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $resNoSources = Invoke-Helper -ScriptName "select-research-outputs.ps1" -ArgumentList @("--workers", $manifestNoSourcesPath, "--base-dir", $researchBaseDir)
    $parsedNoSources = $resNoSources.Stdout | ConvertFrom-Json
    Assert-Equal $parsedNoSources.selected_files.Count 0 "selector: rejects artifact where finding lacks evidence references (source_urls)"
    Assert-Equal $parsedNoSources.omitted_workers.Count 1 "selector: records omission for finding lacking citations"

    # 2.6: Hardening: Reject artifact with non-success status
    $artStatusFailedPath = Join-Path $researchBaseDir "researcher-status-failed.json"
    $artStatusFailedObj = New-ResearcherArtifact @{ status = "failed" }
    [System.IO.File]::WriteAllText($artStatusFailedPath, ($artStatusFailedObj | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $manifestStatusFailedPath = Join-Path $researchBaseDir "manifest-status-failed.json"
    $manifestStatusFailed = [ordered]@{
        workers = @(
            [ordered]@{
                id = "worker-status-failed"
                role = "researcher"
                status = "completed"
                accepted_attempt = 1
                output = "researcher-status-failed.json"
                routing = New-WorkerRoutingRecord "worker-status-failed" "researcher-status-failed.json"
            }
        )
    }
    [System.IO.File]::WriteAllText($manifestStatusFailedPath, ($manifestStatusFailed | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $resStatusFailed = Invoke-Helper -ScriptName "select-research-outputs.ps1" -ArgumentList @("--workers", $manifestStatusFailedPath, "--base-dir", $researchBaseDir)
    $parsedStatusFailed = $resStatusFailed.Stdout | ConvertFrom-Json
    Assert-Equal $parsedStatusFailed.selected_files.Count 0 "selector: rejects artifact with non-success status"

    # =======================================================================
    # 3. Separation of Process Completion from Verification Status
    # Spec: Exit 0 alone does NOT establish verification or acceptance.
    #       Must pass evidence, scope, gate, review, or citation checks.
    # =======================================================================

    # 3.1: Exit 0 with valid structured output is omitted when verification_status is 'failed'
    $manifestVerFailedPath = Join-Path $researchBaseDir "manifest-ver-failed.json"
    $manifestVerFailed = [ordered]@{
        workers = @(
            [ordered]@{
                id = "worker-ver-failed"
                role = "researcher"
                status = "completed"
                accepted_attempt = 1
                output = "researcher-valid.json"
                routing = New-WorkerRoutingRecord "worker-ver-failed" "researcher-valid.json" @{ verification_status = "failed" }
            }
        )
    }
    [System.IO.File]::WriteAllText($manifestVerFailedPath, ($manifestVerFailed | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $resVerFailed = Invoke-Helper -ScriptName "select-research-outputs.ps1" -ArgumentList @("--workers", $manifestVerFailedPath, "--base-dir", $researchBaseDir)
    $parsedVerFailed = $resVerFailed.Stdout | ConvertFrom-Json
    Assert-Equal $parsedVerFailed.selected_files.Count 0 "selector: omits worker when verification_status is failed"
    Assert-Equal $parsedVerFailed.omitted_workers.Count 1 "selector: records omission for failed verification"

    # 3.2: Exit 0 is omitted when verification_status is 'pending' or 'not_performed'
    $manifestVerPendingPath = Join-Path $researchBaseDir "manifest-ver-pending.json"
    $manifestVerPending = [ordered]@{
        workers = @(
            [ordered]@{
                id = "worker-ver-pending"
                role = "researcher"
                status = "completed"
                accepted_attempt = 1
                output = "researcher-valid.json"
                routing = New-WorkerRoutingRecord "worker-ver-pending" "researcher-valid.json" @{ verification_status = "pending" }
            }
        )
    }
    [System.IO.File]::WriteAllText($manifestVerPendingPath, ($manifestVerPending | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $resVerPending = Invoke-Helper -ScriptName "select-research-outputs.ps1" -ArgumentList @("--workers", $manifestVerPendingPath, "--base-dir", $researchBaseDir)
    $parsedVerPending = $resVerPending.Stdout | ConvertFrom-Json
    Assert-Equal $parsedVerPending.selected_files.Count 0 "selector: omits worker when verification_status is pending"

    # 3.3: Exit 0 is omitted when evidence_paths does not match output
    $manifestPathMismatch = Join-Path $researchBaseDir "manifest-path-mismatch.json"
    $manifestMismatch = [ordered]@{
        workers = @(
            [ordered]@{
                id = "worker-mismatch"
                role = "researcher"
                status = "completed"
                accepted_attempt = 1
                output = "researcher-valid.json"
                routing = New-WorkerRoutingRecord "worker-mismatch" "different-file.json"
            }
        )
    }
    [System.IO.File]::WriteAllText($manifestPathMismatch, ($manifestMismatch | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $resMismatch = Invoke-Helper -ScriptName "select-research-outputs.ps1" -ArgumentList @("--workers", $manifestPathMismatch, "--base-dir", $researchBaseDir)
    $parsedMismatch = $resMismatch.Stdout | ConvertFrom-Json
    Assert-Equal $parsedMismatch.selected_files.Count 0 "selector: omits worker when evidence_paths does not match output"

    # 3.4: Exit 0 is omitted when selected output artifact does not exist on disk
    $manifestMissingDiskPath = Join-Path $researchBaseDir "manifest-missing-disk.json"
    $manifestMissingDisk = [ordered]@{
        workers = @(
            [ordered]@{
                id = "worker-missing-disk"
                role = "researcher"
                status = "completed"
                accepted_attempt = 1
                output = "nonexistent-artifact.json"
                routing = New-WorkerRoutingRecord "worker-missing-disk" "nonexistent-artifact.json"
            }
        )
    }
    [System.IO.File]::WriteAllText($manifestMissingDiskPath, ($manifestMissingDisk | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $resMissingDisk = Invoke-Helper -ScriptName "select-research-outputs.ps1" -ArgumentList @("--workers", $manifestMissingDiskPath, "--base-dir", $researchBaseDir)
    $parsedMissingDisk = $resMissingDisk.Stdout | ConvertFrom-Json
    Assert-Equal $parsedMissingDisk.selected_files.Count 0 "selector: omits worker when output file is missing on disk"

    # 3.5: Reviewer verification seam: check-review-verdict.ps1
    $reviewArtifactPath = Write-TestFile "review.patch" "diff --git a/test.py b/test.py`n+def verified_function(): pass`n"
    $reviewCriteriaPath = Write-TestJson "review-criteria.json" ([ordered]@{
        criteria = @(
            [ordered]@{ criterion_id = "CRIT-1" }
        )
    })

    $reviewPassingPath = Write-TestJson "review-passing.json" ([ordered]@{
        structured_output = [ordered]@{
            criteria = @(
                [ordered]@{
                    criterion_id = "CRIT-1"
                    verdict = "pass"
                    quote = "+def verified_function(): pass"
                }
            )
        }
    })
    $resReviewPass = Invoke-Helper -ScriptName "check-review-verdict.ps1" -ArgumentList @(
        "--criteria", $reviewCriteriaPath, "--review", $reviewPassingPath, "--artifact", $reviewArtifactPath
    )
    Assert-Equal $resReviewPass.ExitCode 0 "reviewer seam: exact verbatim quote exits 0"

    $reviewFailPath = Write-TestJson "review-fail.json" ([ordered]@{
        structured_output = [ordered]@{
            criteria = @(
                [ordered]@{
                    criterion_id = "CRIT-1"
                    verdict = "fail"
                    quote = ""
                }
            )
        }
    })
    $resReviewFail = Invoke-Helper -ScriptName "check-review-verdict.ps1" -ArgumentList @(
        "--criteria", $reviewCriteriaPath, "--review", $reviewFailPath, "--artifact", $reviewArtifactPath
    )
    Assert-Equal $resReviewFail.ExitCode 1 "reviewer seam: failing verdict exits 1 for orchestrator review"

    $reviewForgedPath = Write-TestJson "review-forged.json" ([ordered]@{
        structured_output = [ordered]@{
            criteria = @(
                [ordered]@{
                    criterion_id = "CRIT-1"
                    verdict = "pass"
                    quote = "+def fake_nonexistent_function(): pass"
                }
            )
        }
    })
    $resReviewForged = Invoke-Helper -ScriptName "check-review-verdict.ps1" -ArgumentList @(
        "--criteria", $reviewCriteriaPath, "--review", $reviewForgedPath, "--artifact", $reviewArtifactPath
    )
    Assert-Equal $resReviewForged.ExitCode 2 "reviewer seam: forged quote exits 2 (rejected review)"

    # 3.6: Scope verification seam: check-execution-scope.ps1
    # For execution work, acceptance requires execution-scope and frozen-path checks.
    $gitRepoDir = Join-Path $TmpRoot "scope-test-repo"
    [System.IO.Directory]::CreateDirectory($gitRepoDir) | Out-Null
    & git -C $gitRepoDir init -q
    & git -C $gitRepoDir config user.name "Gate Tester"
    & git -C $gitRepoDir config user.email "tester@example.com"
    [System.IO.File]::WriteAllText((Join-Path $gitRepoDir "owned1.txt"), "owned 1`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $gitRepoDir "owned2.txt"), "owned 2`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $gitRepoDir "frozen1.txt"), "frozen 1`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $gitRepoDir "unowned.txt"), "unowned 1`n", [System.Text.Encoding]::UTF8)
    & git -C $gitRepoDir add .
    & git -C $gitRepoDir commit -q -m "Initial baseline commit"
    $baselineRev = (& git -C $gitRepoDir rev-parse HEAD).Trim()

    # Scope check passes when only owned files are modified
    [System.IO.File]::AppendAllText((Join-Path $gitRepoDir "owned1.txt"), "owned modification`n", [System.Text.Encoding]::UTF8)
    $resScopePass = Invoke-Helper -ScriptName "check-execution-scope.ps1" -ArgumentList @(
        "--baseline", $baselineRev,
        "--owned", "owned1.txt",
        "--owned", "owned2.txt",
        "--frozen", "frozen1.txt"
    ) -WorkingDirectory $gitRepoDir
    Assert-Equal $resScopePass.ExitCode 0 "scope seam: valid owned modification exits 0"

    # Scope check fails when unowned file is modified
    [System.IO.File]::AppendAllText((Join-Path $gitRepoDir "unowned.txt"), "unowned modification`n", [System.Text.Encoding]::UTF8)
    $resScopeUnowned = Invoke-Helper -ScriptName "check-execution-scope.ps1" -ArgumentList @(
        "--baseline", $baselineRev,
        "--owned", "owned1.txt",
        "--owned", "owned2.txt",
        "--frozen", "frozen1.txt"
    ) -WorkingDirectory $gitRepoDir
    Assert-NotEqual $resScopeUnowned.ExitCode 0 "scope seam: unowned file modification rejected"
    & git -C $gitRepoDir checkout -q -- unowned.txt

    # Scope check fails when frozen path is modified
    [System.IO.File]::AppendAllText((Join-Path $gitRepoDir "frozen1.txt"), "frozen modification`n", [System.Text.Encoding]::UTF8)
    $resScopeFrozen = Invoke-Helper -ScriptName "check-execution-scope.ps1" -ArgumentList @(
        "--baseline", $baselineRev,
        "--owned", "owned1.txt",
        "--owned", "owned2.txt",
        "--frozen", "frozen1.txt"
    ) -WorkingDirectory $gitRepoDir
    Assert-NotEqual $resScopeFrozen.ExitCode 0 "scope seam: frozen file modification rejected"
    & git -C $gitRepoDir checkout -q -- frozen1.txt

    # 3.7: Citation audit verification seam: check-citation-audit.ps1
    $ledgerJson = '[{"claim_id":"c1","claim":"Claim 1","citations":["https://example.com/1"],"decision_relevance":"critical","status":"supported"}]'
    $validPassAudits = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
    $resAuditPass = Invoke-Helper -ScriptName "check-citation-audit.ps1" -ArgumentList @(
        "--ledger", $ledgerJson, "--auditor", $validPassAudits
    )
    Assert-Equal $resAuditPass.ExitCode 0 "citation audit seam: supported audit exits 0"

    $validReviseAudits = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"refutes","source_classification":"primary"}],"final_status":"revise"}'
    $resAuditRevise = Invoke-Helper -ScriptName "check-citation-audit.ps1" -ArgumentList @(
        "--ledger", $ledgerJson, "--auditor", $validReviseAudits
    )
    Assert-Equal $resAuditRevise.ExitCode 1 "citation audit seam: revision required exits 1"

    $invalidAudits = '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"refutes","source_classification":"primary"}],"final_status":"pass"}'
    $resAuditInvalid = Invoke-Helper -ScriptName "check-citation-audit.ps1" -ArgumentList @(
        "--ledger", $ledgerJson, "--auditor", $invalidAudits
    )
    Assert-Equal $resAuditInvalid.ExitCode 2 "citation audit seam: contradictory verdict exits 2"

    # =======================================================================
    # 4. Explicit Accepted-Attempt Selection After Retry
    # Spec: Verify explicit accepted-attempt selection after a retry.
    #       Never select by wildcard, newest filename, or process completion time.
    # =======================================================================

    $artAttempt1Path = Join-Path $researchBaseDir "retry-worker.attempt1.json"
    $artAttempt2Path = Join-Path $researchBaseDir "retry-worker.attempt2.json"

    # Attempt 1: Failed/inconclusive artifact
    $art1Obj = New-ResearcherArtifact @{
        status = "failed"
        findings = @()
    }
    [System.IO.File]::WriteAllText($artAttempt1Path, ($art1Obj | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    # Attempt 2: Verified successful artifact
    $art2Obj = New-ResearcherArtifact @{
        status = "success"
        angle_id = "angle-retry"
        findings = @(
            [ordered]@{
                claim = "Verified claim from attempt 2"
                source_urls = @("https://example.com/retry-success")
                source_type = "primary"
            }
        )
    }
    [System.IO.File]::WriteAllText($artAttempt2Path, ($art2Obj | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $retryRouting = [ordered]@{
        schema_version = 1
        attempts = @(
            [ordered]@{
                worker_id = "worker-retry"
                role = "researcher"
                mode = "web-research"
                attempt = 1
                policy_revision = "2026-09-03.1"
                route = "default"
                model = "gemini-3.8-flash-high"
                effort = "high"
                reason = "Initial dispatch"
                started_at = "2026-09-03T00:00:00Z"
                ended_at = "2026-09-03T00:01:00Z"
                duration_seconds = 60.0
                exit_code = 1
                state = "failed"
                failure_class = "quality"
                verification_status = "failed"
                evidence_paths = @("retry-worker.attempt1.json")
                usage = $null
            },
            [ordered]@{
                worker_id = "worker-retry"
                role = "researcher"
                mode = "web-research"
                attempt = 2
                policy_revision = "2026-09-03.1"
                route = "default"
                model = "gemini-3.8-flash-high"
                effort = "high"
                reason = "Retry authorized after quality failure"
                started_at = "2026-09-03T00:02:00Z"
                ended_at = "2026-09-03T00:03:00Z"
                duration_seconds = 60.0
                exit_code = 0
                state = "completed"
                failure_class = "none"
                verification_status = "passed"
                evidence_paths = @("retry-worker.attempt2.json")
                usage = $null
            }
        )
    }

    # 4.1: Explicit accepted_attempt: 2 correctly selects attempt 2's artifact
    $manifestRetrySuccessPath = Join-Path $researchBaseDir "manifest-retry-success.json"
    $manifestRetrySuccess = [ordered]@{
        workers = @(
            [ordered]@{
                id = "worker-retry"
                role = "researcher"
                status = "completed"
                accepted_attempt = 2
                output = "retry-worker.attempt2.json"
                routing = $retryRouting
            }
        )
    }
    [System.IO.File]::WriteAllText($manifestRetrySuccessPath, ($manifestRetrySuccess | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $resRetrySuccess = Invoke-Helper -ScriptName "select-research-outputs.ps1" -ArgumentList @("--workers", $manifestRetrySuccessPath, "--base-dir", $researchBaseDir)
    Assert-Equal $resRetrySuccess.ExitCode 0 "selector: retry with accepted_attempt 2 exits 0"
    $parsedRetrySuccess = $resRetrySuccess.Stdout | ConvertFrom-Json
    Assert-Equal $parsedRetrySuccess.selected_files.Count 1 "selector: selects 1 file after retry"
    Assert-True ($parsedRetrySuccess.selected_files[0].EndsWith("retry-worker.attempt2.json")) "selector: selects attempt 2 artifact, not attempt 1"
    Assert-Equal $parsedRetrySuccess.independent_angles[0] "angle-retry" "selector: captures attempt 2 angle"

    # 4.2: Selecting failed attempt (accepted_attempt: 1) is omitted
    $manifestRetryBadPath = Join-Path $researchBaseDir "manifest-retry-bad.json"
    $manifestRetryBad = [ordered]@{
        workers = @(
            [ordered]@{
                id = "worker-retry"
                role = "researcher"
                status = "completed"
                accepted_attempt = 1
                output = "retry-worker.attempt1.json"
                routing = $retryRouting
            }
        )
    }
    [System.IO.File]::WriteAllText($manifestRetryBadPath, ($manifestRetryBad | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $resRetryBad = Invoke-Helper -ScriptName "select-research-outputs.ps1" -ArgumentList @("--workers", $manifestRetryBadPath, "--base-dir", $researchBaseDir)
    $parsedRetryBad = $resRetryBad.Stdout | ConvertFrom-Json
    Assert-Equal $parsedRetryBad.selected_files.Count 0 "selector: omits worker if accepted_attempt points to failed attempt 1"

    # 4.3: Manifest with accepted_attempt outside 1..2 is omitted
    $manifestRetryInvalidAttempt = [ordered]@{
        workers = @(
            [ordered]@{
                id = "worker-retry"
                role = "researcher"
                status = "completed"
                accepted_attempt = 3
                output = "retry-worker.attempt2.json"
                routing = $retryRouting
            }
        )
    }
    $manifestRetryInvalidPath = Join-Path $researchBaseDir "manifest-retry-invalid.json"
    [System.IO.File]::WriteAllText($manifestRetryInvalidPath, ($manifestRetryInvalidAttempt | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $resRetryInvalid = Invoke-Helper -ScriptName "select-research-outputs.ps1" -ArgumentList @("--workers", $manifestRetryInvalidPath, "--base-dir", $researchBaseDir)
    $parsedRetryInvalid = $resRetryInvalid.Stdout | ConvertFrom-Json
    Assert-Equal $parsedRetryInvalid.selected_files.Count 0 "selector: omits worker when accepted_attempt exceeds ceiling"

    # =======================================================================
    # 5. Unrunnable Gates and Shared Failure Vocabulary Extension
    # Spec: Normalize gate exit 126 and 127 to unrunnable.
    #       Record verification: not_performed when gate could not run.
    #       Do not treat this as worker quality failure and do not spend model retry.
    #       Update validators and fixtures to accept failure_class: unrunnable.
    # =======================================================================

    # 5.1: Hardening: collect-provenance.ps1 accepts failure_class 'unrunnable'
    $provUnrunnablePath = Join-Path $TmpRoot "provenance-unrunnable.json"
    $provUnrunnableData = [ordered]@{
        run_id = "test-unrunnable-run"
        request_summary = "Test unrunnable failure class"
        selected_mode = "web-research"
        profile = "standard"
        deep_trigger = $null
        start_time = "2026-09-03T00:00:00Z"
        end_time = "2026-09-03T00:05:00Z"
        duration_seconds = 300.0
        scratch_path = $TmpRoot
        workers = @(
            [ordered]@{
                id = "worker-unrunnable"
                role = "researcher"
                status = "failed"
                output = "worker-unrunnable.attempt1.json"
                accepted_attempt = $null
                routing = [ordered]@{
                    schema_version = 1
                    attempts = @(
                        [ordered]@{
                            worker_id = "worker-unrunnable"
                            role = "researcher"
                            mode = "web-research"
                            attempt = 1
                            policy_revision = "2026-09-03.1"
                            route = "default"
                            model = "gemini-3.8-flash-high"
                            effort = "high"
                            reason = "Initial dispatch"
                            started_at = "2026-09-03T00:00:00Z"
                            ended_at = "2026-09-03T00:00:05Z"
                            duration_seconds = 5.0
                            exit_code = 127
                            state = "failed"
                            failure_class = "unrunnable"
                            verification_status = "not_performed"
                            evidence_paths = @("gate-diag.err")
                            usage = $null
                        }
                    )
                }
            }
        )
        repository_snapshot_paths = @()
        final_citations = @("https://example.com/docs")
        audit_verdicts = @()
        final_status = "partial"
        incomplete_stage_reasons = @("Gate tooling was unrunnable")
    }
    [System.IO.File]::WriteAllText($provUnrunnablePath, ($provUnrunnableData | ConvertTo-Json -Depth 20), [System.Text.Encoding]::UTF8)

    $resProvUnrunnable = Invoke-Helper -ScriptName "collect-provenance.ps1" -ArgumentList @("--validate", $provUnrunnablePath)
    Assert-Equal $resProvUnrunnable.ExitCode 0 "collect-provenance: accepts failure_class unrunnable"

    # 5.2: Hardening: cleanup-research-workspace.ps1 accepts failure_class 'unrunnable'
    $cleanupWs = Join-Path $TmpRoot "cleanup-ws-unrunnable"
    [System.IO.Directory]::CreateDirectory($cleanupWs) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $cleanupWs ".offload-research-workspace"), "offload-research-workspace-v1`n", [System.Text.Encoding]::UTF8)

    $diagPath = Join-Path $cleanupWs "gate-diag.err"
    [System.IO.File]::WriteAllText($diagPath, "command not found: ./nonexistent-gate`n", [System.Text.Encoding]::UTF8)

    $routingUnrunnable = [ordered]@{
        schema_version = 1
        attempts = @(
            [ordered]@{
                worker_id = "researcher-1"
                role = "researcher"
                mode = "web-research"
                attempt = 1
                policy_revision = "2026-09-03.1"
                route = "default"
                model = "gemini-3.8-flash-high"
                effort = "high"
                reason = "Gate tool missing"
                started_at = "2026-09-03T00:00:00Z"
                ended_at = "2026-09-03T00:00:05Z"
                duration_seconds = 5.0
                exit_code = 126
                state = "failed"
                failure_class = "unrunnable"
                verification_status = "not_performed"
                evidence_paths = @("gate-diag.err")
                usage = $null
            }
        )
    }
    [System.IO.File]::WriteAllText((Join-Path $cleanupWs "routing-outcomes.json"), ($routingUnrunnable | ConvertTo-Json -Depth 20), [System.Text.Encoding]::UTF8)

    $resCleanupUnrunnable = Invoke-Helper -ScriptName "cleanup-research-workspace.ps1" -ArgumentList @("--workspace", $cleanupWs, "--status", "success")
    Assert-Equal $resCleanupUnrunnable.ExitCode 0 "cleanup-research-workspace: accepts failure_class unrunnable"

    # 5.3: Unknown bogus failure_class is rejected by collect-provenance.ps1
    $provBogusPath = Join-Path $TmpRoot "provenance-bogus.json"
    $provBogusData = [ordered]@{
        run_id = "test-bogus-run"
        request_summary = "Test bogus failure class"
        selected_mode = "web-research"
        profile = "standard"
        deep_trigger = $null
        start_time = "2026-09-03T00:00:00Z"
        end_time = "2026-09-03T00:05:00Z"
        duration_seconds = 300.0
        scratch_path = $TmpRoot
        workers = @(
            [ordered]@{
                id = "worker-bogus"
                role = "researcher"
                status = "failed"
                output = "worker-bogus.json"
                accepted_attempt = $null
                routing = [ordered]@{
                    schema_version = 1
                    attempts = @(
                        [ordered]@{
                            worker_id = "worker-bogus"
                            role = "researcher"
                            mode = "web-research"
                            attempt = 1
                            policy_revision = "2026-09-03.1"
                            route = "default"
                            model = "gemini-3.8-flash-high"
                            effort = "high"
                            reason = "Bogus failure"
                            started_at = "2026-09-03T00:00:00Z"
                            ended_at = "2026-09-03T00:00:05Z"
                            duration_seconds = 5.0
                            exit_code = 1
                            state = "failed"
                            failure_class = "invented_bogus_failure_class"
                            verification_status = "failed"
                            evidence_paths = @("gate-diag.err")
                            usage = $null
                        }
                    )
                }
            }
        )
        repository_snapshot_paths = @()
        final_citations = @("https://example.com/docs")
        audit_verdicts = @()
        final_status = "partial"
        incomplete_stage_reasons = @("Bogus failure test")
    }
    [System.IO.File]::WriteAllText($provBogusPath, ($provBogusData | ConvertTo-Json -Depth 20), [System.Text.Encoding]::UTF8)

    $resProvBogus = Invoke-Helper -ScriptName "collect-provenance.ps1" -ArgumentList @("--validate", $provBogusPath)
    Assert-NotEqual $resProvBogus.ExitCode 0 "collect-provenance: rejects invented bogus failure_class"

    # 5.4: Unknown bogus failure_class is rejected by cleanup-research-workspace.ps1
    $cleanupWsBogus = Join-Path $TmpRoot "cleanup-ws-bogus"
    [System.IO.Directory]::CreateDirectory($cleanupWsBogus) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $cleanupWsBogus ".offload-research-workspace"), "offload-research-workspace-v1`n", [System.Text.Encoding]::UTF8)
    $routingBogus = [ordered]@{
        schema_version = 1
        attempts = @(
            [ordered]@{
                worker_id = "researcher-1"
                role = "researcher"
                mode = "web-research"
                attempt = 1
                policy_revision = "2026-09-03.1"
                route = "default"
                model = "gemini-3.8-flash-high"
                effort = "high"
                reason = "Bogus failure class test"
                started_at = "2026-09-03T00:00:00Z"
                ended_at = "2026-09-03T00:00:05Z"
                duration_seconds = 5.0
                exit_code = 1
                state = "failed"
                failure_class = "invented_bogus_failure_class"
                verification_status = "failed"
                evidence_paths = @()
                usage = $null
            }
        )
    }
    [System.IO.File]::WriteAllText((Join-Path $cleanupWsBogus "routing-outcomes.json"), ($routingBogus | ConvertTo-Json -Depth 20), [System.Text.Encoding]::UTF8)
    $resCleanupBogus = Invoke-Helper -ScriptName "cleanup-research-workspace.ps1" -ArgumentList @("--workspace", $cleanupWsBogus, "--status", "success")
    Assert-NotEqual $resCleanupBogus.ExitCode 0 "cleanup-research-workspace: rejects invented bogus failure_class"

    # 5.5: Gate execution and outcome normalization contract:
    # When a configured gate process exits 126 or 127:
    # - normalize gate result to failure_class: 'unrunnable', verification_status: 'not_performed'
    # - do NOT treat as quality failure; do NOT spend model retry (allow_retry = $false)
    # When gate process exits 1..125:
    # - failure_class: 'quality', verification_status: 'failed', allow_retry = $true
    # When gate process exits 0:
    # - failure_class: 'none', verification_status: 'passed', allow_retry = $false
    function Execute-GateCommand([string]$gateCommand) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $PwshBin
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-NonInteractive')
        $psi.ArgumentList.Add('-Command')
        $psi.ArgumentList.Add($gateCommand)
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $rawExit = $proc.ExitCode
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        if ($rawExit -eq 0) {
            return [ordered]@{
                exit_code           = 0
                failure_class       = "none"
                verification_status = "passed"
                allow_retry         = $false
                stdout              = $stdout
                stderr              = $stderr
            }
        } elseif ($rawExit -eq 126 -or $rawExit -eq 127) {
            return [ordered]@{
                exit_code           = $rawExit
                failure_class       = "unrunnable"
                verification_status = "not_performed"
                allow_retry         = $false
                stdout              = $stdout
                stderr              = $stderr
            }
        } else {
            return [ordered]@{
                exit_code           = $rawExit
                failure_class       = "quality"
                verification_status = "failed"
                allow_retry         = $true
                stdout              = $stdout
                stderr              = $stderr
            }
        }
    }

    $gateRes0 = Execute-GateCommand "exit 0"
    Assert-Equal $gateRes0.failure_class "none" "gate normalizer: exit 0 produces failure_class none"
    Assert-Equal $gateRes0.verification_status "passed" "gate normalizer: exit 0 produces verification passed"
    Assert-Equal $gateRes0.allow_retry $false "gate normalizer: exit 0 does not allow retry"

    $gateRes1 = Execute-GateCommand "exit 1"
    Assert-Equal $gateRes1.failure_class "quality" "gate normalizer: exit 1 produces quality failure"
    Assert-Equal $gateRes1.verification_status "failed" "gate normalizer: exit 1 produces verification failed"
    Assert-Equal $gateRes1.allow_retry $true "gate normalizer: exit 1 allows retry"

    $gateRes126 = Execute-GateCommand "exit 126"
    Assert-Equal $gateRes126.failure_class "unrunnable" "gate normalizer: exit 126 produces unrunnable"
    Assert-Equal $gateRes126.verification_status "not_performed" "gate normalizer: exit 126 records verification not_performed"
    Assert-Equal $gateRes126.allow_retry $false "gate normalizer: exit 126 does not spend a retry"

    $gateRes127 = Execute-GateCommand "exit 127"
    Assert-Equal $gateRes127.failure_class "unrunnable" "gate normalizer: exit 127 produces unrunnable"
    Assert-Equal $gateRes127.verification_status "not_performed" "gate normalizer: exit 127 records verification not_performed"
    Assert-Equal $gateRes127.allow_retry $false "gate normalizer: exit 127 does not spend a retry"

    # =======================================================================
    # 6. Preservation of Existing Behavior (Operational, Timeout, Quota, Partial-Result)
    # Spec: Preserve existing operational, quality, timeout, quota, and partial-result behavior.
    # =======================================================================

    # 6.1: Operational failures (timeout, tool_error, quota, unknown) in routing records
    foreach ($fc in @('timeout', 'tool_error', 'quota', 'unknown')) {
        $provData = [ordered]@{
            run_id = "test-$fc-run"
            request_summary = "Test $fc failure class"
            selected_mode = "web-research"
            profile = "standard"
            deep_trigger = $null
            start_time = "2026-09-03T00:00:00Z"
            end_time = "2026-09-03T00:05:00Z"
            duration_seconds = 300.0
            scratch_path = $TmpRoot
            workers = @(
                [ordered]@{
                    id = "worker-$fc"
                    role = "researcher"
                    status = "failed"
                    output = "worker-$fc.json"
                    accepted_attempt = $null
                    routing = [ordered]@{
                        schema_version = 1
                        attempts = @(
                            [ordered]@{
                                worker_id = "worker-$fc"
                                role = "researcher"
                                mode = "web-research"
                                attempt = 1
                                policy_revision = "2026-09-03.1"
                                route = "default"
                                model = "gemini-3.8-flash-high"
                                effort = "high"
                                reason = "Observed $fc"
                                started_at = "2026-09-03T00:00:00Z"
                                ended_at = "2026-09-03T00:01:00Z"
                                duration_seconds = 60.0
                                exit_code = $(if ($fc -eq 'timeout') { $null } else { 1 })
                                state = "failed"
                                failure_class = $fc
                                verification_status = $(if ($fc -in @('timeout', 'quota')) { "not_performed" } else { "failed" })
                                evidence_paths = @("diag.err")
                                usage = $null
                            }
                        )
                    }
                }
            )
            repository_snapshot_paths = @()
            final_citations = @("https://example.com/docs")
            audit_verdicts = @()
            final_status = "partial"
            incomplete_stage_reasons = @("Worker failed with $fc")
        }
        $provPath = Join-Path $TmpRoot "provenance-$fc.json"
        [System.IO.File]::WriteAllText($provPath, ($provData | ConvertTo-Json -Depth 20), [System.Text.Encoding]::UTF8)
        $resFc = Invoke-Helper -ScriptName "collect-provenance.ps1" -ArgumentList @("--validate", $provPath)
        Assert-Equal $resFc.ExitCode 0 "collect-provenance: preserves existing failure_class $fc"
    }

    # 6.2: Partial result preservation in select-research-outputs.ps1:
    # When fewer than 2 independent angles survive, synthesis threshold is not met
    $artValid2Path = Join-Path $researchBaseDir "researcher-valid2.json"
    [System.IO.File]::WriteAllText($artValid2Path, ((New-ResearcherArtifact @{ angle_id = "angle-duplicate" }) | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $manifestPartialPath = Join-Path $researchBaseDir "manifest-partial-angles.json"
    $manifestPartial = [ordered]@{
        workers = @(
            [ordered]@{
                id = "worker-1"
                role = "researcher"
                status = "completed"
                accepted_attempt = 1
                output = "researcher-valid.json"
                routing = New-WorkerRoutingRecord "worker-1" "researcher-valid.json"
            },
            [ordered]@{
                id = "worker-unverified"
                role = "researcher"
                status = "completed"
                accepted_attempt = 1
                output = "researcher-valid2.json"
                routing = New-WorkerRoutingRecord "worker-unverified" "researcher-valid2.json" @{ verification_status = "failed" }
            }
        )
    }
    [System.IO.File]::WriteAllText($manifestPartialPath, ($manifestPartial | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $resPartial = Invoke-Helper -ScriptName "select-research-outputs.ps1" -ArgumentList @("--workers", $manifestPartialPath, "--base-dir", $researchBaseDir)
    $parsedPartial = $resPartial.Stdout | ConvertFrom-Json
    Assert-True ($parsedPartial.independent_angle_count -lt 2) "selector: preserves partial-result threshold (< 2 independent angles)"

    if ($script:FailedTests -gt 0) {
        [Console]::Error.WriteLine("FAILED: $($script:FailedTests) of $($script:TotalTests) tests failed.")
        exit 1
    } else {
        [Console]::Out.WriteLine("ok: all $($script:TotalTests) result acceptance tests passed.")
        exit 0
    }
} finally {
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
