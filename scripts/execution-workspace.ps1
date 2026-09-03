#!/usr/bin/env pwsh
# scripts/execution-workspace.ps1
# Platform-agnostic execution workspace lifecycle manager for PowerShell 7+.
# Manages isolated git worktrees for workers: create, verify-export, integrate, cleanup.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:MarkerName = '.offload-execution-workspace'
$script:MarkerContent = 'offload-execution-workspace-v1'
$script:ManifestMarker = 'offload-execution-manifest-v1'

$script:ScriptDir = Split-Path -Parent $PSCommandPath
$script:RootDir = Split-Path -Parent $script:ScriptDir
$script:ScopeChecker = Join-Path $script:ScriptDir 'check-execution-scope.ps1'

function Show-Usage {
    [Console]::Error.WriteLine(@"
Usage:
  execution-workspace.ps1 create --source-repo <path> --task-id <id> --baseline <rev> --owned <path> [--owned <path> ...] [--frozen <path> ...] [--manifest <path>] [--workspace-dir <path>]
  execution-workspace.ps1 verify-export --manifest <path> [--patch-output <path>]
  execution-workspace.ps1 integrate --manifest <path> [--target-repo <path>]
  execution-workspace.ps1 cleanup --manifest <path> [--status <success|failed|retain>]

Commands:
  create           Create an isolated Git worktree and external manifest for a task
  verify-export    Verify candidate scope, export unified binary patch, record SHA-256 digest
  integrate        Preflight in disposable integration checkout and apply verified patch
  cleanup          Safely remove manifest-owned worktree and artifacts
"@)
}

function Fail([string]$message, [int]$exitCode = 1) {
    [Console]::Error.WriteLine("Error: $message")
    exit $exitCode
}

function Canonicalize-Path([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        return ""
    }
    return [System.IO.Path]::GetFullPath($path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathWithin([string]$child, [string]$parent) {
    $childPath = Canonicalize-Path $child
    $parentPath = Canonicalize-Path $parent
    if ([string]::Equals($childPath, $parentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $separator = [System.IO.Path]::DirectorySeparatorChar
    return $childPath.StartsWith("$parentPath$separator", [System.StringComparison]::OrdinalIgnoreCase)
}

function Normalize-RelPath([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        return ""
    }
    $norm = $path.Replace('\', '/')
    while ($norm.StartsWith('./')) {
        $norm = $norm.Substring(2)
    }
    while ($norm.StartsWith('/') -and $norm -ne '/') {
        $norm = $norm.Substring(1)
    }
    while ($norm.EndsWith('/') -and $norm -ne '/') {
        $norm = $norm.Substring(0, $norm.Length - 1)
    }
    if ($norm -eq '.' -or $norm -eq '/') {
        return ""
    }
    return $norm
}

function Get-FileSha256([string]$filePath) {
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Fail "file does not exist for sha256 calculation: $filePath"
    }
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($filePath)
    try {
        $hashBytes = $hasher.ComputeHash($stream)
        return [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $hasher.Dispose()
    }
}

function Get-IsoTimestamp {
    return [System.DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Run-GitCommand {
    param(
        [Parameter(Mandatory=$true)][string]$WorkingDir,
        [Parameter(Mandatory=$true)][string[]]$GitArgs
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    foreach ($a in $GitArgs) {
        $psi.ArgumentList.Add($a)
    }
    $psi.WorkingDirectory = $WorkingDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Stdout   = $stdout
        Stderr   = $stderr
    }
}

# ---------------------------------------------------------------------------
# Command: create
# ---------------------------------------------------------------------------
function Cmd-Create([string[]]$cmdArgs) {
    $sourceRepo = ""
    $taskId = ""
    $baseline = ""
    $owned = [System.Collections.Generic.List[string]]::new()
    $frozen = [System.Collections.Generic.List[string]]::new()
    $manifestPath = ""
    $workspaceDir = ""

    $i = 0
    while ($i -lt $cmdArgs.Count) {
        $arg = [string]$cmdArgs[$i]
        if ($arg -eq '--source-repo') {
            $i++
            if ($i -ge $cmdArgs.Count) { Fail "--source-repo requires a path" }
            $sourceRepo = [string]$cmdArgs[$i]
        } elseif ($arg.StartsWith('--source-repo=')) {
            $sourceRepo = $arg.Substring('--source-repo='.Length)
        } elseif ($arg -eq '--task-id') {
            $i++
            if ($i -ge $cmdArgs.Count) { Fail "--task-id requires a value" }
            $taskId = [string]$cmdArgs[$i]
        } elseif ($arg.StartsWith('--task-id=')) {
            $taskId = $arg.Substring('--task-id='.Length)
        } elseif ($arg -eq '--baseline') {
            $i++
            if ($i -ge $cmdArgs.Count) { Fail "--baseline requires a value" }
            $baseline = [string]$cmdArgs[$i]
        } elseif ($arg.StartsWith('--baseline=')) {
            $baseline = $arg.Substring('--baseline='.Length)
        } elseif ($arg -eq '--owned') {
            $i++
            if ($i -ge $cmdArgs.Count) { Fail "--owned requires a path" }
            $owned.Add([string]$cmdArgs[$i])
        } elseif ($arg.StartsWith('--owned=')) {
            $owned.Add($arg.Substring('--owned='.Length))
        } elseif ($arg -eq '--frozen') {
            $i++
            if ($i -ge $cmdArgs.Count) { Fail "--frozen requires a path" }
            $frozen.Add([string]$cmdArgs[$i])
        } elseif ($arg.StartsWith('--frozen=')) {
            $frozen.Add($arg.Substring('--frozen='.Length))
        } elseif ($arg -eq '--manifest') {
            $i++
            if ($i -ge $cmdArgs.Count) { Fail "--manifest requires a path" }
            $manifestPath = [string]$cmdArgs[$i]
        } elseif ($arg.StartsWith('--manifest=')) {
            $manifestPath = $arg.Substring('--manifest='.Length)
        } elseif ($arg -eq '--workspace-dir') {
            $i++
            if ($i -ge $cmdArgs.Count) { Fail "--workspace-dir requires a path" }
            $workspaceDir = [string]$cmdArgs[$i]
        } elseif ($arg.StartsWith('--workspace-dir=')) {
            $workspaceDir = $arg.Substring('--workspace-dir='.Length)
        } elseif ($arg -eq '-h' -or $arg -eq '--help') {
            Show-Usage
            exit 0
        } else {
            Fail "unrecognized argument for create: $arg"
        }
        $i++
    }

    if ([string]::IsNullOrWhiteSpace($sourceRepo)) { Fail "--source-repo is required" }
    if ([string]::IsNullOrWhiteSpace($taskId)) { Fail "--task-id is required" }
    if ([string]::IsNullOrWhiteSpace($baseline)) { Fail "--baseline is required" }
    if ($owned.Count -eq 0) { Fail "at least one --owned path is required" }

    if (-not ($taskId -match '^[a-zA-Z0-9._-]+$')) {
        Fail "task-id must contain only alphanumeric characters, dots, underscores, or dashes: $taskId"
    }

    if (-not (Test-Path -LiteralPath $sourceRepo -PathType Container)) {
        Fail "source repository directory does not exist: $sourceRepo"
    }
    $canonRepo = Canonicalize-Path $sourceRepo
    $resInside = Run-GitCommand -WorkingDir $canonRepo -GitArgs @('rev-parse', '--is-inside-work-tree')
    if ($resInside.ExitCode -ne 0 -or $resInside.Stdout.Trim() -ne 'true') {
        Fail "source repository is not a git worktree: $sourceRepo"
    }

    # Verify baseline revision
    $resBase = Run-GitCommand -WorkingDir $canonRepo -GitArgs @('rev-parse', '--verify', "${baseline}^{commit}")
    if ($resBase.ExitCode -ne 0) {
        Fail "baseline revision does not resolve to a commit: $baseline"
    }
    $resolvedBaseline = $resBase.Stdout.Trim()

    # Validate owned and frozen paths
    $normOwned = [System.Collections.Generic.List[string]]::new()
    foreach ($o in $owned) {
        $no = Normalize-RelPath $o
        if ([string]::IsNullOrWhiteSpace($no)) { Fail "owned path cannot be empty or root: $o" }
        if ($no.Contains('..')) { Fail "owned path escapes repository: $o" }
        $normOwned.Add($no)
    }

    $normFrozen = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $frozen) {
        $nf = Normalize-RelPath $f
        if ([string]::IsNullOrWhiteSpace($nf)) { Fail "frozen path cannot be empty or root: $f" }
        if ($nf.Contains('..')) { Fail "frozen path escapes repository: $f" }
        $normFrozen.Add($nf)
    }

    if ([string]::IsNullOrWhiteSpace($workspaceDir)) {
        $tempBase = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "offload-exec-$taskId-" + [System.Guid]::NewGuid().ToString('N'))
        $workspaceDir = [System.IO.Path]::Combine($tempBase, 'checkout')
    }
    $canonWorkspace = Canonicalize-Path $workspaceDir

    # Safety checks against roots and repos
    if ([string]::Equals($canonWorkspace, $canonRepo, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "workspace directory cannot be the source repository: $workspaceDir"
    }
    $cwdLocation = Canonicalize-Path (Get-Location).Path
    if ([string]::Equals($canonWorkspace, $cwdLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "workspace directory cannot be process current directory: $workspaceDir"
    }
    $pathRoot = [System.IO.Path]::GetPathRoot($canonWorkspace)
    $trimmedRoot = Canonicalize-Path $pathRoot
    if ([string]::Equals($canonWorkspace, $trimmedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or [string]::IsNullOrEmpty($canonWorkspace)) {
        Fail "workspace directory cannot be filesystem root: $workspaceDir"
    }
    $homeDirs = @($env:USERPROFILE, $env:HOME) | Where-Object { -not [string]::IsNullOrEmpty($_) }
    foreach ($h in $homeDirs) {
        if ([string]::Equals($canonWorkspace, (Canonicalize-Path $h), [System.StringComparison]::OrdinalIgnoreCase)) {
            Fail "workspace directory cannot be user home directory: $workspaceDir"
        }
    }

    if ([string]::IsNullOrWhiteSpace($manifestPath)) {
        $wsParent = Split-Path -Parent $canonWorkspace
        $manifestPath = [System.IO.Path]::Combine($wsParent, "$taskId.manifest.json")
    }
    $canonManifest = Canonicalize-Path $manifestPath

    if ($canonManifest.StartsWith($canonWorkspace + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
        $canonManifest.StartsWith($canonWorkspace + '/', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($canonManifest, $canonWorkspace, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "manifest path must be outside the worker checkout: $manifestPath"
    }

    $manifestDir = Split-Path -Parent $canonManifest
    if (-not (Test-Path -LiteralPath $manifestDir -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($manifestDir) | Out-Null
    }
    $wsParentDir = Split-Path -Parent $canonWorkspace
    if (-not (Test-Path -LiteralPath $wsParentDir -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($wsParentDir) | Out-Null
    }

    if (Test-Path -LiteralPath $canonWorkspace -PathType Container) {
        $items = Get-ChildItem -LiteralPath $canonWorkspace -Force
        if ($items.Count -gt 0) {
            Fail "workspace directory already exists and is not empty: $workspaceDir"
        }
    }

    # Add git worktree
    $resAdd = Run-GitCommand -WorkingDir $canonRepo -GitArgs @('worktree', 'add', '--detach', $canonWorkspace, $resolvedBaseline)
    if ($resAdd.ExitCode -ne 0) {
        Fail "failed to create git worktree at $canonWorkspace from baseline $resolvedBaseline : $($resAdd.Stderr)"
    }

    # Write workspace marker
    $markerFile = [System.IO.Path]::Combine($canonWorkspace, $script:MarkerName)
    [System.IO.File]::WriteAllText($markerFile, "$($script:MarkerContent)`n", [System.Text.UTF8Encoding]::new($false))

    # Ensure marker is in git exclude so it is not treated as an untracked change
    $resExclude = Run-GitCommand -WorkingDir $canonRepo -GitArgs @('rev-parse', '--git-path', 'info/exclude')
    $excludePath = if ($resExclude.ExitCode -eq 0 -and (-not [string]::IsNullOrWhiteSpace($resExclude.Stdout))) {
        $rawEx = $resExclude.Stdout.Trim()
        if ([System.IO.Path]::IsPathRooted($rawEx)) {
            Canonicalize-Path $rawEx
        } else {
            Canonicalize-Path ([System.IO.Path]::Combine($canonRepo, $rawEx))
        }
    } else {
        Canonicalize-Path ([System.IO.Path]::Combine($canonRepo, '.git', 'info', 'exclude'))
    }
    $infoDir = Split-Path -Parent $excludePath
    if (-not (Test-Path -LiteralPath $infoDir -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($infoDir) | Out-Null
    }
    $needExclude = $true
    if (Test-Path -LiteralPath $excludePath -PathType Leaf) {
        $lines = Get-Content -LiteralPath $excludePath -ErrorAction SilentlyContinue
        if ($lines -contains $script:MarkerName) {
            $needExclude = $false
        }
    }
    if ($needExclude) {
        [System.IO.File]::AppendAllText($excludePath, "`n$($script:MarkerName)`n", [System.Text.UTF8Encoding]::new($false))
    }

    $manifestData = [ordered]@{
        schema_version = 1
        marker         = $script:ManifestMarker
        task_id        = $taskId
        source_repo    = $canonRepo
        workspace_dir  = $canonWorkspace
        manifest_path  = $canonManifest
        baseline       = $resolvedBaseline
        owned_paths    = @($normOwned)
        frozen_paths   = @($normFrozen)
        status         = "created"
        created_at     = Get-IsoTimestamp
    }

    $manifestJson = $manifestData | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($canonManifest, "$manifestJson`n", [System.Text.UTF8Encoding]::new($false))

    [Console]::Out.WriteLine($canonWorkspace)
}

# ---------------------------------------------------------------------------
# Command: verify-export
# ---------------------------------------------------------------------------
function Cmd-VerifyExport([string[]]$cmdArgs) {
    $manifestPath = ""
    $patchOutput = ""

    $i = 0
    while ($i -lt $cmdArgs.Count) {
        $arg = [string]$cmdArgs[$i]
        if ($arg -eq '--manifest') {
            $i++
            if ($i -ge $cmdArgs.Count) { Fail "--manifest requires a path" }
            $manifestPath = [string]$cmdArgs[$i]
        } elseif ($arg.StartsWith('--manifest=')) {
            $manifestPath = $arg.Substring('--manifest='.Length)
        } elseif ($arg -eq '--patch-output') {
            $i++
            if ($i -ge $cmdArgs.Count) { Fail "--patch-output requires a path" }
            $patchOutput = [string]$cmdArgs[$i]
        } elseif ($arg.StartsWith('--patch-output=')) {
            $patchOutput = $arg.Substring('--patch-output='.Length)
        } elseif ($arg -eq '-h' -or $arg -eq '--help') {
            Show-Usage
            exit 0
        } else {
            Fail "unrecognized argument for verify-export: $arg"
        }
        $i++
    }

    if ([string]::IsNullOrWhiteSpace($manifestPath)) { Fail "--manifest is required" }
    $canonManifest = Canonicalize-Path $manifestPath
    if (-not (Test-Path -LiteralPath $canonManifest -PathType Leaf)) {
        Fail "manifest file does not exist: $manifestPath"
    }

    $manifestContent = [System.IO.File]::ReadAllText($canonManifest, [System.Text.Encoding]::UTF8)
    $manifest = $manifestContent | ConvertFrom-Json

    if ($manifest.marker -ne $script:ManifestMarker) {
        Fail "invalid manifest marker in $manifestPath"
    }

    $workspaceDir = Canonicalize-Path $manifest.workspace_dir
    $sourceRepo = Canonicalize-Path $manifest.source_repo
    $baseline = [string]$manifest.baseline
    $taskId = [string]$manifest.task_id

    if (-not (Test-Path -LiteralPath $workspaceDir -PathType Container)) {
        Fail "candidate workspace directory does not exist: $workspaceDir"
    }
    $markerFile = [System.IO.Path]::Combine($workspaceDir, $script:MarkerName)
    if (-not (Test-Path -LiteralPath $markerFile -PathType Leaf)) {
        Fail "candidate directory lacks execution workspace marker: $workspaceDir"
    }
    $markerContent = ([System.IO.File]::ReadAllText($markerFile)).Trim()
    if ($markerContent -ne $script:MarkerContent) {
        Fail "invalid execution workspace marker content in $workspaceDir"
    }

    $ownedPaths = @($manifest.owned_paths)
    $frozenPaths = @($manifest.frozen_paths)

    if ($ownedPaths.Count -eq 0) {
        Fail "manifest contains no owned paths"
    }

    # The review artifact must live outside the candidate so the worker cannot
    # change the evidence after export.
    if ([string]::IsNullOrWhiteSpace($patchOutput)) {
        $mDir = Split-Path -Parent $canonManifest
        $patchOutput = [System.IO.Path]::Combine($mDir, "$taskId.patch")
    }
    $canonPatch = Canonicalize-Path $patchOutput
    if (Test-PathWithin $canonPatch $workspaceDir) {
        Fail "patch output must be outside candidate workspace: $patchOutput"
    }

    # 1. Run scope verification via check-execution-scope.ps1 inside candidate workspace
    $scopeArgs = [System.Collections.Generic.List[string]]::new()
    $scopeArgs.Add('-NoProfile')
    $scopeArgs.Add('-NonInteractive')
    $scopeArgs.Add('-File')
    $scopeArgs.Add($script:ScopeChecker)
    $scopeArgs.Add('--baseline')
    $scopeArgs.Add($baseline)
    foreach ($o in $ownedPaths) {
        $scopeArgs.Add('--owned')
        $scopeArgs.Add([string]$o)
    }
    foreach ($f in $frozenPaths) {
        $scopeArgs.Add('--frozen')
        $scopeArgs.Add([string]$f)
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    foreach ($sa in $scopeArgs) {
        $psi.ArgumentList.Add($sa)
    }
    $psi.WorkingDirectory = $workspaceDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $scopeProc = [System.Diagnostics.Process]::Start($psi)
    $scopeOut = $scopeProc.StandardOutput.ReadToEnd()
    $scopeErr = $scopeProc.StandardError.ReadToEnd()
    $scopeProc.WaitForExit()

    if ($scopeProc.ExitCode -ne 0) {
        [Console]::Error.WriteLine("Error: execution scope check failed for candidate $taskId :")
        if (-not [string]::IsNullOrWhiteSpace($scopeOut)) { [Console]::Error.WriteLine($scopeOut.Trim()) }
        if (-not [string]::IsNullOrWhiteSpace($scopeErr)) { [Console]::Error.WriteLine($scopeErr.Trim()) }
        exit $scopeProc.ExitCode
    }

    # 2. Stage all changes (uncommitted and untracked)
    $resAdd = Run-GitCommand -WorkingDir $workspaceDir -GitArgs @('add', '-A')
    if ($resAdd.ExitCode -ne 0) {
        Fail "failed to stage working tree changes: $($resAdd.Stderr)"
    }

    # Determine patch destination
    $patchDir = Split-Path -Parent $canonPatch
    if (-not (Test-Path -LiteralPath $patchDir -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($patchDir) | Out-Null
    }

    # Generate binary diff from baseline
    $resDiff = Run-GitCommand -WorkingDir $workspaceDir -GitArgs @('diff', '--cached', '--find-renames', '-p', '--binary', $baseline, '--output', $canonPatch)
    if ($resDiff.ExitCode -ne 0) {
        Fail "failed to export git diff from baseline $baseline : $($resDiff.Stderr)"
    }
    if (-not (Test-Path -LiteralPath $canonPatch -PathType Leaf)) {
        Fail "failed to produce patch file at $canonPatch"
    }

    # 3. Compute content digest
    $hexDigest = Get-FileSha256 $canonPatch
    $patchDigest = "sha256:$hexDigest"

    # 4. Verify touched paths in diff against owned and frozen
    $resNames = Run-GitCommand -WorkingDir $workspaceDir -GitArgs @('diff', '--cached', '--name-status', '-z', '--find-renames', $baseline)
    if ($resNames.ExitCode -ne 0) {
        Fail "failed to list exported paths from baseline $baseline : $($resNames.Stderr)"
    }
    $rawNames = $resNames.Stdout.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)
    $touchedList = [System.Collections.Generic.List[string]]::new()

    $nameIndex = 0
    while ($nameIndex -lt $rawNames.Length) {
        $status = [string]$rawNames[$nameIndex]
        if ($nameIndex + 1 -ge $rawNames.Length) {
            Fail "malformed NUL-delimited git diff output"
        }
        $t = Normalize-RelPath ([string]$rawNames[$nameIndex + 1])
        if ([string]::IsNullOrWhiteSpace($t)) {
            $nameIndex += 2
            continue
        }
        $touchedList.Add($t)
        if ($status.StartsWith('R') -or $status.StartsWith('C')) {
            if ($nameIndex + 2 -ge $rawNames.Length) {
                Fail "malformed NUL-delimited git rename output"
            }
            $renameTarget = Normalize-RelPath ([string]$rawNames[$nameIndex + 2])
            if (-not [string]::IsNullOrWhiteSpace($renameTarget)) {
                $touchedList.Add($renameTarget)
            }
            $nameIndex += 1
        }
        $nameIndex += 2
    }

    foreach ($t in $touchedList) {
        foreach ($f in $frozenPaths) {
            $nf = [string]$f
            if ($t -eq $nf -or $t.StartsWith("$nf/")) {
                Fail "exported diff touches frozen path: $t"
            }
        }

        $isOwned = $false
        foreach ($o in $ownedPaths) {
            $no = [string]$o
            if ($t -eq $no -or $t.StartsWith("$no/")) {
                $isOwned = $true
                break
            }
        }
        if (-not $isOwned) {
            Fail "exported diff touches unowned path: $t"
        }
    }

    # 5. Update manifest
    $manifestData = [ordered]@{
        schema_version = $manifest.schema_version
        marker         = $manifest.marker
        task_id        = $manifest.task_id
        source_repo    = $manifest.source_repo
        workspace_dir  = $manifest.workspace_dir
        manifest_path  = $manifest.manifest_path
        baseline       = $manifest.baseline
        owned_paths    = @($manifest.owned_paths)
        frozen_paths   = @($manifest.frozen_paths)
        status         = "exported"
        patch_file     = $canonPatch
        patch_digest   = $patchDigest
        touched_paths  = @($touchedList)
        exported_at    = Get-IsoTimestamp
    }

    $manifestJson = $manifestData | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($canonManifest, "$manifestJson`n", [System.Text.UTF8Encoding]::new($false))

    [Console]::Out.WriteLine($canonPatch)
}

# ---------------------------------------------------------------------------
# Command: integrate
# ---------------------------------------------------------------------------
function Cmd-Integrate([string[]]$cmdArgs) {
    $manifestPath = ""
    $targetRepo = ""

    $i = 0
    while ($i -lt $cmdArgs.Count) {
        $arg = [string]$cmdArgs[$i]
        if ($arg -eq '--manifest') {
            $i++
            if ($i -ge $cmdArgs.Count) { Fail "--manifest requires a path" }
            $manifestPath = [string]$cmdArgs[$i]
        } elseif ($arg.StartsWith('--manifest=')) {
            $manifestPath = $arg.Substring('--manifest='.Length)
        } elseif ($arg -eq '--target-repo') {
            $i++
            if ($i -ge $cmdArgs.Count) { Fail "--target-repo requires a path" }
            $targetRepo = [string]$cmdArgs[$i]
        } elseif ($arg.StartsWith('--target-repo=')) {
            $targetRepo = $arg.Substring('--target-repo='.Length)
        } elseif ($arg -eq '-h' -or $arg -eq '--help') {
            Show-Usage
            exit 0
        } else {
            Fail "unrecognized argument for integrate: $arg"
        }
        $i++
    }

    if ([string]::IsNullOrWhiteSpace($manifestPath)) { Fail "--manifest is required" }
    $canonManifest = Canonicalize-Path $manifestPath
    if (-not (Test-Path -LiteralPath $canonManifest -PathType Leaf)) {
        Fail "manifest file does not exist: $manifestPath"
    }

    $manifestContent = [System.IO.File]::ReadAllText($canonManifest, [System.Text.Encoding]::UTF8)
    $manifest = $manifestContent | ConvertFrom-Json

    if ($manifest.marker -ne $script:ManifestMarker) {
        Fail "invalid manifest marker in $manifestPath"
    }

    $patchFile = [string]$manifest.patch_file
    $patchDigest = [string]$manifest.patch_digest
    $sourceRepo = Canonicalize-Path $manifest.source_repo
    $taskId = [string]$manifest.task_id

    if ([string]::IsNullOrWhiteSpace($patchFile) -or [string]::IsNullOrWhiteSpace($patchDigest)) {
        Fail "manifest does not record an exported patch file or digest; run verify-export first"
    }
    $canonPatch = Canonicalize-Path $patchFile
    if (-not (Test-Path -LiteralPath $canonPatch -PathType Leaf)) {
        Fail "patch file not found at: $canonPatch"
    }

    # 1. Content digest verification
    $actualDigest = "sha256:" + (Get-FileSha256 $canonPatch)
    if ($actualDigest -ne $patchDigest) {
        Fail "patch content digest mismatch: expected $patchDigest, got $actualDigest"
    }

    if ([string]::IsNullOrWhiteSpace($targetRepo)) {
        $targetRepo = $sourceRepo
    }
    $canonTarget = Canonicalize-Path $targetRepo
    if (-not (Test-Path -LiteralPath $canonTarget -PathType Container)) {
        Fail "target repository directory does not exist: $targetRepo"
    }
    $resInside = Run-GitCommand -WorkingDir $canonTarget -GitArgs @('rev-parse', '--is-inside-work-tree')
    if ($resInside.ExitCode -ne 0) {
        Fail "target repository is not a git worktree: $targetRepo"
    }

    # 2. Preflight into disposable integration checkout
    $integBase = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "offload-integ-$taskId-" + [System.Guid]::NewGuid().ToString('N'))
    $integDir = [System.IO.Path]::Combine($integBase, 'checkout')
    [System.IO.Directory]::CreateDirectory($integBase) | Out-Null

    $resAdd = Run-GitCommand -WorkingDir $canonTarget -GitArgs @('worktree', 'add', '--detach', $integDir, 'HEAD')
    if ($resAdd.ExitCode -ne 0) {
        Fail "failed to create disposable integration worktree at $integDir : $($resAdd.Stderr)"
    }

    $preflightPassed = $false
    $applyError = ""

    try {
        $resApply = Run-GitCommand -WorkingDir $integDir -GitArgs @('apply', '--binary', $canonPatch)
        if ($resApply.ExitCode -eq 0) {
            $preflightPassed = $true
        } else {
            $applyError = $resApply.Stderr
        }
    } finally {
        # Unconditionally cleanup disposable integration worktree
        Run-GitCommand -WorkingDir $canonTarget -GitArgs @('worktree', 'remove', '--force', $integDir) | Out-Null
        if (Test-Path -LiteralPath $integBase) {
            Remove-Item -LiteralPath $integBase -Recurse -Force -ErrorAction SilentlyContinue
        }
        Run-GitCommand -WorkingDir $canonTarget -GitArgs @('worktree', 'prune') | Out-Null
    }

    if (-not $preflightPassed) {
        Fail "integration preflight failed (patch conflict or unapplicable delta); candidate retained without publishing changes to target checkout: $applyError"
    }

    # 3. Apply patch to target repository
    $resTargetApply = Run-GitCommand -WorkingDir $canonTarget -GitArgs @('apply', '--binary', $canonPatch)
    if ($resTargetApply.ExitCode -ne 0) {
        Fail "failed to apply patch to target repository: $targetRepo : $($resTargetApply.Stderr)"
    }

    # 4. Update manifest status
    $manifestData = [ordered]@{
        schema_version = $manifest.schema_version
        marker         = $manifest.marker
        task_id        = $manifest.task_id
        source_repo    = $manifest.source_repo
        workspace_dir  = $manifest.workspace_dir
        manifest_path  = $manifest.manifest_path
        baseline       = $manifest.baseline
        owned_paths    = @($manifest.owned_paths)
        frozen_paths   = @($manifest.frozen_paths)
        status         = "integrated"
        patch_file     = $manifest.patch_file
        patch_digest   = $manifest.patch_digest
        touched_paths  = @($manifest.touched_paths)
        exported_at    = $manifest.exported_at
        integrated_at  = Get-IsoTimestamp
    }

    $manifestJson = $manifestData | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($canonManifest, "$manifestJson`n", [System.Text.UTF8Encoding]::new($false))

    [Console]::Out.WriteLine("Successfully integrated candidate $taskId into $canonTarget")
}

# ---------------------------------------------------------------------------
# Command: cleanup
# ---------------------------------------------------------------------------
function Cmd-Cleanup([string[]]$cmdArgs) {
    $manifestPath = ""
    $status = "success"

    $i = 0
    while ($i -lt $cmdArgs.Count) {
        $arg = [string]$cmdArgs[$i]
        if ($arg -eq '--manifest') {
            $i++
            if ($i -ge $cmdArgs.Count) { Fail "--manifest requires a path" }
            $manifestPath = [string]$cmdArgs[$i]
        } elseif ($arg.StartsWith('--manifest=')) {
            $manifestPath = $arg.Substring('--manifest='.Length)
        } elseif ($arg -eq '--status') {
            $i++
            if ($i -ge $cmdArgs.Count) { Fail "--status requires a value" }
            $status = [string]$cmdArgs[$i]
        } elseif ($arg.StartsWith('--status=')) {
            $status = $arg.Substring('--status='.Length)
        } elseif ($arg -eq '-h' -or $arg -eq '--help') {
            Show-Usage
            exit 0
        } else {
            Fail "unrecognized argument for cleanup: $arg"
        }
        $i++
    }

    if ([string]::IsNullOrWhiteSpace($manifestPath)) { Fail "--manifest is required" }
    $canonManifest = Canonicalize-Path $manifestPath
    if (-not (Test-Path -LiteralPath $canonManifest -PathType Leaf)) {
        Fail "manifest file does not exist: $manifestPath"
    }

    $manifestContent = [System.IO.File]::ReadAllText($canonManifest, [System.Text.Encoding]::UTF8)
    $manifest = $manifestContent | ConvertFrom-Json

    if ($manifest.marker -ne $script:ManifestMarker) {
        Fail "invalid manifest marker in $manifestPath"
    }

    $workspaceDir = [string]$manifest.workspace_dir
    $sourceRepo = [string]$manifest.source_repo
    $taskId = [string]$manifest.task_id
    $patchFile = if ($manifest.PSObject.Properties['patch_file']) { [string]$manifest.patch_file } else { "" }

    if ([string]::IsNullOrWhiteSpace($workspaceDir)) { Fail "manifest does not specify workspace_dir" }
    if ([string]::IsNullOrWhiteSpace($sourceRepo)) { Fail "manifest does not specify source_repo" }

    if ($status -notin @('success', 'failed', 'retain')) {
        Fail "invalid cleanup status: $status (must be success, failed, or retain)"
    }

    if ($status -in @('failed', 'retain')) {
        [Console]::Out.WriteLine("Candidate $taskId marked $status; retaining workspace at $workspaceDir")
        exit 0
    }

    if (-not (Test-Path -LiteralPath $workspaceDir -PathType Container)) {
        Run-GitCommand -WorkingDir $sourceRepo -GitArgs @('worktree', 'prune') | Out-Null
        Remove-Item -LiteralPath $canonManifest -Force -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($patchFile)) {
            Remove-Item -LiteralPath $patchFile -Force -ErrorAction SilentlyContinue
        }
        [Console]::Out.WriteLine("Cleaned up manifest for absent workspace: $workspaceDir")
        exit 0
    }

    $canonWorkspace = Canonicalize-Path $workspaceDir
    $canonSource = Canonicalize-Path $sourceRepo

    # Safety bounds
    $pathRoot = [System.IO.Path]::GetPathRoot($canonWorkspace)
    $trimmedRoot = Canonicalize-Path $pathRoot
    if ([string]::Equals($canonWorkspace, $trimmedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or [string]::IsNullOrEmpty($canonWorkspace)) {
        Fail "refusing to clean filesystem root: $canonWorkspace"
    }

    $cwdLocation = Canonicalize-Path (Get-Location).Path
    if ([string]::Equals($canonWorkspace, $cwdLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "refusing to clean process current directory: $canonWorkspace"
    }
    $envCwd = Canonicalize-Path [System.Environment]::CurrentDirectory
    if ([string]::Equals($canonWorkspace, $envCwd, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "refusing to clean process current directory: $canonWorkspace"
    }

    $homeDirs = @($env:USERPROFILE, $env:HOME) | Where-Object { -not [string]::IsNullOrEmpty($_) }
    foreach ($h in $homeDirs) {
        if ([string]::Equals($canonWorkspace, (Canonicalize-Path $h), [System.StringComparison]::OrdinalIgnoreCase)) {
            Fail "refusing to clean user home directory: $canonWorkspace"
        }
    }

    if ([string]::Equals($canonWorkspace, $canonSource, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "refusing to clean source repository checkout: $canonWorkspace"
    }

    $dotGitDir = [System.IO.Path]::Combine($canonWorkspace, '.git')
    if ([System.IO.Directory]::Exists($dotGitDir)) {
        Fail "refusing to clean main git repository (not a detached worktree): $canonWorkspace"
    }

    $markerFile = [System.IO.Path]::Combine($canonWorkspace, $script:MarkerName)
    if (-not (Test-Path -LiteralPath $markerFile -PathType Leaf)) {
        Fail "refusing to clean unmarked directory (missing $($script:MarkerName)): $canonWorkspace"
    }
    $markerVal = ([System.IO.File]::ReadAllText($markerFile)).Trim()
    if ($markerVal -ne $script:MarkerContent) {
        Fail "refusing to clean directory with invalid marker content: $canonWorkspace"
    }

    # Verify registered worktree
    $resList = Run-GitCommand -WorkingDir $canonSource -GitArgs @('worktree', 'list', '--porcelain')
    $isRegistered = $false
    $lines = $resList.Stdout.Split("`n")
    foreach ($line in $lines) {
        $tline = $line.Trim()
        if ($tline.StartsWith('worktree ')) {
            $wtPath = Canonicalize-Path ($tline.Substring('worktree '.Length))
            if ([string]::Equals($wtPath, $canonWorkspace, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isRegistered = $true
                break
            }
        }
    }

    if (-not $isRegistered) {
        Fail "directory is not registered as a worktree of ${sourceRepo}: $canonWorkspace"
    }

    # Remove worktree safely
    Run-GitCommand -WorkingDir $canonSource -GitArgs @('worktree', 'remove', '--force', $canonWorkspace) | Out-Null
    if (Test-Path -LiteralPath $canonWorkspace) {
        Remove-Item -LiteralPath $canonWorkspace -Recurse -Force -ErrorAction SilentlyContinue
    }
    Run-GitCommand -WorkingDir $canonSource -GitArgs @('worktree', 'prune') | Out-Null

    $wsParent = Split-Path -Parent $canonWorkspace
    $wsParentName = Split-Path -Leaf $wsParent
    if ($wsParentName.StartsWith('offload-exec-')) {
        Remove-Item -LiteralPath $wsParent -Recurse -Force -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath $canonManifest -Force -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($patchFile)) {
        Remove-Item -LiteralPath $patchFile -Force -ErrorAction SilentlyContinue
    }

    [Console]::Out.WriteLine("Cleaned up execution workspace: $canonWorkspace")
}

# ---------------------------------------------------------------------------
# CLI Entrypoint
# ---------------------------------------------------------------------------
if ($args.Count -eq 0) {
    Show-Usage
    exit 1
}

$commandVerb = [string]$args[0]
$restArgs = if ($args.Count -gt 1) { [string[]]$args[1..($args.Count - 1)] } else { @() }

switch ($commandVerb) {
    'create' {
        Cmd-Create $restArgs
    }
    { $_ -in @('verify-export', 'export') } {
        Cmd-VerifyExport $restArgs
    }
    'integrate' {
        Cmd-Integrate $restArgs
    }
    'cleanup' {
        Cmd-Cleanup $restArgs
    }
    { $_ -in @('-h', '--help') } {
        Show-Usage
        exit 0
    }
    default {
        Fail "unrecognized command: $commandVerb (must be create, verify-export, integrate, or cleanup)"
    }
}
