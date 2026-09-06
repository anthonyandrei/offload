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

function Invoke-Captured([string]$file, [string[]]$arguments, [string]$stdoutPath, [string]$stderrPath, [int]$timeoutMilliseconds = 0) {
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
        $timedOut = $false
        if ($timeoutMilliseconds -gt 0) {
            if (-not $process.WaitForExit($timeoutMilliseconds)) {
                $timedOut = $true
                try { $process.Kill($true) } catch { }
                $process.WaitForExit()
            }
        } else {
            $process.WaitForExit()
        }
        [System.IO.File]::WriteAllText($stdoutPath, $stdoutTask.Result, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($stderrPath, $stderrTask.Result, [System.Text.Encoding]::UTF8)
        return [pscustomobject]@{ Code = $process.ExitCode; TimedOut = $timedOut }
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

function Get-UsageGroupForModel([string]$modelId) {
    if ($modelId -match '^gemini-') { return 'gemini' }
    if ($modelId -match '^(claude-|gpt-)') { return 'claude-and-gpt' }
    return ''
}

function Get-UsageGroup([string]$name) {
    $normalized = ([string]$name).ToLowerInvariant()
    if ($normalized -match 'gemini') { return 'gemini' }
    if ($normalized -match 'claude' -and $normalized -match 'gpt') { return 'claude-and-gpt' }
    return ''
}

function Get-NormalizedResetTime($value) {
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return '' }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return '' }
    return $parsed.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

function Get-UsageSnapshot([string]$raw) {
    $snapshot = [ordered]@{
        observed_at = ''
        reason = 'AGY usage probe did not expose supported group-level usage'
        groups = @{}
    }
    $document = $null
    try { $document = ConvertFrom-Json -InputObject $raw -Depth 30 -ErrorAction Stop }
    catch {
        $snapshot.reason = 'AGY usage probe returned malformed JSON'
        return [pscustomobject]$snapshot
    }
    $status = if ($document.PSObject.Properties['status']) { [string]$document.status } else { '' }
    if ($status -notin @('SUCCESS', 'success')) {
        $snapshot.reason = 'AGY usage probe returned a non-success status'
        return [pscustomobject]$snapshot
    }

    $groups = @()
    $command = if ($document.PSObject.Properties['command']) { $document.command } else { $null }
    if ($null -ne $command -and $command.PSObject.Properties['data'] -and $null -ne $command.data -and $command.data.PSObject.Properties['groups']) {
        $groups = @($command.data.groups)
    } elseif ($null -ne $command -and $command.PSObject.Properties['groups']) {
        $groups = @($command.groups)
    } elseif ($document.PSObject.Properties['groups']) {
        $groups = @($document.groups)
    }
    $recognizedGroups = 0
    foreach ($group in $groups) {
        if ($null -eq $group) { continue }
        $groupName = if ($group.PSObject.Properties['id']) { [string]$group.id } elseif ($group.PSObject.Properties['name']) { [string]$group.name } else { '' }
        $groupKey = Get-UsageGroup $groupName
        if ([string]::IsNullOrWhiteSpace($groupKey)) { continue }
        $recognizedGroups++
        $scopes = [System.Collections.Generic.List[object]]::new()
        if (-not $group.PSObject.Properties['buckets']) { continue }
        foreach ($bucket in @($group.buckets)) {
            if ($null -eq $bucket -or -not $bucket.PSObject.Properties['id'] -or -not $bucket.PSObject.Properties['window'] -or -not $bucket.PSObject.Properties['remaining_fraction'] -or -not $bucket.PSObject.Properties['reset_time']) { continue }
            $bucketId = [string]$bucket.id
            $window = [string]$bucket.window
            $remaining = 0.0
            if ([string]::IsNullOrWhiteSpace($bucketId) -or [string]::IsNullOrWhiteSpace($window) -or -not [double]::TryParse([string]$bucket.remaining_fraction, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$remaining) -or $remaining -lt 0 -or $remaining -gt 1) { continue }
            $resetAt = Get-NormalizedResetTime $bucket.reset_time
            if ([string]::IsNullOrWhiteSpace($resetAt)) { continue }
            $scopes.Add([ordered]@{
                scope_id = $bucketId
                window = $window
                remaining_units = $remaining
                reserved_units = 0
                reset_at = $resetAt
            })
        }
        if ($scopes.Count -gt 0) { $snapshot.groups[$groupKey] = @($scopes) }
    }
    if ($snapshot.groups.Count -eq 0) {
        if ($recognizedGroups -gt 0) { $snapshot.reason = 'AGY usage probe returned no valid group-level usage bucket' }
        return [pscustomobject]$snapshot
    }
    $snapshot.observed_at = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $snapshot.reason = ''
    return [pscustomobject]$snapshot
}

function Get-Preflight($usageSnapshot, [string]$usageGroup) {
    $usageReason = [string]$usageSnapshot.reason
    $observedAt = [string]$usageSnapshot.observed_at
    if (-not [string]::IsNullOrWhiteSpace($usageGroup) -and $usageSnapshot.groups.Contains($usageGroup) -and @($usageSnapshot.groups[$usageGroup]).Count -gt 0) {
        $usageReason = 'AGY usage exposes group-level fractions without protocol capacity units or reservation data'
    } elseif ([string]::IsNullOrWhiteSpace($usageReason)) {
        $usageReason = if ([string]::IsNullOrWhiteSpace($usageGroup)) { 'AGY model ID is not mapped to a supported usage group' } else { "AGY usage probe returned no valid usage bucket for model group '$usageGroup'" }
    }
    return [ordered]@{
        access = [ordered]@{ state = 'unknown'; reason = 'AGY headless discovery does not expose a non-secret account identifier'; account_ref = '' }
        entitlement = [ordered]@{ state = 'unknown'; reason = 'AGY headless discovery does not expose model entitlement'; billing_route = 'unknown' }
        usage = [ordered]@{ state = 'unknown'; reason = $usageReason; source = 'agy-usage'; observed_at = $observedAt; scopes = @() }
    }
}

function Convert-ModelListToCatalog([string]$raw, $usageSnapshot) {
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
                supported_efforts = @($effort)
                capabilities = @()
                scores = [ordered]@{
                    fast = Get-PreferenceScore $family 'fast'
                    balanced = Get-PreferenceScore $family 'balanced'
                    deep = Get-PreferenceScore $family 'deep'
                }
                preflight = Get-Preflight $usageSnapshot (Get-UsageGroupForModel $modelId)
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
        adapter_revision = 'agy-3'
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
        $modelsResult = Invoke-Captured $program.File ($program.Prefix + @('models')) $stdout $stderr 15000
        if ($modelsResult.TimedOut) { Fail 'AGY catalog discovery timed out' 127 }
        if ($modelsResult.Code -ne 0) { Fail "AGY catalog discovery failed with exit code $($modelsResult.Code)" 127 }
        $usageStdout = [System.IO.Path]::GetTempFileName()
        $usageStderr = [System.IO.Path]::GetTempFileName()
        try {
            $usageResult = Invoke-Captured $program.File ($program.Prefix + @('-p', '/usage', '--output-format', 'json', '--print-timeout', '15s')) $usageStdout $usageStderr 15000
            if ($usageResult.TimedOut) {
                $usageSnapshot = [pscustomobject]@{ observed_at = ''; reason = 'AGY usage probe timed out'; groups = @{} }
            } elseif ($usageResult.Code -ne 0) {
                $usageSnapshot = [pscustomobject]@{ observed_at = ''; reason = "AGY usage probe failed with exit code $($usageResult.Code)"; groups = @{} }
            } else {
                $usageSnapshot = Get-UsageSnapshot ([System.IO.File]::ReadAllText($usageStdout))
            }
            [Console]::Out.Write((Convert-ModelListToCatalog ([System.IO.File]::ReadAllText($stdout)) $usageSnapshot))
        } finally {
            Remove-Item -LiteralPath $usageStdout, $usageStderr -Force -ErrorAction SilentlyContinue
        }
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
$launchResult = Invoke-Captured $program.File ($program.Prefix + @('--model', $modelId) + $workerArgs.ToArray()) $outputPath $errorPath
exit $launchResult.Code
