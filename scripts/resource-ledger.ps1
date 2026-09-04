#!/usr/bin/env pwsh
# scripts/resource-ledger.ps1
# Durable, orchestrator-owned ownership ledger for worker resources.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:LedgerMarker = 'offload-resource-ledger-v1'
$script:KnownStates = @('registered', 'active', 'completed', 'failed', 'timed_out', 'cancelled', 'quota_handoff', 'cleanup_pending', 'removed', 'retained', 'unknown', 'dirty', 'unmerged', 'ambiguous')

function Fail([string]$message, [int]$exitCode = 1) {
    [Console]::Error.WriteLine("Error: $message")
    exit $exitCode
}

function Usage {
    [Console]::Error.WriteLine(@"
Usage:
  resource-ledger.ps1 init --ledger PATH
  resource-ledger.ps1 register --ledger PATH --assignment-id ID --parent-id ID --resource-type TYPE --owner-marker NAME=VALUE (--path PATH | --process-id PID) [--parent-path PATH] [--resource-id ID] [--state STATE]
  resource-ledger.ps1 update --ledger PATH --resource-id ID --state STATE [--allow-dirty true|false] [--error MESSAGE]
  resource-ledger.ps1 cleanup --ledger PATH --resource-id ID
  resource-ledger.ps1 reconcile --ledger PATH [--source-repo PATH ...]
"@)
}

function Canonical([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function IsoNow { return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Ensure-Parent([string]$Path) {
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
}

function Atomic-Write([string]$Path, $Value) {
    Ensure-Parent $Path
    $tmp = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    $json = $Value | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($tmp, "$json`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-Ledger([string]$Path) {
    $canon = Canonical $Path
    if (-not (Test-Path -LiteralPath $canon -PathType Leaf)) { Fail "ledger file does not exist: $Path" }
    try { $ledger = Get-Content -LiteralPath $canon -Raw | ConvertFrom-Json -Depth 20 } catch { Fail "invalid ledger JSON: $Path ($($_.Exception.Message))" }
    if ($null -eq $ledger -or $ledger.marker -ne $script:LedgerMarker -or $ledger.schema_version -ne 1) { Fail "invalid resource ledger marker or schema: $Path" }
    if ($null -eq $ledger.resources) { $ledger | Add-Member -NotePropertyName resources -NotePropertyValue @() }
    return $ledger
}

function Write-Ledger([string]$Path, $Ledger) {
    $Ledger.updated_at = IsoNow
    Atomic-Write (Canonical $Path) $Ledger
}

function Test-Within([string]$Child, [string]$Parent) {
    $c = Canonical $Child; $p = Canonical $Parent
    if ([string]::IsNullOrWhiteSpace($c) -or [string]::IsNullOrWhiteSpace($p)) { return $false }
    if ([string]::Equals($c, $p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $c.StartsWith("$p$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)
}

function Assert-Ledger-Outside([string]$Ledger, [string]$ResourcePath) {
    if ([string]::IsNullOrWhiteSpace($ResourcePath)) { return }
    if (Test-Within (Canonical $Ledger) (Canonical $ResourcePath)) { Fail "ledger must be outside the resource path: $Ledger" }
}

function Get-OwnerMarker($Record) {
    if ($null -eq $Record.owner_marker) { return $null }
    $name = [string]$Record.owner_marker.name
    $value = [string]$Record.owner_marker.value
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($value)) { return $null }
    return @{ name = $name; value = $value }
}

function Test-ReparseTree([string]$Path) {
    $root = Get-Item -LiteralPath $Path -Force
    if ($root.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { return $true }
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
        if ($item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { return $true }
        if ($item.PSIsContainer -and (Test-ReparseTree $item.FullName)) { return $true }
    }
    return $false
}

function Run-Git([string]$WorkingDir, [string[]]$GitArgs) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'; $psi.WorkingDirectory = $WorkingDir; $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    foreach ($a in $GitArgs) { $psi.ArgumentList.Add($a) }
    $p = [Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEnd(); $e = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    return [PSCustomObject]@{ ExitCode = $p.ExitCode; Stdout = $o; Stderr = $e }
}

function Get-Resource($Ledger, [string]$Id) {
    return @($Ledger.resources | Where-Object { $_.resource_id -eq $Id }) | Select-Object -First 1
}

function New-Ledger([string]$Path) {
    $canon = Canonical $Path
    if (Test-Path -LiteralPath $canon -PathType Leaf) { Read-Ledger $canon | Out-Null; return }
    Atomic-Write $canon ([ordered]@{ schema_version = 1; marker = $script:LedgerMarker; ledger_id = [Guid]::NewGuid().ToString('N'); created_at = IsoNow; updated_at = IsoNow; resources = @() })
}

function Parse-Args([string[]]$InputArgs) {
    $v = @{}; $pos = @{}; $i = 0
    while ($i -lt $InputArgs.Count) {
        $a = [string]$InputArgs[$i]
        if (-not $a.StartsWith('--')) { Fail "unexpected argument: $a" }
        if ($a.Contains('=')) { $parts = $a.Substring(2).Split('=', 2); $v[$parts[0]] = $parts[1] }
        else { $key = $a.Substring(2); $i++; if ($i -ge $InputArgs.Count) { Fail "--$key requires a value" }; $v[$key] = [string]$InputArgs[$i] }
        $i++
    }
    return $v
}

function Require($Options, [string]$Name) {
    if (-not $Options.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace([string]$Options[$Name])) { Fail "--$Name is required" }
    return [string]$Options[$Name]
}

function Cmd-Register($o) {
    $ledgerPath = Canonical (Require $o 'ledger'); $assignment = Require $o 'assignment-id'; $parent = Require $o 'parent-id'; $type = Require $o 'resource-type'; $markerRaw = Require $o 'owner-marker'
    $markerParts = $markerRaw.Split('=', 2); if ($markerParts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($markerParts[0]) -or [string]::IsNullOrWhiteSpace($markerParts[1])) { Fail '--owner-marker must be NAME=VALUE' }
    $resourcePath = if ($o.ContainsKey('path')) { Canonical ([string]$o['path']) } else { '' }
    $processId = if ($o.ContainsKey('process-id')) { [int]$o['process-id'] } else { 0 }
    if ([string]::IsNullOrWhiteSpace($resourcePath) -and $processId -le 0) { Fail 'one of --path or --process-id is required' }
    Assert-Ledger-Outside $ledgerPath $resourcePath
    $state = if ($o.ContainsKey('state')) { [string]$o['state'] } else { 'registered' }
    if ($script:KnownStates -notcontains $state) { Fail "invalid resource state: $state" }
    $ledger = if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) { Read-Ledger $ledgerPath } else { New-Ledger $ledgerPath; Read-Ledger $ledgerPath }
    $id = if ($o.ContainsKey('resource-id')) { [string]$o['resource-id'] } else { "${type}:$([Guid]::NewGuid().ToString('N'))" }
    $existing = Get-Resource $ledger $id
    $now = IsoNow
    $record = [ordered]@{ resource_id = $id; assignment_id = $assignment; parent_id = $parent; parent_path = if ($o.ContainsKey('parent-path')) { Canonical ([string]$o['parent-path']) } else { $null }; resource_type = $type; path = if ($resourcePath) { $resourcePath } else { $null }; process_identity = if ($processId -gt 0) { [ordered]@{ pid = $processId; start_time = if ($o.ContainsKey('process-start-time')) { [string]$o['process-start-time'] } else { $null } } } else { $null }; owner_marker = [ordered]@{ name = $markerParts[0]; value = $markerParts[1] }; state = $state; allow_dirty = $false; created_at = $now; updated_at = $now; cleanup_attempts = 0; last_error = $null }
    if ($null -ne $existing) { foreach ($p in $record.Keys) { $existing | Add-Member -Force -NotePropertyName $p -NotePropertyValue $record[$p] } } else { $ledger.resources = @($ledger.resources) + @([PSCustomObject]$record) }
    Write-Ledger $ledgerPath $ledger
    [Console]::Out.WriteLine(($record | ConvertTo-Json -Depth 8 -Compress))
}

function Cmd-Update($o) {
    $ledgerPath = Canonical (Require $o 'ledger'); $id = Require $o 'resource-id'; $state = Require $o 'state'
    if ($script:KnownStates -notcontains $state) { Fail "invalid resource state: $state" }
    $ledger = Read-Ledger $ledgerPath; $record = Get-Resource $ledger $id
    if ($null -eq $record) { Fail "resource not found in ledger: $id" }
    $record.state = $state; $record.updated_at = IsoNow
    if ($o.ContainsKey('allow-dirty')) { $record.allow_dirty = ([string]$o['allow-dirty']).ToLowerInvariant() -eq 'true' }
    if ($o.ContainsKey('error')) { $record.last_error = [string]$o['error'] }
    Write-Ledger $ledgerPath $ledger
    [Console]::Out.WriteLine(($record | ConvertTo-Json -Depth 8 -Compress))
}

function Test-ProcessIdentity($Record) {
    if ($null -eq $Record.process_identity -or [int]$Record.process_identity.pid -le 0) { return $false }
    try {
        $p = Get-Process -Id ([int]$Record.process_identity.pid) -ErrorAction Stop
        if ($null -ne $Record.process_identity.start_time -and -not [string]::IsNullOrWhiteSpace([string]$Record.process_identity.start_time)) {
            $storedStart = $Record.process_identity.start_time
            if ($storedStart -is [DateTime]) {
                $expected = ([DateTime]$storedStart).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss')
            } else {
                $expected = [DateTimeOffset]::Parse([string]$storedStart).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss')
            }
            $actual = $p.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss')
            return $actual -eq $expected
        }
        return $true
    } catch { return $false }
}

function Stop-OwnedProcess($Record) {
    if ($null -eq $Record.process_identity -or [int]$Record.process_identity.pid -le 0) { return $true }
    $processId = [int]$Record.process_identity.pid
    if ($processId -eq $PID) { return $false }
    $p = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $true }
    if ($null -ne $Record.process_identity.start_time -and -not [string]::IsNullOrWhiteSpace([string]$Record.process_identity.start_time) -and -not (Test-ProcessIdentity $Record)) { return $false }
    try { Stop-Process -Id $processId -Force -ErrorAction Stop } catch { try { $p.Kill($true) } catch { } }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 100
        $remaining = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $remaining) { return $true }
        if ($IsWindows) { try { & taskkill.exe /PID $processId /T /F | Out-Null } catch { } }
    } while ([DateTime]::UtcNow -lt $deadline)
    return ($null -eq (Get-Process -Id $processId -ErrorAction SilentlyContinue))
}

function Get-WorktreeRegistered([string]$Repo, [string]$Path) {
    $result = Run-Git $Repo @('worktree', 'list', '--porcelain')
    if ($result.ExitCode -ne 0) { return $false }
    foreach ($line in $result.Stdout -split "`n") { if ($line.Trim().StartsWith('worktree ')) { if ([string]::Equals((Canonical $line.Trim().Substring(9)), (Canonical $Path), [StringComparison]::OrdinalIgnoreCase)) { return $true } } }
    return $false
}

function Get-GitRoot([string]$Path) {
    $result = Run-Git $Path @('rev-parse', '--show-toplevel')
    if ($result.ExitCode -ne 0) { return '' }
    return Canonical $result.Stdout.Trim()
}

function Classify-And-Cleanup($Ledger, $Record, [string]$LedgerPath) {
    $result = [ordered]@{ resource_id = $Record.resource_id; state = [string]$Record.state; removed = $false; retained = $false; reason = $null }
    if ($Record.state -in @('removed', 'retained', 'unknown', 'dirty', 'unmerged', 'ambiguous')) { $result.retained = $Record.state -ne 'removed'; $result.reason = "already-$($Record.state)"; return $result }
    $Record.updated_at = IsoNow
    if ($null -ne $Record.process_identity -and [int]$Record.process_identity.pid -gt 0 -and [int]$Record.process_identity.pid -ne $PID -and -not (Test-ProcessIdentity $Record)) { $result.retained = $true; $result.reason = 'process identity does not match'; $Record.state = 'retained'; $result.state = 'retained'; $Record.last_error = $result.reason; return $result }
    if (-not (Stop-OwnedProcess $Record)) { $result.retained = $true; $result.reason = 'owned process is still running or could not be terminated'; $Record.state = 'retained'; $result.state = 'retained'; $Record.last_error = $result.reason; return $result }
    $path = [string]$Record.path
    if ([string]::IsNullOrWhiteSpace($path)) { $Record.state = 'removed'; $result.state = 'removed'; $result.removed = $true; return $result }
    $canon = Canonical $path
    if (-not (Test-Path -LiteralPath $canon -PathType Container)) { $Record.state = 'removed'; $result.state = 'removed'; $result.removed = $true; $result.reason = 'path already absent'; return $result }
    $root = Canonical ([IO.Path]::GetPathRoot($canon)); $cwd = Canonical (Get-Location).Path
    $protectedHomes = @($env:USERPROFILE, $env:HOME) | Where-Object { $_ } | ForEach-Object { Canonical $_ }
    if ([string]::Equals($canon, $root, [StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($canon, $cwd, [StringComparison]::OrdinalIgnoreCase) -or $protectedHomes -contains $canon) { $result.retained = $true; $result.reason = 'protected path'; $Record.state = 'ambiguous'; $result.state = 'ambiguous'; $Record.last_error = $result.reason; return $result }
    if ($null -eq (Get-OwnerMarker $Record)) { $result.retained = $true; $result.reason = 'owner marker is missing or invalid'; $Record.state = 'unknown'; $result.state = 'unknown'; $Record.last_error = $result.reason; return $result }
    $marker = Get-OwnerMarker $Record; $markerFile = Join-Path $canon $marker.name
    if (-not (Test-Path -LiteralPath $markerFile -PathType Leaf) -or ([IO.File]::ReadAllText($markerFile)).Trim() -ne $marker.value) { $result.retained = $true; $result.reason = 'owner marker does not match'; $Record.state = 'unknown'; $result.state = 'unknown'; $Record.last_error = $result.reason; return $result }
    if (Test-ReparseTree $canon) { $result.retained = $true; $result.reason = 'resource contains a reparse point'; $Record.state = 'ambiguous'; $result.state = 'ambiguous'; $Record.last_error = $result.reason; return $result }
    if (-not [string]::IsNullOrWhiteSpace([string]$Record.parent_path)) {
        $parent = Canonical ([string]$Record.parent_path)
        if ([string]::Equals($canon, $parent, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $parent -PathType Container)) { $result.retained = $true; $result.reason = 'invalid parent repository'; $Record.state = 'ambiguous'; $result.state = 'ambiguous'; $Record.last_error = $result.reason; return $result }
        if ($Record.resource_type -eq 'git-worktree' -and -not (Get-WorktreeRegistered $parent $canon)) { $result.retained = $true; $result.reason = 'worktree is not registered with its parent repository'; $Record.state = 'ambiguous'; $result.state = 'ambiguous'; $Record.last_error = $result.reason; return $result }
        if ($Record.resource_type -eq 'git-worktree' -and -not $Record.allow_dirty) {
            $dirty = Run-Git $canon @('status', '--porcelain'); $unmerged = Run-Git $canon @('ls-files', '-u')
            if (-not [string]::IsNullOrWhiteSpace($dirty.Stdout)) { $result.retained = $true; $result.reason = 'worktree is dirty'; $Record.state = 'dirty'; $result.state = 'dirty'; $Record.last_error = $result.reason; return $result }
            if (-not [string]::IsNullOrWhiteSpace($unmerged.Stdout) -or (Test-Path -LiteralPath (Join-Path $canon '.git\MERGE_HEAD'))) { $result.retained = $true; $result.reason = 'worktree has an unmerged state'; $Record.state = 'unmerged'; $result.state = 'unmerged'; $Record.last_error = $result.reason; return $result }
        }
    }
    if ($Record.resource_type -ne 'git-worktree' -and [string]::Equals((Get-GitRoot $canon), $canon, [StringComparison]::OrdinalIgnoreCase)) { $result.retained = $true; $result.reason = 'resource is a git checkout'; $Record.state = 'ambiguous'; $result.state = 'ambiguous'; $Record.last_error = $result.reason; return $result }
    try {
        if ($Record.resource_type -eq 'git-worktree') { Run-Git (Canonical $Record.parent_path) @('worktree', 'remove', '--force', $canon) | Out-Null; Run-Git (Canonical $Record.parent_path) @('worktree', 'prune') | Out-Null } else { Remove-Item -LiteralPath $canon -Recurse -Force }
        $Record.state = 'removed'; $Record.updated_at = IsoNow; $result.state = 'removed'; $result.removed = $true
    } catch { $result.retained = $true; $result.reason = $_.Exception.Message; $Record.state = 'retained'; $result.state = 'retained'; $Record.last_error = $result.reason }
    return $result
}

function Cmd-Cleanup($o) {
    $ledgerPath = Canonical (Require $o 'ledger'); $id = Require $o 'resource-id'; $ledger = Read-Ledger $ledgerPath; $record = Get-Resource $ledger $id
    if ($null -eq $record) { Fail "resource not found in ledger: $id" }
    $record.cleanup_attempts = [int]$record.cleanup_attempts + 1
    $result = Classify-And-Cleanup $ledger $record $ledgerPath; Write-Ledger $ledgerPath $ledger; [Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 8 -Compress))
}

function Cmd-Reconcile($o) {
    $ledgerPath = Canonical (Require $o 'ledger'); $ledger = Read-Ledger $ledgerPath; $results = [System.Collections.Generic.List[object]]::new()
    $repos = @(); foreach ($key in $o.Keys) { if ($key -eq 'source-repo') { $repos += Canonical ([string]$o[$key]) } }
    foreach ($repo in $repos) {
        if (-not (Test-Path -LiteralPath $repo -PathType Container)) { continue }
        $wt = Run-Git $repo @('worktree', 'list', '--porcelain'); if ($wt.ExitCode -ne 0) { continue }
        foreach ($line in $wt.Stdout -split "`n") {
            if (-not $line.Trim().StartsWith('worktree ')) { continue }
            $path = Canonical $line.Trim().Substring(9); if ([string]::Equals($path, $repo, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $known = @($ledger.resources | Where-Object { [string]::Equals([string]$_.path, $path, [StringComparison]::OrdinalIgnoreCase) })
            if ($known.Count -eq 0) {
                $ledger.resources = @($ledger.resources) + @([PSCustomObject][ordered]@{ resource_id = "unknown-worktree:$([Guid]::NewGuid().ToString('N'))"; assignment_id = 'unknown'; parent_id = $repo; parent_path = $repo; resource_type = 'git-worktree'; path = $path; process_identity = $null; owner_marker = [ordered]@{ name = ''; value = '' }; state = 'unknown'; allow_dirty = $false; created_at = IsoNow; updated_at = IsoNow; cleanup_attempts = 0; last_error = 'worktree was not present in the ownership ledger' })
                $results.Add([ordered]@{ path = $path; state = 'unknown'; retained = $true; removed = $false })
            }
        }
    }
    $pending = @($ledger.resources | Where-Object { $_.state -notin @('removed', 'retained', 'unknown', 'dirty', 'unmerged', 'ambiguous') })
    foreach ($record in @($pending | Where-Object { $_.resource_type -eq 'worker-process' }) + @($pending | Where-Object { $_.resource_type -ne 'worker-process' })) { $record.cleanup_attempts = [int]$record.cleanup_attempts + 1; $results.Add((Classify-And-Cleanup $ledger $record $ledgerPath)) }
    Write-Ledger $ledgerPath $ledger; [Console]::Out.WriteLine((@($results) | ConvertTo-Json -Depth 8 -Compress))
}

if ($args.Count -eq 0) { Usage; exit 1 }
$verb = [string]$args[0]; $options = if ($args.Count -gt 1) { Parse-Args ([string[]]$args[1..($args.Count - 1)]) } else { @{} }
switch ($verb) {
    'init' { New-Ledger (Require $options 'ledger'); [Console]::Out.WriteLine((@{ ledger = Canonical (Require $options 'ledger'); state = 'ready' } | ConvertTo-Json -Compress)) }
    'register' { Cmd-Register $options }
    'update' { Cmd-Update $options }
    'cleanup' { Cmd-Cleanup $options }
    'reconcile' { Cmd-Reconcile $options }
    '-h' { Usage; exit 0 }
    '--help' { Usage; exit 0 }
    default { Fail "unrecognized command: $verb" }
}
