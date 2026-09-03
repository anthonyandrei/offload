#!/usr/bin/env pwsh
# Maintainer-only compatibility probe. It is intentionally not part of CI.
$ErrorActionPreference = 'Stop'; Set-StrictMode -Version 3.0
$workspace=''; $output=''
for ($i=0; $i -lt $args.Count; $i++) {
    switch ([string]$args[$i]) {
        '--workspace' { $i++; if ($i -ge $args.Count) { throw '--workspace requires a directory' }; $workspace=[string]$args[$i] }
        '--output' { $i++; if ($i -ge $args.Count) { throw '--output requires a file' }; $output=[string]$args[$i] }
        default { throw "unknown argument: $($args[$i])" }
    }
}
if ([string]::IsNullOrWhiteSpace($workspace) -or [string]::IsNullOrWhiteSpace($output)) { throw 'usage: probe-agy-compatibility.ps1 --workspace <disposable-dir> --output <report.json>' }
[IO.Directory]::CreateDirectory($workspace) | Out-Null
$agy = if ($env:AGY_BIN) { $env:AGY_BIN } else { 'agy' }
$fixedPrompt = 'In the disposable probe workspace, report the observed permission mode, exposed tools and commands, and attempt the requested sentinel write. Return the fixed structured schema.'
$fixedRole = 'researcher'; $fixedModel = 'gemini-3.8-flash-high'; $fixedSchema = '1'
function Invoke-Captured([string[]]$arguments, [string]$workingDirectory, [string]$sentinel) {
    $psi=[Diagnostics.ProcessStartInfo]::new(); $isPs1=$agy -match '(?i)\.ps1$'
    if ($isPs1) { $psi.FileName=(Get-Command pwsh).Source; [void]$psi.ArgumentList.Add('-NoProfile'); [void]$psi.ArgumentList.Add('-NonInteractive'); [void]$psi.ArgumentList.Add('-File'); [void]$psi.ArgumentList.Add($agy) } else { $psi.FileName=$agy }
    foreach ($a in $arguments) { [void]$psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory=$workingDirectory; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.UseShellExecute=$false
    $psi.Environment['FAKE_AGY_SENTINEL_TARGET']=$sentinel
    $sw=[Diagnostics.Stopwatch]::StartNew(); $p=[Diagnostics.Process]::Start($psi); $stdout=$p.StandardOutput.ReadToEnd(); $stderr=$p.StandardError.ReadToEnd(); $p.WaitForExit(); $sw.Stop()
    $parsed=$null; $parseStatus='invalid'
    try { $parsed=$stdout.Trim() | ConvertFrom-Json; if ($null -ne $parsed) { $parseStatus='valid' } } catch { }
    [pscustomobject]@{ exit_code=$p.ExitCode; stdout=$stdout; stderr=$stderr; parse_status=$parseStatus; structured_output=if ($parsed -and $parsed.PSObject.Properties.Name -contains 'structured_output') { $parsed.structured_output } else { $null }; duration_seconds=[Math]::Round($sw.Elapsed.TotalSeconds,3); sentinel_exists=[IO.File]::Exists($sentinel); parsed=$parsed }
}
function Invoke-Version {
    $psi=[Diagnostics.ProcessStartInfo]::new(); $isPs1=$agy -match '(?i)\.ps1$'; if ($isPs1) { $psi.FileName=(Get-Command pwsh).Source; [void]$psi.ArgumentList.Add('-NoProfile'); [void]$psi.ArgumentList.Add('-NonInteractive'); [void]$psi.ArgumentList.Add('-File'); [void]$psi.ArgumentList.Add($agy) } else { $psi.FileName=$agy }; [void]$psi.ArgumentList.Add('--version'); $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.UseShellExecute=$false
    $p=[Diagnostics.Process]::Start($psi); $o=$p.StandardOutput.ReadToEnd(); $e=$p.StandardError.ReadToEnd(); $p.WaitForExit(); [pscustomobject]@{ exit_code=$p.ExitCode; stdout=$o; stderr=$e }
}
$version=Invoke-Version; if ($version.exit_code -ne 0 -or [string]::IsNullOrWhiteSpace($version.stdout)) { throw 'could not establish agy version' }
$arms=[System.Collections.Generic.List[object]]::new()
foreach ($mode in @('plan','default')) {
    $armDir=Join-Path $workspace $mode; [IO.Directory]::CreateDirectory($armDir) | Out-Null; $sentinel=Join-Path $armDir 'sentinel.txt'; $resultFile=Join-Path $armDir 'result.json'
    $argList=[System.Collections.Generic.List[string]]::new(); if ($mode -eq 'plan') { $argList.Add('--mode'); $argList.Add('plan') }; $argList.Add('--role'); $argList.Add($fixedRole); $argList.Add('--model'); $argList.Add($fixedModel); $argList.Add('--schema-version'); $argList.Add($fixedSchema); $argList.Add('--prompt'); $argList.Add($fixedPrompt); $argList.Add('--output'); $argList.Add($resultFile)
    $run=Invoke-Captured $argList.ToArray() $armDir $sentinel
    $parsedArm=$run.parsed; $armObserved=$false; $reportedSentinel='unknown'; $permission=$null; $tools=@(); $commands=@(); $usage=$null
    if ($null -ne $parsedArm) {
        if ($parsedArm.PSObject.Properties.Name -contains 'structured_output' -and $null -ne $parsedArm.structured_output) {
            $so=$parsedArm.structured_output; $armObserved=([string]$so.arm -eq $mode); $reportedSentinel=[string]$so.sentinel_result; if ($so.PSObject.Properties.Name -contains 'permission_mode') { $permission=[string]$so.permission_mode }; if ($so.PSObject.Properties.Name -contains 'tools') { $tools=@($so.tools) }; if ($so.PSObject.Properties.Name -contains 'commands') { $commands=@($so.commands) }
        }
        if ($parsedArm.PSObject.Properties.Name -contains 'usage') { $usage=$parsedArm.usage }
    }
    $sentinelEstablished=$run.sentinel_exists -or ($mode -eq 'plan' -and $reportedSentinel -eq 'blocked') -or ($mode -eq 'default' -and $reportedSentinel -eq 'succeeded')
    if (-not $armObserved -or $run.parse_status -ne 'valid' -or -not $sentinelEstablished) { throw "could not establish compatibility arm '$mode' or its sentinel result" }
    $recordedInvocation = if ($mode -eq 'plan') { @('--mode', 'plan', '--role', $fixedRole, '--model', $fixedModel, '--schema-version', $fixedSchema) } else { @('--role', $fixedRole, '--model', $fixedModel, '--schema-version', $fixedSchema) }
    $arms.Add([ordered]@{ arm=$mode; invocation=$recordedInvocation; exit_code=$run.exit_code; parse_status=$run.parse_status; stdout=$run.stdout; stderr=$run.stderr; permission_mode=$permission; tools=$tools; commands=$commands; sentinel=@{ attempted=$true; file=$sentinel; exists=$run.sentinel_exists; reported=$reportedSentinel }; duration_seconds=$run.duration_seconds; usage=$usage })
}
$report=[ordered]@{ schema_version=1; observed_at=[DateTime]::UtcNow.ToString('o'); version=$version.stdout.Trim(); version_exit_code=$version.exit_code; fixed_prompt=$fixedPrompt; role=$fixedRole; model=$fixedModel; output_schema_version=$fixedSchema; arms=$arms.ToArray(); observations=@('Plan mode is a version-sensitive behavioral observation, not a safety guarantee.','Compare exposed tools, commands, permission mode, and sentinel behavior before updating documentation.'); warnings=@('This probe is maintainer-only and must run in a disposable workspace; it is not a deterministic CI gate.') }
$raw=[IO.Path]::GetTempFileName(); try { [IO.File]::WriteAllText($raw,($report | ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false)); $redactor=Join-Path $PSScriptRoot 'redact-publication-secrets.ps1'; $LASTEXITCODE=0; & $redactor --input $raw --output $output; if ($LASTEXITCODE -ne 0) { throw 'probe publication redaction failed' } } finally { Remove-Item -LiteralPath $raw -Force -ErrorAction SilentlyContinue }
[Console]::Out.WriteLine("compatibility probe wrote $output")
