#!/usr/bin/env pwsh
# tests/test_review_artifact.ps1
# Verifies that verify-export records one complete, digest-checked review artifact.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$RootDir = Split-Path -Parent $PSScriptRoot
$Helper = Join-Path $RootDir 'scripts/execution-workspace.ps1'
$Pwsh = (Get-Command pwsh).Source
$TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('offload-test-review-artifact-' + [Guid]::NewGuid().ToString('N'))

function Fail([string]$message) {
    [Console]::Error.WriteLine("FAIL: $message")
    exit 1
}

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { Fail $message }
    [Console]::Out.WriteLine("ok - $message")
}

function Invoke-Helper([string]$workingDir, [string[]]$arguments) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Pwsh
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-NonInteractive')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($Helper)
    foreach ($argument in $arguments) { $psi.ArgumentList.Add($argument) }
    $psi.WorkingDirectory = $workingDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [PSCustomObject]@{ ExitCode = $process.ExitCode; Stdout = $stdout.Trim(); Stderr = $stderr }
}

function Init-Repo([string]$repo) {
    [IO.Directory]::CreateDirectory($repo) | Out-Null
    & git -C $repo init -q
    & git -C $repo config user.name 'Test User'
    & git -C $repo config user.email 'test@example.com'
    & git -C $repo config commit.gpgsign false
    & git -C $repo config core.autocrlf false
}

try {
    [IO.Directory]::CreateDirectory($TmpRoot) | Out-Null
    $repo = Join-Path $TmpRoot 'repo'
    $scratch = Join-Path $TmpRoot 'scratch'
    Init-Repo $repo
    [IO.Directory]::CreateDirectory($scratch) | Out-Null

    $baselineFiles = @{
        'committed.txt' = 'committed baseline`n'
        'staged.txt' = 'staged baseline`n'
        'unstaged.txt' = 'unstaged baseline`n'
        'deleted.txt' = 'deleted baseline`n'
        'renamed.txt' = 'rename source baseline`n'
        'binary.dat' = [byte[]](0, 1, 2, 3)
    }
    foreach ($entry in $baselineFiles.GetEnumerator()) {
        $path = Join-Path $repo $entry.Key
        if ($entry.Value -is [byte[]]) { [IO.File]::WriteAllBytes($path, $entry.Value) }
        else { [IO.File]::WriteAllText($path, $entry.Value) }
    }
    & git -C $repo add .
    & git -C $repo commit -q -m baseline
    $baseline = (& git -C $repo rev-parse HEAD).Trim()

    $manifest = Join-Path $scratch 'candidate.manifest.json'
    $created = Invoke-Helper $TmpRoot @('create', '--source-repo', $repo, '--task-id', 'candidate', '--baseline', $baseline, '--owned', 'committed.txt', '--owned', 'staged.txt', '--owned', 'unstaged.txt', '--owned', 'deleted.txt', '--owned', 'renamed.txt', '--owned', 'binary.dat', '--owned', 'new.txt', '--manifest', $manifest)
    Assert-True ($created.ExitCode -eq 0) "candidate workspace is created"
    $workspace = $created.Stdout

    [IO.File]::WriteAllText((Join-Path $workspace 'committed.txt'), "committed edit`n")
    & git -C $workspace add committed.txt
    & git -C $workspace commit -q -m committed-edit
    [IO.File]::WriteAllText((Join-Path $workspace 'staged.txt'), "staged edit`n")
    & git -C $workspace add staged.txt
    [IO.File]::WriteAllText((Join-Path $workspace 'unstaged.txt'), "unstaged edit`n")
    [IO.File]::WriteAllText((Join-Path $workspace 'new.txt'), "new file edit`n")
    Remove-Item -LiteralPath (Join-Path $workspace 'deleted.txt')
    & git -C $workspace mv renamed.txt renamed-final.txt
    [IO.File]::WriteAllBytes((Join-Path $workspace 'binary.dat'), [byte[]](9, 8, 7, 6))

    $unownedRename = Invoke-Helper $TmpRoot @('verify-export', '--manifest', $manifest)
    Assert-True ($unownedRename.ExitCode -ne 0) "export rejects an unowned rename destination"

    # The renamed destination is also owned. Scope checking must expose both names.
    $manifestData = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
    $manifestData.owned_paths += 'renamed-final.txt'
    $manifestData | ConvertTo-Json -Depth 5 | Set-Content -NoNewline -LiteralPath $manifest

    $exported = Invoke-Helper $TmpRoot @('verify-export', '--manifest', $manifest)
    Assert-True ($exported.ExitCode -eq 0) "mixed candidate changes export successfully"
    $artifact = $exported.Stdout
    Assert-True (Test-Path -LiteralPath $artifact -PathType Leaf) "review artifact is written outside the candidate"
    $artifactText = [IO.File]::ReadAllText($artifact)
    Assert-True $artifactText.Contains('committed edit') "artifact contains committed edits"
    Assert-True $artifactText.Contains('staged edit') "artifact contains staged edits"
    Assert-True $artifactText.Contains('unstaged edit') "artifact contains unstaged edits"
    Assert-True $artifactText.Contains('new file edit') "artifact contains new files"
    Assert-True $artifactText.Contains('deleted file mode') "artifact contains deletions"
    Assert-True $artifactText.Contains('rename from renamed.txt') -and $artifactText.Contains('rename to renamed-final.txt') "artifact contains rename metadata"
    Assert-True $artifactText.Contains('GIT binary patch') "artifact identifies binary changes"

    $recorded = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
    $actualDigest = 'sha256:' + (Get-FileHash -Algorithm SHA256 -LiteralPath $artifact).Hash.ToLowerInvariant()
    Assert-True ($recorded.patch_file -eq $artifact) "manifest records the exact artifact path"
    Assert-True ($recorded.patch_digest -eq $actualDigest) "manifest records the artifact digest"

    $insideArtifact = Join-Path $workspace 'review.patch'
    $insideExport = Invoke-Helper $TmpRoot @('verify-export', '--manifest', $manifest, '--patch-output', $insideArtifact)
    Assert-True ($insideExport.ExitCode -ne 0) "export rejects an artifact path inside the candidate"

    $before = [IO.File]::ReadAllBytes($artifact)
    [IO.File]::WriteAllText((Join-Path $workspace 'unstaged.txt'), "candidate changed after export`n")
    $after = [IO.File]::ReadAllBytes($artifact)
    Assert-True ([Linq.Enumerable]::SequenceEqual($before, $after)) "candidate changes do not mutate the recorded artifact"

    # Fake reviewer consumes the recorded bytes, never the candidate checkout.
    $reviewQuote = Select-String -LiteralPath $artifact -Pattern 'staged edit' -SimpleMatch
    Assert-True ($null -ne $reviewQuote) "fake reviewer can quote the recorded artifact"
    $digestCheck = 'sha256:' + (Get-FileHash -Algorithm SHA256 -LiteralPath $artifact).Hash.ToLowerInvariant()
    Assert-True ($digestCheck -eq $recorded.patch_digest) "quote verification can recheck the recorded digest"

    [Console]::Out.WriteLine('all review artifact powershell tests passed')
} finally {
    if (Test-Path -LiteralPath $TmpRoot) { Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
