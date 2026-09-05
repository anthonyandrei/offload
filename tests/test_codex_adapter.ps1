#!/usr/bin/env pwsh
# tests/test_codex_adapter.ps1
# Contract tests for the Codex worker adapter.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$Root = Split-Path -Parent $PSScriptRoot
$Adapter = Join-Path $Root 'scripts/run-codex-json.ps1'
$TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("offload-codex-adapter-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpRoot | Out-Null

function Fail([string]$Message) {
    throw "FAIL: $Message"
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { Fail $Message }
    Write-Output "ok - $Message"
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        Fail "$Message (expected '$Expected', got '$Actual')"
    }
    Write-Output "ok - $Message"
}

function Write-JsonFile([string]$Path, $Value) {
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Invoke-Tool([string]$FilePath, [string[]]$ArgumentList, [hashtable]$Environment = @{}, [string]$WorkingDirectory = $TmpRoot) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($arg in $ArgumentList) { $psi.ArgumentList.Add($arg) }
    foreach ($entry in $Environment.GetEnumerator()) {
        $psi.Environment[$entry.Key] = [string]$entry.Value
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Invoke-Adapter([string[]]$ArgumentList, [hashtable]$Environment = @{}, [string]$WorkingDirectory = $TmpRoot) {
    $pwsh = (Get-Command pwsh).Source
    return Invoke-Tool $pwsh (@('-NoProfile', '-NonInteractive', '-File', $Adapter) + $ArgumentList) $Environment $WorkingDirectory
}

try {
    $FakeCodex = Join-Path $TmpRoot 'fake-codex.ps1'
    @'
$ArgsList = @($args)
if ($env:FAKE_CODEX_RECORD_ARGS) {
    $ArgsList | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:FAKE_CODEX_RECORD_ARGS -Encoding utf8
}
$schema = $null
for ($i = 0; $i -lt $ArgsList.Count; $i++) {
    if ($ArgsList[$i] -eq '--output-schema') { $schema = $ArgsList[$i + 1] }
}
if ($env:FAKE_CODEX_SCHEMA_RECORD -and $schema) { Copy-Item -LiteralPath $schema -Destination $env:FAKE_CODEX_SCHEMA_RECORD -Force }
$last = $null
for ($i = 0; $i -lt $ArgsList.Count; $i++) {
    if ($ArgsList[$i] -eq '--output-last-message') { $last = $ArgsList[$i + 1] }
}
if ($ArgsList -contains '--help' -or $ArgsList -contains '-h') {
    Write-Output 'Codex exec --json --output-schema --output-last-message --sandbox --ask-for-approval --cd'
    exit 0
}
if ($env:FAKE_CODEX_MODE -eq 'sleep') {
    while ($true) { Start-Sleep -Milliseconds 50 }
}
if ($env:FAKE_CODEX_MODE -eq 'malformed') {
    Set-Content -LiteralPath $last -Value '{not-json' -Encoding utf8
    Write-Output '{"type":"malformed"}'
    exit 0
}
if ($env:FAKE_CODEX_MODE -eq 'quota') {
    Set-Content -LiteralPath $last -Value '{"error":"quota exhausted"}' -Encoding utf8
    exit 0
}
$result = [ordered]@{ status = 'success'; structured_output = [ordered]@{ ok = $true; child_assignment_request = [ordered]@{ prompt = 'do more' } } }
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $last -Encoding utf8
Write-Output '{"type":"turn.completed"}'
'@ | Set-Content -LiteralPath $FakeCodex -Encoding utf8

    $Catalog = Join-Path $TmpRoot 'catalog.json'
    Write-JsonFile $Catalog ([ordered]@{
        schema_version = 1
        revision = 'fake-catalog-1'
        models = @(
            [ordered]@{ id = 'fake-fast-model'; preference = 'fast'; efforts = @('low', 'medium') }
            [ordered]@{ id = 'fake-balanced-model'; preference = 'balanced'; efforts = @('medium', 'high') }
            [ordered]@{ id = 'fake-deep-model'; preference = 'deep'; efforts = @('high') }
        )
    })

    # 1. Operation catalog test
    $catalogRequest = Join-Path $TmpRoot 'catalog-request.json'
    Write-JsonFile $catalogRequest ([ordered]@{
        protocol_version = 2
        role = 'worker'
        preference = 'balanced'
        effort = 'high'
        required_capabilities = @('structured-output')
        policy_revision = 'test-policy-1'
    })

    $cap = Invoke-Adapter @('--operation', 'catalog', '--request', $catalogRequest, '--codex', $FakeCodex) @{ CODEX_MODEL_CATALOG = $Catalog }
    Assert-Equal $cap.ExitCode 0 'catalog discovery exits successfully'
    $capDoc = $cap.Stdout | ConvertFrom-Json
    Assert-Equal $capDoc.vendor 'codex' 'catalog report identifies Codex'
    Assert-Equal $capDoc.adapter 'codex' 'catalog report identifies adapter as codex'
    Assert-Equal $capDoc.protocol_version 2 'catalog report specifies protocol_version 2'
    Assert-Equal $capDoc.models[0].preflight.access.state 'unknown' 'catalog does not infer authenticated access'
    Assert-True ($capDoc.models.Count -ge 1) 'catalog report includes models'
    Assert-True ($capDoc.models[0].supported_efforts -contains 'low' -or $capDoc.models[0].supported_efforts -contains 'medium') 'catalog models include supported_efforts'

    # 2. Operation launch test with arguments preserving spaces
    $worktree = Join-Path $TmpRoot 'worktree with spaces'
    New-Item -ItemType Directory -Path $worktree | Out-Null

    $selection = Join-Path $TmpRoot 'selection.json'
    Write-JsonFile $selection ([ordered]@{
        protocol_version = 2
        model_id = 'fake-balanced-model'
        effort = 'high'
        preference = 'balanced'
        vendor = 'codex'
    })

    $resultOutput = Join-Path $TmpRoot 'success-result.json'
    $errorOutput = Join-Path $TmpRoot 'success.err'
    $recordedArgsFile = Join-Path $TmpRoot 'recorded-args.json'
    $recordedSchemaFile = Join-Path $TmpRoot 'recorded-schema.json'
    $testPrompt = 'Return the bounded result with spaces and "quotes".'

    $success = Invoke-Adapter @(
        '--operation', 'launch',
        '--request', $selection,
        '--output', $resultOutput,
        '--error', $errorOutput,
        '--codex', $FakeCodex,
        '--',
        '--cd', $worktree,
        '--prompt', $testPrompt,
        '--json-schema', '{"type":"object","required":["ok"]}'
    ) @{
        CODEX_MODEL_CATALOG = $Catalog
        FAKE_CODEX_RECORD_ARGS = $recordedArgsFile
        FAKE_CODEX_SCHEMA_RECORD = $recordedSchemaFile
    }

    Assert-Equal $success.ExitCode 0 'successful launch exits successfully'
    Assert-True (Test-Path -LiteralPath $resultOutput) 'result output file is written'
    $successDoc = Get-Content -LiteralPath $resultOutput -Raw | ConvertFrom-Json
    Assert-Equal $successDoc.status 'success' 'successful launch returns success status'
    Assert-True $successDoc.structured_output.ok 'successful launch returns structured output'
    Assert-Equal $successDoc.model_id 'fake-balanced-model' 'result includes selected model_id'

    # Verify space preservation in arguments
    $recordedArgs = Get-Content -LiteralPath $recordedArgsFile -Raw | ConvertFrom-Json
    Assert-True ($recordedArgs -contains $testPrompt) 'prompt argument boundary with spaces preserved'
    Assert-True ($recordedArgs -contains $worktree) 'worktree path argument boundary with spaces preserved'
    $schemaArgIndex = [Array]::IndexOf([string[]]$recordedArgs, '--output-schema')
    Assert-True ($schemaArgIndex -ge 0) 'inline schema is forwarded as output-schema'
    $forwardedSchema = Get-Content -LiteralPath $recordedSchemaFile -Raw
    Assert-Equal ($forwardedSchema.Trim()) '{"type":"object","required":["ok"]}' 'inline schema content is preserved'

    # 3. Malformed worker output test
    $malformedOutput = Join-Path $TmpRoot 'malformed-result.json'
    $malformed = Invoke-Adapter @(
        '--operation', 'launch',
        '--request', $selection,
        '--output', $malformedOutput,
        '--error', (Join-Path $TmpRoot 'malformed.err'),
        '--codex', $FakeCodex,
        '--',
        '--cd', $worktree,
        '--prompt', 'malformed'
    ) @{
        CODEX_MODEL_CATALOG = $Catalog
        FAKE_CODEX_MODE = 'malformed'
    }
    Assert-True ($malformed.ExitCode -ne 0) 'malformed worker output exits nonzero'

    # 4. Quota exhaustion test
    $quotaOutput = Join-Path $TmpRoot 'quota-result.json'
    $quota = Invoke-Adapter @(
        '--operation', 'launch',
        '--request', $selection,
        '--output', $quotaOutput,
        '--error', (Join-Path $TmpRoot 'quota.err'),
        '--codex', $FakeCodex,
        '--',
        '--cd', $worktree,
        '--prompt', 'quota'
    ) @{
        CODEX_MODEL_CATALOG = $Catalog
        FAKE_CODEX_MODE = 'quota'
    }
    Assert-Equal $quota.ExitCode 75 'quota exhaustion exits 75'

    # 5. Cancellation test
    $cancelFile = Join-Path $TmpRoot 'cancel.request'
    $cancelOutput = Join-Path $TmpRoot 'cancel-result.json'
    New-Item -ItemType File -Path $cancelFile | Out-Null
    $canceled = Invoke-Adapter @(
        '--operation', 'launch',
        '--request', $selection,
        '--output', $cancelOutput,
        '--error', (Join-Path $TmpRoot 'cancel.err'),
        '--codex', $FakeCodex,
        '--cancel-file', $cancelFile,
        '--',
        '--cd', $worktree,
        '--prompt', 'sleep'
    ) @{
        CODEX_MODEL_CATALOG = $Catalog
        FAKE_CODEX_MODE = 'sleep'
    }
    Assert-Equal $canceled.ExitCode 130 'cancellation exits 130'

    # 6. Missing catalog fails closed
    $unsupported = Invoke-Adapter @(
        '--operation', 'catalog',
        '--request', $catalogRequest,
        '--codex', $FakeCodex
    ) @{}
    Assert-True ($unsupported.ExitCode -ne 0) 'missing catalog exits nonzero'

    Write-Output 'all Codex adapter contract checks passed'
} finally {
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -LiteralPath $TmpRoot -Recurse -Force
    }
}
