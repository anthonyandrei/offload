#!/usr/bin/env pwsh
# Validate the vendor-neutral worker adapter assignment/result boundary.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Fail([string]$message) {
    [Console]::Error.WriteLine("ERROR: $message")
    exit 2
}

function Read-Object([string]$path, [string]$label) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail "$label does not exist: $path" }
    try {
        $value = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        Fail "$label is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $value -or $value -isnot [PSCustomObject]) { Fail "$label must be a JSON object" }
    return $value
}

function Property($object, [string]$name, [string]$label) {
    $property = $object.PSObject.Properties[$name]
    if ($null -eq $property) { Fail "$label is missing '$name'" }
    return $property.Value
}

function String-Value($value, [string]$label) {
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { Fail "$label must be a non-empty string" }
    return [string]$value
}

function String-Array($value, [string]$label) {
    # ConvertFrom-Json unwraps empty and one-item arrays. Assert-Json-Arrays
    # validates the source JSON shape; here null represents a valid empty array.
    if ($null -eq $value) { return @() }
    $items = @($value)
    foreach ($item in $items) { [void](String-Value $item $label) }
    return $items | ForEach-Object { [string]$_ }
}

function Assert-Json-Arrays([string]$json, [string]$label, [string[]]$paths) {
    try { $document = [System.Text.Json.JsonDocument]::Parse($json) }
    catch { Fail "$label is not valid JSON: $($_.Exception.Message)" }
    try {
        foreach ($path in $paths) {
            $element = $document.RootElement
            foreach ($name in $path.Split('.')) { $element = $element.GetProperty($name) }
            if ($element.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { Fail "$label.$path must be an array" }
        }
    } catch [System.Collections.Generic.KeyNotFoundException] {
        Fail "$label array property is missing"
    } finally {
        $document.Dispose()
    }
}

function Canonical([string]$path) {
    try { return [IO.Path]::GetFullPath($path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) }
    catch { Fail "invalid path '$path'" }
}

function Is-Within([string]$child, [string]$parent) {
    $childPath = Canonical $child
    $parentPath = Canonical $parent
    return [string]::Equals($childPath, $parentPath, [StringComparison]::OrdinalIgnoreCase) -or
        $childPath.StartsWith("$parentPath$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)
}

function Contains-String([string[]]$allowed, [string]$value) {
    return $allowed -contains $value
}

function Check-Subset([string[]]$actual, [string[]]$allowed, [string]$label) {
    foreach ($item in $actual) {
        if (-not (Contains-String $allowed $item)) { Fail "$label widens the assignment with '$item'" }
    }
}

function Check-Path-Subset([string[]]$actual, [string[]]$allowed, [string]$label) {
    foreach ($item in $actual) {
        $covered = $false
        foreach ($grant in $allowed) {
            if ($item -eq $grant -or $item.StartsWith("$grant/", [StringComparison]::OrdinalIgnoreCase)) { $covered = $true; break }
        }
        if (-not $covered) { Fail "$label widens the assignment with '$item'" }
    }
}

function Check-Constraints($assignment, $result) {
    $grants = Property $assignment 'constraints' 'assignment'
    $used = Property $result 'constraint_snapshot' 'result'

    $grantTools = String-Array (Property $grants 'tools' 'assignment.constraints') 'assignment.constraints.tools'
    $grantPermissions = String-Array (Property $grants 'permissions' 'assignment.constraints') 'assignment.constraints.permissions'
    $grantOwned = String-Array (Property $grants 'owned_paths' 'assignment.constraints') 'assignment.constraints.owned_paths'
    $grantFrozen = String-Array (Property $grants 'frozen_paths' 'assignment.constraints') 'assignment.constraints.frozen_paths'
    $grantCleanup = String-Array (Property $grants 'cleanup_resource_ids' 'assignment.constraints') 'assignment.constraints.cleanup_resource_ids'

    Check-Subset (String-Array (Property $used 'tools' 'result.constraint_snapshot') 'result.constraint_snapshot.tools') $grantTools 'tools'
    Check-Subset (String-Array (Property $used 'permissions' 'result.constraint_snapshot') 'result.constraint_snapshot.permissions') $grantPermissions 'permissions'
    Check-Path-Subset (String-Array (Property $used 'owned_paths' 'result.constraint_snapshot') 'result.constraint_snapshot.owned_paths') $grantOwned 'owned_paths'
    Check-Path-Subset (String-Array (Property $used 'frozen_paths' 'result.constraint_snapshot') 'result.constraint_snapshot.frozen_paths') $grantFrozen 'frozen_paths'
    Check-Subset (String-Array (Property $used 'cleanup_resource_ids' 'result.constraint_snapshot') 'result.constraint_snapshot.cleanup_resource_ids') $grantCleanup 'cleanup_resource_ids'

    $grantWorktree = Property $grants 'worktree' 'assignment.constraints'
    $usedWorktree = Property $used 'worktree' 'result.constraint_snapshot'
    $grantWorktreeId = String-Value (Property $grantWorktree 'id' 'assignment.constraints.worktree') 'assignment worktree id'
    $usedWorktreeId = String-Value (Property $usedWorktree 'id' 'result.constraint_snapshot.worktree') 'result worktree id'
    if ($grantWorktreeId -ne $usedWorktreeId) { Fail 'result changes the worktree id' }
    $grantWorktreePath = Canonical (String-Value (Property $grantWorktree 'path' 'assignment.constraints.worktree') 'assignment worktree path')
    $usedWorktreePath = Canonical (String-Value (Property $usedWorktree 'path' 'result.constraint_snapshot.worktree') 'result worktree path')
    if ($grantWorktreePath -ne $usedWorktreePath) { Fail 'result changes the worktree path' }

    $grantArtifactRoot = Canonical (String-Value (Property $grants 'artifact_root' 'assignment.constraints') 'assignment artifact root')
    $usedArtifactRoot = Canonical (String-Value (Property $used 'artifact_root' 'result.constraint_snapshot') 'result artifact root')
    if ($grantArtifactRoot -ne $usedArtifactRoot) { Fail 'result changes the artifact root' }
    return $grantArtifactRoot
}

if ($args.Count -ne 4 -or $args[0] -ne '--assignment' -or $args[2] -ne '--result') {
    [Console]::Error.WriteLine('Usage: check-worker-adapter.ps1 --assignment FILE --result FILE')
    exit 2
}

$assignment = Read-Object ([string]$args[1]) 'assignment'
$result = Read-Object ([string]$args[3]) 'result'
Assert-Json-Arrays (Get-Content -LiteralPath ([string]$args[1]) -Raw) 'assignment' @(
    'constraints.tools', 'constraints.permissions', 'constraints.owned_paths',
    'constraints.frozen_paths', 'constraints.cleanup_resource_ids'
)
Assert-Json-Arrays (Get-Content -LiteralPath ([string]$args[3]) -Raw) 'result' @(
    'constraint_snapshot.tools', 'constraint_snapshot.permissions',
    'constraint_snapshot.owned_paths', 'constraint_snapshot.frozen_paths',
    'constraint_snapshot.cleanup_resource_ids', 'ownership.resource_ids',
    'resources', 'artifacts'
)

if ((Property $assignment 'contract_version' 'assignment') -ne 1) { Fail 'assignment contract_version must be 1' }
if ((Property $result 'contract_version' 'result') -ne 1) { Fail 'result contract_version must be 1' }
$assignmentId = String-Value (Property $assignment 'assignment_id' 'assignment') 'assignment_id'
if ((String-Value (Property $result 'assignment_id' 'result') 'result.assignment_id') -ne $assignmentId) { Fail 'result assignment_id does not match assignment' }
[void](String-Value (Property (Property $assignment 'request' 'assignment') 'prompt' 'assignment.request') 'assignment.request.prompt')
$artifactRoot = Check-Constraints $assignment $result

$allowedStatuses = @('succeeded', 'failed', 'cancelled', 'malformed')
$status = String-Value (Property $result 'status' 'result') 'result.status'
if ($allowedStatuses -notcontains $status) { Fail "result.status '$status' is not supported" }

$ownership = Property $result 'ownership' 'result'
$ownedResourceIds = String-Array (Property $ownership 'resource_ids' 'result.ownership') 'result.ownership.resource_ids'
$resources = @((Property $result 'resources' 'result'))
foreach ($resource in $resources) {
    if ($null -eq $resource -or $resource -isnot [PSCustomObject]) { Fail 'result.resources entries must be objects' }
    $resourceId = String-Value (Property $resource 'id' 'result.resources entry') 'result resource id'
    if ($ownedResourceIds -notcontains $resourceId) { Fail "resource '$resourceId' is outside the adapter ownership record" }
    [void](String-Value (Property $resource 'type' 'result.resources entry') 'result resource type')
    $resourcePathProperty = $resource.PSObject.Properties['path']
    if ($null -ne $resourcePathProperty) {
        if (-not (Is-Within (String-Value $resourcePathProperty.Value 'result resource path') (String-Value (Property $assignment.constraints.worktree 'path' 'assignment worktree') 'assignment worktree path'))) {
            Fail "resource '$resourceId' path is outside the worktree"
        }
    }
}

$artifacts = @((Property $result 'artifacts' 'result'))
foreach ($artifact in $artifacts) {
    if ($null -eq $artifact -or $artifact -isnot [PSCustomObject]) { Fail 'result.artifacts entries must be objects' }
    $path = String-Value (Property $artifact 'path' 'result.artifact') 'result artifact path'
    if (-not (Is-Within $path $artifactRoot)) { Fail "artifact path is outside artifact_root: $path" }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail "artifact does not exist: $path" }
    if ((Property $artifact 'verified' 'result.artifact') -ne $false) { Fail 'adapter cannot claim an artifact is verified' }
    [void](String-Value (Property $artifact 'kind' 'result.artifact') 'result artifact kind')
    [void](String-Value (Property $artifact 'sha256' 'result.artifact') 'result artifact sha256')
}

$model = Property $result 'model_selection' 'result'
[void](String-Value (Property $model 'provider' 'result.model_selection') 'result model provider')
[void](String-Value (Property $model 'model_id' 'result.model_selection') 'result model id')
[void](String-Value (Property $model 'selection_reason' 'result.model_selection') 'result model selection reason')
$exit = Property $result 'exit' 'result'
if ((Property $exit 'code' 'result.exit') -isnot [int] -and (Property $exit 'code' 'result.exit') -isnot [long]) { Fail 'result.exit.code must be an integer' }
$publication = Property $result 'publication' 'result'
if ((String-Value (Property $publication 'status' 'result.publication') 'result publication status') -ne 'unpublished') { Fail 'adapter cannot publish a result' }

@{ contract_version = 1; status = 'accepted-for-orchestrator-verification'; assignment_id = $assignmentId } | ConvertTo-Json -Compress
exit 0
