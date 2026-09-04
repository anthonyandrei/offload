#!/usr/bin/env pwsh
# scripts/cleanup-research-workspace.ps1
# Cleans up research workspaces while verifying safety markers and preserving outputs.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Show-Usage {
    [Console]::Error.WriteLine("Usage: cleanup-research-workspace.ps1 --workspace <path> --status <success|partial|failed>")
}

function Fail([string]$message, [int]$exitCode = 1) {
    [Console]::Error.WriteLine("Error: $message")
    exit $exitCode
}

$workspace = ""
$status = ""

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    if ($arg -eq '--workspace') {
        $i++
        if ($i -ge $args.Count) {
            Show-Usage
            Fail "--workspace requires a path"
        }
        $workspace = [string]$args[$i]
    } elseif ($arg -eq '--status') {
        $i++
        if ($i -ge $args.Count) {
            Show-Usage
            Fail "--status requires a value"
        }
        $status = [string]$args[$i]
    } elseif ($arg -eq '-h' -or $arg -eq '--help') {
        Show-Usage
        exit 0
    } else {
        Show-Usage
        Fail "unrecognized argument: $arg"
    }
    $i++
}

if ([string]::IsNullOrWhiteSpace($workspace) -or [string]::IsNullOrWhiteSpace($status)) {
    Show-Usage
    Fail "--workspace and --status are required"
}

if ($status -notin @('success', 'partial', 'failed')) {
    Fail "invalid status: $status (must be success, partial, or failed)"
}

if (-not (Test-Path -LiteralPath $workspace -PathType Container)) {
    Fail "workspace directory does not exist: $workspace"
}

$canonicalWs = [System.IO.Path]::GetFullPath($workspace)
$trimmedWs = $canonicalWs.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

# Reject filesystem root
$pathRoot = [System.IO.Path]::GetPathRoot($canonicalWs)
$trimmedRoot = $pathRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
if ([string]::Equals($trimmedWs, $trimmedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or [string]::IsNullOrEmpty($trimmedWs)) {
    Fail "unsafe workspace path (filesystem root): $canonicalWs"
}

# Reject process current directory
$pwshCwd = [System.IO.Path]::GetFullPath((Get-Location).Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
if ([string]::Equals($trimmedWs, $pwshCwd, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "unsafe workspace path (process current directory): $canonicalWs"
}
$envCwd = [System.IO.Path]::GetFullPath([System.Environment]::CurrentDirectory).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
if ([string]::Equals($trimmedWs, $envCwd, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "unsafe workspace path (process current directory): $canonicalWs"
}

# Reject user home directory
$homeDirs = @($env:USERPROFILE, $env:HOME) | Where-Object { -not [string]::IsNullOrEmpty($_) }
foreach ($h in $homeDirs) {
    $canonH = [System.IO.Path]::GetFullPath($h).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if ([string]::Equals($trimmedWs, $canonH, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "unsafe workspace path (user home directory): $canonicalWs"
    }
}

# Reject Git worktree root
$gitPath = [System.IO.Path]::Combine($canonicalWs, '.git')
if ([System.IO.Directory]::Exists($gitPath) -or [System.IO.File]::Exists($gitPath)) {
    Fail "unsafe workspace path (git worktree root): $canonicalWs"
}

# Reject unmarked directory or invalid marker version
$markerFile = [System.IO.Path]::Combine($canonicalWs, '.offload-research-workspace')
if (-not [System.IO.File]::Exists($markerFile)) {
    Fail "directory lacks offload workspace marker: $canonicalWs"
}

$markerRaw = [System.IO.File]::ReadAllText($markerFile, [System.Text.Encoding]::UTF8)
if ($markerRaw.Trim() -ne 'offload-research-workspace-v1') {
    Fail "invalid workspace marker version: $canonicalWs"
}

function Remove-EntryWithoutFollowingReparsePoint([string]$entry) {
    $attributes = [System.IO.File]::GetAttributes($entry)
    $isDirectory = $attributes.HasFlag([System.IO.FileAttributes]::Directory)

    if ($attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
        # Delete the link itself. Do not enumerate or mutate its target.
        if ($isDirectory) {
            [System.IO.Directory]::Delete($entry, $false)
        } else {
            [System.IO.File]::Delete($entry)
        }
        return
    }

    if ($isDirectory) {
        foreach ($child in [System.IO.Directory]::GetFileSystemEntries($entry)) {
            Remove-EntryWithoutFollowingReparsePoint $child
        }
        [System.IO.Directory]::Delete($entry, $false)
        return
    }

    if ($attributes.HasFlag([System.IO.FileAttributes]::ReadOnly)) {
        [System.IO.File]::SetAttributes($entry, [System.IO.FileAttributes]::Normal)
    }
    [System.IO.File]::Delete($entry)
}

$routingFileName = 'routing-outcomes.json'
$dispositionFileName = 'evidence-disposition.json'
$retainedFileNames = @('final.md', 'provenance.json', $routingFileName, $dispositionFileName, '.offload-research-workspace')

function Get-JsonProperty($object, [string]$name) {
    if ($null -eq $object) {
        return $null
    }
    $property = $object.PSObject.Properties[$name]
    if ($null -eq $property) {
        return $null
    }
    return ,$property.Value
}

function Assert-RoutingRecord($record, [string]$path) {
    if ($null -eq $record -or $record -isnot [pscustomobject]) {
        Fail "invalid routing record: $path"
    }

    $schemaVersion = Get-JsonProperty $record 'schema_version'
    if ($schemaVersion -ne 1) {
        Fail "invalid routing record schema_version: $path"
    }

    $attempts = Get-JsonProperty $record 'attempts'
    if ($null -eq $attempts -or $attempts -isnot [array]) {
        Fail "invalid routing record attempts: $path"
    }
    $attemptList = @($attempts)
    $seenAttempts = @{}
    $attemptCounts = @{}
    foreach ($attempt in $attemptList) {
        if ($null -eq $attempt -or $attempt -isnot [pscustomobject]) {
            Fail "routing record contains a non-object attempt: $path"
        }

        foreach ($field in @('worker_id', 'role', 'mode', 'policy_revision', 'route', 'effort', 'reason', 'state', 'started_at', 'ended_at', 'duration_seconds', 'exit_code', 'failure_class', 'evidence_paths', 'usage')) {
            if ($null -eq $attempt.PSObject.Properties[$field]) {
                Fail "routing record attempt is missing field '$field': $path"
            }
        }
        foreach ($field in @('worker_id', 'role', 'mode', 'policy_revision', 'route', 'effort', 'reason', 'state', 'failure_class')) {
            $value = Get-JsonProperty $attempt $field
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                Fail "routing record attempt is missing string field '$field': $path"
            }
        }
        $startedAt = Get-JsonProperty $attempt 'started_at'
        if ($startedAt -isnot [string] -and $startedAt -isnot [datetime]) {
            Fail "routing record attempt is missing timestamp field 'started_at': $path"
        }
        $endedAt = Get-JsonProperty $attempt 'ended_at'
        if ($null -ne $endedAt -and $endedAt -isnot [string] -and $endedAt -isnot [datetime]) {
            Fail "routing record attempt has invalid timestamp field 'ended_at': $path"
        }

        $attemptNumber = Get-JsonProperty $attempt 'attempt'
        if (($attemptNumber -isnot [int] -and $attemptNumber -isnot [long] -and $attemptNumber -isnot [double]) -or [double]$attemptNumber -ne [math]::Truncate([double]$attemptNumber)) {
            Fail "routing record attempt number is not numeric: $path"
        }
        $workerId = [string](Get-JsonProperty $attempt 'worker_id')
        $attemptKey = "$workerId`0$([int]$attemptNumber)"
        if ($attemptNumber -notin @(1, 2) -or $seenAttempts.ContainsKey($attemptKey)) {
            Fail "routing record attempt numbers are invalid or duplicated: $path"
        }
        $seenAttempts[$attemptKey] = $true
        if (-not $attemptCounts.ContainsKey($workerId)) { $attemptCounts[$workerId] = 0 }
        $attemptCounts[$workerId]++
        if ($attemptCounts[$workerId] -gt 2) {
            Fail "routing record contains more than two attempts for worker '$workerId': $path"
        }

        $verification = Get-JsonProperty $attempt 'verification_status'
        if ($null -eq $verification) {
            $verification = Get-JsonProperty $attempt 'verification'
        }
        if ($verification -isnot [string] -or $verification -notin @('pending', 'passed', 'failed', 'not_performed')) {
            Fail "routing record attempt is missing verification status: $path"
        }

        if ((Get-JsonProperty $attempt 'role') -notin @('scout', 'gate-author', 'implementer', 'reviewer', 'researcher', 'synthesizer', 'auditor')) {
            Fail "routing record attempt has an invalid role: $path"
        }
        if ((Get-JsonProperty $attempt 'mode') -notin @('execution', 'repo-research', 'web-research')) {
            Fail "routing record attempt has an invalid mode: $path"
        }
        if ((Get-JsonProperty $attempt 'route') -notin @('default', 'quality-retry')) {
            Fail "routing record attempt has an invalid route: $path"
        }
        $model = [string](Get-JsonProperty $attempt 'model')
        $effort = [string](Get-JsonProperty $attempt 'effort')
        $modelId = [string](Get-JsonProperty $attempt 'model_id')
        if ([string]::IsNullOrWhiteSpace($model) -and [string]::IsNullOrWhiteSpace($modelId)) {
            Fail "routing record attempt has no model or model_id: $path"
        }
        if (-not [string]::IsNullOrWhiteSpace($modelId) -and -not [string]::IsNullOrWhiteSpace($model) -and $model -ne $modelId) {
            Fail "routing record attempt model and model_id disagree: $path"
        }
        if ($effort -notin @('low', 'medium', 'high')) {
            Fail "routing record attempt has invalid effort: $path"
        }
        if ([string]::IsNullOrWhiteSpace($modelId) -and ($model -notmatch '^gemini-[a-zA-Z0-9.-]+-(low|medium|high)$' -or -not $model.EndsWith("-$effort"))) {
            Fail "legacy routing record model must be a Gemini model ID with an effort suffix: $path"
        }
        if ((Get-JsonProperty $attempt 'state') -notin @('running', 'completed', 'failed', 'interrupted')) {
            Fail "routing record attempt has an invalid state: $path"
        }
        if ((Get-JsonProperty $attempt 'failure_class') -notin @('none', 'quality', 'timeout', 'tool_error', 'quota', 'unrunnable', 'unknown')) {
            Fail "routing record attempt has an invalid failure class: $path"
        }

        $duration = Get-JsonProperty $attempt 'duration_seconds'
        if ($null -ne $duration -and (($duration -isnot [int] -and $duration -isnot [long] -and $duration -isnot [double]) -or $duration -lt 0 -or [double]::IsNaN([double]$duration) -or [double]::IsInfinity([double]$duration))) {
            Fail "routing record attempt has an invalid duration: $path"
        }
        $exitCode = Get-JsonProperty $attempt 'exit_code'
        if ($null -ne $exitCode -and (($exitCode -isnot [int] -and $exitCode -isnot [long] -and $exitCode -isnot [double]) -or [double]$exitCode -ne [math]::Truncate([double]$exitCode))) {
            Fail "routing record attempt has an invalid exit code: $path"
        }
        $usage = Get-JsonProperty $attempt 'usage'
        if ($null -ne $usage -and $usage -isnot [pscustomobject]) {
            Fail "routing record attempt has invalid usage: $path"
        }

        $evidencePaths = Get-JsonProperty $attempt 'evidence_paths'
        if ($null -eq $evidencePaths -or $evidencePaths -isnot [array]) {
            Fail "routing record attempt is missing evidence_paths: $path"
        }
        foreach ($evidencePath in @($evidencePaths)) {
            if ($evidencePath -isnot [string]) {
                Fail "routing record evidence path is not a string: $path"
            }
        }
    }
}

function New-DispositionEntry([string]$relativePath, [string]$disposition, $existsBeforeCleanup, [string]$sha256, [string]$reason) {
    $entry = [ordered]@{
        path = $relativePath
        exists_before_cleanup = $existsBeforeCleanup
        sha256 = if ([string]::IsNullOrEmpty($sha256)) { $null } else { $sha256 }
        disposition = $disposition
        status = $disposition
    }
    if (-not [string]::IsNullOrEmpty($reason)) {
        $entry.reason = $reason
    }
    return [pscustomobject]$entry
}

function Get-EvidenceDisposition([string]$relativePath, [string]$workspacePath) {
    if ([string]::IsNullOrWhiteSpace($relativePath) -or [System.IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '[\x00-\x1f\x7f]' -or $relativePath -match ':') {
        return New-DispositionEntry $relativePath 'uninspected' $null $null 'path is not a safe relative workspace path'
    }

    $parts = @($relativePath -split '[\\/]')
    $unsafeParts = @($parts | Where-Object { [string]::IsNullOrEmpty($_) -or $_ -eq '.' -or $_ -eq '..' })
    if ($parts.Count -eq 0 -or $unsafeParts.Count -gt 0) {
        return New-DispositionEntry $relativePath 'uninspected' $null $null 'path contains unsafe traversal components'
    }

    $candidate = $workspacePath
    foreach ($part in $parts) {
        $candidate = [System.IO.Path]::Combine($candidate, $part)
        try {
            $attributes = [System.IO.File]::GetAttributes($candidate)
        } catch [System.IO.FileNotFoundException] {
            return New-DispositionEntry $relativePath 'missing' $false $null ''
        } catch [System.IO.DirectoryNotFoundException] {
            return New-DispositionEntry $relativePath 'missing' $false $null ''
        }
        if ($attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
            return New-DispositionEntry $relativePath 'uninspected' $true $null 'path contains a reparse point'
        }
    }

    $attributes = [System.IO.File]::GetAttributes($candidate)
    if ($attributes.HasFlag([System.IO.FileAttributes]::Directory)) {
        return New-DispositionEntry $relativePath 'uninspected' $true $null 'path is not a regular file'
    }

    $hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($candidate))).ToLowerInvariant()
    $normalized = ($parts -join '/')
    $disposition = if ($normalized -in $retainedFileNames) { 'retained' } else { 'pruned' }
    return New-DispositionEntry $relativePath $disposition $true $hash ''
}

function Get-RoutingEvidencePaths([string]$routingPath) {
    try {
        $routingAttributes = [System.IO.File]::GetAttributes($routingPath)
    } catch [System.IO.FileNotFoundException] {
        return @()
    } catch [System.IO.DirectoryNotFoundException] {
        return @()
    }
    if ($routingAttributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
        Fail "routing record must be a regular file: $routingPath"
    }
    if ($routingAttributes.HasFlag([System.IO.FileAttributes]::Directory)) {
        Fail "routing record must be a regular file: $routingPath"
    }

    try {
        $record = Get-Content -LiteralPath $routingPath -Raw | ConvertFrom-Json
    } catch {
        Fail "routing record is not valid JSON: $routingPath"
    }
    Assert-RoutingRecord $record $routingPath

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($attempt in @($record.attempts)) {
        foreach ($evidencePath in (Get-JsonProperty $attempt 'evidence_paths')) {
            if (-not $paths.Contains([string]$evidencePath)) {
                $paths.Add([string]$evidencePath)
            }
        }
    }
    return $paths.ToArray()
}

function Assert-ProvenanceAcceptedAttempts([string]$workspacePath, [object]$routingRecord) {
    $provenancePath = [System.IO.Path]::Combine($workspacePath, 'provenance.json')
    if (-not (Test-Path -LiteralPath $provenancePath -PathType Leaf)) {
        return
    }
    try {
        $provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
    } catch {
        Fail "provenance.json is not valid JSON: $provenancePath"
    }
    $workersNode = Get-JsonProperty $provenance 'workers'
    if ($null -eq $workersNode) { return }
    $workers = @($workersNode)
    foreach ($worker in $workers) {
        if ($null -eq $worker -or $worker -isnot [pscustomobject]) {
            Fail "provenance workers must be objects: $provenancePath"
        }
        $workerId = if ($null -ne $worker.PSObject.Properties['id']) { [string]$worker.id } elseif ($null -ne $worker.PSObject.Properties['worker_id']) { [string]$worker.worker_id } else { '' }
        if ([string]::IsNullOrWhiteSpace($workerId) -or $null -eq $worker.PSObject.Properties['accepted_attempt']) {
            continue
        }
        $acceptedAttempt = Get-JsonProperty $worker 'accepted_attempt'
        if (($acceptedAttempt -isnot [int] -and $acceptedAttempt -isnot [long] -and $acceptedAttempt -isnot [double]) -or [double]$acceptedAttempt -ne [math]::Truncate([double]$acceptedAttempt) -or $acceptedAttempt -notin @(1, 2)) {
            Fail "provenance worker '$workerId' has an invalid accepted_attempt: $provenancePath"
        }
        $output = [string](Get-JsonProperty $worker 'output')
        if ([string]::IsNullOrWhiteSpace($output)) {
            Fail "provenance worker '$workerId' has no selected output: $provenancePath"
        }
        $matches = @(@($routingRecord.attempts) | Where-Object {
            $verification = Get-JsonProperty $_ 'verification_status'
            if ($null -eq $verification) { $verification = Get-JsonProperty $_ 'verification' }
            [string](Get-JsonProperty $_ 'worker_id') -eq $workerId -and
            (Get-JsonProperty $_ 'attempt') -eq [int]$acceptedAttempt -and
            (Get-JsonProperty $_ 'state') -eq 'completed' -and
            $verification -eq 'passed' -and
            (Get-JsonProperty $_ 'exit_code') -eq 0 -and
            @((Get-JsonProperty $_ 'evidence_paths')).Count -gt 0 -and
            [string](@((Get-JsonProperty $_ 'evidence_paths'))[0]) -eq $output
        })
        if ($matches.Count -ne 1) {
            Fail "provenance worker '$workerId' accepted_attempt does not resolve to one verified routing attempt: $provenancePath"
        }
        $selectedPath = if ([System.IO.Path]::IsPathRooted($output)) { $output } else { [System.IO.Path]::Combine($workspacePath, $output) }
        if (-not (Test-Path -LiteralPath $selectedPath -PathType Leaf)) {
            Fail "provenance worker '$workerId' selected output does not exist: $selectedPath"
        }
    }
}

function Write-EvidenceDisposition([string]$workspacePath, [string]$routingPath, [string]$dispositionPath) {
    $evidencePaths = @(Get-RoutingEvidencePaths $routingPath)
    if (Test-Path -LiteralPath $routingPath -PathType Leaf) {
        $routingRecord = Get-Content -LiteralPath $routingPath -Raw | ConvertFrom-Json
        Assert-ProvenanceAcceptedAttempts $workspacePath $routingRecord
    }
    $existingAttributes = $null
    try {
        $existingAttributes = [System.IO.File]::GetAttributes($dispositionPath)
    } catch [System.IO.FileNotFoundException] {
        $existingAttributes = $null
    } catch [System.IO.DirectoryNotFoundException] {
        $existingAttributes = $null
    }
    if ($null -ne $existingAttributes) {
        $attributes = $existingAttributes
        if ($attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
            Fail "evidence disposition manifest must be a regular file: $dispositionPath"
        }
        if ($attributes.HasFlag([System.IO.FileAttributes]::Directory)) {
            Fail "evidence disposition manifest path is a directory: $dispositionPath"
        }
        try {
            $existing = Get-Content -LiteralPath $dispositionPath -Raw | ConvertFrom-Json
        } catch {
            Fail "existing evidence disposition manifest is not valid JSON: $dispositionPath"
        }
        $existingEntries = Get-JsonProperty $existing 'entries'
        if ((Get-JsonProperty $existing 'schema_version') -ne 1 -or $null -eq $existingEntries -or $existingEntries -isnot [array]) {
            Fail "existing evidence disposition manifest has an invalid schema: $dispositionPath"
        }
        return
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $evidencePaths) {
        $entries.Add((Get-EvidenceDisposition $path $workspacePath))
    }
    $manifest = [ordered]@{
        schema_version = 1
        routing_record = $routingFileName
        entries = @($entries)
    }
    try {
        $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $dispositionPath -Encoding utf8
    } catch {
        Fail "could not write evidence disposition manifest: $dispositionPath"
    }
}

# Cleanup according to status
if ($status -eq 'success') {
    $routingPath = [System.IO.Path]::Combine($canonicalWs, $routingFileName)
    $dispositionPath = [System.IO.Path]::Combine($canonicalWs, $dispositionFileName)
    Write-EvidenceDisposition $canonicalWs $routingPath $dispositionPath
    $entries = [System.IO.Directory]::GetFileSystemEntries($canonicalWs)
    foreach ($entry in $entries) {
        $baseName = [System.IO.Path]::GetFileName($entry)
        if ($baseName -in $retainedFileNames) {
            continue
        }

        # Check every entry before descending so nested links are never followed.
        Remove-EntryWithoutFollowingReparsePoint $entry
    }
}

exit 0
