#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Show-Usage {
    [Console]::Error.WriteLine('Usage: select-research-outputs.ps1 --workers FILE [--base-dir DIRECTORY]')
    [Console]::Error.WriteLine('Selects completed, verified researcher artifacts from an explicit worker manifest.')
}

$workersPath = $null
$baseDir = (Get-Location).Path
$index = 0
while ($index -lt $Arguments.Count) {
    switch ($Arguments[$index]) {
        '--workers' {
            if ($index + 1 -ge $Arguments.Count) { Show-Usage; exit 2 }
            $workersPath = $Arguments[$index + 1]
            $index += 2
        }
        '--base-dir' {
            if ($index + 1 -ge $Arguments.Count) { Show-Usage; exit 2 }
            $baseDir = $Arguments[$index + 1]
            $index += 2
        }
        '--help' { Show-Usage; exit 0 }
        '-h' { Show-Usage; exit 0 }
        default { Show-Usage; exit 2 }
    }
}

if ([string]::IsNullOrWhiteSpace($workersPath)) { Show-Usage; exit 2 }
if (-not (Test-Path -LiteralPath $workersPath -PathType Leaf)) {
    Write-Error "select-research-outputs: worker manifest does not exist: $workersPath"
    exit 2
}
if (-not (Test-Path -LiteralPath $baseDir -PathType Container)) {
    Write-Error "select-research-outputs: base directory does not exist: $baseDir"
    exit 2
}

try {
    $workersDocument = Get-Content -LiteralPath $workersPath -Raw | ConvertFrom-Json
} catch {
    Write-Error 'select-research-outputs: invalid worker manifest'
    exit 2
}

if ($workersDocument -is [System.Array]) {
    $workers = @($workersDocument)
} elseif ($null -ne $workersDocument -and $workersDocument.PSObject.Properties.Name -contains 'workers' -and $workersDocument.workers -is [System.Array]) {
    $workers = @($workersDocument.workers)
} else {
    Write-Error 'select-research-outputs: expected a workers array or an object containing workers'
    exit 2
}

$selectedFiles = [System.Collections.Generic.List[string]]::new()
$independentAngles = [System.Collections.Generic.List[string]]::new()
$omittedWorkers = [System.Collections.Generic.List[object]]::new()

function Add-Omission([string]$workerId, [string]$reason) {
    $omittedWorkers.Add([ordered]@{ worker_id = $workerId; reason = $reason })
}

foreach ($worker in $workers) {
    $workerId = if ($worker.PSObject.Properties.Name -contains 'id') { [string]$worker.id } elseif ($worker.PSObject.Properties.Name -contains 'worker_id') { [string]$worker.worker_id } else { '<unknown>' }
    if (-not ($worker.PSObject.Properties.Name -contains 'role') -or $worker.role -ne 'researcher') { continue }
    if (-not ($worker.PSObject.Properties.Name -contains 'status') -or $worker.status -ne 'completed') {
        Add-Omission $workerId 'worker is not completed'
        continue
    }
    if (-not ($worker.PSObject.Properties.Name -contains 'accepted_attempt') -or $worker.accepted_attempt -notin @(1, 2)) {
        Add-Omission $workerId 'accepted_attempt is missing or outside the two-attempt ceiling'
        continue
    }
    $acceptedAttempt = [int]$worker.accepted_attempt
    if (-not ($worker.PSObject.Properties.Name -contains 'output') -or [string]::IsNullOrWhiteSpace([string]$worker.output)) {
        Add-Omission $workerId 'selected output path is missing'
        continue
    }
    $output = [string]$worker.output
    if (-not ($worker.PSObject.Properties.Name -contains 'routing') -or $null -eq $worker.routing -or $worker.routing.schema_version -ne 1 -or $null -eq $worker.routing.attempts) {
        Add-Omission $workerId 'routing attempts are missing the versioned container'
        continue
    }

    $matchingAttempts = @( @($worker.routing.attempts) | Where-Object {
        $_.worker_id -eq $workerId -and
        $_.attempt -eq $acceptedAttempt -and
        $_.state -eq 'completed' -and
        $_.verification_status -eq 'passed' -and
        $_.exit_code -eq 0 -and
        $null -ne $_.evidence_paths -and
        @($_.evidence_paths).Count -gt 0 -and
        [string]$_.evidence_paths[0] -eq $output
    })
    if ($matchingAttempts.Count -ne 1) {
        Add-Omission $workerId 'accepted attempt is not a uniquely completed, verified attempt'
        continue
    }

    $selectedPath = if ([System.IO.Path]::IsPathRooted($output)) { $output } else { Join-Path $baseDir $output }
    if (-not (Test-Path -LiteralPath $selectedPath -PathType Leaf)) {
        Add-Omission $workerId 'selected output artifact does not exist'
        continue
    }
    try {
        $artifact = Get-Content -LiteralPath $selectedPath -Raw | ConvertFrom-Json
    } catch {
        Add-Omission $workerId 'selected artifact is not valid JSON'
        continue
    }
    $structuredOutput = if ($null -ne $artifact -and $artifact.PSObject.Properties.Name -contains 'structured_output') { $artifact.structured_output } else { $null }
    $findings = @()
    if ($null -ne $structuredOutput -and $structuredOutput.PSObject.Properties.Name -contains 'findings') {
        $findings = @($structuredOutput.findings)
    }
    $findingsValid = $findings.Count -gt 0
    foreach ($finding in $findings) {
        if ($null -eq $finding -or $finding.PSObject.Properties.Name -notcontains 'source_urls' -or $finding.source_urls -isnot [System.Array] -or @($finding.source_urls).Count -eq 0 -or @($finding.source_urls | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
            $findingsValid = $false
            break
        }
    }
    if ($null -eq $artifact -or $null -eq $structuredOutput -or $structuredOutput.status -ne 'success' -or [string]::IsNullOrWhiteSpace([string]$structuredOutput.angle_id) -or [string]::IsNullOrWhiteSpace([string]$structuredOutput.question) -or -not $findingsValid) {
        Add-Omission $workerId 'selected artifact is not a substantive researcher result'
        continue
    }

    $selectedFiles.Add($selectedPath)
    $independentAngles.Add([string]$structuredOutput.angle_id)
}

$uniqueAngles = @($independentAngles | Sort-Object -Unique)
$result = [ordered]@{
    selected_files = @($selectedFiles)
    independent_angles = $uniqueAngles
    independent_angle_count = $uniqueAngles.Count
    omitted_workers = @($omittedWorkers)
}
$result | ConvertTo-Json -Depth 10 -Compress
