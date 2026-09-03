#!/usr/bin/env pwsh
# tests/test_execution_workspace.ps1
# Acceptance tests for scripts/execution-workspace.ps1
# Verifies candidate isolation, scope enforcement, digest auditing,
# disposable preflight integration, and cleanup ownership guards on PowerShell 7+.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:TotalTests = 0
$script:FailedTests = 0

function Pass([string]$name) {
    $script:TotalTests++
    [Console]::Out.WriteLine("ok - $name")
}

function Fail([string]$name, [string]$reason = "") {
    $script:TotalTests++
    $script:FailedTests++
    $msg = if ($reason) { "FAIL: $name - $reason" } else { "FAIL: $name" }
    [Console]::Error.WriteLine($msg)
    exit 1
}

function Assert-True([bool]$condition, [string]$name, [string]$reason = "") {
    if ($condition) {
        Pass $name
    } else {
        $failureReason = if ($reason) { $reason } else { "Condition was false" }
        Fail $name $failureReason
    }
}

function Assert-False([bool]$condition, [string]$name, [string]$reason = "") {
    if (-not $condition) {
        Pass $name
    } else {
        $failureReason = if ($reason) { $reason } else { "Condition was true" }
        Fail $name $failureReason
    }
}

function Assert-Equal($actual, $expected, [string]$name) {
    if ($actual -eq $expected) {
        Pass $name
    } else {
        Fail $name "Expected '$expected', got '$actual'"
    }
}

function Assert-NotEqual($actual, $expected, [string]$name) {
    if ($actual -ne $expected) {
        Pass $name
    } else {
        Fail $name "Expected not '$expected', but got '$actual'"
    }
}

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
$PwshBin = if ($pwshCmd) { $pwshCmd.Source } else { (Get-Process -Id $PID).Path }

$RootDir = Split-Path -Parent $PSScriptRoot
$ScriptsDir = Join-Path $RootDir 'scripts'
$HelperScript = Join-Path $ScriptsDir 'execution-workspace.ps1'

if (-not (Test-Path -LiteralPath $HelperScript -PathType Leaf)) {
    Fail "Helper existence check" "Script not found at $HelperScript"
}

$TmpRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "offload-test-exec-ws-ps-" + [System.Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($TmpRoot) | Out-Null

function Cleanup-TestRoot {
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Helper([string[]]$ArgumentList) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $PwshBin
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-NonInteractive')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($HelperScript)
    foreach ($a in $ArgumentList) {
        $psi.ArgumentList.Add($a)
    }
    $psi.WorkingDirectory = $TmpRoot
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

function Init-Repo([string]$repoDir) {
    [System.IO.Directory]::CreateDirectory($repoDir) | Out-Null
    & git -C $repoDir init -q
    & git -C $repoDir config user.name "Test User"
    & git -C $repoDir config user.email "test@example.com"
    & git -C $repoDir config commit.gpgsign false
    & git -C $repoDir config core.autocrlf false
}

try {
    # =======================================================================
    # 1. CLI validation & error handling
    # =======================================================================
    $resNoArgs = Invoke-Helper @()
    Assert-NotEqual $resNoArgs.ExitCode 0 "CLI requires command verb"

    $resUnknown = Invoke-Helper @('unknown-command')
    Assert-NotEqual $resUnknown.ExitCode 0 "CLI rejects unknown command verb"

    $resHelp = Invoke-Helper @('create', '--help')
    Assert-Equal $resHelp.ExitCode 0 "CLI supports help flag"

    # =======================================================================
    # 2. Sibling tasks starting from same baseline
    # =======================================================================
    $origRepo = Join-Path $TmpRoot 'orig_repo'
    Init-Repo $origRepo
    [System.IO.File]::WriteAllText((Join-Path $origRepo 'base.txt'), "base content`n")
    [System.IO.File]::WriteAllText((Join-Path $origRepo 'a.txt'), "a initial`n")
    [System.IO.File]::WriteAllText((Join-Path $origRepo 'b.txt'), "b initial`n")
    & git -C $origRepo add .
    & git -C $origRepo commit -q -m "initial commit"
    $baseline = (& git -C $origRepo rev-parse HEAD).Trim()

    $scratch = Join-Path $TmpRoot 'scratch'
    [System.IO.Directory]::CreateDirectory($scratch) | Out-Null

    # Create Candidate A
    $manifestA = Join-Path $scratch 'task-a.manifest.json'
    $resCreateA = Invoke-Helper @(
        'create',
        '--source-repo', $origRepo,
        '--task-id', 'task-a',
        '--baseline', $baseline,
        '--owned', 'a.txt',
        '--manifest', $manifestA
    )
    Assert-Equal $resCreateA.ExitCode 0 "create candidate A succeeds"
    $wsA = $resCreateA.Stdout.Trim()
    Assert-True (Test-Path -LiteralPath $wsA -PathType Container) "workspace A created on disk"
    Assert-True (Test-Path -LiteralPath (Join-Path $wsA '.offload-execution-workspace') -PathType Leaf) "workspace A has marker file"
    Assert-True (Test-Path -LiteralPath $manifestA -PathType Leaf) "manifest A created on disk"

    # Create Candidate B
    $manifestB = Join-Path $scratch 'task-b.manifest.json'
    $resCreateB = Invoke-Helper @(
        'create',
        '--source-repo', $origRepo,
        '--task-id', 'task-b',
        '--baseline', $baseline,
        '--owned', 'b.txt',
        '--manifest', $manifestB
    )
    Assert-Equal $resCreateB.ExitCode 0 "create candidate B succeeds at same baseline"
    $wsB = $resCreateB.Stdout.Trim()
    Assert-True (Test-Path -LiteralPath $wsB -PathType Container) "workspace B created on disk"

    # Fake workers independently edit their owned files
    # Worker A commits one change and leaves another uncommitted
    [System.IO.File]::WriteAllText((Join-Path $wsA 'a.txt'), "a modified committed`n")
    & git -C $wsA commit -q -am "worker a commit"
    [System.IO.File]::AppendAllText((Join-Path $wsA 'a.txt'), "a modified uncommitted line`n")

    # Worker B modifies b.txt without committing
    [System.IO.File]::WriteAllText((Join-Path $wsB 'b.txt'), "b modified uncommitted`n")

    # Verify-export Candidate A
    $resExportA = Invoke-Helper @('verify-export', '--manifest', $manifestA)
    Assert-Equal $resExportA.ExitCode 0 "verify-export candidate A succeeds"
    $patchA = $resExportA.Stdout.Trim()
    Assert-True (Test-Path -LiteralPath $patchA -PathType Leaf) "patch file A produced on disk"
    $patchAContent = [System.IO.File]::ReadAllText($patchA)
    Assert-True ($patchAContent.Contains("a modified committed")) "patch A contains committed changes"
    Assert-True ($patchAContent.Contains("a modified uncommitted line")) "patch A contains uncommitted changes"

    # Verify-export Candidate B
    $resExportB = Invoke-Helper @('verify-export', '--manifest', $manifestB)
    Assert-Equal $resExportB.ExitCode 0 "verify-export candidate B succeeds"
    $patchB = $resExportB.Stdout.Trim()
    Assert-True (Test-Path -LiteralPath $patchB -PathType Leaf) "patch file B produced on disk"
    $patchBContent = [System.IO.File]::ReadAllText($patchB)
    Assert-True ($patchBContent.Contains("b modified uncommitted")) "patch B contains uncommitted changes"

    # Integrate Candidate A into original repository
    $resIntegA = Invoke-Helper @('integrate', '--manifest', $manifestA, '--target-repo', $origRepo)
    Assert-Equal $resIntegA.ExitCode 0 "integrate candidate A succeeds"
    $targetAContent = [System.IO.File]::ReadAllText((Join-Path $origRepo 'a.txt'))
    Assert-True ($targetAContent.Contains("a modified uncommitted line")) "candidate A changes applied to target repo"

    # Commit Candidate A in target repo so working tree is clean for candidate B
    & git -C $origRepo commit -q -am "integrated task a"

    # Integrate Candidate B into original repository
    $resIntegB = Invoke-Helper @('integrate', '--manifest', $manifestB, '--target-repo', $origRepo)
    Assert-Equal $resIntegB.ExitCode 0 "integrate candidate B succeeds alongside candidate A"
    $targetBContent = [System.IO.File]::ReadAllText((Join-Path $origRepo 'b.txt'))
    Assert-True ($targetBContent.Contains("b modified uncommitted")) "candidate B changes applied to target repo"

    # =======================================================================
    # 3. Scope violation blocks export and integration
    # =======================================================================
    $manifestBad = Join-Path $scratch 'task-bad.manifest.json'
    $resCreateBad = Invoke-Helper @(
        'create',
        '--source-repo', $origRepo,
        '--task-id', 'task-bad',
        '--baseline', $baseline,
        '--owned', 'a.txt',
        '--frozen', 'base.txt',
        '--manifest', $manifestBad
    )
    Assert-Equal $resCreateBad.ExitCode 0 "create task-bad succeeds"
    $wsBad = $resCreateBad.Stdout.Trim()

    # Worker violates scope by modifying unowned b.txt and frozen base.txt
    [System.IO.File]::WriteAllText((Join-Path $wsBad 'b.txt'), "unowned mutation`n")
    [System.IO.File]::WriteAllText((Join-Path $wsBad 'base.txt'), "frozen mutation`n")
    & git -C $wsBad commit -q -am "violating commit"

    $resExportBad = Invoke-Helper @('verify-export', '--manifest', $manifestBad)
    Assert-NotEqual $resExportBad.ExitCode 0 "scope violation blocks verify-export"

    $resIntegBad = Invoke-Helper @('integrate', '--manifest', $manifestBad, '--target-repo', $origRepo)
    Assert-NotEqual $resIntegBad.ExitCode 0 "unexported candidate cannot be integrated"

    # =======================================================================
    # 4. Content digest tampering detection
    # =======================================================================
    $tamperRepo = Join-Path $TmpRoot 'tamper_repo'
    Init-Repo $tamperRepo
    [System.IO.File]::WriteAllText((Join-Path $tamperRepo 'base.txt'), "base content`n")
    [System.IO.File]::WriteAllText((Join-Path $tamperRepo 'a.txt'), "a initial`n")
    & git -C $tamperRepo add .
    & git -C $tamperRepo commit -q -m "initial"

    # Tamper patch file A
    [System.IO.File]::AppendAllText($patchA, "`n# injected tampering`n")
    $resIntegTamper = Invoke-Helper @('integrate', '--manifest', $manifestA, '--target-repo', $tamperRepo)
    Assert-NotEqual $resIntegTamper.ExitCode 0 "integrate tampered patch returns non-zero"
    Assert-True ($resIntegTamper.Stderr.Contains("content digest mismatch")) "patch content digest mismatch reported"

    # =======================================================================
    # 5. Integration conflict in disposable checkout preflight
    # =======================================================================
    $conflictRepo = Join-Path $TmpRoot 'conflict_repo'
    Init-Repo $conflictRepo
    [System.IO.File]::WriteAllText((Join-Path $conflictRepo 'conflict.txt'), "common line`n")
    & git -C $conflictRepo add .
    & git -C $conflictRepo commit -q -m "initial"
    $cBase = (& git -C $conflictRepo rev-parse HEAD).Trim()

    $manifestC = Join-Path $scratch 'task-c.manifest.json'
    $resCreateC = Invoke-Helper @(
        'create',
        '--source-repo', $conflictRepo,
        '--task-id', 'task-c',
        '--baseline', $cBase,
        '--owned', 'conflict.txt',
        '--manifest', $manifestC
    )
    $wsC = $resCreateC.Stdout.Trim()

    # Candidate C changes conflict.txt
    [System.IO.File]::WriteAllText((Join-Path $wsC 'conflict.txt'), "candidate change`n")
    $resExportC = Invoke-Helper @('verify-export', '--manifest', $manifestC)
    Assert-Equal $resExportC.ExitCode 0 "export candidate C succeeds"

    # Target repo makes conflicting commit
    [System.IO.File]::WriteAllText((Join-Path $conflictRepo 'conflict.txt'), "conflicting caller change`n")
    & git -C $conflictRepo commit -q -am "conflicting commit"

    # Integration should detect conflict in disposable preflight
    $resIntegConflict = Invoke-Helper @('integrate', '--manifest', $manifestC, '--target-repo', $conflictRepo)
    Assert-NotEqual $resIntegConflict.ExitCode 0 "integration conflict detected and exits non-zero"
    $targetConflictText = [System.IO.File]::ReadAllText((Join-Path $conflictRepo 'conflict.txt'))
    Assert-True ($targetConflictText.Contains("conflicting caller change")) "target repo retained its own content"
    $statusConflict = (& git -C $conflictRepo status --porcelain)
    Assert-True ([string]::IsNullOrWhiteSpace($statusConflict)) "target repo working tree left clean"

    # =======================================================================
    # 6. Cleanup ownership guards
    # =======================================================================
    $resCleanRetain = Invoke-Helper @('cleanup', '--manifest', $manifestA, '--status', 'retain')
    Assert-Equal $resCleanRetain.ExitCode 0 "cleanup with status retain exits 0"
    Assert-True (Test-Path -LiteralPath $wsA -PathType Container) "workspace A retained on disk"

    # Manifest attacking source repo
    $manifestAttack = Join-Path $scratch 'attack.manifest.json'
    $attackData = [ordered]@{
        schema_version = 1
        marker         = 'offload-execution-manifest-v1'
        task_id        = 'attack'
        source_repo    = $origRepo
        workspace_dir  = $origRepo
        manifest_path  = $manifestAttack
        baseline       = $baseline
        owned_paths    = @('a.txt')
        frozen_paths   = @()
    }
    [System.IO.File]::WriteAllText($manifestAttack, ($attackData | ConvertTo-Json -Depth 5))

    $resCleanAttack = Invoke-Helper @('cleanup', '--manifest', $manifestAttack)
    Assert-NotEqual $resCleanAttack.ExitCode 0 "cleanup refuses to clean source repository"
    Assert-True (Test-Path -LiteralPath $origRepo -PathType Container) "source repository preserved"

    # Normal cleanup of Candidate A
    $resCleanA = Invoke-Helper @('cleanup', '--manifest', $manifestA, '--status', 'success')
    Assert-Equal $resCleanA.ExitCode 0 "normal cleanup succeeds"
    Assert-False (Test-Path -LiteralPath $wsA) "workspace A removed from disk"
    Assert-False (Test-Path -LiteralPath $manifestA) "manifest A removed from disk"

    [Console]::Out.WriteLine("all powershell execution workspace tests passed ($($script:TotalTests) tests)")
} finally {
    Cleanup-TestRoot
}
