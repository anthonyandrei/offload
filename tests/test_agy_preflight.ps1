#!/usr/bin/env pwsh
# Acceptance tests for AGY discovery, preflight normalization, and diagnostics.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$script:Passed = 0

function Pass([string]$name) {
    $script:Passed++
    [Console]::Out.WriteLine("ok - $name")
}

function Fail([string]$name, [string]$reason = '') {
    $suffix = if ($reason) { " - $reason" } else { '' }
    [Console]::Error.WriteLine("FAIL: $name$suffix")
    exit 1
}

function Assert-True([bool]$condition, [string]$name, [string]$reason = '') {
    if ($condition) { Pass $name } else { Fail $name $(if ($reason) { $reason } else { 'condition was false' }) }
}

function Assert-False([bool]$condition, [string]$name, [string]$reason = '') {
    Assert-True (-not $condition) $name $(if ($reason) { $reason } else { 'condition was true' })
}

function Assert-Equal($actual, $expected, [string]$name) {
    if ($actual -eq $expected) { Pass $name } else { Fail $name "expected '$expected', got '$actual'" }
}

function Assert-Contains([string]$actual, [string]$expected, [string]$name) {
    if ($actual.Contains($expected)) { Pass $name } else { Fail $name "expected '$expected' in '$actual'" }
}

function Assert-NotContains([string]$actual, [string]$unexpected, [string]$name) {
    if (-not $actual.Contains($unexpected)) { Pass $name } else { Fail $name "did not expect '$unexpected' in '$actual'" }
}

function Invoke-Process([string]$fileName, [string[]]$arguments, [hashtable]$environment = @{}, [int]$timeoutMilliseconds = 30000) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $fileName
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in $arguments) { [void]$psi.ArgumentList.Add($argument) }
    foreach ($key in $environment.Keys) { $psi.Environment[$key] = [string]$environment[$key] }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw "failed to start $fileName" }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($timeoutMilliseconds)) {
            try { $process.Kill($true) } catch { }
            $process.WaitForExit()
            return [pscustomobject]@{ ExitCode = 124; Stdout = $stdout.Result; Stderr = $stderr.Result }
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout.Result; Stderr = $stderr.Result }
    } finally {
        $process.Dispose()
    }
}

function Write-Json([string]$path, $value) {
    $value | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path -Encoding utf8
}

function New-Preflight($scenario) {
    # Selector cases start at the protocol-2 boundary. Raw AGY normalization is
    # exercised above; the live CLI cannot produce verified access or entitlement.
    $accessState = [string]$scenario.access_state
    $entitlementState = [string]$scenario.entitlement_state
    $billingRoute = [string]$scenario.billing_route
    $accessReason = if ($accessState -eq 'verified') { 'fixture verified access' } else { "fixture access state $accessState" }
    $entitlementReason = if ($entitlementState -in @('active', 'continuing')) { 'fixture entitlement is continuing' } else { "fixture entitlement state $entitlementState" }
    $usageState = [string]$scenario.usage_state
    $usageReason = 'fixture usage is known and fresh'
    $observedAt = ''
    $scopes = @()
    switch ([string]$scenario.usage_mode) {
        'known' {
            $usageState = 'known'
            $observedAt = [DateTime]::UtcNow.ToString('o')
            $scopes = @([ordered]@{ scope_id = 'fixture-window'; remaining_units = 20; reserved_units = 0 })
        }
        'exhausted' {
            $usageState = 'exhausted'
            $usageReason = 'fixture provider reports exhausted capacity'
            $observedAt = [DateTime]::UtcNow.ToString('o')
            $scopes = @([ordered]@{ scope_id = 'fixture-window'; remaining_units = 0; reserved_units = 0 })
        }
        'insufficient' {
            $usageState = 'known'
            $usageReason = 'fixture provider reports insufficient capacity'
            $observedAt = [DateTime]::UtcNow.ToString('o')
            $scopes = @([ordered]@{ scope_id = 'fixture-window'; remaining_units = 2; reserved_units = 0 })
        }
        'malformed' {
            $usageState = 'malformed'
            $usageReason = 'fixture usage response was malformed'
        }
        'stale' {
            $usageState = 'stale'
            $usageReason = 'fixture usage observation is stale'
            $observedAt = '2000-01-01T00:00:00Z'
            $scopes = @([ordered]@{ scope_id = 'fixture-window'; remaining_units = 20; reserved_units = 0 })
        }
        'unsupported' {
            $usageState = 'unknown'
            $usageReason = 'fixture usage interface is unsupported'
        }
        'timed-out' {
            $usageState = 'timed-out'
            $usageReason = 'fixture usage probe timed out'
        }
        default {
            $usageState = 'unknown'
            $usageReason = 'fixture omitted usage response'
        }
    }
    $cancellationPending = if ($scenario.PSObject.Properties['cancellation_pending']) { [bool]$scenario.cancellation_pending } else { $false }
    [ordered]@{
        access = [ordered]@{ state = $accessState; reason = $accessReason; account_ref = [string]$scenario.account_ref }
        entitlement = [ordered]@{ state = $entitlementState; reason = $entitlementReason; billing_route = $billingRoute; cancellation_pending = $cancellationPending }
        usage = [ordered]@{ state = $usageState; reason = $usageReason; source = 'agy-fixture'; observed_at = $observedAt; scopes = $scopes }
    }
}

function New-Catalog($scenario) {
    [ordered]@{
        protocol_version = 2
        adapter = 'agy'
        adapter_revision = 'agy-fixture-1'
        vendor = 'agy'
        catalog_revision = "fixture-$($scenario.name)"
        models = @([ordered]@{
            id = "fixture-$($scenario.name)"
            provider = 'agy'
            family_hint = 'flash'
            supported_efforts = @('high')
            capabilities = @()
            scores = [ordered]@{ fast = 1; balanced = 1; deep = 1 }
            preflight = New-Preflight $scenario
        })
    }
}

function New-Request {
    [ordered]@{
        protocol_version = 2
        role = 'researcher'
        preference = 'balanced'
        effort = 'high'
        required_capabilities = @()
        policy_revision = 'policy-1'
        route = 'default'
    }
}

$root = Split-Path -Parent $PSScriptRoot
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$adapter = Join-Path $root 'scripts/agy-adapter.ps1'
$selector = Join-Path $root 'scripts/select-compatible-worker.ps1'
$policy = Join-Path $root 'model-policy.json'
$fixturePath = Join-Path $root 'tests/fixtures/agy-preflight/scenarios.json'
$fakeAgy = Join-Path $root 'tests/fixtures/agy-preflight/fake-agy.ps1'
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -Depth 30
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("offload-agy-preflight-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $requestPath = Join-Path $testRoot 'catalog-request.json'
    Write-Json $requestPath (New-Request)
    $callLog = Join-Path $testRoot 'adapter-calls.log'
    $adapterResult = Invoke-Process $pwsh @('-NoProfile', '-NonInteractive', '-File', $adapter, '--operation', 'catalog', '--request', $requestPath) @{
        AGY_BIN = $fakeAgy
        AGY_PREFLIGHT_FIXTURE = $fixturePath
        AGY_PREFLIGHT_SCENARIO = 'unsupported-usage'
        AGY_PREFLIGHT_CALL_LOG = $callLog
    }
    Assert-Equal $adapterResult.ExitCode 0 'model-list fixture returns a protocol-2 catalog'
    $adapterCatalog = $adapterResult.Stdout | ConvertFrom-Json -Depth 50
    Assert-True (@($adapterCatalog.models).Count -gt 0) 'model-list fixture still reports discovered models'
    Assert-Equal $adapterCatalog.models[0].preflight.access.state 'unknown' 'unsupported access remains unknown'
    Assert-Equal $adapterCatalog.models[0].preflight.entitlement.state 'unknown' 'unsupported entitlement remains unknown'
    Assert-Equal $adapterCatalog.models[0].preflight.usage.state 'unknown' 'unsupported usage remains unknown'
    Assert-Contains ([string]$adapterCatalog.models[0].preflight.usage.reason) 'failed with exit code 2' 'unsupported usage keeps a precise probe reason'
    Assert-True ($null -eq $adapterCatalog.models[0].PSObject.Properties['available']) 'adapter does not emit optimistic availability'
    $calls = Get-Content -LiteralPath $callLog -Raw
    Assert-Contains $calls 'models' 'catalog discovery calls the model-list interface'
    Assert-Contains $calls '/usage' 'catalog discovery calls the bounded usage interface'
    Assert-NotContains $calls '--model' 'catalog discovery does not launch a worker'
    Assert-NotContains $calls 'prompt' 'catalog discovery does not send a billable prompt'

    $timestampCallLog = Join-Path $testRoot 'timestamp-calls.log'
    $timestampResult = Invoke-Process $pwsh @('-NoProfile', '-NonInteractive', '-File', $adapter, '--operation', 'catalog', '--request', $requestPath) @{
        AGY_BIN = $fakeAgy
        AGY_PREFLIGHT_FIXTURE = $fixturePath
        AGY_PREFLIGHT_SCENARIO = 'verified'
        AGY_PREFLIGHT_CALL_LOG = $timestampCallLog
    }
    if ($timestampResult.ExitCode -ne 0) { Fail 'valid usage fixture returns a catalog' $timestampResult.Stderr }
    Assert-Equal $timestampResult.ExitCode 0 'valid usage fixture returns a catalog'
    $timestampCatalog = $timestampResult.Stdout | ConvertFrom-Json -Depth 50
    Assert-True (@($timestampCatalog.models | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.preflight.usage.observed_at) }).Count -eq 0) 'usage discovery preserves the observation timestamp'

    $modelTimeoutCallLog = Join-Path $testRoot 'model-timeout-calls.log'
    $modelTimeout = Invoke-Process $pwsh @('-NoProfile', '-NonInteractive', '-File', $adapter, '--operation', 'catalog', '--request', $requestPath) @{
        AGY_BIN = $fakeAgy
        AGY_PREFLIGHT_FIXTURE = $fixturePath
        AGY_PREFLIGHT_SCENARIO = 'timed-out-models'
        AGY_PREFLIGHT_CALL_LOG = $modelTimeoutCallLog
    }
    Assert-Equal $modelTimeout.ExitCode 127 'model discovery timeout fails closed'
    Assert-Contains $modelTimeout.Stderr 'catalog discovery timed out' 'model discovery timeout is diagnosed precisely'
    Assert-NotContains (Get-Content -LiteralPath $modelTimeoutCallLog -Raw) '/usage' 'model discovery timeout does not continue to usage probing'

    foreach ($providerExitCode in @(124, 137)) {
        $providerFailureCallLog = Join-Path $testRoot "models-exit-$providerExitCode-calls.log"
        $providerFailure = Invoke-Process $pwsh @('-NoProfile', '-NonInteractive', '-File', $adapter, '--operation', 'catalog', '--request', $requestPath) @{
            AGY_BIN = $fakeAgy
            AGY_PREFLIGHT_FIXTURE = $fixturePath
            AGY_PREFLIGHT_SCENARIO = "models-exit-$providerExitCode"
            AGY_PREFLIGHT_CALL_LOG = $providerFailureCallLog
        }
        Assert-Equal $providerFailure.ExitCode 127 "provider model failure $providerExitCode fails closed"
        Assert-Contains $providerFailure.Stderr "failed with exit code $providerExitCode" "provider model failure $providerExitCode keeps its exit diagnostic"
        Assert-NotContains $providerFailure.Stderr 'discovery timed out' "provider model failure $providerExitCode is not mislabeled as a timeout"
    }

    foreach ($providerExitCode in @(124, 137)) {
        $usageFailureCallLog = Join-Path $testRoot "usage-exit-$providerExitCode-calls.log"
        $usageFailure = Invoke-Process $pwsh @('-NoProfile', '-NonInteractive', '-File', $adapter, '--operation', 'catalog', '--request', $requestPath) @{
            AGY_BIN = $fakeAgy
            AGY_PREFLIGHT_FIXTURE = $fixturePath
            AGY_PREFLIGHT_SCENARIO = "usage-exit-$providerExitCode"
            AGY_PREFLIGHT_CALL_LOG = $usageFailureCallLog
        }
        Assert-Equal $usageFailure.ExitCode 0 "provider usage failure $providerExitCode still returns a catalog"
        $usageFailureCatalog = $usageFailure.Stdout | ConvertFrom-Json -Depth 50
        $usageFailureReason = [string]$usageFailureCatalog.models[0].preflight.usage.reason
        Assert-Contains $usageFailureReason "failed with exit code $providerExitCode" "provider usage failure $providerExitCode keeps its exit diagnostic"
        Assert-NotContains $usageFailureReason 'timed out' "provider usage failure $providerExitCode is not mislabeled as a timeout"
    }

    $redactionCallLog = Join-Path $testRoot 'redaction-calls.log'
    $redaction = Invoke-Process $pwsh @('-NoProfile', '-NonInteractive', '-File', $adapter, '--operation', 'catalog', '--request', $requestPath) @{
        AGY_BIN = $fakeAgy
        AGY_PREFLIGHT_FIXTURE = $fixturePath
        AGY_PREFLIGHT_SCENARIO = 'redaction-unsupported-usage'
        AGY_PREFLIGHT_CALL_LOG = $redactionCallLog
    }
    Assert-NotContains ($redaction.Stdout + $redaction.Stderr) 'agy-secret-token-should-never-escape' 'adapter suppresses raw provider stderr secrets'

    foreach ($scenario in @($fixture.scenarios)) {
        $catalogPath = Join-Path $testRoot "$($scenario.name)-catalog.json"
        $outputPath = Join-Path $testRoot "$($scenario.name)-selection.json"
        Write-Json $catalogPath (New-Catalog $scenario)
        $selectorArguments = @('--catalog', $catalogPath, '--policy', $policy, '--request', $requestPath, '--output', $outputPath)
        $explicit = $false
        if ($scenario.PSObject.Properties['requires_explicit_provider']) { $explicit = [bool]$scenario.requires_explicit_provider }
        if ($explicit) { $selectorArguments += @('--provider', 'agy', '--allow-unknown-usage') }
        $selectorInvocation = @('-NoProfile', '-NonInteractive', '-File', $selector) + $selectorArguments
        $result = Invoke-Process $pwsh $selectorInvocation
        if ([bool]$scenario.expected_eligible) {
            Assert-Equal $result.ExitCode 0 "$($scenario.name) produces an eligible selection"
            $selection = $result.Stdout | ConvertFrom-Json -Depth 50
            Assert-Equal $selection.eligibility 'eligible' "$($scenario.name) records eligibility"
            Assert-Equal $selection.provider 'agy' "$($scenario.name) preserves provider identity"
            Assert-Equal $selection.preflight.access.account_ref '[redacted]' "$($scenario.name) redacts account references in selection output"
            Assert-NotContains $result.Stdout 'fixture-account' "$($scenario.name) does not persist the raw account reference"
            if ($explicit) {
                Assert-True ([bool]$selection.usage_uncertain) "$($scenario.name) records unknown usage"
                Assert-Contains (($selection.preflight_reasons | ConvertTo-Json -Compress)) 'usage' "$($scenario.name) preserves the usage diagnostic"
            } else {
                Assert-False ([bool]$selection.usage_uncertain) "$($scenario.name) records known usage"
            }
            if ($scenario.name -eq 'cancellation-pending') {
                Assert-True ([bool]$selection.preflight.entitlement.cancellation_pending) 'cancellation-pending remains traceable while eligible'
            }
        } else {
            $expectedExitCode = if ($explicit) { 3 } else { 4 }
            Assert-Equal $result.ExitCode $expectedExitCode "$($scenario.name) remains ineligible"
            switch ([string]$scenario.name) {
                'unauthenticated' { Assert-Contains $result.Stderr 'provider-confirmed access failure' 'provider-confirmed unauthenticated access is preserved' }
                'missing-access' { Assert-Contains $result.Stderr 'access verification unavailable or unsupported' 'missing access verification is not reported as denial' }
                'wrong-account' { Assert-Contains $result.Stderr 'provider-confirmed access failure' 'provider-confirmed account failure is preserved' }
                'expired' { Assert-Contains $result.Stderr 'provider-confirmed entitlement expired' 'expired entitlement is preserved' }
                'paid-fallback' { Assert-Contains $result.Stderr 'provider-confirmed paid fallback' 'paid fallback is preserved' }
                'wrong-billing' { Assert-Contains $result.Stderr 'provider-confirmed billing failure' 'provider-confirmed billing denial is preserved' }
                'exhausted' { Assert-Contains $result.Stderr 'provider-confirmed usage exhausted' 'known exhaustion is preserved' }
                'exhausted-explicit-provider' { Assert-Contains $result.Stderr 'provider-confirmed usage exhausted' 'explicit provider cannot bypass known exhaustion' }
                'insufficient-capacity' { Assert-Contains $result.Stderr 'provider-confirmed capacity insufficient' 'known insufficient capacity is preserved' }
                'insufficient-capacity-explicit-provider' { Assert-Contains $result.Stderr 'provider-confirmed capacity insufficient' 'explicit provider cannot bypass insufficient capacity' }
                'malformed-usage' { Assert-Contains $result.Stderr 'usage observation is malformed' 'malformed usage is preserved' }
                'stale-usage' { Assert-Contains $result.Stderr 'usage observation is stale' 'stale usage is preserved' }
                'timed-out-usage' { Assert-Contains $result.Stderr 'usage probe timed out' 'timed-out usage is preserved' }
                default { Assert-Contains $result.Stderr 'usage verification unavailable or unsupported' 'unsupported or missing usage is not reported as exhaustion' }
            }
            if ($scenario.name -notin @('exhausted', 'exhausted-explicit-provider')) {
                Assert-NotContains $result.Stderr 'provider-confirmed usage exhausted' "$($scenario.name) does not gain an exhaustion claim"
            }
        }
    }

    $secretScenario = [pscustomobject]@{
        name = 'secret-diagnostic'; access_state = 'unknown'; account_ref = ''; entitlement_state = 'active'; billing_route = 'included'; usage_state = 'unknown'; usage_mode = 'unsupported'
    }
    $secretCatalog = New-Catalog $secretScenario
    $secretCatalog.models[0].preflight.access.reason = 'token=agy-secret-token account=private-account token="agy-quoted-secret value"'
    $secretCatalog.models[0].preflight.usage.reason = 'secret=agy-secret-token'
    $secretCatalogPath = Join-Path $testRoot 'secret-catalog.json'
    $secretOutputPath = Join-Path $testRoot 'secret-selection.json'
    Write-Json $secretCatalogPath $secretCatalog
    $secretResult = Invoke-Process $pwsh @('-NoProfile', '-NonInteractive', '-File', $selector, '--catalog', $secretCatalogPath, '--policy', $policy, '--request', $requestPath, '--output', $secretOutputPath)
    Assert-Equal $secretResult.ExitCode 4 'secret diagnostic fixture remains ineligible'
    Assert-NotContains $secretResult.Stderr 'agy-secret-token' 'selection diagnostics redact secret values'
    Assert-NotContains $secretResult.Stderr 'agy-quoted-secret value' 'selection diagnostics redact quoted secret values'

    $eligibleSecretScenario = [pscustomobject]@{
        name = 'eligible-secret'; access_state = 'verified'; account_ref = 'private-account'; entitlement_state = 'active'; billing_route = 'included'; usage_state = 'known'; usage_mode = 'known'
    }
    $eligibleSecretCatalog = New-Catalog $eligibleSecretScenario
    $eligibleSecretCatalog.models[0].preflight.access.reason = '{"access_token":"agy-secret-token","account_ref":"private-account"} Bearer agy-secret-token token="agy-quoted-secret value"'
    $eligibleSecretCatalog.models[0].preflight.usage.reason = 'api_key=agy-secret-token'
    $eligibleSecretCatalogPath = Join-Path $testRoot 'eligible-secret-catalog.json'
    $eligibleSecretOutputPath = Join-Path $testRoot 'eligible-secret-selection.json'
    Write-Json $eligibleSecretCatalogPath $eligibleSecretCatalog
    $eligibleSecretResult = Invoke-Process $pwsh @('-NoProfile', '-NonInteractive', '-File', $selector, '--catalog', $eligibleSecretCatalogPath, '--policy', $policy, '--request', $requestPath, '--output', $eligibleSecretOutputPath)
    Assert-Equal $eligibleSecretResult.ExitCode 0 'eligible secret fixture remains selectable'
    $eligibleSecretSelection = $eligibleSecretResult.Stdout | ConvertFrom-Json -Depth 50
    $eligibleSecretText = $eligibleSecretResult.Stdout + (Get-Content -LiteralPath $eligibleSecretOutputPath -Raw)
    Assert-NotContains $eligibleSecretText 'agy-secret-token' 'eligible selection output redacts secret values'
    Assert-NotContains $eligibleSecretText 'agy-quoted-secret value' 'eligible selection output redacts quoted secret values'
    Assert-NotContains $eligibleSecretText 'private-account' 'eligible selection output redacts private account values'
    Assert-Equal $eligibleSecretSelection.preflight.access.account_ref '[redacted]' 'eligible selection normalizes the account reference'
    Assert-Contains ([string]$eligibleSecretSelection.preflight.access.reason) 'Bearer [redacted]' 'eligible selection redacts bearer tokens in reasons'

    [Console]::Out.WriteLine("all AGY preflight checks passed ($($script:Passed) tests)")
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
