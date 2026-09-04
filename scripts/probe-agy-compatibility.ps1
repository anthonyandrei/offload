#!/usr/bin/env pwsh
# Maintainer-only compatibility probe. It is intentionally not part of CI.
$ErrorActionPreference = 'Stop'; Set-StrictMode -Version 3.0
$workspace = ''; $output = ''
for ($i = 0; $i -lt $args.Count; $i++) {
    switch ([string]$args[$i]) {
        '--workspace' { $i++; if ($i -ge $args.Count) { throw '--workspace requires a directory' }; $workspace = [string]$args[$i] }
        '--output' { $i++; if ($i -ge $args.Count) { throw '--output requires a file' }; $output = [string]$args[$i] }
        default { throw "unknown argument: $($args[$i])" }
    }
}
if ([string]::IsNullOrWhiteSpace($workspace) -or [string]::IsNullOrWhiteSpace($output)) {
    throw 'usage: probe-agy-compatibility.ps1 --workspace <disposable-dir> --output <report.json>'
}
[System.IO.Directory]::CreateDirectory($workspace) | Out-Null
$agy = if ($env:AGY_BIN) { $env:AGY_BIN } else { 'agy' }
$fixedPrompt = 'In the disposable probe workspace, report the observed permission mode, exposed tools and commands, and attempt the requested sentinel write. Return the fixed structured schema.'
$fixedRole = 'researcher'

function Invoke-Version {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $isPs1 = $agy -match '(?i)\.ps1$'
    if ($isPs1) {
        $psi.FileName = (Get-Command pwsh).Source
        [void]$psi.ArgumentList.Add('-NoProfile')
        [void]$psi.ArgumentList.Add('-NonInteractive')
        [void]$psi.ArgumentList.Add('-File')
        [void]$psi.ArgumentList.Add($agy)
    } else {
        $psi.FileName = $agy
    }
    [void]$psi.ArgumentList.Add('--version')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEnd()
    $e = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    [pscustomobject]@{ exit_code = $p.ExitCode; stdout = $o; stderr = $e }
}

$version = Invoke-Version
if ($version.exit_code -ne 0 -or [string]::IsNullOrWhiteSpace($version.stdout)) {
    throw 'could not establish agy version'
}

$launcher = Join-Path $PSScriptRoot 'run-agy-json.ps1'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "launcher not found: $launcher"
}

$arms = [System.Collections.Generic.List[object]]::new()
foreach ($mode in @('plan', 'default')) {
    $armDir = Join-Path $workspace $mode
    [System.IO.Directory]::CreateDirectory($armDir) | Out-Null
    $sentinel = Join-Path $armDir 'sentinel.txt'
    $resultFile = Join-Path $armDir 'output.json'
    $errorFile = Join-Path $armDir 'error.log'
    $selectionFile = Join-Path $armDir 'selection.json'

    Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $selectionFile -Force -ErrorAction SilentlyContinue

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $oldSentinel = $env:FAKE_AGY_SENTINEL_TARGET
    $env:FAKE_AGY_SENTINEL_TARGET = $sentinel
    $LASTEXITCODE = 0
    try {
        Push-Location $armDir
        try {
            if ($mode -eq 'plan') {
                & $launcher --role $fixedRole --selection-output $selectionFile --output $resultFile --error $errorFile '--' --mode plan --prompt $fixedPrompt
            } else {
                & $launcher --role $fixedRole --selection-output $selectionFile --output $resultFile --error $errorFile '--' --prompt $fixedPrompt
            }
        } finally {
            Pop-Location
        }
    } finally {
        if ($null -ne $oldSentinel) {
            $env:FAKE_AGY_SENTINEL_TARGET = $oldSentinel
        } else {
            Remove-Item env:FAKE_AGY_SENTINEL_TARGET -ErrorAction SilentlyContinue
        }
    }
    $armExitCode = $LASTEXITCODE
    $sw.Stop()

    $stdout = if (Test-Path -LiteralPath $resultFile -PathType Leaf) {
        [System.IO.File]::ReadAllText($resultFile, [System.Text.Encoding]::UTF8)
    } else { '' }

    $stderr = if (Test-Path -LiteralPath $errorFile -PathType Leaf) {
        [System.IO.File]::ReadAllText($errorFile, [System.Text.Encoding]::UTF8)
    } else { '' }

    $parsed = $null
    $parseStatus = 'invalid'
    try {
        $trimmed = $stdout.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $parsed = $trimmed | ConvertFrom-Json
            if ($null -ne $parsed) {
                $parseStatus = 'valid'
            }
        }
    } catch { }

    $selection = $null
    try {
        if (Test-Path -LiteralPath $selectionFile -PathType Leaf) {
            $selection = [System.IO.File]::ReadAllText($selectionFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        }
    } catch { }
    foreach ($selectionField in @('adapter', 'vendor', 'model_id', 'effort', 'catalog_revision')) {
        if ($null -eq $selection -or [string]::IsNullOrWhiteSpace([string]$selection.$selectionField)) {
            throw "compatibility arm '$mode' did not produce selection metadata: $selectionField"
        }
    }

    $armObserved = $false
    $reportedSentinel = 'unknown'
    $permission = $null
    $tools = @()
    $commands = @()
    $usage = $null

    if ($null -ne $parsed -and $parseStatus -eq 'valid') {
        if ($parsed.PSObject.Properties.Name -contains 'structured_output' -and $null -ne $parsed.structured_output) {
            $so = $parsed.structured_output
            if ($so.PSObject.Properties.Name -contains 'arm') {
                $armObserved = ([string]$so.arm -eq $mode)
            }
            if ($so.PSObject.Properties.Name -contains 'sentinel_result') {
                $reportedSentinel = [string]$so.sentinel_result
            }
            if ($so.PSObject.Properties.Name -contains 'permission_mode') {
                $permission = [string]$so.permission_mode
            }
            if ($so.PSObject.Properties.Name -contains 'tools' -and $null -ne $so.tools) {
                $tools = @($so.tools)
            }
            if ($so.PSObject.Properties.Name -contains 'commands' -and $null -ne $so.commands) {
                $commands = @($so.commands)
            }
        }
        if ($parsed.PSObject.Properties.Name -contains 'usage' -and $null -ne $parsed.usage) {
            $usage = $parsed.usage
        }
    }

    $sentinelExists = [System.IO.File]::Exists($sentinel)
    $sentinelEstablished = $sentinelExists -or ($mode -eq 'plan' -and $reportedSentinel -eq 'blocked') -or ($mode -eq 'default' -and $reportedSentinel -eq 'succeeded')

    if ($armExitCode -ne 0 -or -not $armObserved -or $parseStatus -ne 'valid' -or -not $sentinelEstablished) {
        throw "could not establish compatibility arm '$mode' or its sentinel result (exit code: $armExitCode, parse status: $parseStatus)"
    }

    $recordedInvocation = if ($mode -eq 'plan') {
        @('--role', $fixedRole, '--selection-output', $selectionFile, '--output', $resultFile, '--error', $errorFile, '--', '--mode', 'plan', '--prompt', $fixedPrompt)
    } else {
        @('--role', $fixedRole, '--selection-output', $selectionFile, '--output', $resultFile, '--error', $errorFile, '--', '--prompt', $fixedPrompt)
    }

    $arms.Add([ordered]@{
        arm = $mode
        invocation = $recordedInvocation
        output_artifact = $resultFile
        error_artifact = $errorFile
        selection_artifact = $selectionFile
        selection = $selection
        exit_code = $armExitCode
        parse_status = $parseStatus
        stdout = $stdout
        stderr = $stderr
        permission_mode = $permission
        tools = $tools
        commands = $commands
        sentinel = [ordered]@{
            attempted = $true
            file = $sentinel
            exists = $sentinelExists
            reported = $reportedSentinel
        }
        duration_seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 3)
        usage = $usage
    })
}

$report = [ordered]@{
    schema_version = 1
    observed_at = [DateTime]::UtcNow.ToString('o')
    version = $version.stdout.Trim()
    version_exit_code = $version.exit_code
    fixed_prompt = $fixedPrompt
    role = $fixedRole
    arms = $arms.ToArray()
    observations = @(
        'Plan mode is a version-sensitive behavioral observation, not a safety guarantee.',
        'Compare exposed tools, commands, permission mode, and sentinel behavior before updating documentation.'
    )
    warnings = @(
        'This probe is maintainer-only and must run in a disposable workspace; it is not a deterministic CI gate.'
    )
}

$raw = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($raw, ($report | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
    $redactor = Join-Path $PSScriptRoot 'redact-publication-secrets.ps1'
    $LASTEXITCODE = 0
    & $redactor --input $raw --output $output
    if ($LASTEXITCODE -ne 0) {
        throw 'probe publication redaction failed'
    }
} finally {
    Remove-Item -LiteralPath $raw -Force -ErrorAction SilentlyContinue
}
[Console]::Out.WriteLine("compatibility probe wrote $output")
