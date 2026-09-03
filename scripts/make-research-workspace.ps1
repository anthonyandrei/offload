#!/usr/bin/env pwsh
# scripts/make-research-workspace.ps1
# Creates an isolated research workspace with scoped repository snapshot.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Show-Usage {
    [Console]::Error.WriteLine("Usage: make-research-workspace.ps1 [--source-repo <path>] [--path <declared-path> ...]")
}

function Cleanup-And-Fail([string]$ws, [string]$message, [int]$exitCode = 1) {
    [Console]::Error.WriteLine("Error: $message")
    if ($ws -and (Test-Path -LiteralPath $ws)) {
        Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit $exitCode
}

$sourceRepo = ""
$declaredPaths = [System.Collections.Generic.List[string]]::new()

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    if ($arg -eq '--source-repo') {
        $i++
        if ($i -ge $args.Count) {
            Show-Usage
            [Console]::Error.WriteLine("Error: --source-repo requires a path")
            exit 1
        }
        $sourceRepo = [string]$args[$i]
    } elseif ($arg -eq '--path') {
        $i++
        if ($i -ge $args.Count) {
            Show-Usage
            [Console]::Error.WriteLine("Error: --path requires a path")
            exit 1
        }
        $declaredPaths.Add([string]$args[$i])
    } elseif ($arg -eq '-h' -or $arg -eq '--help') {
        Show-Usage
        exit 0
    } else {
        Show-Usage
        [Console]::Error.WriteLine("Error: unrecognized argument: $arg")
        exit 1
    }
    $i++
}

# Create isolated temporary workspace
$tempDir = [System.IO.Path]::GetTempPath()
$workspaceName = "offload-research-" + [System.Guid]::NewGuid().ToString("N")
$workspace = [System.IO.Path]::Combine($tempDir, $workspaceName)

try {
    [System.IO.Directory]::CreateDirectory($workspace) | Out-Null
    $markerFile = [System.IO.Path]::Combine($workspace, '.offload-research-workspace')
    [System.IO.File]::WriteAllText($markerFile, "offload-research-workspace-v1`n", [System.Text.UTF8Encoding]::new($false))
} catch {
    Cleanup-And-Fail $workspace "failed to initialize workspace: $($_.Exception.Message)"
}

if (-not [string]::IsNullOrEmpty($sourceRepo)) {
    if (-not (Test-Path -LiteralPath $sourceRepo -PathType Container)) {
        Cleanup-And-Fail $workspace "source repository does not exist: $sourceRepo"
    }

    $canonicalRepo = [System.IO.Path]::GetFullPath($sourceRepo).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

    foreach ($declaredPath in $declaredPaths) {
        # Check rooted or absolute
        if ([System.IO.Path]::IsPathRooted($declaredPath) -or $declaredPath.StartsWith('/') -or $declaredPath.StartsWith('\')) {
            Cleanup-And-Fail $workspace "declared path must be relative to the source repository: $declaredPath"
        }

        # Check traversal
        $normPath = $declaredPath -replace '\\', '/'
        $parts = $normPath.Split('/')
        foreach ($part in $parts) {
            if ($part -eq '..') {
                Cleanup-And-Fail $workspace "declared path escapes the source repository: $declaredPath"
            }
        }

        # Normalize relative path
        $relPath = $normPath
        while ($relPath.StartsWith('./')) {
            $relPath = $relPath.Substring(2)
        }

        $fullSrc = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($canonicalRepo, $relPath))

        # Ensure it does not escape source repo
        $repoPrefix = $canonicalRepo + [System.IO.Path]::DirectorySeparatorChar
        if (-not ($fullSrc -eq $canonicalRepo -or $fullSrc.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
            Cleanup-And-Fail $workspace "declared path resolves outside source repository: $declaredPath"
        }

        # Check if declared path exists
        $srcExists = (Test-Path -LiteralPath $fullSrc)
        if (-not $srcExists) {
            [Console]::Error.WriteLine("Warning: declared path does not exist: $fullSrc")
            continue
        }

        # Check for symlink/junction/reparse point in path hierarchy
        $accumPath = $canonicalRepo
        foreach ($part in $parts) {
            if ([string]::IsNullOrEmpty($part) -or $part -eq '.') { continue }
            $accumPath = [System.IO.Path]::Combine($accumPath, $part)
            if (Test-Path -LiteralPath $accumPath) {
                $attr = [System.IO.File]::GetAttributes($accumPath)
                if ($attr.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                    Cleanup-And-Fail $workspace "declared path contains a symlink or junction: $declaredPath"
                }
            }
        }

        # If it's a directory, check all descendants for reparse point
        if (Test-Path -LiteralPath $fullSrc -PathType Container) {
            try {
                $dirInfo = [System.IO.DirectoryInfo]::new($fullSrc)
                $descendants = $dirInfo.EnumerateFileSystemInfos("*", [System.IO.SearchOption]::AllDirectories)
                foreach ($item in $descendants) {
                    if ($item.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                        Cleanup-And-Fail $workspace "declared path contains a symlink or junction: $declaredPath"
                    }
                }
            } catch {
                Cleanup-And-Fail $workspace "failed scanning directory attributes: $($_.Exception.Message)"
            }
        }

        # Copy to destination: $workspace/repo/$relPath
        $dest = [System.IO.Path]::Combine($workspace, 'repo', ($relPath -replace '/', [System.IO.Path]::DirectorySeparatorChar))

        try {
            if (Test-Path -LiteralPath $fullSrc -PathType Container) {
                if (-not [System.IO.Directory]::Exists($dest)) {
                    [System.IO.Directory]::CreateDirectory($dest) | Out-Null
                }
                foreach ($dir in [System.IO.Directory]::GetDirectories($fullSrc, "*", [System.IO.SearchOption]::AllDirectories)) {
                    $sub = $dir.Substring($fullSrc.Length).TrimStart('/\')
                    $destSub = [System.IO.Path]::Combine($dest, $sub)
                    if (-not [System.IO.Directory]::Exists($destSub)) {
                        [System.IO.Directory]::CreateDirectory($destSub) | Out-Null
                    }
                }
                foreach ($file in [System.IO.Directory]::GetFiles($fullSrc, "*", [System.IO.SearchOption]::AllDirectories)) {
                    $sub = $file.Substring($fullSrc.Length).TrimStart('/\')
                    $destFile = [System.IO.Path]::Combine($dest, $sub)
                    [System.IO.File]::Copy($file, $destFile, $true)
                }
            } else {
                $destParent = [System.IO.Path]::GetDirectoryName($dest)
                if (-not [string]::IsNullOrEmpty($destParent) -and -not [System.IO.Directory]::Exists($destParent)) {
                    [System.IO.Directory]::CreateDirectory($destParent) | Out-Null
                }
                [System.IO.File]::Copy($fullSrc, $dest, $true)
            }
        } catch {
            Cleanup-And-Fail $workspace "failed to copy declared path: $declaredPath ($($_.Exception.Message))"
        }
    }
}

Write-Output $workspace
exit 0
