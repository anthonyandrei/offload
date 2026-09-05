#!/usr/bin/env pwsh
# Shared worker capacity reservations. The ledger stores no credentials.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Fail([string]$Message, [int]$Code = 2) {
    [Console]::Error.WriteLine("ERROR: $Message")
    exit $Code
}

function Usage {
    [Console]::Error.WriteLine('Usage: capacity-ledger.ps1 init|reserve|release|reconcile --ledger PATH [--selection PATH] [--reservation-id ID] [--state completed|cancelled|failed|recovered] [--reason TEXT]')
}

function Now { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Full([string]$Path) { [IO.Path]::GetFullPath($Path) }

function AtomicWrite([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $tmp = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($tmp, (($Value | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function ReadLedger([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [ordered]@{ schema_version = 1; ledger = 'worker-capacity'; created_at = (Now); updated_at = (Now); reservations = @() } }
    try { $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 30 } catch { Fail "invalid capacity ledger JSON: $Path" }
    if ($value.schema_version -ne 1 -or $value.ledger -ne 'worker-capacity') { Fail "unsupported capacity ledger: $Path" }
    if ($null -eq $value.reservations) { $value | Add-Member -NotePropertyName reservations -NotePropertyValue @() }
    return $value
}

function WithLock([string]$Path, [scriptblock]$Action) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $lockPath = "$Path.lock"
    $stream = $null
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        try { $stream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None); break } catch { Start-Sleep -Milliseconds 50 }
    }
    if ($null -eq $stream) { Fail "could not lock capacity ledger: $Path" 4 }
    try { & $Action } finally { $stream.Dispose() }
}

function ParseArgs([string[]]$InputArgs) {
    if ($InputArgs.Count -lt 1) { Usage; exit 2 }
    $result = @{ command = [string]$InputArgs[0] }
    $i = 1
    while ($i -lt $InputArgs.Count) {
        $arg = [string]$InputArgs[$i]
        if (-not $arg.StartsWith('--') -or $i + 1 -ge $InputArgs.Count) { Fail "invalid argument: $arg" }
        $result[$arg.Substring(2)] = [string]$InputArgs[$i + 1]
        $i += 2
    }
    return $result
}

$options = ParseArgs $args
$command = [string]$options.command
if ($command -notin @('init', 'reserve', 'release', 'reconcile')) { Usage; exit 2 }
if (-not $options.ContainsKey('ledger')) { Fail '--ledger is required' }
$ledgerPath = Full ([string]$options.ledger)

WithLock $ledgerPath {
    $ledger = ReadLedger $ledgerPath
    if ($command -eq 'init') {
        AtomicWrite $ledgerPath $ledger
        [Console]::Out.WriteLine(($ledger | ConvertTo-Json -Depth 30 -Compress))
        return
    }

    if ($command -eq 'reserve') {
        if (-not $options.ContainsKey('selection')) { Fail '--selection is required for reserve' }
        $selectionPath = Full ([string]$options.selection)
        try { $selection = Get-Content -LiteralPath $selectionPath -Raw | ConvertFrom-Json -Depth 30 } catch { Fail "invalid selection JSON: $selectionPath" }
        if ($selection.protocol_version -ne 2 -or [string]::IsNullOrWhiteSpace([string]$selection.model_id)) { Fail 'selection must use protocol 2 and include model_id' 4 }
        $units = [int]$selection.capacity_estimate.required_units
        if ($units -le 0) { Fail 'selection capacity estimate must be positive' 4 }
        $reservationId = if ($options.ContainsKey('reservation-id')) { [string]$options.'reservation-id' } else { "reservation-$([Guid]::NewGuid().ToString('N'))" }
        if (@($ledger.reservations | Where-Object { $_.reservation_id -eq $reservationId }).Count -gt 0) { Fail "reservation already exists: $reservationId" 4 }
        $scopeIds = @($selection.reservation.scopes | ForEach-Object { [string]$_ } | Where-Object { $_ })
        $active = @($ledger.reservations | Where-Object { $_.state -eq 'active' -and $_.provider -eq $selection.provider -and $_.model_id -eq $selection.model_id })
        foreach ($scopeId in $scopeIds) {
            $scope = @($selection.preflight.usage.scopes | Where-Object { [string]$_.scope_id -eq $scopeId }) | Select-Object -First 1
            if ($null -eq $scope) { Fail "selection is missing capacity scope: $scopeId" 4 }
            $alreadyReserved = 0
            foreach ($record in $active) { if (@($record.scopes | Where-Object { [string]$_ -eq $scopeId }).Count -gt 0) { $alreadyReserved += [int]$record.required_units } }
            $available = [double]$scope.remaining_units - [double]$scope.reserved_units - $alreadyReserved
            if ($available -lt $units) { Fail "capacity reservation rejected for scope $scopeId" 4 }
        }
        $record = [ordered]@{ reservation_id = $reservationId; state = 'active'; provider = [string]$selection.provider; model_id = [string]$selection.model_id; required_units = $units; scopes = $scopeIds; created_at = (Now); updated_at = (Now); released_at = $null; release_reason = $null; evidence = [ordered]@{ adapter = [string]$selection.adapter; adapter_revision = [string]$selection.adapter_revision; catalog_revision = [string]$selection.catalog_revision; policy_revision = [string]$selection.policy_revision; usage_observed_at = [string]$selection.usage_observed_at; usage_uncertain = [bool]$selection.usage_uncertain } }
        $ledger.reservations = @($ledger.reservations) + @([PSCustomObject]$record); $ledger.updated_at = Now; AtomicWrite $ledgerPath $ledger
        [Console]::Out.WriteLine(($record | ConvertTo-Json -Depth 30 -Compress)); return
    }

    if (-not $options.ContainsKey('reservation-id')) { Fail '--reservation-id is required' }
    $reservationId = [string]$options.'reservation-id'
    $record = @($ledger.reservations | Where-Object { $_.reservation_id -eq $reservationId }) | Select-Object -First 1
    if ($null -eq $record) { Fail "reservation not found: $reservationId" 4 }
    if ($command -eq 'release') { $state = 'released' } else { $state = if ($options.ContainsKey('state')) { [string]$options.state } else { 'recovered' } }
    if ($state -notin @('released', 'completed', 'cancelled', 'failed', 'recovered')) { Fail "invalid terminal state: $state" }
    $record.state = $state; $record.updated_at = Now; $record.released_at = Now; $record.release_reason = if ($options.ContainsKey('reason')) { [string]$options.reason } else { $state }
    $ledger.updated_at = Now; AtomicWrite $ledgerPath $ledger
    [Console]::Out.WriteLine(($record | ConvertTo-Json -Depth 30 -Compress))
}
