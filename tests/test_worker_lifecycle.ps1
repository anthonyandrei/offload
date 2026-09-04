#!/usr/bin/env pwsh
# Acceptance tests for the shared worker lifecycle contract.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:TotalTests = 0
$script:FailedTests = 0

function Pass([string]$name) {
    $script:TotalTests++
    [Console]::Out.WriteLine("ok - $name")
}

function Fail([string]$name, [string]$reason = "") {
    $script:TotalTests++
    $script:FailedTests++
    $detail = if ($reason) { " - $reason" } else { "" }
    [Console]::Error.WriteLine("FAIL: $name$detail")
    exit 1
}

function Assert-Equal($actual, $expected, [string]$name) {
    if ($actual -eq $expected) {
        Pass $name
    } else {
        Fail $name "Expected '$expected', got '$actual'"
    }
}

function Assert-True([bool]$condition, [string]$name, [string]$reason = "") {
    if ($condition) {
        Pass $name
    } else {
        Fail $name $(if ($reason) { $reason } else { "Condition was false" })
    }
}

function Invoke-Process {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{}
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($arg in $ArgumentList) { $psi.ArgumentList.Add($arg) }
    foreach ($key in $Environment.Keys) { $psi.Environment[$key] = [string]$Environment[$key] }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Stdout = $stdout.GetAwaiter().GetResult()
        Stderr = $stderr.GetAwaiter().GetResult()
    }
}

$rootDir = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $rootDir 'scripts/run-agy-json.ps1'
$shLauncher = Join-Path $rootDir 'scripts/run-agy-json.sh'
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "offload-worker-lifecycle-$([System.Guid]::NewGuid().ToString('N'))"
[System.IO.Directory]::CreateDirectory($tmpRoot) | Out-Null
$savedAdapterBin = $env:OFFLOAD_ADAPTER_BIN
$savedAdapterCatalog = $env:FAKE_ADAPTER_CATALOG

try {
    $fakeDir = Join-Path $tmpRoot 'bin'
    [System.IO.Directory]::CreateDirectory($fakeDir) | Out-Null
$fakeAgy = Join-Path $fakeDir 'fake-agy.ps1'
@'
[Console]::Error.WriteLine('fake worker stderr')
if ($env:FAKE_AGY_QUOTA) {
    [Console]::Error.WriteLine('quota exhausted')
    [Console]::Out.WriteLine('{"status":"error","error":"quota exhausted"}')
    exit 75
}
if ($env:FAKE_AGY_MALFORMED) {
    [Console]::Out.WriteLine('{not-json')
    exit 0
}
if ($env:FAKE_AGY_SCALAR) {
    [Console]::Out.WriteLine('{"status":"success","structured_output":"not-an-object"}')
    exit 0
}
if ($env:FAKE_AGY_SLEEP_SECONDS) {
    Start-Sleep -Seconds ([int]$env:FAKE_AGY_SLEEP_SECONDS)
}
[Console]::Out.WriteLine('{"status":"success","response":"ok","structured_output":{"ok":true}}')
'@ | Set-Content -LiteralPath $fakeAgy -Encoding utf8

    $fakeAdapter = Join-Path $rootDir 'tests/fixtures/fake-worker-adapter.ps1'
    $fakeCatalog = Join-Path $tmpRoot 'lifecycle-catalog.json'
    [ordered]@{
        protocol_version = 1
        adapter = 'fake'
        adapter_revision = 'fake-1'
        vendor = 'test-vendor'
        catalog_revision = 'lifecycle-1'
        models = @(
            [ordered]@{
                id = 'gemini-3.8-flash-high'
                available = $true
                quota_available = $true
                supported_efforts = @('high')
                capabilities = @()
                scores = [ordered]@{ fast = 10; balanced = 10; deep = 10 }
            }
        )
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fakeCatalog -Encoding utf8
    $env:OFFLOAD_ADAPTER_BIN = $fakeAdapter
    $env:FAKE_ADAPTER_CATALOG = $fakeCatalog

    $outputPath = Join-Path $tmpRoot 'attempt-1.json'
    $errorPath = Join-Path $tmpRoot 'attempt-1.err'
    $lifecyclePath = Join-Path $tmpRoot 'attempt-1.lifecycle.json'
    $ledgerPath = Join-Path $tmpRoot 'resource-ledger.json'
    $result = Invoke-Process -FilePath 'pwsh' -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-File', $launcher,
        '--role', 'implementer',
        '--output', $outputPath,
        '--error', $errorPath,
        '--lifecycle', $lifecyclePath,
        '--assignment-id', 'assignment-1',
        '--attempt', '1',
        '--mode', 'execution',
        '--verification-baseline', 'baseline-1',
        '--resource-ledger', $ledgerPath,
        '--', '-p', 'lifecycle test'
    ) -Environment @{ AGY_BIN = $fakeAgy }

    Assert-Equal $result.ExitCode 0 'normal worker exits successfully'
    $lifecycle = Get-Content -LiteralPath $lifecyclePath -Raw | ConvertFrom-Json
    $states = @($lifecycle.events | ForEach-Object { $_.state }) -join ','
    Assert-Equal $states 'created,started,running,completed,retained,cleaned' 'normal worker records the shared lifecycle'
    Assert-Equal $lifecycle.state 'cleaned' 'normal worker ends in cleaned state'
    Assert-Equal $lifecycle.assignment_id 'assignment-1' 'lifecycle records assignment identity'
    Assert-Equal $lifecycle.attempt 1 'lifecycle records attempt number'
    Assert-Equal $lifecycle.verification_baseline 'baseline-1' 'lifecycle records verification baseline'
    Assert-Equal $lifecycle.model 'gemini-3.8-flash-high' 'lifecycle records pinned model'
    Assert-Equal $lifecycle.effort 'high' 'lifecycle records pinned effort'
    Assert-Equal $lifecycle.exit_code 0 'lifecycle records worker exit result'
    Assert-True (Test-Path -LiteralPath $outputPath) 'normal worker retains stdout artifact'
    Assert-True (Test-Path -LiteralPath $errorPath) 'normal worker retains stderr artifact'
    Assert-True (Test-Path -LiteralPath $ledgerPath) 'normal worker records resource ledger'

    $retryOutput = Join-Path $tmpRoot 'attempt-2.json'
    $retryError = Join-Path $tmpRoot 'attempt-2.err'
    $retryLifecycle = Join-Path $tmpRoot 'attempt-2.lifecycle.json'
    $retry = Invoke-Process -FilePath 'pwsh' -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-File', $launcher,
        '--role', 'implementer', '--output', $retryOutput, '--error', $retryError,
        '--lifecycle', $retryLifecycle, '--assignment-id', 'assignment-1', '--attempt', '2',
        '--resource-ledger', $ledgerPath, '--', '-p', 'retry lifecycle test'
    ) -Environment @{ AGY_BIN = $fakeAgy }
    Assert-Equal $retry.ExitCode 0 'retry worker exits successfully'
    $retryRecord = Get-Content -LiteralPath $retryLifecycle -Raw | ConvertFrom-Json
    Assert-Equal $retryRecord.model $lifecycle.model 'retry uses the ledger pinned model'
    Assert-Equal $retryRecord.verification_baseline $lifecycle.verification_baseline 'retry inherits the ledger verification baseline'
    $ledger = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json
    Assert-Equal @($ledger.attempts).Count 2 'resource ledger records both attempts'

    $thirdOutput = Join-Path $tmpRoot 'attempt-3.json'
    $third = Invoke-Process -FilePath 'pwsh' -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-File', $launcher,
        '--role', 'implementer', '--output', $thirdOutput, '--error', (Join-Path $tmpRoot 'attempt-3.err'),
        '--lifecycle', (Join-Path $tmpRoot 'attempt-3.lifecycle.json'), '--assignment-id', 'assignment-1', '--attempt', '3',
        '--resource-ledger', $ledgerPath, '--', '-p', 'third attempt must be rejected'
    ) -Environment @{ AGY_BIN = $fakeAgy }
    Assert-True ($third.ExitCode -ne 0) 'third attempt is rejected by the retry limit'

    $malformedOutput = Join-Path $tmpRoot 'malformed.json'
    $malformedError = Join-Path $tmpRoot 'malformed.err'
    $malformedLifecycle = Join-Path $tmpRoot 'malformed.lifecycle.json'
    $malformed = Invoke-Process -FilePath 'pwsh' -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-File', $launcher,
        '--role', 'implementer', '--output', $malformedOutput, '--error', $malformedError,
        '--lifecycle', $malformedLifecycle, '--assignment-id', 'assignment-malformed', '--attempt', '1',
        '--', '-p', 'malformed lifecycle test'
    ) -Environment @{ AGY_BIN = $fakeAgy; FAKE_AGY_MALFORMED = '1' }
    Assert-True ($malformed.ExitCode -ne 0) 'malformed worker exits unsuccessfully'
    $malformedRecord = Get-Content -LiteralPath $malformedLifecycle -Raw | ConvertFrom-Json
    Assert-Equal $malformedRecord.state 'cleaned' 'malformed worker still closes lifecycle'
    Assert-Equal ((@($malformedRecord.events | ForEach-Object { $_.state }) -join ',')) 'created,started,running,failed,retained,cleaned' 'malformed output cannot complete assignment'
    Assert-Equal $malformedRecord.failure_class 'malformed_output' 'malformed output records diagnosis'

    $scalarLifecycle = Join-Path $tmpRoot 'scalar.lifecycle.json'
    $scalar = Invoke-Process -FilePath 'pwsh' -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-File', $launcher,
        '--role', 'implementer', '--output', (Join-Path $tmpRoot 'scalar.json'), '--error', (Join-Path $tmpRoot 'scalar.err'),
        '--lifecycle', $scalarLifecycle, '--assignment-id', 'assignment-scalar', '--attempt', '1',
        '--', '-p', 'scalar lifecycle test'
    ) -Environment @{ AGY_BIN = $fakeAgy; FAKE_AGY_SCALAR = '1' }
    Assert-True ($scalar.ExitCode -ne 0) 'scalar structured output exits unsuccessfully'
    $scalarRecord = Get-Content -LiteralPath $scalarLifecycle -Raw | ConvertFrom-Json
    Assert-Equal $scalarRecord.failure_class 'malformed_output' 'scalar structured output records diagnosis'

    $timeoutOutput = Join-Path $tmpRoot 'timeout.json'
    $timeoutError = Join-Path $tmpRoot 'timeout.err'
    $timeoutLifecycle = Join-Path $tmpRoot 'timeout.lifecycle.json'
    $timedOut = Invoke-Process -FilePath 'pwsh' -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-File', $launcher,
        '--role', 'implementer', '--output', $timeoutOutput, '--error', $timeoutError,
        '--lifecycle', $timeoutLifecycle, '--assignment-id', 'assignment-timeout', '--attempt', '1',
        '--timeout-seconds', '1', '--', '-p', 'timeout lifecycle test'
    ) -Environment @{ AGY_BIN = $fakeAgy; FAKE_AGY_SLEEP_SECONDS = '10' }
    Assert-Equal $timedOut.ExitCode 124 'timed out worker returns canonical timeout code'
    $timeoutRecord = Get-Content -LiteralPath $timeoutLifecycle -Raw | ConvertFrom-Json
    Assert-Equal $timeoutRecord.exit_code 124 'timeout lifecycle records canonical launcher exit result'
    Assert-Equal $timeoutRecord.failure_class 'timeout' 'timeout records diagnosis'
    Assert-Equal ((@($timeoutRecord.events | ForEach-Object { $_.state }) -join ',')) 'created,started,running,failed,retained,cleaned' 'timeout retains evidence after stopping worker'

    $quotaOutput = Join-Path $tmpRoot 'quota.json'
    $quotaError = Join-Path $tmpRoot 'quota.err'
    $quotaLifecycle = Join-Path $tmpRoot 'quota.lifecycle.json'
    $quota = Invoke-Process -FilePath 'pwsh' -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-File', $launcher,
        '--role', 'implementer', '--output', $quotaOutput, '--error', $quotaError,
        '--lifecycle', $quotaLifecycle, '--assignment-id', 'assignment-quota', '--attempt', '1',
        '--', '-p', 'quota lifecycle test'
    ) -Environment @{ AGY_BIN = $fakeAgy; FAKE_AGY_QUOTA = '1' }
    Assert-Equal $quota.ExitCode 75 'quota exhaustion returns handoff code'
    $quotaRecord = Get-Content -LiteralPath $quotaLifecycle -Raw | ConvertFrom-Json
    Assert-Equal $quotaRecord.state 'cleaned' 'quota handoff closes lifecycle'
    Assert-Equal $quotaRecord.failure_class 'quota' 'quota handoff records diagnosis'
    Assert-True ((@($quotaRecord.events | ForEach-Object { $_.state }) -contains 'quota-handoff')) 'quota exhaustion records quota-handoff state'

    $cancelOutput = Join-Path $tmpRoot 'cancel.json'
    $cancelError = Join-Path $tmpRoot 'cancel.err'
    $cancelLifecycle = Join-Path $tmpRoot 'cancel.lifecycle.json'
    $cancelFile = Join-Path $tmpRoot 'cancel.request'
    $cancelArgs = @(
        '-NoProfile', '-NonInteractive', '-File', $launcher,
        '--role', 'implementer', '--output', $cancelOutput, '--error', $cancelError,
        '--lifecycle', $cancelLifecycle, '--assignment-id', 'assignment-cancel', '--attempt', '1',
        '--cancel-file', $cancelFile, '--', '-p', 'cancel lifecycle test'
    )
    $cancelPsi = [System.Diagnostics.ProcessStartInfo]::new()
    $cancelPsi.FileName = 'pwsh'
    $cancelPsi.UseShellExecute = $false
    $cancelPsi.CreateNoWindow = $true
    $cancelPsi.RedirectStandardOutput = $true
    $cancelPsi.RedirectStandardError = $true
    foreach ($arg in $cancelArgs) { $cancelPsi.ArgumentList.Add($arg) }
    $cancelPsi.Environment['AGY_BIN'] = $fakeAgy
    $cancelPsi.Environment['FAKE_AGY_SLEEP_SECONDS'] = '10'
    $cancelProc = [System.Diagnostics.Process]::Start($cancelPsi)
    $cancelDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $cancelLifecycle) -and [DateTime]::UtcNow -lt $cancelDeadline) {
        Start-Sleep -Milliseconds 20
    }
    while ((Get-Content -LiteralPath $cancelLifecycle -Raw | ConvertFrom-Json).state -ne 'running' -and [DateTime]::UtcNow -lt $cancelDeadline) {
        Start-Sleep -Milliseconds 20
    }
    [System.IO.File]::WriteAllText($cancelFile, 'cancel')
    $cancelProc.WaitForExit()
    $cancelProc.StandardOutput.ReadToEnd() | Out-Null
    $cancelProc.StandardError.ReadToEnd() | Out-Null
    $cancelExitCode = $cancelProc.ExitCode
    $cancelProc.Dispose()
    Assert-Equal $cancelExitCode 130 'canceled worker returns canonical cancellation code'
    $cancelRecord = Get-Content -LiteralPath $cancelLifecycle -Raw | ConvertFrom-Json
    Assert-Equal $cancelRecord.exit_code 130 'cancellation lifecycle records canonical launcher exit result'
    Assert-Equal $cancelRecord.state 'cleaned' 'canceled worker closes lifecycle'
    Assert-Equal $cancelRecord.failure_class 'canceled' 'cancellation records diagnosis'
    Assert-Equal ((@($cancelRecord.events | ForEach-Object { $_.state }) -join ',')) 'created,started,running,canceled,retained,cleaned' 'canceled worker is stopped before cleanup'

    $bashCommand = $null
    if ($IsWindows) {
        if (Test-Path -LiteralPath 'C:\Program Files\Git\bin\bash.exe' -PathType Leaf) {
            $bashCommand = 'C:\Program Files\Git\bin\bash.exe'
        } elseif (Test-Path -LiteralPath 'C:\Program Files\Git\usr\bin\bash.exe' -PathType Leaf) {
            $bashCommand = 'C:\Program Files\Git\usr\bin\bash.exe'
        }
    }
    if (-not $bashCommand) {
        $bashCandidate = Get-Command bash -ErrorAction SilentlyContinue
        if ($bashCandidate) {
            $candidateSource = if ($bashCandidate.Source) { $bashCandidate.Source } else { $bashCandidate.Name }
            if (-not $IsWindows -or -not $candidateSource.StartsWith($env:SystemRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $bashCommand = $candidateSource
            }
        }
    }
    if ($bashCommand -and (Test-Path -LiteralPath $shLauncher -PathType Leaf)) {
        $bashAgy = Join-Path $fakeDir 'fake-agy-bash'
        @'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake bash stderr\n' >&2
if [ "${FAKE_BASH_MODE:-}" = quota ]; then
  printf 'quota exhausted\n' >&2
  printf '{"status":"error","error":"quota exhausted"}\n'
  exit 75
fi
if [ "${FAKE_BASH_MODE:-}" = malformed ]; then
  printf '{not-json\n'
  exit 0
fi
if [ "${FAKE_BASH_MODE:-}" = scalar ]; then
  printf '{"status":"success","structured_output":"not-an-object"}\n'
  exit 0
fi
printf '{"status":"success","response":"ok","structured_output":{"ok":true}}\n'
'@ | Set-Content -LiteralPath $bashAgy -Encoding utf8
        $bashRunner = Join-Path $tmpRoot 'run-bash-lifecycle.sh'
        @'
#!/usr/bin/env bash
set -euo pipefail
export AGY_BIN="$1"
export AGY_BIN="$(cygpath -u "$AGY_BIN")"
export OFFLOAD_ADAPTER_BIN="$(cygpath -u "$7")"
export FAKE_ADAPTER_CATALOG="$(cygpath -u "$FAKE_ADAPTER_CATALOG")"
chmod +x "$AGY_BIN" "$OFFLOAD_ADAPTER_BIN"
launcher="$(cygpath -u "$2")"
out_file="$(cygpath -u "$3")"
err_file="$(cygpath -u "$4")"
lifecycle_file="$(cygpath -u "$5")"
ledger_file="$(cygpath -u "$6")"
"$launcher" --role implementer --output "$out_file" --error "$err_file" --lifecycle "$lifecycle_file" --assignment-id assignment-bash --attempt 1 --mode execution --verification-baseline baseline-bash --resource-ledger "$ledger_file" -- -p 'bash lifecycle test'
'@ | Set-Content -LiteralPath $bashRunner -Encoding utf8
        if (-not $IsWindows) {
            [System.IO.File]::SetUnixFileMode($bashAgy, [System.IO.UnixFileMode]509)
            [System.IO.File]::SetUnixFileMode($bashRunner, [System.IO.UnixFileMode]509)
        }
        $bashAdapter = Join-Path $rootDir 'tests/fixtures/fake-worker-adapter.sh'
        $bashOut = Join-Path $tmpRoot 'bash.json'
        $bashErr = Join-Path $tmpRoot 'bash.err'
        $bashLifecycle = Join-Path $tmpRoot 'bash.lifecycle.json'
        $bashLedger = Join-Path $tmpRoot 'bash.ledger.json'
        $bashResult = Invoke-Process -FilePath $bashCommand -ArgumentList @(
            ($bashRunner -replace '\\', '/'), ($bashAgy -replace '\\', '/'), ($shLauncher -replace '\\', '/'),
            ($bashOut -replace '\\', '/'), ($bashErr -replace '\\', '/'), ($bashLifecycle -replace '\\', '/'),
            ($bashLedger -replace '\\', '/'), ($bashAdapter -replace '\\', '/')
        )
        Assert-Equal $bashResult.ExitCode 0 'bash worker exits successfully'
        $bashRecord = Get-Content -LiteralPath $bashLifecycle -Raw | ConvertFrom-Json
        Assert-Equal ((@($bashRecord.events | ForEach-Object { $_.state }) -join ',')) 'created,started,running,completed,retained,cleaned' 'bash records the same shared lifecycle'
        Assert-Equal $bashRecord.model 'gemini-3.8-flash-high' 'bash records pinned model'

        $bashMalformedLifecycle = Join-Path $tmpRoot 'bash-malformed.lifecycle.json'
        $bashMalformed = Invoke-Process -FilePath $bashCommand -ArgumentList @(
            ($bashRunner -replace '\\', '/'), ($bashAgy -replace '\\', '/'), ($shLauncher -replace '\\', '/'),
            ((Join-Path $tmpRoot 'bash-malformed.json') -replace '\\', '/'),
            ((Join-Path $tmpRoot 'bash-malformed.err') -replace '\\', '/'), ($bashMalformedLifecycle -replace '\\', '/'),
            ((Join-Path $tmpRoot 'bash-malformed.ledger.json') -replace '\\', '/'), ($bashAdapter -replace '\\', '/')
        ) -Environment @{ FAKE_BASH_MODE = 'malformed' }
        Assert-True ($bashMalformed.ExitCode -ne 0) 'bash malformed worker exits unsuccessfully'
        $bashMalformedRecord = Get-Content -LiteralPath $bashMalformedLifecycle -Raw | ConvertFrom-Json
        Assert-Equal $bashMalformedRecord.failure_class 'malformed_output' 'bash malformed output records diagnosis'
        Assert-Equal ((@($bashMalformedRecord.events | ForEach-Object { $_.state }) -join ',')) 'created,started,running,failed,retained,cleaned' 'bash malformed output cannot complete assignment'

        $bashScalarLifecycle = Join-Path $tmpRoot 'bash-scalar.lifecycle.json'
        $bashScalar = Invoke-Process -FilePath $bashCommand -ArgumentList @(
            ($bashRunner -replace '\\', '/'), ($bashAgy -replace '\\', '/'), ($shLauncher -replace '\\', '/'),
            ((Join-Path $tmpRoot 'bash-scalar.json') -replace '\\', '/'),
            ((Join-Path $tmpRoot 'bash-scalar.err') -replace '\\', '/'), ($bashScalarLifecycle -replace '\\', '/'),
            ((Join-Path $tmpRoot 'bash-scalar.ledger.json') -replace '\\', '/'), ($bashAdapter -replace '\\', '/')
        ) -Environment @{ FAKE_BASH_MODE = 'scalar' }
        Assert-True ($bashScalar.ExitCode -ne 0) 'bash scalar structured output exits unsuccessfully'
        $bashScalarRecord = Get-Content -LiteralPath $bashScalarLifecycle -Raw | ConvertFrom-Json
        Assert-Equal $bashScalarRecord.failure_class 'malformed_output' 'bash scalar structured output records diagnosis'

        $bashQuotaLifecycle = Join-Path $tmpRoot 'bash-quota.lifecycle.json'
        $bashQuota = Invoke-Process -FilePath $bashCommand -ArgumentList @(
            ($bashRunner -replace '\\', '/'), ($bashAgy -replace '\\', '/'), ($shLauncher -replace '\\', '/'),
            ((Join-Path $tmpRoot 'bash-quota.json') -replace '\\', '/'),
            ((Join-Path $tmpRoot 'bash-quota.err') -replace '\\', '/'), ($bashQuotaLifecycle -replace '\\', '/'),
            ((Join-Path $tmpRoot 'bash-quota.ledger.json') -replace '\\', '/'), ($bashAdapter -replace '\\', '/')
        ) -Environment @{ FAKE_BASH_MODE = 'quota' }
        Assert-Equal $bashQuota.ExitCode 75 'bash quota exhaustion returns handoff code'
        $bashQuotaRecord = Get-Content -LiteralPath $bashQuotaLifecycle -Raw | ConvertFrom-Json
        Assert-Equal $bashQuotaRecord.failure_class 'quota' 'bash quota handoff records diagnosis'
        Assert-True ((@($bashQuotaRecord.events | ForEach-Object { $_.state }) -contains 'quota-handoff')) 'bash quota exhaustion records quota-handoff state'
    } else {
        [Console]::Out.WriteLine('skip - bash not found on host; skipping worker lifecycle parity')
    }
} finally {
    if ($null -eq $savedAdapterBin) {
        Remove-Item Env:OFFLOAD_ADAPTER_BIN -ErrorAction SilentlyContinue
    } else {
        $env:OFFLOAD_ADAPTER_BIN = $savedAdapterBin
    }
    if ($null -eq $savedAdapterCatalog) {
        Remove-Item Env:FAKE_ADAPTER_CATALOG -ErrorAction SilentlyContinue
    } else {
        $env:FAKE_ADAPTER_CATALOG = $savedAdapterCatalog
    }
    if (Test-Path -LiteralPath $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force
    }
}

if ($script:FailedTests -gt 0) { exit 1 }
[Console]::Out.WriteLine("$($script:TotalTests) tests passed")
exit 0
