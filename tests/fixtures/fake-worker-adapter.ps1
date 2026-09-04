#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$operation = ''
$requestPath = ''
$outputPath = ''
$errorPath = ''
$workerArgs = [System.Collections.Generic.List[string]]::new()
$i = 0
while ($i -lt $args.Count) {
    $current = [string]$args[$i]
    if ($current -eq '--') {
        $i++
        while ($i -lt $args.Count) { $workerArgs.Add([string]$args[$i]); $i++ }
        break
    }
    switch ($current) {
        '--operation' { $i++; $operation = [string]$args[$i] }
        '--request' { $i++; $requestPath = [string]$args[$i] }
        '--output' { $i++; $outputPath = [string]$args[$i] }
        '--error' { $i++; $errorPath = [string]$args[$i] }
        default { throw "unknown fake adapter option: $current" }
    }
    $i++
}

if ($operation -eq 'catalog') {
    $catalogPath = [Environment]::GetEnvironmentVariable('FAKE_ADAPTER_CATALOG')
    if ([string]::IsNullOrWhiteSpace($catalogPath)) { throw 'FAKE_ADAPTER_CATALOG is required' }
    [Console]::Out.Write([System.IO.File]::ReadAllText($catalogPath))
    exit 0
}
if ($operation -ne 'launch') { throw 'fake adapter operation must be catalog or launch' }
$selection = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($requestPath)) -Depth 20
$capturePath = [Environment]::GetEnvironmentVariable('FAKE_ADAPTER_CAPTURE')
if (-not [string]::IsNullOrWhiteSpace($capturePath)) {
    [ordered]@{ selection = $selection; worker_args = $workerArgs.ToArray() } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $capturePath -Encoding utf8
}
$agyBin = [Environment]::GetEnvironmentVariable('AGY_BIN')
if (-not [string]::IsNullOrWhiteSpace($agyBin)) {
    $agyArgs = @('--model', [string]$selection.model_id, '--effort', [string]$selection.effort) + $workerArgs.ToArray()
    if ($agyBin.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        & (Get-Command pwsh -ErrorAction Stop).Source -NoProfile -NonInteractive -File $agyBin @agyArgs > $outputPath 2> $errorPath
    } else {
        & $agyBin @agyArgs > $outputPath 2> $errorPath
    }
    exit $LASTEXITCODE
}
[ordered]@{ status = 'SUCCESS'; model_id = $selection.model_id; effort = $selection.effort; worker_args = $workerArgs.ToArray() } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outputPath -Encoding utf8
[System.IO.File]::WriteAllText($errorPath, '')
$exitCode = [Environment]::GetEnvironmentVariable('FAKE_ADAPTER_LAUNCH_EXIT_CODE')
if (-not [string]::IsNullOrWhiteSpace($exitCode)) { exit ([int]$exitCode) }
exit 0
