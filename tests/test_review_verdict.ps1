#!/usr/bin/env pwsh
# tests/test_review_verdict.ps1
# Regression coverage for exhaustive reviewer criterion verification.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$RootDir = Split-Path -Parent $PSScriptRoot
$Helper = Join-Path $RootDir 'scripts/check-review-verdict.ps1'
$Pwsh = (Get-Command pwsh).Source
$TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('offload-test-review-verdict-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($TmpRoot) | Out-Null

function Fail([string]$message) {
    [Console]::Error.WriteLine("FAIL: $message")
    exit 1
}

function Pass([string]$message) {
    [Console]::Out.WriteLine("ok - $message")
}

function Invoke-ReviewCheck([string]$reviewPath, [string]$name, [int]$expectedExit, [string]$criteriaFile = '') {
    if ([string]::IsNullOrEmpty($criteriaFile)) { $criteriaFile = $criteriaPath }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Pwsh
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-NonInteractive')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($Helper)
    $psi.ArgumentList.Add('--criteria')
    $psi.ArgumentList.Add($criteriaFile)
    $psi.ArgumentList.Add('--review')
    $psi.ArgumentList.Add($reviewPath)
    $psi.ArgumentList.Add('--artifact')
    $psi.ArgumentList.Add($artifactPath)
    $psi.WorkingDirectory = $TmpRoot
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne $expectedExit) {
        Fail "$name expected exit $expectedExit, got $($process.ExitCode): $stderr"
    }
}

function Write-Json([string]$name, $value) {
    $path = Join-Path $TmpRoot $name
    [System.IO.File]::WriteAllText($path, ($value | ConvertTo-Json -Compress -Depth 10), [System.Text.Encoding]::UTF8)
    return $path
}

$artifactPath = Join-Path $TmpRoot 'review.patch'
[System.IO.File]::WriteAllText($artifactPath, "diff --git a/example.txt b/example.txt`n+++ b/example.txt`n+literal evidence line`n", [System.Text.Encoding]::UTF8)
$criteriaPath = Write-Json 'criteria.json' @(
    [ordered]@{ criterion_id = 'C1'; text = 'first criterion' }
    [ordered]@{ criterion_id = 'C2'; text = 'second criterion' }
)

try {
    $cases = @(
        @{ Name = 'empty'; Expected = 2; Review = [ordered]@{ criteria = @() }; Message = 'empty reviewer output is rejected' }
        @{ Name = 'partial'; Expected = 2; Review = [ordered]@{ criteria = @([ordered]@{ criterion_id = 'C1'; verdict = 'pass'; quote = '+literal evidence line' }) }; Message = 'partial reviewer coverage is rejected' }
        @{ Name = 'malformed'; Expected = 2; Review = [ordered]@{ criteria = @(
            [ordered]@{ criterion_id = 'C1'; verdict = 'pass' }
            [ordered]@{ criterion_id = 'C2'; verdict = 'pass'; quote = '+literal evidence line' }
        ) }; Message = 'malformed reviewer entries are rejected' }
        @{ Name = 'duplicate'; Expected = 2; Review = [ordered]@{ criteria = @(
            [ordered]@{ criterion_id = 'C1'; verdict = 'pass'; quote = '+literal evidence line' }
            [ordered]@{ criterion_id = 'C1'; verdict = 'pass'; quote = '+literal evidence line' }
            [ordered]@{ criterion_id = 'C2'; verdict = 'pass'; quote = '+literal evidence line' }
        ) }; Message = 'duplicate criterion IDs are rejected' }
        @{ Name = 'unknown'; Expected = 2; Review = [ordered]@{ criteria = @(
            [ordered]@{ criterion_id = 'C1'; verdict = 'pass'; quote = '+literal evidence line' }
            [ordered]@{ criterion_id = 'C2'; verdict = 'pass'; quote = '+literal evidence line' }
            [ordered]@{ criterion_id = 'C3'; verdict = 'pass'; quote = '+literal evidence line' }
        ) }; Message = 'unknown criterion IDs are rejected' }
        @{ Name = 'failed'; Expected = 1; Review = [ordered]@{ criteria = @(
            [ordered]@{ criterion_id = 'C1'; verdict = 'fail'; quote = '' }
            [ordered]@{ criterion_id = 'C2'; verdict = 'pass'; quote = '+literal evidence line' }
        ) }; Message = 'complete failed verdicts block automated acceptance' }
        @{ Name = 'hedged'; Expected = 1; Review = [ordered]@{ criteria = @(
            [ordered]@{ criterion_id = 'C1'; verdict = 'hedge'; quote = '' }
            [ordered]@{ criterion_id = 'C2'; verdict = 'pass'; quote = '+literal evidence line' }
        ) }; Message = 'complete hedged verdicts block automated acceptance' }
        @{ Name = 'forged'; Expected = 2; Review = [ordered]@{ criteria = @(
            [ordered]@{ criterion_id = 'C1'; verdict = 'pass'; quote = '+forged evidence line' }
            [ordered]@{ criterion_id = 'C2'; verdict = 'pass'; quote = '+literal evidence line' }
        ) }; Message = 'forged evidence quotes are rejected' }
        @{ Name = 'complete'; Expected = 0; Review = [ordered]@{ structured_output = [ordered]@{ criteria = @(
            [ordered]@{ criterion_id = 'C1'; verdict = 'pass'; quote = '+literal evidence line' }
            [ordered]@{ criterion_id = 'C2'; verdict = 'pass'; quote = '+++ b/example.txt' }
        ) } }; Message = 'complete all-pass reviewer output with artifact evidence is accepted' }
    )

    foreach ($case in $cases) {
        $reviewPath = Write-Json "$($case.Name).json" $case.Review
        Invoke-ReviewCheck $reviewPath $case.Name $case.Expected
        Pass $case.Message
    }

    $singleCriteriaPath = Join-Path $TmpRoot 'single-criteria.json'
    [System.IO.File]::WriteAllText($singleCriteriaPath, '[{"criterion_id":"C1","text":"only criterion"}]', [System.Text.Encoding]::UTF8)
    $singleReviewPath = Join-Path $TmpRoot 'single-review.json'
    [System.IO.File]::WriteAllText($singleReviewPath, '{"criteria":[{"criterion_id":"C1","verdict":"pass","quote":"+literal evidence line"}]}', [System.Text.Encoding]::UTF8)
    Invoke-ReviewCheck $singleReviewPath 'single' 0 $singleCriteriaPath
    Pass 'single-criterion arrays are preserved'

    [Console]::Out.WriteLine('all review verdict powershell tests passed')
} finally {
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
