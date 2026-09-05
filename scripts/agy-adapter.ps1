#!/usr/bin/env pwsh
# Reference worker adapter. Vendor-specific AGY syntax lives here, not in the launcher.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Fail([string]$message, [int]$exitCode = 2) {
    [Console]::Error.WriteLine("ERROR: $message")
    exit $exitCode
}

function Resolve-Program([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { Fail 'AGY_BIN is empty' }
    if ($path.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        return @{ File = (Get-Command pwsh -ErrorAction Stop).Source; Prefix = @('-NoProfile', '-NonInteractive', '-File', $path) }
    }
    return @{ File = $path; Prefix = @() }
}

function Invoke-Captured([string]$file, [string[]]$arguments, [string]$stdoutPath, [string]$stderrPath) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $file
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in $arguments) { [void]$psi.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { Fail "failed to start adapter command: $file" 127 }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [System.IO.File]::WriteAllText($stdoutPath, $stdoutTask.Result, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($stderrPath, $stderrTask.Result, [System.Text.Encoding]::UTF8)
        return $process.ExitCode
    } finally {
        $process.Dispose()
    }
}

function Get-FamilyHint([string]$modelId) {
    if ($modelId -match '^gemini-[^-]+-(?<family>flash|pro)-') { return $Matches.family }
    if ($modelId -match '^claude-[^-]+-(?<family>opus|sonnet|haiku)') { return $Matches.family }
    if ($modelId -match '^gpt-oss-') { return 'oss' }
    return 'unknown'
}

function Get-PreferenceScore([string]$family, [string]$preference) {
    $scores = @{
        fast = @{ flash = 1; haiku = 2; oss = 2; sonnet = 3; pro = 4; opus = 5; unknown = 100 }
        balanced = @{ sonnet = 1; flash = 2; oss = 3; pro = 3; haiku = 4; opus = 5; unknown = 100 }
        deep = @{ opus = 1; pro = 2; sonnet = 3; oss = 4; flash = 5; haiku = 6; unknown = 100 }
    }
    if ($scores.ContainsKey($preference) -and $scores[$preference].ContainsKey($family)) { return $scores[$preference][$family] }
    return 100
}

function Get-Preflight($model) {
    if ($null -ne $model -and $model.PSObject.Properties['preflight']) { return $model.preflight }
    return [ordered]@{
        access = [ordered]@{ state = 'unknown'; reason = 'adapter did not verify authenticated access'; account_ref = '' }
        entitlement = [ordered]@{ state = 'unknown'; reason = 'adapter did not verify model entitlement'; billing_route = 'unknown' }
        usage = [ordered]@{ state = 'unknown'; reason = 'adapter did not query usage'; source = 'not-queried'; observed_at = ''; scopes = @() }
    }
}

function Convert-ModelListToCatalog([string]$raw) {
    $models = @(
        foreach ($line in ($raw -split "`r?`n")) {
            if ($line -notmatch '^\s*(?<id>\S+)\s+(?<label>.+?)\s*$') { continue }
            $modelId = $Matches.id
            if ($modelId -notmatch '-(?<effort>low|medium|high)$') { continue }
            $effort = $Matches.effort
            $family = Get-FamilyHint $modelId
            [ordered]@{
                id = $modelId
                family_hint = $family
                available = $true
                quota_available = $true
                supported_efforts = @($effort)
                capabilities = @()
                scores = [ordered]@{
                    fast = Get-PreferenceScore $family 'fast'
                    balanced = Get-PreferenceScore $family 'balanced'
                    deep = Get-PreferenceScore $family 'deep'
                }
                preflight = Get-Preflight $null
            }
        }
    )
    if ($models.Count -eq 0) { Fail 'AGY catalog discovery returned no recognizable models' 127 }
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try { $revision = [Convert]::ToHexString($hash.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))).ToLowerInvariant() }
    finally { $hash.Dispose() }
    [ordered]@{
        protocol_version = 2
        adapter = 'agy'
        adapter_revision = 'agy-2'
        vendor = 'agy'
        catalog_revision = $revision
        models = $models
    } | ConvertTo-Json -Depth 20 -Compress
}

$operation = ''
$requestPath = ''
$outputPath = ''
$errorPath = ''
$workerArgs = [System.Collections.Generic.List[string]]::new()
$afterDelimiter = $false
$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    if ($arg -eq '--') {
        $afterDelimiter = $true
        $i++
        while ($i -lt $args.Count) { $workerArgs.Add([string]$args[$i]); $i++ }
        break
    }
    if ($arg -in @('--operation', '--request', '--output', '--error')) {
        if ($i + 1 -ge $args.Count) { Fail "$arg requires a value" }
        $value = [string]$args[$i + 1]
        switch ($arg) {
            '--operation' { $operation = $value }
            '--request' { $requestPath = $value }
            '--output' { $outputPath = $value }
            '--error' { $errorPath = $value }
        }
        $i += 2
        continue
    }
    Fail "unknown adapter option: $arg"
}

if ($operation -ne 'catalog' -and $operation -ne 'launch') { Fail 'operation must be catalog or launch' }
if ([string]::IsNullOrWhiteSpace($requestPath) -or -not (Test-Path -LiteralPath $requestPath -PathType Leaf)) { Fail 'request file is required' }

$request = $null
try { $request = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($requestPath)) -Depth 20 -ErrorAction Stop }
catch { Fail "request is not valid JSON: $($_.Exception.Message)" }

$agyValue = [Environment]::GetEnvironmentVariable('AGY_BIN')
if ([string]::IsNullOrWhiteSpace($agyValue)) { $agyValue = 'agy' }
$program = Resolve-Program $agyValue

if ($operation -eq 'catalog') {
    $catalogPath = [Environment]::GetEnvironmentVariable('OFFLOAD_ADAPTER_CATALOG')
    if (-not [string]::IsNullOrWhiteSpace($catalogPath)) {
        if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) { Fail "catalog file not found: $catalogPath" 127 }
        [Console]::Out.Write([System.IO.File]::ReadAllText($catalogPath))
        exit 0
    }

    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    try {
        $code = Invoke-Captured $program.File ($program.Prefix + @('models')) $stdout $stderr
        if ($code -ne 0) { Fail "AGY catalog discovery failed with exit code ${code}: $([System.IO.File]::ReadAllText($stderr))" 127 }
        [Console]::Out.Write((Convert-ModelListToCatalog ([System.IO.File]::ReadAllText($stdout))))
    } finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

if (-not $afterDelimiter -or $workerArgs.Count -eq 0) { Fail 'worker arguments are required after --' }
if ([string]::IsNullOrWhiteSpace($outputPath) -or [string]::IsNullOrWhiteSpace($errorPath)) { Fail 'launch requires output and error paths' }
$modelId = [string]$request.model_id
if ([string]::IsNullOrWhiteSpace($modelId)) { $modelId = [string]$request.model }
if ([string]::IsNullOrWhiteSpace($modelId)) { Fail 'selection is missing model_id' }

# AGY accepts the exact model ID here. The launcher never needs to know this syntax.
$code = Invoke-Captured $program.File ($program.Prefix + @('--model', $modelId) + $workerArgs.ToArray()) $outputPath $errorPath
exit $code
