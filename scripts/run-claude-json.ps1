#!/usr/bin/env pwsh
# scripts/run-claude-json.ps1
# Claude worker adapter. Conforms to the adapter contract (--operation catalog | launch).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Fail([string]$Message, [int]$Code = 2) {
    [Console]::Error.WriteLine("ERROR: $Message")
    exit $Code
}

function Usage {
    [Console]::Error.WriteLine("Usage: run-claude-json.ps1 --operation catalog --request REQUEST.json [--claude PATH]")
    [Console]::Error.WriteLine("       run-claude-json.ps1 --operation launch --request SELECTION.json --output OUTPUT --error ERROR [--claude PATH] [--cancel-file FILE] [--timeout-seconds N] -- WORKER_ARGS...")
}

function Resolve-Claude([string]$Requested) {
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $cmd = Get-Command $Requested -ErrorAction SilentlyContinue
        if ($cmd) {
            if ($cmd.Source) { return $cmd.Source }
            return $cmd.Name
        }
        if (Test-Path -LiteralPath $Requested -PathType Leaf) { return (Resolve-Path -LiteralPath $Requested).Path }
        Fail "Claude executable does not exist: $Requested" 127
    }
    $envBin = [Environment]::GetEnvironmentVariable('CLAUDE_BIN')
    if (-not [string]::IsNullOrWhiteSpace($envBin)) {
        return Resolve-Claude $envBin
    }
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd) {
        if ($cmd.Source) { return $cmd.Source }
        return $cmd.Name
    }
    Fail 'claude was not found; set CLAUDE_BIN or add claude to PATH' 127
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

function Probe-Claude([string]$ClaudePath) {
    $psi = New-ProcessInfo $ClaudePath @('--help')
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
        $source = [Environment]::GetEnvironmentVariable('CLAUDE_MODEL_CATALOG')
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

function Get-FamilyHint([string]$ModelId) {
    if ($ModelId -match 'opus') { return 'opus' }
    if ($ModelId -match 'sonnet') { return 'sonnet' }
    if ($ModelId -match 'haiku') { return 'haiku' }
    return 'unknown'
}

function Get-PreferenceScore([string]$Family) {
    switch ($Family) {
        'haiku'   { return [ordered]@{ fast = 1; balanced = 2; deep = 3 } }
        'sonnet'  { return [ordered]@{ fast = 2; balanced = 1; deep = 2 } }
        'opus'    { return [ordered]@{ fast = 3; balanced = 2; deep = 1 } }
        default   { return [ordered]@{ fast = 100; balanced = 100; deep = 100 } }
    }
}

$operation = ''
$requestPath = ''
$outputPath = ''
$errorPath = ''
$claudePath = ''
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
    if ($arg -in @('--operation', '--request', '--output', '--error', '--claude', '--cancel-file', '--timeout-seconds')) {
        if ($i + 1 -ge $args.Count) { Fail "$arg requires a value" }
        $val = [string]$args[$i + 1]
        switch ($arg) {
            '--operation' { $operation = $val }
            '--request' { $requestPath = $val }
            '--output' { $outputPath = $val }
            '--error' { $errorPath = $val }
            '--claude' { $claudePath = $val }
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

$resolvedClaude = Resolve-Claude $claudePath

if ($operation -eq 'catalog') {
    $probe = Probe-Claude $resolvedClaude
    if ($probe.ExitCode -ne 0 -or -not $probe.Stdout.Contains('--output-format')) {
        Fail 'Claude CLI does not advertise structured JSON output' 127
    }

    $rawCatalog = Get-CatalogData
    if ($null -eq $rawCatalog -or $null -eq $rawCatalog.models -or @($rawCatalog.models).Count -eq 0) {
        Fail 'host does not expose a model catalog' 127
    }

    $models = @(
        foreach ($m in @($rawCatalog.models)) {
            if ($m -is [string]) {
                $mId = [string]$m
                $family = Get-FamilyHint $mId
                [ordered]@{
                    id = $mId
                    family_hint = $family
                    available = $true
                    quota_available = $true
                    supported_efforts = @('low', 'medium', 'high')
                    capabilities = @('structured-output')
                    scores = Get-PreferenceScore $family
                }
            } elseif ($m -is [PSCustomObject]) {
                $mId = [string]$m.id
                $family = if ($m.PSObject.Properties['family_hint']) { [string]$m.family_hint } else { Get-FamilyHint $mId }
                $efforts = if ($m.PSObject.Properties['supported_efforts']) { @($m.supported_efforts) } elseif ($m.PSObject.Properties['efforts']) { @($m.efforts) } else { @('low', 'medium', 'high') }
                $caps = if ($m.PSObject.Properties['capabilities']) { @($m.capabilities) } else { @('structured-output') }
                $scores = if ($m.PSObject.Properties['scores']) { $m.scores } else { Get-PreferenceScore $family }
                [ordered]@{
                    id = $mId
                    family_hint = $family
                    available = if ($m.PSObject.Properties['available']) { [bool]$m.available } else { $true }
                    quota_available = if ($m.PSObject.Properties['quota_available']) { [bool]$m.quota_available } else { $true }
                    supported_efforts = @($efforts | ForEach-Object { [string]$_ })
                    capabilities = @($caps | ForEach-Object { [string]$_ })
                    scores = $scores
                }
            }
        }
    )

    $revision = if ($rawCatalog.PSObject.Properties['revision']) { [string]$rawCatalog.revision } else {
        $hash = [System.Security.Cryptography.SHA256]::Create()
        try { [Convert]::ToHexString($hash.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($rawCatalog | ConvertTo-Json -Depth 20)))).ToLowerInvariant() }
        finally { $hash.Dispose() }
    }

    $catalogDoc = [ordered]@{
        protocol_version = 1
        adapter = 'claude'
        adapter_revision = 'claude-1'
        vendor = 'anthropic'
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
$permissionMode = 'acceptEdits'
$resumeSession = ''
$allowedTools = [System.Collections.Generic.List[string]]::new()
$disallowedTools = [System.Collections.Generic.List[string]]::new()
$disallowedTools.Add('Task')
$disallowedTools.Add('Agent')

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
    if ($warg -eq '--permission-mode') {
        $j++; if ($j -lt $workerArgs.Count) { $permissionMode = [string]$workerArgs[$j] }
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
    if ($warg -in @('--allowedTools', '--allowed-tools')) {
        $j++; if ($j -lt $workerArgs.Count) { $allowedTools.Add([string]$workerArgs[$j]) }
        $j++; continue
    }
    if ($warg -in @('--disallowedTools', '--disallowed-tools')) {
        $j++; if ($j -lt $workerArgs.Count) { $disallowedTools.Add([string]$workerArgs[$j]) }
        $j++; continue
    }
    if (-not $prompt -and -not $warg.StartsWith('-')) {
        $prompt = $warg
        $j++; continue
    }
    $j++
}

if ($permissionMode -eq 'bypassPermissions') { Fail 'bypassPermissions is not allowed' }

if ([string]::IsNullOrWhiteSpace($worktree)) {
    $worktree = (Get-Location).Path
}
$worktree = [System.IO.Path]::GetFullPath($worktree)

if (-not (Test-Path -LiteralPath $worktree -PathType Container)) {
    Fail "working directory does not exist: $worktree"
}

# Sandbox marker validation
$markerPath = Join-Path $worktree '.offload-execution-workspace'
$markerExpected = 'offload-execution-workspace-v1'
if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    $markerPath = Join-Path $worktree '.offload-research-workspace'
    $markerExpected = 'offload-research-workspace-v1'
}
if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    Fail 'unsupported or unmarked sandbox; use an isolated offload workspace'
}
try {
    $markerContent = [System.IO.File]::ReadAllText($markerPath).Trim()
    if ($markerContent -ne $markerExpected) { Fail 'invalid isolated workspace marker' }
} catch {
    Fail 'could not read isolated workspace marker'
}

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

$claudeArgs = [System.Collections.Generic.List[string]]::new()
$claudeArgs.Add('-p')
$claudeArgs.Add($prompt)
$claudeArgs.Add('--output-format')
$claudeArgs.Add('json')
$claudeArgs.Add('--permission-mode')
$claudeArgs.Add($permissionMode)
foreach ($t in $disallowedTools) {
    $claudeArgs.Add('--disallowedTools')
    $claudeArgs.Add($t)
}
foreach ($t in $allowedTools) {
    $claudeArgs.Add('--allowedTools')
    $claudeArgs.Add($t)
}
if ($modelId) {
    $claudeArgs.Add('--model')
    $claudeArgs.Add($modelId)
}
if ($resumeSession) {
    $claudeArgs.Add('--resume')
    $claudeArgs.Add($resumeSession)
}

$psi = New-ProcessInfo $resolvedClaude $claudeArgs.ToArray() $worktree
$proc = [System.Diagnostics.Process]::new()
$proc.StartInfo = $psi
try {
    if (-not $proc.Start()) { Fail "failed to start Claude: $resolvedClaude" 127 }
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

    if ($proc.ExitCode -eq 75 -or "$stdout`n$stderr" -match '(?i)quota|rate limit|too many requests|429') {
        exit 75
    }

    if ($proc.ExitCode -eq 0) {
        try {
            $document = $stdout | ConvertFrom-Json -Depth 30 -ErrorAction Stop
            if ($document.subtype -eq 'success' -or $document.status -eq 'success') {
                $response = if ($document.result) { [string]$document.result } elseif ($document.response) { [string]$document.response } else { $null }
                $sessionId = if ($document.session_id) { [string]$document.session_id } else { $null }
                $result = [ordered]@{
                    status = 'success'
                    response = $response
                    session_id = $sessionId
                    structured_output = $document
                    model_id = $modelId
                }
                $resultJson = $result | ConvertTo-Json -Depth 20
                [System.IO.File]::WriteAllText($outFull, "$resultJson`n", [System.Text.Encoding]::UTF8)
                exit 0
            } else {
                [System.IO.File]::WriteAllText($outFull, $stdout, [System.Text.Encoding]::UTF8)
                Fail 'Claude returned a non-success result' 1
            }
        } catch {
            [System.IO.File]::WriteAllText($outFull, $stdout, [System.Text.Encoding]::UTF8)
            Fail 'malformed Claude JSON output' 1
        }
    }

    [System.IO.File]::WriteAllText($outFull, $stdout, [System.Text.Encoding]::UTF8)
    exit $proc.ExitCode
} finally {
    $proc.Dispose()
}
