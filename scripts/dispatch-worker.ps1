#!/usr/bin/env pwsh
# scripts/dispatch-worker.ps1
# Orchestrator-only assignment admission, worktree creation, and worker launch.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:StateMarker = 'offload-dispatch-state-v1'
$script:ScriptDir = Split-Path -Parent $PSCommandPath
$script:RootDir = Split-Path -Parent $script:ScriptDir
$script:Launcher = Join-Path $script:ScriptDir 'run-agy-json.ps1'
$script:WorkspaceHelper = Join-Path $script:ScriptDir 'execution-workspace.ps1'

function Fail([string]$message, [int]$exitCode = 2) {
    [Console]::Error.WriteLine("Error: $message")
    exit $exitCode
}

function Usage {
    [Console]::Error.WriteLine(@"
Usage:
  dispatch-worker.ps1 --state FILE --assignment-id ID [--parent-assignment-id ID]
    --role ROLE --source-repo DIR --baseline REV --owned PATH [--owned PATH ...]
    --output FILE --error FILE --timeout-seconds N --resource-units N
    [--max-depth N --max-width N --max-timeout-seconds N --max-resource-units N]
    [--frozen PATH ...] [--workspace-dir DIR] [--workspace-manifest FILE] -- agy-arguments...
"@)
}

function Get-Now {
    return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Write-JsonFile([string]$path, $value) {
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $tmp = "$path.$PID.tmp"
    $json = $value | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($tmp, "$json`n", [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Acquire-StateLock([string]$statePath) {
    $lockPath = "$statePath.lock"
    $parent = Split-Path -Parent $statePath
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $started = [DateTime]::UtcNow
    while ($true) {
        try {
            $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $lockStream.Dispose()
            return $lockPath
        } catch [System.IO.IOException] {
            if (([DateTime]::UtcNow - $started).TotalSeconds -ge 15) {
                Fail "timed out acquiring dispatch ledger lock: $statePath" 1
            }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Release-StateLock([string]$lockPath) {
    if ($lockPath -and (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

function New-State([int]$maxDepth, [int]$maxWidth, [int]$maxTimeout, [int]$maxResources) {
    return [ordered]@{
        schema_version = 1
        marker = $script:StateMarker
        limits = [ordered]@{
            max_depth = $maxDepth
            max_width = $maxWidth
            max_timeout_seconds = $maxTimeout
            max_resource_units = $maxResources
        }
        assignments = @()
        events = @()
        created_at = Get-Now
    }
}

function Read-State([string]$statePath, [bool]$create, [int]$maxDepth, [int]$maxWidth, [int]$maxTimeout, [int]$maxResources) {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        if (-not $create) { Fail "dispatch ledger does not exist: $statePath" }
        return New-State $maxDepth $maxWidth $maxTimeout $maxResources
    }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    } catch {
        Fail "dispatch ledger is not valid JSON: $statePath"
    }
    if ($null -eq $state -or $state.marker -ne $script:StateMarker -or $state.schema_version -ne 1) {
        Fail "invalid dispatch ledger: $statePath"
    }
    if ($null -eq $state.limits -or $null -eq $state.assignments -or $null -eq $state.events) {
        Fail "dispatch ledger is missing limits, assignments, or events: $statePath"
    }
    return $state
}

function Record-Rejection([string]$statePath, [string]$assignmentId, [string]$reason, [hashtable]$request) {
    if ([string]::IsNullOrWhiteSpace($statePath) -or -not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return }
    $lock = Acquire-StateLock $statePath
    try {
        $state = Read-State $statePath $false 0 0 0 0
        $event = [ordered]@{
            type = 'nested_dispatch_rejected'
            actor = if ($env:OFFLOAD_WORKER_CONTEXT -eq '1') { 'worker' } else { 'orchestrator' }
            assignment_id = $assignmentId
            reason = $reason
            request = $request
            recorded_at = Get-Now
        }
        $state.events = @($state.events) + $event
        Write-JsonFile $statePath $state
    } finally {
        Release-StateLock $lock
    }
}

function Parse-PositiveInt([string]$name, [string]$value, [bool]$allowZero = $false) {
    $number = 0
    if (-not [int]::TryParse($value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        Fail "$name must be an integer: $value"
    }
    if (($allowZero -and $number -lt 0) -or (-not $allowZero -and $number -le 0)) {
        $kind = if ($allowZero) { 'non-negative' } else { 'positive' }
        Fail "$name must be $kind"
    }
    return $number
}

$statePath = ''
$assignmentId = ''
$parentId = ''
$role = ''
$sourceRepo = ''
$baseline = ''
$outputPath = ''
$errorPath = ''
$workspaceDir = ''
$workspaceManifest = ''
$owned = [System.Collections.Generic.List[string]]::new()
$frozen = [System.Collections.Generic.List[string]]::new()
$workerArgs = [System.Collections.Generic.List[string]]::new()
$maxDepthArg = $null
$maxWidthArg = $null
$maxTimeoutArg = $null
$maxResourcesArg = $null
$depthArg = $null
$timeoutArg = $null
$resourcesArg = $null
$afterDelimiter = $false

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    if ($afterDelimiter) {
        $workerArgs.Add($arg)
        $i++
        continue
    }
    if ($arg -eq '--') { $afterDelimiter = $true; $i++; continue }
    $value = $null
    $name = $arg
    if ($arg -match '^([^=]+)=(.*)$') { $name = $Matches[1]; $value = $Matches[2] }
    $takesValue = @('--state','--assignment-id','--parent-assignment-id','--role','--source-repo','--baseline','--owned','--frozen','--output','--error','--workspace-dir','--workspace-manifest','--max-depth','--max-width','--max-timeout-seconds','--max-resource-units','--depth','--timeout-seconds','--resource-units') -contains $name
    if (-not $takesValue) { Usage; Fail "unknown dispatcher option: $arg" }
    if ($null -eq $value) {
        if ($i + 1 -ge $args.Count) { Usage; Fail "$name requires a value" }
        $i++
        $value = [string]$args[$i]
    }
    switch ($name) {
        '--state' { $statePath = $value }
        '--assignment-id' { $assignmentId = $value }
        '--parent-assignment-id' { $parentId = $value }
        '--role' { $role = $value }
        '--source-repo' { $sourceRepo = $value }
        '--baseline' { $baseline = $value }
        '--owned' { $owned.Add($value) }
        '--frozen' { $frozen.Add($value) }
        '--output' { $outputPath = $value }
        '--error' { $errorPath = $value }
        '--workspace-dir' { $workspaceDir = $value }
        '--workspace-manifest' { $workspaceManifest = $value }
        '--max-depth' { $maxDepthArg = Parse-PositiveInt $name $value $true }
        '--max-width' { $maxWidthArg = Parse-PositiveInt $name $value $false }
        '--max-timeout-seconds' { $maxTimeoutArg = Parse-PositiveInt $name $value $false }
        '--max-resource-units' { $maxResourcesArg = Parse-PositiveInt $name $value $false }
        '--depth' { $depthArg = Parse-PositiveInt $name $value $true }
        '--timeout-seconds' { $timeoutArg = Parse-PositiveInt $name $value $false }
        '--resource-units' { $resourcesArg = Parse-PositiveInt $name $value $false }
    }
    $i++
}

if (-not $afterDelimiter) { Usage; Fail "-- delimiter is required" }
if ($workerArgs.Count -eq 0) { Usage; Fail "agy arguments are required after --" }
foreach ($required in @(@{n='--state';v=$statePath}, @{n='--assignment-id';v=$assignmentId}, @{n='--role';v=$role}, @{n='--source-repo';v=$sourceRepo}, @{n='--baseline';v=$baseline}, @{n='--output';v=$outputPath}, @{n='--error';v=$errorPath})) {
    if ([string]::IsNullOrWhiteSpace($required.v)) { Usage; Fail "$($required.n) is required" }
}
if ($owned.Count -eq 0) { Fail 'at least one --owned path is required' }
if ($null -eq $timeoutArg) { Fail '--timeout-seconds is required' }
if ($null -eq $resourcesArg) { Fail '--resource-units is required' }
if ($assignmentId -match '[\\/\s]') { Fail '--assignment-id cannot contain whitespace or path separators' }

if ($env:OFFLOAD_WORKER_CONTEXT -eq '1') {
    Record-Rejection $statePath $assignmentId 'worker context cannot create assignments, processes, or worktrees' @{
        role = $role
        parent_assignment_id = if ($parentId) { $parentId } else { $null }
        owned_paths = @($owned)
    }
    Fail 'worker dispatch rejected: only the orchestrator may create assignments, processes, or worktrees' 126
}

$statePath = [System.IO.Path]::GetFullPath($statePath)
$sourceRepo = [System.IO.Path]::GetFullPath($sourceRepo)
$outputPath = [System.IO.Path]::GetFullPath($outputPath)
$errorPath = [System.IO.Path]::GetFullPath($errorPath)
if ($workspaceDir) { $workspaceDir = [System.IO.Path]::GetFullPath($workspaceDir) }
if ($workspaceManifest) { $workspaceManifest = [System.IO.Path]::GetFullPath($workspaceManifest) }
if (-not $workspaceManifest) {
    $workspaceManifest = Join-Path ([System.IO.Path]::GetDirectoryName($statePath)) "$assignmentId.manifest.json"
}
$lock = Acquire-StateLock $statePath
$state = $null
$assignment = $null
try {
    $isRoot = [string]::IsNullOrWhiteSpace($parentId)
    if ($isRoot -and ($null -eq $maxDepthArg -or $null -eq $maxWidthArg -or $null -eq $maxTimeoutArg -or $null -eq $maxResourcesArg)) {
        Fail 'root dispatch requires --max-depth, --max-width, --max-timeout-seconds, and --max-resource-units'
    }
    $state = Read-State $statePath $isRoot ([int]($maxDepthArg ?? 0)) ([int]($maxWidthArg ?? 0)) ([int]($maxTimeoutArg ?? 0)) ([int]($maxResourcesArg ?? 0))
    if (-not $isRoot) {
        foreach ($pair in @(
            @{n='max-depth';v=$maxDepthArg;actual=$state.limits.max_depth},
            @{n='max-width';v=$maxWidthArg;actual=$state.limits.max_width},
            @{n='max-timeout-seconds';v=$maxTimeoutArg;actual=$state.limits.max_timeout_seconds},
            @{n='max-resource-units';v=$maxResourcesArg;actual=$state.limits.max_resource_units}
        )) {
            if ($null -ne $pair.v -and $pair.v -ne $pair.actual) {
                $request = @{ parent_assignment_id = $parentId; limit = $pair.n; requested = $pair.v; allowed = $pair.actual }
                $state.events = @($state.events) + [ordered]@{ type='nested_dispatch_rejected'; actor='orchestrator'; assignment_id=$assignmentId; reason='child attempted to widen an immutable dispatch limit'; request=$request; recorded_at=(Get-Now) }
                Write-JsonFile $statePath $state
                Fail "child cannot change dispatch limit --$($pair.n)" 126
            }
        }
    }
    $parent = $null
    if (-not $isRoot) {
        $parents = @($state.assignments | Where-Object { $_.assignment_id -eq $parentId })
        if ($parents.Count -ne 1) { Fail "parent assignment does not exist uniquely: $parentId" }
        $parent = $parents[0]
    }
    $depth = if ($isRoot) { 0 } else { [int]$parent.depth + 1 }
    if ($null -ne $depthArg -and [int]$depthArg -ne $depth) { Fail "--depth does not match parent depth" }
    if ($depth -gt [int]$state.limits.max_depth) {
        $state.events = @($state.events) + [ordered]@{ type='nested_dispatch_rejected'; actor='orchestrator'; assignment_id=$assignmentId; reason='maximum dispatch depth exceeded'; request=@{ parent_assignment_id=$parentId; depth=$depth; max_depth=$state.limits.max_depth }; recorded_at=(Get-Now) }
        Write-JsonFile $statePath $state
        Fail 'dispatch rejected: maximum depth exceeded' 126
    }
    if (-not $isRoot) {
        $childCount = @($state.assignments | Where-Object { $_.parent_assignment_id -eq $parentId }).Count
        if ($childCount -ge [int]$state.limits.max_width) {
            $state.events = @($state.events) + [ordered]@{ type='nested_dispatch_rejected'; actor='orchestrator'; assignment_id=$assignmentId; reason='maximum child width exceeded'; request=@{ parent_assignment_id=$parentId; width=$childCount + 1; max_width=$state.limits.max_width }; recorded_at=(Get-Now) }
            Write-JsonFile $statePath $state
            Fail 'dispatch rejected: maximum child width exceeded' 126
        }
    }
    if ([int]$timeoutArg -gt [int]$state.limits.max_timeout_seconds) {
        $state.events = @($state.events) + [ordered]@{ type='nested_dispatch_rejected'; actor='orchestrator'; assignment_id=$assignmentId; reason='assignment timeout exceeds maximum'; request=@{ timeout_seconds=$timeoutArg; max_timeout_seconds=$state.limits.max_timeout_seconds }; recorded_at=(Get-Now) }
        Write-JsonFile $statePath $state
        Fail 'dispatch rejected: timeout exceeds maximum' 126
    }
    $usedResources = 0
    foreach ($existingAssignment in @($state.assignments)) {
        $usedResources += [int]$existingAssignment.budget.resource_units
    }
    if ([int]$usedResources + [int]$resourcesArg -gt [int]$state.limits.max_resource_units) {
        $state.events = @($state.events) + [ordered]@{ type='nested_dispatch_rejected'; actor='orchestrator'; assignment_id=$assignmentId; reason='maximum resource budget exceeded'; request=@{ resource_units=$resourcesArg; used_resource_units=$usedResources; max_resource_units=$state.limits.max_resource_units }; recorded_at=(Get-Now) }
        Write-JsonFile $statePath $state
        Fail 'dispatch rejected: resource budget exceeded' 126
    }
    if (@($state.assignments | Where-Object { $_.assignment_id -eq $assignmentId }).Count -ne 0) { Fail "assignment id already exists: $assignmentId" }

    $assignment = [ordered]@{
        assignment_id = $assignmentId
        parent_assignment_id = if ($isRoot) { $null } else { $parentId }
        child_assignment_ids = @()
        depth = $depth
        budget = [ordered]@{ timeout_seconds = [int]$timeoutArg; resource_units = [int]$resourcesArg }
        owned_paths = @($owned)
        frozen_paths = @($frozen)
        role = $role
        lifecycle_state = 'created'
        source_repo = [System.IO.Path]::GetFullPath($sourceRepo)
        baseline = $baseline
        output_path = [System.IO.Path]::GetFullPath($outputPath)
        error_path = [System.IO.Path]::GetFullPath($errorPath)
        workspace_manifest = if ($workspaceManifest) { [System.IO.Path]::GetFullPath($workspaceManifest) } else { $null }
        workspace_dir = if ($workspaceDir) { [System.IO.Path]::GetFullPath($workspaceDir) } else { $null }
        created_at = Get-Now
        started_at = $null
        ended_at = $null
        exit_code = $null
    }
    $state.assignments = @($state.assignments) + $assignment
    if ($parent) {
        $parent.child_assignment_ids = @($parent.child_assignment_ids) + $assignmentId
    }
    Write-JsonFile $statePath $state
} finally {
    Release-StateLock $lock
}

$workspaceArgs = @('create', '--source-repo', $sourceRepo, '--task-id', $assignmentId, '--baseline', $baseline)
foreach ($path in $owned) { $workspaceArgs += @('--owned', $path) }
foreach ($path in $frozen) { $workspaceArgs += @('--frozen', $path) }
if ($workspaceManifest) { $workspaceArgs += @('--manifest', $workspaceManifest) }
if ($workspaceDir) { $workspaceArgs += @('--workspace-dir', $workspaceDir) }
$global:LASTEXITCODE = 0
$workspaceOutput = & $script:WorkspaceHelper @workspaceArgs 2>&1 | Out-String
$workspaceExitCode = $LASTEXITCODE
if ($workspaceExitCode -ne 0) {
    $lock = Acquire-StateLock $statePath
    try {
        $state = Read-State $statePath $false 0 0 0 0
        $record = @($state.assignments | Where-Object { $_.assignment_id -eq $assignmentId })[0]
        $record.lifecycle_state = 'failed'
        $record.ended_at = Get-Now
        $record.failure = "worktree creation failed: $($workspaceOutput.Trim())"
        Write-JsonFile $statePath $state
    } finally { Release-StateLock $lock }
    Fail "failed to create worker worktree: $($workspaceOutput.Trim())" 1
}
if ($workspaceDir) {
    $workspacePath = [System.IO.Path]::GetFullPath($workspaceDir)
} else {
    if (-not $workspaceManifest -or -not (Test-Path -LiteralPath $workspaceManifest -PathType Leaf)) {
        $lock = Acquire-StateLock $statePath
        try {
            $state = Read-State $statePath $false 0 0 0 0
            $record = @($state.assignments | Where-Object { $_.assignment_id -eq $assignmentId })[0]
            $record.lifecycle_state = 'failed'
            $record.ended_at = Get-Now
            $record.exit_code = 1
            $record.failure = 'workspace helper did not produce a manifest for the assigned worker'
            Write-JsonFile $statePath $state
        } finally { Release-StateLock $lock }
        Fail 'workspace helper did not produce a manifest for the assigned worker'
    }
    $workspaceRecord = Get-Content -LiteralPath $workspaceManifest -Raw | ConvertFrom-Json
    $workspacePath = [string]$workspaceRecord.workspace_dir
}
if (-not (Test-Path -LiteralPath $workspacePath -PathType Container)) {
    $lock = Acquire-StateLock $statePath
    try {
        $state = Read-State $statePath $false 0 0 0 0
        $record = @($state.assignments | Where-Object { $_.assignment_id -eq $assignmentId })[0]
        $record.lifecycle_state = 'failed'
        $record.ended_at = Get-Now
        $record.exit_code = 1
        $record.failure = "assigned worker worktree does not exist: $workspacePath"
        Write-JsonFile $statePath $state
    } finally { Release-StateLock $lock }
    Fail "assigned worker worktree does not exist: $workspacePath" 1
}

$lock = Acquire-StateLock $statePath
try {
    $state = Read-State $statePath $false 0 0 0 0
    $record = @($state.assignments | Where-Object { $_.assignment_id -eq $assignmentId })[0]
    $record.workspace_dir = $workspacePath
    $record.workspace_manifest = if ($workspaceManifest) { [System.IO.Path]::GetFullPath($workspaceManifest) } else { $record.workspace_manifest }
    $record.lifecycle_state = 'running'
    $record.started_at = Get-Now
    Write-JsonFile $statePath $state
} finally { Release-StateLock $lock }

$launcherArgs = @('--role', $role, '--timeout-seconds', [string]$timeoutArg, '--output', $outputPath, '--error', $errorPath, '--') + @($workerArgs)
$workerExitCode = 0
Push-Location -LiteralPath $workspacePath
try {
    & $script:Launcher @launcherArgs
    $workerExitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

$lock = Acquire-StateLock $statePath
try {
    $state = Read-State $statePath $false 0 0 0 0
    $record = @($state.assignments | Where-Object { $_.assignment_id -eq $assignmentId })[0]
    $record.lifecycle_state = if ($workerExitCode -eq 0) { 'completed' } else { 'failed' }
    $record.ended_at = Get-Now
    $record.exit_code = $workerExitCode
    Write-JsonFile $statePath $state
} finally { Release-StateLock $lock }

[ordered]@{ assignment_id = $assignmentId; parent_assignment_id = $assignment.parent_assignment_id; depth = $assignment.depth; lifecycle_state = if ($workerExitCode -eq 0) { 'completed' } else { 'failed' }; workspace_dir = $workspacePath; output_path = [System.IO.Path]::GetFullPath($outputPath); error_path = [System.IO.Path]::GetFullPath($errorPath) } | ConvertTo-Json -Compress
exit $workerExitCode
