$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) ("offload-capacity-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw "FAIL: $message" }
    Write-Output "ok - $message"
}

function Invoke-Ledger([string]$command, [string[]]$arguments) {
    $script = Join-Path $root 'scripts/capacity-ledger.ps1'
    $output = & pwsh -NoProfile -File $script $command @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ledger $command failed: $($output -join "`n")" }
    return ($output -join "`n") | ConvertFrom-Json -Depth 30
}

try {
    $ledger = Join-Path $temp 'capacity.json'
    $selection = Join-Path $temp 'selection.json'
    $selectionValue = [ordered]@{
        protocol_version = 2
        adapter = 'test-adapter'
        adapter_revision = 'test-2'
        vendor = 'test-provider'
        provider = 'test-provider'
        model_id = 'test-model'
        policy_revision = 'test-policy'
        catalog_revision = 'test-catalog'
        usage_observed_at = [DateTime]::UtcNow.ToString('o')
        usage_uncertain = $false
        preflight = [ordered]@{ usage = [ordered]@{ scopes = @([ordered]@{ scope_id = 'shared-window'; remaining_units = 4; reserved_units = 0 }) } }
        capacity_estimate = [ordered]@{ required_units = 3 }
        reservation = [ordered]@{ required_units = 3; scopes = @('shared-window') }
    }
    $selectionValue | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $selection -Encoding utf8

    Invoke-Ledger 'init' @('--ledger', $ledger) | Out-Null
    $first = Invoke-Ledger 'reserve' @('--ledger', $ledger, '--selection', $selection, '--reservation-id', 'first')
    Assert-True ($first.state -eq 'active') 'reservation starts active'
    Assert-True ($first.evidence.usage_uncertain -eq $false) 'reservation records usage certainty'

    $secondError = & pwsh -NoProfile -File (Join-Path $root 'scripts/capacity-ledger.ps1') reserve --ledger $ledger --selection $selection --reservation-id second 2>&1
    Assert-True ($LASTEXITCODE -eq 4) 'competing reservation is rejected atomically'

    $completed = Invoke-Ledger 'reconcile' @('--ledger', $ledger, '--reservation-id', 'first', '--state', 'completed', '--reason', 'worker completed')
    Assert-True ($completed.state -eq 'completed') 'completed reservation releases capacity'

    $second = Invoke-Ledger 'reserve' @('--ledger', $ledger, '--selection', $selection, '--reservation-id', 'second')
    Assert-True ($second.state -eq 'active') 'released capacity can be reserved again'
    $recovered = Invoke-Ledger 'reconcile' @('--ledger', $ledger, '--reservation-id', 'second', '--state', 'recovered', '--reason', 'launcher recovery')
    Assert-True ($recovered.state -eq 'recovered') 'recovery is a terminal reservation state'

    $raw = Get-Content -LiteralPath $ledger -Raw
    Assert-True ($raw -notmatch 'secret|token|password|api[_-]?key') 'ledger contains no credential-shaped fields'
    Write-Output 'capacity ledger checks passed'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
