#!/usr/bin/env pwsh
# Select a worker only after adapter preflight establishes access, entitlement,
# capabilities, and capacity for the complete retry budget.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Fail([string]$message, [int]$code = 4) {
    [Console]::Error.WriteLine("ERROR: $message")
    exit $code
}

function P($object, [string]$name) {
    if ($null -eq $object) { return $null }
    $property = $object.PSObject.Properties[$name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Has($object, [string]$name) {
    return $null -ne $object -and $null -ne $object.PSObject.Properties[$name]
}

function Text($value) {
    if ($null -eq $value) { return '' }
    return [string]$value
}

function State($value) { return (Text $value).Trim().ToLowerInvariant() }

function Is-Number($value) {
    if ($null -eq $value -or $value -is [bool] -or $value -is [string] -or $value -is [char]) { return $false }
    return $value -is [byte] -or $value -is [sbyte] -or $value -is [int16] -or $value -is [uint16] -or $value -is [int32] -or $value -is [uint32] -or $value -is [int64] -or $value -is [uint64] -or $value -is [single] -or $value -is [double] -or $value -is [decimal]
}

function Read-Json([string]$path, [string]$label) {
    try {
        return ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path)) -Depth 50 -ErrorAction Stop
    } catch {
        Fail "$label is not valid JSON: $($_.Exception.Message)" 127
    }
}

function Safe-Reason([string]$value) {
    $text = (Text $value) -replace '[\r\n\t]+', ' '
    $text = $text -replace '(?i)(access[_-]?token|api[_-]?key|token|secret|password|authorization|account(?:[_-]?ref)?|billing(?:[_-]?route)?)[=:]\s*(?:"[^"]*"|''[^'']*''|\S+)', '$1=[redacted]'
    $text = $text -replace '(?i)"(access[_-]?token|api[_-]?key|token|secret|password|authorization|account(?:[_-]?ref)?|billing(?:[_-]?route)?)"\s*:\s*"[^"]*"', '"$1":"[redacted]"'
    $text = $text -replace '(?i)bearer\s+\S+', 'Bearer [redacted]'
    if ($text.Length -gt 240) { return $text.Substring(0, 240) }
    return $text
}

function Sanitize-Preflight($record) {
    $access = P $record 'access'; if ($null -eq $access) { $access = [pscustomobject]@{} }
    $entitlement = P $record 'entitlement'; if ($null -eq $entitlement) { $entitlement = [pscustomobject]@{} }
    $usage = P $record 'usage'; if ($null -eq $usage) { $usage = [pscustomobject]@{} }
    $safeScopes = [System.Collections.Generic.List[object]]::new()
    foreach ($scope in @((P $usage 'scopes'))) {
        if ($null -eq $scope -or -not (Has $scope 'remaining_units') -or -not (Has $scope 'reserved_units')) { continue }
        $remainingValue = P $scope 'remaining_units'; $reservedValue = P $scope 'reserved_units'
        if (-not (Is-Number $remainingValue) -or -not (Is-Number $reservedValue)) { continue }
        try {
            $remainingUnits = [double]$remainingValue
            $reservedUnits = [double]$reservedValue
            if ([double]::IsNaN($remainingUnits) -or [double]::IsInfinity($remainingUnits) -or [double]::IsNaN($reservedUnits) -or [double]::IsInfinity($reservedUnits)) { continue }
            [void]$safeScopes.Add([ordered]@{
                scope_id = Safe-Reason (Text (P $scope 'scope_id'))
                remaining_units = $remainingUnits
                reserved_units = $reservedUnits
            })
        } catch { }
    }
    [ordered]@{
        access = [ordered]@{
            state = State (P $access 'state')
            reason = Safe-Reason (P $access 'reason')
            account_ref = if (Text (P $access 'account_ref')) { '[redacted]' } else { '' }
        }
        entitlement = [ordered]@{
            state = State (P $entitlement 'state')
            reason = Safe-Reason (P $entitlement 'reason')
            billing_route = State (P $entitlement 'billing_route')
            cancellation_pending = if (Has $entitlement 'cancellation_pending') { [bool](P $entitlement 'cancellation_pending') } else { $false }
        }
        usage = [ordered]@{
            state = State (P $usage 'state')
            reason = Safe-Reason (P $usage 'reason')
            source = Safe-Reason (P $usage 'source')
            observed_at = Safe-Reason (Text (P $usage 'observed_at'))
            scopes = @($safeScopes.ToArray())
        }
    }
}

function Verification-Reason([string]$kind, $record) {
    $state = State (P $record 'state')
    $billingState = State (P $record 'billing_route')
    $reason = Safe-Reason (P $record 'reason')
    if (-not $reason) { $reason = if ($state) { "state=$state" } else { 'state was not reported' } }

    if ($kind -eq 'access') {
        if ($state -in @('denied', 'rejected', 'unauthenticated', 'forbidden')) { return "provider-confirmed access failure: $reason" }
        if ($state -in @('expired', 'revoked')) { return "provider-confirmed access ${state}: $reason" }
        return "access verification unavailable or unsupported: $reason"
    }
    if ($kind -eq 'entitlement') {
        if ($state -in @('denied', 'rejected', 'forbidden', 'expired', 'revoked')) { return "provider-confirmed entitlement ${state}: $reason" }
        return "entitlement verification unavailable or unsupported: $reason"
    }
    if ($billingState -eq 'paid-fallback') { return 'billing route is a provider-confirmed paid fallback' }
    if ($billingState -in @('denied', 'rejected', 'forbidden', 'expired', 'revoked', 'disallowed')) { return "provider-confirmed billing failure: $reason" }
    return "billing verification unavailable or unsupported: $reason"
}

function Usage-Reason($usage, [string]$state) {
    $reason = Safe-Reason (P $usage 'reason')
    if (-not $reason) { $reason = if ($state) { "state=$state" } else { 'state was not reported' } }
    switch ($state) {
        'exhausted' { return "provider-confirmed usage exhausted: $reason" }
        'malformed' { return "usage observation is malformed: $reason" }
        'stale' { return "usage observation is stale: $reason" }
        'timed-out' { return "usage probe timed out: $reason" }
        default { return "usage verification unavailable or unsupported: $reason" }
    }
}

$catalogPath = ''; $policyPath = ''; $requestPath = ''; $outputPath = ''; $pinPath = ''; $provider = ''; $allowUnknownUsage = $false
$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    switch ($arg) {
        '--catalog' { $i++; if ($i -ge $args.Count) { Fail '--catalog requires a value' 2 }; $catalogPath = [string]$args[$i] }
        '--policy' { $i++; if ($i -ge $args.Count) { Fail '--policy requires a value' 2 }; $policyPath = [string]$args[$i] }
        '--request' { $i++; if ($i -ge $args.Count) { Fail '--request requires a value' 2 }; $requestPath = [string]$args[$i] }
        '--output' { $i++; if ($i -ge $args.Count) { Fail '--output requires a value' 2 }; $outputPath = [string]$args[$i] }
        '--pin' { $i++; if ($i -ge $args.Count) { Fail '--pin requires a value' 2 }; $pinPath = [string]$args[$i] }
        '--provider' { $i++; if ($i -ge $args.Count) { Fail '--provider requires a value' 2 }; $provider = [string]$args[$i] }
        '--allow-unknown-usage' { $allowUnknownUsage = $true }
        default { Fail "unknown selector option: $arg" 2 }
    }
    $i++
}
if (-not $catalogPath -or -not $policyPath -or -not $requestPath -or -not $outputPath) { Fail '--catalog, --policy, --request, and --output are required' 2 }

$catalog = Read-Json $catalogPath 'adapter catalog'
$policy = Read-Json $policyPath 'model policy'
$request = Read-Json $requestPath 'catalog request'
if ((P $catalog 'protocol_version') -ne 2) { Fail "adapter catalog has unsupported protocol_version '$(P $catalog 'protocol_version')'; protocol version 2 requires verified preflight records" 127 }
$adapter = Text (P $catalog 'adapter'); $vendor = Text (P $catalog 'vendor'); $catalogRevision = Text (P $catalog 'catalog_revision'); $adapterRevision = Text (P $catalog 'adapter_revision')
if (@($adapter, $vendor, $catalogRevision, $adapterRevision | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) { Fail 'adapter catalog is missing required metadata' 127 }

$pinForEligibility = $null; $pinProviderForEligibility = ''
if ($pinPath) {
    if (-not (Test-Path -LiteralPath $pinPath -PathType Leaf)) { Fail "pinned selection file not found: $pinPath" 3 }
    $pinForEligibility = Read-Json $pinPath 'pinned selection'
    $pinProviderForEligibility = Text (P $pinForEligibility 'provider')
    if (-not $pinProviderForEligibility) { $pinProviderForEligibility = Text (P $pinForEligibility 'vendor') }
}
$unknownUsageAllowed = $allowUnknownUsage -and (($provider -and $provider.Trim()) -or ($pinPath -and $pinProviderForEligibility))

$estimate = P $policy 'capacity_estimation'
$estimateVersion = if (Has $estimate 'version') { [int](P $estimate 'version') } else { 1 }
$assignmentUnits = if (Has $estimate 'assignment_units') { [int](P $estimate 'assignment_units') } else { 1 }
$verificationUnits = if (Has $estimate 'verification_units') { [int](P $estimate 'verification_units') } else { 1 }
$retryUnits = if (Has $estimate 'retry_units') { [int](P $estimate 'retry_units') } else { 1 }
$requiredUnits = $assignmentUnits + $verificationUnits + $retryUnits
$freshness = if (Has $estimate 'usage_freshness_seconds') { [int](P $estimate 'usage_freshness_seconds') } else { 300 }
if ($estimateVersion -lt 1 -or $requiredUnits -le 0 -or $freshness -le 0) { Fail 'capacity estimation policy is invalid' 127 }
$allowedBillingRoutes = @('included', 'subscription', 'test-subscription', 'probe-subscription', 'free', 'trial', 'community', 'enterprise')
$effort = Text (P $request 'effort'); $preference = Text (P $request 'preference')
$requiredCapabilities = @((P $request 'required_capabilities')) | ForEach-Object { Text $_ } | Where-Object { $_ }
$now = [DateTime]::UtcNow
$eligible = [System.Collections.Generic.List[object]]::new()
$rejections = [System.Collections.Generic.List[string]]::new()

foreach ($model in @((P $catalog 'models'))) {
    $id = Text (P $model 'id')
    $modelProvider = Text (P $model 'provider')
    if (-not $modelProvider) { $modelProvider = if (Has $model 'vendor') { Text (P $model 'vendor') } else { $vendor } }
    $preflight = P $model 'preflight'; if ($null -eq $preflight) { $preflight = [pscustomobject]@{} }
    $access = P $preflight 'access'; if ($null -eq $access) { $access = [pscustomobject]@{} }
    $entitlement = P $preflight 'entitlement'; if ($null -eq $entitlement) { $entitlement = [pscustomobject]@{} }
    $usage = P $preflight 'usage'; if ($null -eq $usage) { $usage = [pscustomobject]@{} }
    $blocking = [System.Collections.Generic.List[string]]::new()
    $diagnostics = [System.Collections.Generic.List[string]]::new()
    $accessState = State (P $access 'state'); $entitlementState = State (P $entitlement 'state'); $billing = State (P $entitlement 'billing_route')

    if (-not $id) { $blocking.Add('missing model id') }
    if ((Has $model 'available') -and (P $model 'available') -eq $false) { $blocking.Add('adapter marked model unavailable') }
    if ((Has $model 'quota_available') -and (P $model 'quota_available') -eq $false) { $blocking.Add('adapter marked quota unavailable') }
    if ($accessState -notin @('verified', 'authenticated', 'available')) {
        $diagnostic = Verification-Reason 'access' $access
        $diagnostics.Add($diagnostic); $blocking.Add($diagnostic)
    } elseif (-not (Text (P $access 'account_ref'))) {
        $diagnostic = 'access is verified but the account identifier is missing'
        $diagnostics.Add($diagnostic); $blocking.Add($diagnostic)
    }
    if ($entitlementState -notin @('active', 'continuing')) {
        $diagnostic = Verification-Reason 'entitlement' $entitlement
        $diagnostics.Add($diagnostic); $blocking.Add($diagnostic)
    }
    if ($billing -notin $allowedBillingRoutes) {
        $diagnostic = Verification-Reason 'billing' $entitlement
        $diagnostics.Add($diagnostic); $blocking.Add($diagnostic)
    }

    $supportedEfforts = @((P $model 'supported_efforts')) | ForEach-Object { Text $_ }
    if ($supportedEfforts -notcontains $effort) { $blocking.Add('effort is unsupported') }
    $caps = @((P $model 'capabilities')) | ForEach-Object { Text $_ }
    foreach ($cap in $requiredCapabilities) { if ($caps -notcontains $cap) { $blocking.Add("missing capability '$cap'") } }

    $usageState = State (P $usage 'state')
    $usageDiagnostic = $null
    $observedValue = P $usage 'observed_at'; $observedText = Text $observedValue; $observed = $null
    if ($observedValue -is [DateTime]) {
        $observed = [DateTime]::SpecifyKind([DateTime]$observedValue, [DateTimeKind]::Utc)
        $observedText = $observed.ToString('o')
    } elseif ($observedValue -is [DateTimeOffset]) {
        $observed = $observedValue.UtcDateTime
        $observedText = $observed.ToString('o')
    } elseif ($observedText) {
        try { $observed = [DateTime]::Parse($observedText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal) } catch { $observed = $null }
    }
    $scopes = @((P $usage 'scopes'))
    $ageSeconds = if ($null -ne $observed) { $now.Subtract([DateTime]$observed).TotalSeconds } else { [double]::PositiveInfinity }
    $usageKnown = $usageState -eq 'known' -and $null -ne $observed -and $observed -le $now -and $ageSeconds -le $freshness -and $scopes.Count -gt 0
    $remaining = [double]::PositiveInfinity
    if ($usageKnown) {
        foreach ($scope in $scopes) {
            if (-not (Has $scope 'remaining_units') -or -not (Has $scope 'reserved_units')) { $usageKnown = $false; break }
            $remainingValue = P $scope 'remaining_units'; $reservedValue = P $scope 'reserved_units'
            if (-not (Is-Number $remainingValue) -or -not (Is-Number $reservedValue)) { $usageKnown = $false; break }
            try {
                $available = [double]$remainingValue - [double]$reservedValue
                if ([double]::IsNaN($available) -or [double]::IsInfinity($available)) { $usageKnown = $false; break }
                if ($available -lt $remaining) { $remaining = $available }
                if ($available -lt $requiredUnits) {
                    $scopeId = Safe-Reason (Text (P $scope 'scope_id'))
                    $blocking.Add("provider-confirmed capacity insufficient in scope '$scopeId'")
                }
            } catch { $usageKnown = $false; break }
        }
    }
    if ($usageState -eq 'exhausted') {
        $usageDiagnostic = Usage-Reason $usage $usageState
        $diagnostics.Add($usageDiagnostic); $blocking.Add($usageDiagnostic)
    } elseif (-not $usageKnown) {
        $usageDiagnostic = if ($usageState -eq 'known') { 'usage observation is malformed or incomplete' } else { Usage-Reason $usage $usageState }
        $diagnostics.Add($usageDiagnostic)
        if (-not $unknownUsageAllowed) { $blocking.Add($usageDiagnostic) } else { $remaining = $null }
    }

    $candidateAllowed = $blocking.Count -eq 0 -and ($usageKnown -or $unknownUsageAllowed)
    if ($candidateAllowed) {
        $scoreValue = P (P $model 'scores') $preference
        if ($null -eq $scoreValue) { $scoreValue = 1000000 }
        try { $score = [double]$scoreValue } catch { $score = 1000000 }
        $eligible.Add([pscustomobject]@{
            Model = $model; Id = $id; Provider = $modelProvider; Score = $score; Remaining = $remaining
            UsageKnown = $usageKnown; Preflight = $preflight; PreflightReasons = @($diagnostics)
        })
    } elseif ($id) {
        $rejections.Add("$(Safe-Reason $id): $((@($blocking + $diagnostics | Select-Object -Unique)) -join ', ')")
    }
}

$diagnosticDetail = if ($rejections.Count) { "; candidate diagnostics: $($rejections -join '; ')" } else { '' }
if ($eligible.Count -eq 0) {
    if ($provider) { Fail "explicit provider '$provider' is not eligible; no silent fallback is permitted$diagnosticDetail" 3 }
    Fail "no eligible worker: verified access, active entitlement, required capability, and capacity for assignment + verification + one retry are required$diagnosticDetail" 4
}

$selected = $null
if ($pinPath) {
    $pin = $pinForEligibility; $pinId = Text (P $pin 'model_id'); $pinProvider = $pinProviderForEligibility
    if ((Text (P $pin 'adapter')) -ne $adapter -or (Text (P $pin 'effort')) -ne $effort -or -not $pinId) { Fail 'pinned selection does not match the current adapter or policy effort; explicit fallback or handoff is required' 3 }
    $selected = $eligible | Where-Object { $_.Id -eq $pinId -and $_.Provider -eq $pinProvider } | Select-Object -First 1
    if ($null -eq $selected) { Fail "pinned model '$pinId' is unavailable or no longer eligible; explicit fallback or handoff is required$diagnosticDetail" 3 }
    $reason = "pinned selection adapter=$adapter provider=$($selected.Provider) model_id=$pinId; preflight revalidated"
} elseif ($provider) {
    $candidates = @($eligible | Where-Object { $_.Provider -eq $provider -or (Text (P $_.Model 'adapter')) -eq $provider -or (Text (P $_.Model 'vendor')) -eq $provider })
    if (-not $candidates.Count) { Fail "explicit provider '$provider' is not eligible; no silent fallback is permitted$diagnosticDetail" 3 }
    $selected = $candidates | Sort-Object Score, @{ Expression = { if ($null -eq $_.Remaining) { -1 } else { -[double]$_.Remaining } } }, Provider, Id | Select-Object -First 1
    $reason = "explicit provider '$provider' selected after eligibility checks; no fallback"
} else {
    $selected = $eligible | Sort-Object Score, @{ Expression = { if ($null -eq $_.Remaining) { -1 } else { -[double]$_.Remaining } } }, Provider, Id | Select-Object -First 1
    $reason = "selected by preference=$preference, capability match, and remaining capacity; estimate units=$requiredUnits (assignment=$assignmentUnits, verification=$verificationUnits, retry=$retryUnits)"
}

$safePreflight = Sanitize-Preflight $selected.Preflight
$usage = P $safePreflight 'usage'
$selection = [ordered]@{
    protocol_version = 2; adapter = $adapter; adapter_revision = $adapterRevision; vendor = $vendor
    provider = $selected.Provider; model_id = $selected.Id; model = $selected.Id; family_hint = Text (P $selected.Model 'family_hint')
    preference = $preference; effort = $effort; catalog_revision = $catalogRevision; policy_revision = Text (P $policy 'policy_revision')
    required_capabilities = @($requiredCapabilities); selection_reason = $reason; route = Text (P $request 'route')
    eligibility = 'eligible'; eligibility_reason = 'verified access, active entitlement, compatible capabilities, and sufficient capacity'
    preflight = $safePreflight; preflight_reasons = @($selected.PreflightReasons | ForEach-Object { Safe-Reason (Text $_) })
    capacity_estimate = [ordered]@{ version = $estimateVersion; assignment_units = $assignmentUnits; verification_units = $verificationUnits; retry_units = $retryUnits; required_units = $requiredUnits; freshness_seconds = $freshness }
    usage_observed_at = Text (P $usage 'observed_at'); usage_uncertain = (-not $selected.UsageKnown)
    reservation = [ordered]@{ required_units = $requiredUnits; scopes = @((P $usage 'scopes') | ForEach-Object { Text (P $_ 'scope_id') }) }
}
$json = $selection | ConvertTo-Json -Depth 50
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($outputPath), $json, [System.Text.Encoding]::UTF8)
[Console]::Out.Write($json)
