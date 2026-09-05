#!/usr/bin/env pwsh
# scripts/run-codex-json.ps1
# Codex worker adapter. Conforms to the adapter contract (--operation catalog | launch).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Fail([string]$Message, [int]$Code = 2) {
    [Console]::Error.WriteLine("ERROR: $Message")
    exit $Code
}

function Usage {
    [Console]::Error.WriteLine("Usage: run-codex-json.ps1 --operation catalog --request REQUEST.json [--codex PATH]")
    [Console]::Error.WriteLine("       run-codex-json.ps1 --operation launch --request SELECTION.json --output OUTPUT --error ERROR [--codex PATH] [--cancel-file FILE] [--timeout-seconds N] -- WORKER_ARGS...")
}

function Resolve-Executable([string]$Requested) {
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $cmd = Get-Command $Requested -ErrorAction SilentlyContinue
        if ($cmd) {
            if ($cmd.Source) { return $cmd.Source }
            return $cmd.Name
        }
        if (Test-Path -LiteralPath $Requested -PathType Leaf) { return (Resolve-Path -LiteralPath $Requested).Path }
        Fail "Codex executable does not exist: $Requested" 127
    }
    $envBin = [Environment]::GetEnvironmentVariable('CODEX_BIN')
    if (-not [string]::IsNullOrWhiteSpace($envBin)) {
        return Resolve-Executable $envBin
    }
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd) {
        if ($cmd.Source) { return $cmd.Source }
        return $cmd.Name
    }
    Fail 'Codex executable was not found on PATH or via CODEX_BIN' 127
}

function New-ProcessInfo([string]$File, [string[]]$Arguments, [string]$WorkingDirectory = '') {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    if ($File.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        $psi.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-NonInteractive')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add($File)
    } else {
        $psi.FileName = $File
    }
    foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add([string]$arg) }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    return $psi
}

function Probe-Codex([string]$CodexPath) {
    $psi = New-ProcessInfo $CodexPath @('--help')
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { return @{ ExitCode = 127; Stdout = ''; Stderr = 'failed to start' } }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return @{ ExitCode = $process.ExitCode; Stdout = $outTask.Result; Stderr = $errTask.Result }
    } finally {
        $process.Dispose()
    }
}

function Get-CatalogData {
    $source = [Environment]::GetEnvironmentVariable('OFFLOAD_ADAPTER_CATALOG')
    if ([string]::IsNullOrWhiteSpace($source)) {
        $source = [Environment]::GetEnvironmentVariable('CODEX_MODEL_CATALOG')
    }
    if ([string]::IsNullOrWhiteSpace($source)) { return $null }
    try {
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            return Get-Content -LiteralPath $source -Raw | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        }
        return $source | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    } catch {
        return $null
    }
}

function Get-Preflight($model) {
    if ($null -ne $model -and $model.PSObject.Properties['preflight']) { return $model.preflight }
    return [ordered]@{
        access = [ordered]@{ state = 'unknown'; reason = 'adapter did not verify authenticated access'; account_ref = '' }
        entitlement = [ordered]@{ state = 'unknown'; reason = 'adapter did not verify model entitlement'; billing_route = 'unknown' }
        usage = [ordered]@{ state = 'unknown'; reason = 'adapter did not query usage'; source = 'not-queried'; observed_at = ''; scopes = @() }
    }
}

$operation = ''
$requestPath = ''
$outputPath = ''
$errorPath = ''
$codexPath = ''
$cancelFile = ''
$timeoutSeconds = 0
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
    if ($arg -in @('--operation', '--request', '--output', '--error', '--codex', '--cancel-file', '--timeout-seconds')) {
        if ($i + 1 -ge $args.Count) { Fail "$arg requires a value" }
        $val = [string]$args[$i + 1]
        switch ($arg) {
            '--operation' { $operation = $val }
            '--request' { $requestPath = $val }
            '--output' { $outputPath = $val }
            '--error' { $errorPath = $val }
            '--codex' { $codexPath = $val }
            '--cancel-file' { $cancelFile = $val }
            '--timeout-seconds' { [void][int]::TryParse($val, [ref]$timeoutSeconds) }
        }
        $i += 2
        continue
    }
    if ($arg -in @('-h', '--help')) { Usage; exit 0 }
    Fail "unknown adapter option: $arg"
}

if ($operation -ne 'catalog' -and $operation -ne 'launch') { Fail 'operation must be catalog or launch' }
if ([string]::IsNullOrWhiteSpace($requestPath) -or -not (Test-Path -LiteralPath $requestPath -PathType Leaf)) {
    Fail 'request file is required and must exist'
}

$resolvedCodex = Resolve-Executable $codexPath

if ($operation -eq 'catalog') {
    $probe = Probe-Codex $resolvedCodex
    $structured = $probe.Stdout.Contains('--json') -and $probe.Stdout.Contains('--output-schema') -and $probe.Stdout.Contains('--output-last-message')
    if ($probe.ExitCode -ne 0 -or -not $structured) {
        Fail 'host lacks required structured-output flags' 127
    }

    $rawCatalog = Get-CatalogData
    if ($null -eq $rawCatalog -or $null -eq $rawCatalog.models -or @($rawCatalog.models).Count -eq 0) {
        Fail 'host does not expose a model catalog' 127
    }

    $models = @(
        foreach ($m in @($rawCatalog.models)) {
            $efforts = if ($m.PSObject.Properties['supported_efforts']) { @($m.supported_efforts) } elseif ($m.PSObject.Properties['efforts']) { @($m.efforts) } else { @('low', 'medium', 'high') }
            $caps = if ($m.PSObject.Properties['capabilities']) { @($m.capabilities) } else { @('structured-output') }
            $family = if ($m.PSObject.Properties['family_hint']) { [string]$m.family_hint } else { 'unknown' }
            $scores = if ($m.PSObject.Properties['scores']) { $m.scores } else {
                $pref = if ($m.PSObject.Properties['preference']) { [string]$m.preference } else { 'balanced' }
                switch ($pref) {
                    'fast'     { [ordered]@{ fast = 1; balanced = 2; deep = 3 } }
                    'balanced' { [ordered]@{ fast = 2; balanced = 1; deep = 2 } }
                    'deep'     { [ordered]@{ fast = 3; balanced = 2; deep = 1 } }
                    default    { [ordered]@{ fast = 100; balanced = 100; deep = 100 } }
                }
            }
            [ordered]@{
                id = [string]$m.id
                family_hint = $family
                available = if ($m.PSObject.Properties['available']) { [bool]$m.available } else { $true }
                quota_available = if ($m.PSObject.Properties['quota_available']) { [bool]$m.quota_available } else { $true }
                supported_efforts = @($efforts | ForEach-Object { [string]$_ })
                capabilities = @($caps | ForEach-Object { [string]$_ })
                scores = $scores
                preflight = Get-Preflight $m
            }
        }
    )

    $revision = if ($rawCatalog.PSObject.Properties['revision']) { [string]$rawCatalog.revision } else {
        $hash = [System.Security.Cryptography.SHA256]::Create()
        try { [Convert]::ToHexString($hash.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($rawCatalog | ConvertTo-Json -Depth 20)))).ToLowerInvariant() }
        finally { $hash.Dispose() }
    }

    $catalogDoc = [ordered]@{
        protocol_version = 2
        adapter = 'codex'
        adapter_revision = 'codex-2'
        vendor = 'codex'
        catalog_revision = $revision
        models = $models
    }
    [Console]::Out.Write(($catalogDoc | ConvertTo-Json -Depth 20 -Compress))
    exit 0
}

# Launch operation
if (-not $afterDelimiter -or $workerArgs.Count -eq 0) { Fail 'worker arguments are required after --' }
if ([string]::IsNullOrWhiteSpace($outputPath) -or [string]::IsNullOrWhiteSpace($errorPath)) { Fail 'launch requires output and error paths' }

$selection = $null
try {
    $selection = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json -Depth 20 -ErrorAction Stop
} catch {
    Fail "request is not valid JSON: $($_.Exception.Message)"
}

$modelId = [string]$selection.model_id
if ([string]::IsNullOrWhiteSpace($modelId)) { $modelId = [string]$selection.model }
if ([string]::IsNullOrWhiteSpace($modelId)) { Fail 'selection is missing model_id' }

$prompt = ''
$worktree = ''
$schemaPath = ''
$schemaInline = ''
$resumeSession = ''
$j = 0
while ($j -lt $workerArgs.Count) {
    $warg = [string]$workerArgs[$j]
    if ($warg -eq '--') {
        $j++
        if ($j -lt $workerArgs.Count) {
            $prompt = [string]$workerArgs[$j]
            $j++
        }
        break
    }
    if ($warg -in @('-p', '--prompt')) {
        $j++; if ($j -lt $workerArgs.Count) { $prompt = [string]$workerArgs[$j] }
        $j++; continue
    }
    if ($warg.StartsWith('--prompt=')) {
        $prompt = $warg.Substring(9)
        $j++; continue
    }
    if ($warg -in @('--cd', '-C', '--working-directory')) {
        $j++; if ($j -lt $workerArgs.Count) { $worktree = [string]$workerArgs[$j] }
        $j++; continue
    }
    if ($warg.StartsWith('--cd=')) {
        $worktree = $warg.Substring(5)
        $j++; continue
    }
    if ($warg -in @('--output-schema', '--json-schema')) {
        $j++; if ($j -lt $workerArgs.Count) { $candidateSchema = [string]$workerArgs[$j]; if ($candidateSchema.TrimStart().StartsWith('{') -or $candidateSchema.TrimStart().StartsWith('[')) { $schemaInline = $candidateSchema; $schemaPath = '' } else { $schemaPath = $candidateSchema } }
        $j++; continue
    }
    if ($warg -in @('--resume', '--resume-session')) {
        $j++; if ($j -lt $workerArgs.Count) { $resumeSession = [string]$workerArgs[$j] }
        $j++; continue
    }
    if ($warg -eq '--cancel-file') {
        $j++; if ($j -lt $workerArgs.Count) { $cancelFile = [string]$workerArgs[$j] }
        $j++; continue
    }
    if ($warg -eq '--timeout-seconds') {
        $j++; if ($j -lt $workerArgs.Count) { [void][int]::TryParse([string]$workerArgs[$j], [ref]$timeoutSeconds) }
        $j++; continue
    }
    if (-not $prompt -and -not $warg.StartsWith('-')) {
        $prompt = $warg
        $j++; continue
    }
    $j++
}

if ([string]::IsNullOrWhiteSpace($worktree)) {
    $worktree = (Get-Location).Path
}
$worktree = [System.IO.Path]::GetFullPath($worktree)

$outFull = [System.IO.Path]::GetFullPath($outputPath)
$errFull = [System.IO.Path]::GetFullPath($errorPath)
$outParent = Split-Path -Parent $outFull
if ($outParent -and -not (Test-Path -LiteralPath $outParent -PathType Container)) {
    [System.IO.Directory]::CreateDirectory($outParent) | Out-Null
}
$errParent = Split-Path -Parent $errFull
if ($errParent -and -not (Test-Path -LiteralPath $errParent -PathType Container)) {
    [System.IO.Directory]::CreateDirectory($errParent) | Out-Null
}

$tempSchema = $null
if (-not [string]::IsNullOrWhiteSpace($schemaInline)) {
    try { $null = $schemaInline | ConvertFrom-Json -Depth 30 -ErrorAction Stop } catch { Fail "inline output schema is not valid JSON: $($_.Exception.Message)" 2 }
    $tempSchema = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempSchema, $schemaInline, [System.Text.Encoding]::UTF8)
    $schemaPath = $tempSchema
} elseif ([string]::IsNullOrWhiteSpace($schemaPath) -or -not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    $tempSchema = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempSchema, '{"type":"object","additionalProperties":true}', [System.Text.Encoding]::UTF8)
    $schemaPath = $tempSchema
} else {
    $schemaPath = [System.IO.Path]::GetFullPath($schemaPath)
}

$lastMessage = [System.IO.Path]::GetTempFileName()
$codexArgs = [System.Collections.Generic.List[string]]::new()
$codexArgs.Add('exec')
if (-not [string]::IsNullOrWhiteSpace($resumeSession)) {
    $codexArgs.Add('resume')
    $codexArgs.Add($resumeSession)
}
$codexArgs.Add('--json')
$codexArgs.Add('--ephemeral')
$codexArgs.Add('--cd')
$codexArgs.Add($worktree)
$codexArgs.Add('--sandbox')
$codexArgs.Add('workspace-write')
$codexArgs.Add('--ask-for-approval')
$codexArgs.Add('never')
$codexArgs.Add('--output-schema')
$codexArgs.Add($schemaPath)
$codexArgs.Add('--output-last-message')
$codexArgs.Add($lastMessage)
$codexArgs.Add('--model')
$codexArgs.Add($modelId)
$codexArgs.Add('--')
$codexArgs.Add($prompt)

$psi = New-ProcessInfo $resolvedCodex $codexArgs.ToArray() $worktree
$proc = [System.Diagnostics.Process]::new()
$proc.StartInfo = $psi
try {
    if (-not $proc.Start()) { Fail "failed to start Codex: $resolvedCodex" 127 }
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $termination = 'natural'
    while (-not $proc.HasExited) {
        if (-not [string]::IsNullOrWhiteSpace($cancelFile) -and (Test-Path -LiteralPath $cancelFile -PathType Leaf)) {
            $termination = 'canceled'
            try { $proc.Kill($true) } catch { }
            break
        }
        if ($timeoutSeconds -gt 0 -and $watch.Elapsed.TotalSeconds -ge $timeoutSeconds) {
            $termination = 'timeout'
            try { $proc.Kill($true) } catch { }
            break
        }
        Start-Sleep -Milliseconds 25
    }
    try { $proc.WaitForExit() } catch { }
    [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    [System.IO.File]::WriteAllText($errFull, $stderr, [System.Text.Encoding]::UTF8)

    if ($termination -eq 'canceled') {
        exit 130
    }
    if ($termination -eq 'timeout') {
        exit 124
    }

    if ($proc.ExitCode -eq 75 -or "$stdout`n$stderr" -match '(?i)quota|rate.?limit') {
        exit 75
    }

    if (Test-Path -LiteralPath $lastMessage -PathType Leaf) {
        $lastContent = [System.IO.File]::ReadAllText($lastMessage)
        if ($lastContent -match '(?i)quota|rate.?limit') {
            [System.IO.File]::WriteAllText($errFull, "quota exhausted: $lastContent", [System.Text.Encoding]::UTF8)
            exit 75
        }
        $lastJson = $null
        try {
            $lastJson = ConvertFrom-Json -InputObject $lastContent -Depth 20 -ErrorAction Stop
        } catch {
            [System.IO.File]::WriteAllText($outFull, $lastContent, [System.Text.Encoding]::UTF8)
            Fail "malformed worker JSON output: $($_.Exception.Message)" 1
        }

        if ($null -eq $lastJson -or $lastJson -isnot [PSCustomObject] -or -not $lastJson.PSObject.Properties['structured_output']) {
            [System.IO.File]::WriteAllText($outFull, $lastContent, [System.Text.Encoding]::UTF8)
            Fail 'last-message artifact lacks structured_output' 1
        }

        if ($lastJson.PSObject.Properties['status'] -and [string]$lastJson.status -match '(?i)quota|rate.?limit') {
            exit 75
        }

        $result = [ordered]@{
            status = 'success'
            structured_output = $lastJson.structured_output
            model_id = $modelId
        }
        if ($lastJson.PSObject.Properties['child_assignment_request']) {
            $result.child_assignment_request = $lastJson.child_assignment_request
        }
        $resultJson = $result | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($outFull, "$resultJson`n", [System.Text.Encoding]::UTF8)

        if ($proc.ExitCode -ne 0) { exit $proc.ExitCode }
        exit 0
    }

    Fail 'Codex did not produce the required last-message artifact' 1
} finally {
    if ($null -ne $tempSchema -and (Test-Path -LiteralPath $tempSchema -PathType Leaf)) {
        Remove-Item -LiteralPath $tempSchema -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $lastMessage -PathType Leaf) {
        Remove-Item -LiteralPath $lastMessage -Force -ErrorAction SilentlyContinue
    }
    $proc.Dispose()
}
