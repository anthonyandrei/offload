#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$fixturePath = [Environment]::GetEnvironmentVariable('AGY_PREFLIGHT_FIXTURE')
$callLog = [Environment]::GetEnvironmentVariable('AGY_PREFLIGHT_CALL_LOG')
$scenario = [Environment]::GetEnvironmentVariable('AGY_PREFLIGHT_SCENARIO')
if ([string]::IsNullOrWhiteSpace($fixturePath) -or [string]::IsNullOrWhiteSpace($callLog)) { throw 'AGY preflight fixture and call log are required' }
if ([string]::IsNullOrWhiteSpace($scenario)) { $scenario = 'discovery' }

$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -Depth 20
Add-Content -LiteralPath $callLog -Value ($args -join ' ')

if ($scenario -like 'redaction*') {
    [Console]::Error.WriteLine("token=$($fixture.redaction_sentinel) account=private-account billing=private-route")
}

if ($args.Count -eq 1 -and $args[0] -eq 'models') {
    if ($scenario -eq 'timed-out-models') { Start-Sleep -Seconds 16; exit 124 }
    if ($scenario -eq 'models-exit-124') { exit 124 }
    if ($scenario -eq 'models-exit-137') { exit 137 }
    foreach ($model in @($fixture.model_list)) { [Console]::Out.WriteLine([string]$model) }
    exit 0
}

if ($args.Count -ge 4 -and $args[0] -eq '-p' -and $args[1] -eq '/usage' -and $args[2] -eq '--output-format' -and $args[3] -eq 'json') {
    switch ($scenario) {
        { $_ -in @('unsupported', 'unsupported-usage', 'redaction-unsupported', 'redaction-unsupported-usage') } { [Console]::Error.WriteLine('unknown option: /usage'); exit 2 }
        { $_ -in @('malformed', 'malformed-usage') } { [Console]::Out.WriteLine('{malformed usage response'); exit 0 }
        { $_ -in @('timed-out', 'timed-out-usage') } { Start-Sleep -Seconds 16; exit 124 }
        'usage-exit-124' { exit 124 }
        'usage-exit-137' { exit 137 }
        default { [Console]::Out.WriteLine('{"status":"SUCCESS","groups":[{"id":"gemini","buckets":[{"id":"gemini-fixture","window":"daily","remaining_fraction":0.75,"reset_time":"2099-01-01T00:00:00Z"}]}]}'); exit 0 }
    }
}

if (($args -contains '--model') -or ($args | Where-Object { [string]$_ -like '--model=*' })) {
    [Console]::Out.WriteLine('{"status":"success","structured_output":{"ok":true}}')
    exit 0
}

[Console]::Error.WriteLine('unexpected fake AGY invocation')
exit 2
