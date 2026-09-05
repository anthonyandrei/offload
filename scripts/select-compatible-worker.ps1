#!/usr/bin/env pwsh
# Select a worker only after adapter preflight establishes access, entitlement,
# capabilities, and capacity for the complete retry budget.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Fail([string]$message, [int]$code = 4) { [Console]::Error.WriteLine("ERROR: $message"); exit $code }
function P($object, [string]$name) {
    if ($null -eq $object) { return $null }
    $property = $object.PSObject.Properties[$name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
function Has($object, [string]$name) { return $null -ne $object -and $null -ne $object.PSObject.Properties[$name] }
function Text($value) { if ($null -eq $value) { return '' }; return [string]$value }
function State($value) { return (Text $value).Trim().ToLowerInvariant() }
function Read-Json([string]$path, [string]$label) {
    try { return ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path)) -Depth 50 -ErrorAction Stop }
    catch { Fail "$label is not valid JSON: $($_.Exception.Message)" 127 }
}

$catalogPath=''; $policyPath=''; $requestPath=''; $outputPath=''; $pinPath=''; $provider=''; $allowUnknownUsage=$false
$i=0
while ($i -lt $args.Count) {
    $arg=[string]$args[$i]
    switch ($arg) {
        '--catalog' { $i++; if ($i -ge $args.Count) { Fail '--catalog requires a value' 2 }; $catalogPath=[string]$args[$i] }
        '--policy' { $i++; if ($i -ge $args.Count) { Fail '--policy requires a value' 2 }; $policyPath=[string]$args[$i] }
        '--request' { $i++; if ($i -ge $args.Count) { Fail '--request requires a value' 2 }; $requestPath=[string]$args[$i] }
        '--output' { $i++; if ($i -ge $args.Count) { Fail '--output requires a value' 2 }; $outputPath=[string]$args[$i] }
        '--pin' { $i++; if ($i -ge $args.Count) { Fail '--pin requires a value' 2 }; $pinPath=[string]$args[$i] }
        '--provider' { $i++; if ($i -ge $args.Count) { Fail '--provider requires a value' 2 }; $provider=[string]$args[$i] }
        '--allow-unknown-usage' { $allowUnknownUsage=$true }
        default { Fail "unknown selector option: $arg" 2 }
    }
    $i++
}
if (-not $catalogPath -or -not $policyPath -or -not $requestPath -or -not $outputPath) { Fail '--catalog, --policy, --request, and --output are required' 2 }

$catalog=Read-Json $catalogPath 'adapter catalog'; $policy=Read-Json $policyPath 'model policy'; $request=Read-Json $requestPath 'catalog request'
if ((P $catalog 'protocol_version') -ne 2) { Fail "adapter catalog has unsupported protocol_version '$(P $catalog 'protocol_version')'; protocol version 2 requires verified preflight records" 127 }
$adapter=Text (P $catalog 'adapter'); $vendor=Text (P $catalog 'vendor'); $catalogRevision=Text (P $catalog 'catalog_revision'); $adapterRevision=Text (P $catalog 'adapter_revision')
if (@($adapter,$vendor,$catalogRevision,$adapterRevision | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) { Fail 'adapter catalog is missing required metadata' 127 }
$pinForEligibility=$null; $pinProviderForEligibility=''
if ($pinPath) {
    if (-not (Test-Path -LiteralPath $pinPath -PathType Leaf)) { Fail "pinned selection file not found: $pinPath" 3 }
    $pinForEligibility=Read-Json $pinPath 'pinned selection'; $pinProviderForEligibility=Text (P $pinForEligibility 'provider'); if (-not $pinProviderForEligibility) { $pinProviderForEligibility=Text (P $pinForEligibility 'vendor') }
}
$unknownUsageAllowed=$allowUnknownUsage -and (($provider -and $provider.Trim()) -or ($pinPath -and $pinProviderForEligibility))

$estimate=P $policy 'capacity_estimation'
$estimateVersion=if (Has $estimate 'version') { [int](P $estimate 'version') } else { 1 }
$assignmentUnits=if (Has $estimate 'assignment_units') { [int](P $estimate 'assignment_units') } else { 1 }
$verificationUnits=if (Has $estimate 'verification_units') { [int](P $estimate 'verification_units') } else { 1 }
$retryUnits=if (Has $estimate 'retry_units') { [int](P $estimate 'retry_units') } else { 1 }
$requiredUnits=$assignmentUnits+$verificationUnits+$retryUnits
$freshness=if (Has $estimate 'usage_freshness_seconds') { [int](P $estimate 'usage_freshness_seconds') } else { 300 }
if ($estimateVersion -lt 1 -or $requiredUnits -le 0 -or $freshness -le 0) { Fail 'capacity estimation policy is invalid' 127 }
$effort=Text (P $request 'effort'); $preference=Text (P $request 'preference'); $requiredCapabilities=@((P $request 'required_capabilities'))|ForEach-Object{Text $_}|Where-Object{$_}
$now=[DateTime]::UtcNow; $eligible=[System.Collections.Generic.List[object]]::new(); $rejections=[System.Collections.Generic.List[string]]::new()

foreach ($model in @((P $catalog 'models'))) {
    $id=Text (P $model 'id'); $modelProvider=Text (P $model 'provider'); if (-not $modelProvider) { $modelProvider=if (Has $model 'vendor') { Text (P $model 'vendor') } else { $vendor } }
    $preflight=P $model 'preflight'; $access=P $preflight 'access'; $entitlement=P $preflight 'entitlement'; $usage=P $preflight 'usage'
    $reasons=[System.Collections.Generic.List[string]]::new(); $accessState=State (P $access 'state'); $entitlementState=State (P $entitlement 'state'); $billing=Text (P $entitlement 'billing_route')
    if (-not $id) { $reasons.Add('missing model id') }
    if ((Has $model 'available') -and (P $model 'available') -eq $false) { $reasons.Add('adapter marked model unavailable') }
    if ((Has $model 'quota_available') -and (P $model 'quota_available') -eq $false) { $reasons.Add('adapter marked quota unavailable') }
    if ($accessState -notin @('verified','authenticated','available')) { $reasons.Add('access is not verified') }
    if (-not (Text (P $access 'account_ref'))) { $reasons.Add('account identifier is missing') }
    if ($entitlementState -notin @('active','continuing')) { $reasons.Add('entitlement is not active') }
    if (-not $billing -or $billing -in @('paid-fallback','unknown')) { $reasons.Add('billing route is not established') }
    $supportedEfforts=@((P $model 'supported_efforts'))|ForEach-Object{Text $_}; if ($supportedEfforts -notcontains $effort) { $reasons.Add('effort is unsupported') }
    $caps=@((P $model 'capabilities'))|ForEach-Object{Text $_}; foreach ($cap in $requiredCapabilities) { if ($caps -notcontains $cap) { $reasons.Add("missing capability '$cap'") } }
    $observedText=Text (P $usage 'observed_at'); $observed=$null; if ($observedText) { try { $observed=[DateTime]::Parse($observedText).ToUniversalTime() } catch { $observed=$null } }
    $scopes=@((P $usage 'scopes')); $ageSeconds=if($null -ne $observed){$now.Subtract([DateTime]$observed).TotalSeconds}else{[double]::PositiveInfinity}; $usageKnown=(State (P $usage 'state') -eq 'known' -and $null -ne $observed -and $observed -le $now -and $ageSeconds -le $freshness -and $scopes.Count -gt 0); $remaining=[double]::PositiveInfinity
    if ($usageKnown) {
        foreach ($scope in $scopes) {
            if (-not (Has $scope 'remaining_units') -or -not (Has $scope 'reserved_units')) { $usageKnown=$false; break }
            try { $available=[double](P $scope 'remaining_units')-[double](P $scope 'reserved_units'); if ($available -lt $remaining) { $remaining=$available }; if ($available -lt $requiredUnits) { $reasons.Add("insufficient capacity in scope '$(Text (P $scope 'scope_id'))'") } } catch { $usageKnown=$false; break }
        }
    }
    if ((State (P $usage 'state')) -eq 'exhausted') { $reasons.Add('usage is exhausted') }
    if (-not $usageKnown) { if (-not $unknownUsageAllowed) { $reasons.Add('usage is unknown or stale') } else { $remaining=$null } }
    $nonUsage=@($reasons|Where-Object{$_ -notmatch '^usage is unknown or stale$' -and $_ -notmatch '^insufficient capacity'})
    $hasExhaustion=@($reasons|Where-Object{$_ -match '^insufficient capacity'}).Count -gt 0
    if ($nonUsage.Count -eq 0 -and (-not $hasExhaustion) -and ($usageKnown -or $unknownUsageAllowed)) {
        $scoreValue=P (P $model 'scores') $preference; if ($null -eq $scoreValue) { $scoreValue=1000000 }; try { $score=[double]$scoreValue } catch { $score=1000000 }
        $eligible.Add([pscustomobject]@{ Model=$model; Id=$id; Provider=$modelProvider; Score=$score; Remaining=$remaining; UsageKnown=$usageKnown; Preflight=$preflight })
    } elseif ($reasons.Count -gt 0) { $rejections.Add("${id}: $($reasons -join ', ')") }
}
if ($eligible.Count -eq 0) { $detail=if($rejections.Count){"; $($rejections -join '; ')"}else{''}; Fail "no eligible worker: verified access, active entitlement, required capability, and capacity for assignment + verification + one retry are required$detail" 4 }

$selected=$null
if ($pinPath) {
    $pin=$pinForEligibility; $pinId=Text (P $pin 'model_id'); $pinProvider=$pinProviderForEligibility
    if ((Text (P $pin 'adapter')) -ne $adapter -or (Text (P $pin 'effort')) -ne $effort -or -not $pinId) { Fail 'pinned selection does not match the current adapter or policy effort; explicit fallback or handoff is required' 3 }
    $selected=$eligible|Where-Object{$_.Id -eq $pinId -and $_.Provider -eq $pinProvider}|Select-Object -First 1; if ($null -eq $selected) { Fail "pinned model '$pinId' is unavailable or no longer eligible; explicit fallback or handoff is required" 3 }
    $reason="pinned selection adapter=$adapter provider=$($selected.Provider) model_id=$pinId; preflight revalidated"
} elseif ($provider) {
    $candidates=@($eligible|Where-Object{$_.Provider -eq $provider -or (Text (P $_.Model 'adapter')) -eq $provider -or (Text (P $_.Model 'vendor')) -eq $provider})
    if (-not $candidates.Count) { Fail "explicit provider '$provider' is not eligible; no silent fallback is permitted" 3 }
    $selected=$candidates|Sort-Object Score,@{Expression={if($null -eq $_.Remaining){-1}else{-[double]$_.Remaining}}},Provider,Id|Select-Object -First 1; $reason="explicit provider '$provider' selected after eligibility checks; no fallback"
} else {
    $selected=$eligible|Sort-Object Score,@{Expression={if($null -eq $_.Remaining){-1}else{-[double]$_.Remaining}}},Provider,Id|Select-Object -First 1
    $reason="selected by preference=$preference, capability match, and remaining capacity; estimate units=$requiredUnits (assignment=$assignmentUnits, verification=$verificationUnits, retry=$retryUnits)"
}

$usage=P $selected.Preflight 'usage'
$selection=[ordered]@{ protocol_version=2; adapter=$adapter; adapter_revision=$adapterRevision; vendor=$vendor; provider=$selected.Provider; model_id=$selected.Id; model=$selected.Id; family_hint=Text (P $selected.Model 'family_hint'); preference=$preference; effort=$effort; catalog_revision=$catalogRevision; policy_revision=Text (P $policy 'policy_revision'); required_capabilities=@($requiredCapabilities); selection_reason=$reason; route=Text (P $request 'route'); eligibility='eligible'; eligibility_reason='verified access, active entitlement, compatible capabilities, and sufficient capacity'; preflight=$selected.Preflight; capacity_estimate=[ordered]@{version=$estimateVersion;assignment_units=$assignmentUnits;verification_units=$verificationUnits;retry_units=$retryUnits;required_units=$requiredUnits;freshness_seconds=$freshness}; usage_observed_at=Text (P $usage 'observed_at'); usage_uncertain=(-not $selected.UsageKnown); reservation=[ordered]@{required_units=$requiredUnits;scopes=@((P $usage 'scopes')|ForEach-Object{Text (P $_ 'scope_id')})} }
$json=$selection|ConvertTo-Json -Depth 50; [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($outputPath),$json,[System.Text.Encoding]::UTF8); [Console]::Out.Write($json)
