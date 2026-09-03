#!/usr/bin/env pwsh
# tests/test_execution_scope.ps1
# Self-contained acceptance test suite for scripts/check-execution-scope.ps1.
# Implements contracts specified in docs/specs/0001-platform-agnostic-workflows.md.
# Strict constraints: Standalone PowerShell 7 / .NET only, no Pester, Python, jq, or network.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# ---------------------------------------------------------------------------
# Compact Self-Contained Assertion Harness
# ---------------------------------------------------------------------------

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
        Fail $name (if ($reason) { $reason } else { "Condition was false" })
    }
}

function Assert-False([bool]$condition, [string]$name, [string]$reason = "") {
    if (-not $condition) {
        Pass $name
    } else {
        Fail $name (if ($reason) { $reason } else { "Condition was true" })
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

# ---------------------------------------------------------------------------
# Public Process Runner
# ---------------------------------------------------------------------------

$PwshBin = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $PwshBin) {
    $PwshBin = (Get-Process -Id $PID).Path
}

$RootDir = Split-Path -Parent $PSScriptRoot
$ScriptsDir = Join-Path $RootDir 'scripts'
$HelperScript = 'check-execution-scope.ps1'
$HelperPath = Join-Path $ScriptsDir $HelperScript

if (-not (Test-Path -LiteralPath $HelperPath)) {
    Fail "Helper existence check" "Script '$HelperScript' does not exist at '$HelperPath'"
}

function Invoke-ToolProcess {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = $null
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($arg in $ArgumentList) {
        $psi.ArgumentList.Add($arg)
    }
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    foreach ($key in $Environment.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$Environment[$key]
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Stdout   = $stdoutTask.GetAwaiter().GetResult()
        Stderr   = $stderrTask.GetAwaiter().GetResult()
    }
}

function Invoke-ScopeHelper {
    param(
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{}
    )
    $pwshArgs = @('-NoProfile', '-NonInteractive', '-File', $HelperPath) + $ArgumentList
    return Invoke-ToolProcess -FilePath $PwshBin -ArgumentList $pwshArgs -Environment $Environment -WorkingDirectory $WorkingDirectory
}

function Invoke-Git {
    param(
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [string[]]$ArgumentList = @()
    )
    $gitArgs = @('-C', $WorkingDirectory) + $ArgumentList
    $res = Invoke-ToolProcess -FilePath 'git' -ArgumentList $gitArgs
    if ($res.ExitCode -ne 0) {
        throw "git command failed with exit code $($res.ExitCode): git -C $WorkingDirectory $($ArgumentList -join ' ')`nStderr: $($res.Stderr)"
    }
    return $res.Stdout
}

function Init-GitRepo([string]$Path) {
    [System.IO.Directory]::CreateDirectory($Path) | Out-Null
    Invoke-Git -WorkingDirectory $Path -ArgumentList @('init', '-q') | Out-Null
    Invoke-Git -WorkingDirectory $Path -ArgumentList @('config', 'user.name', 'Test User') | Out-Null
    Invoke-Git -WorkingDirectory $Path -ArgumentList @('config', 'user.email', 'test@example.com') | Out-Null
    Invoke-Git -WorkingDirectory $Path -ArgumentList @('config', 'commit.gpgsign', 'false') | Out-Null
}

# ---------------------------------------------------------------------------
# Test Environment Setup
# ---------------------------------------------------------------------------

$TmpRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "offload-scope-test-$([System.Guid]::NewGuid().ToString('N'))")
[System.IO.Directory]::CreateDirectory($TmpRoot) | Out-Null

try {
    # =======================================================================
    # 1. CLI Argument and Environment Validation
    # =======================================================================

    # 1.1 Fails outside a git worktree
    $nonGitDir = Join-Path $TmpRoot 'non_git'
    [System.IO.Directory]::CreateDirectory($nonGitDir) | Out-Null
    $resNonGit = Invoke-ScopeHelper -WorkingDirectory $nonGitDir -ArgumentList @('--owned', 'base.txt')
    Assert-True ($resNonGit.ExitCode -ne 0) "CLI rejects execution outside a git worktree"

    # 1.2 Fails when no --owned arguments are provided
    $repoClean = Join-Path $TmpRoot 'repo_clean'
    Init-GitRepo $repoClean
    [System.IO.File]::WriteAllText((Join-Path $repoClean 'base.txt'), "base content`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoClean -ArgumentList @('add', 'base.txt') | Out-Null
    Invoke-Git -WorkingDirectory $repoClean -ArgumentList @('commit', '-m', 'initial commit', '-q') | Out-Null

    $resNoOwned = Invoke-ScopeHelper -WorkingDirectory $repoClean -ArgumentList @()
    Assert-True ($resNoOwned.ExitCode -ne 0) "CLI requires at least one --owned argument"

    # 1.3 Fails on unknown arguments
    $resUnknown = Invoke-ScopeHelper -WorkingDirectory $repoClean -ArgumentList @('--owned', 'base.txt', '--unknown-argument')
    Assert-True ($resUnknown.ExitCode -ne 0) "CLI rejects unknown arguments"

    # 1.4 Fails when --owned has no value
    $resNoVal = Invoke-ScopeHelper -WorkingDirectory $repoClean -ArgumentList @('--owned')
    Assert-True ($resNoVal.ExitCode -ne 0) "CLI rejects --owned without value"

    # =======================================================================
    # 2. Clean Repository ("Clean Success")
    # =======================================================================

    $resClean = Invoke-ScopeHelper -WorkingDirectory $repoClean -ArgumentList @('--owned', 'base.txt')
    Assert-Equal $resClean.ExitCode 0 "clean repository returns 0"
    Assert-Equal $resClean.Stdout.Trim() "" "clean repository produces empty stdout"

    $resCleanFrozen = Invoke-ScopeHelper -WorkingDirectory $repoClean -ArgumentList @('--owned', 'base.txt', '--frozen', 'base.txt')
    Assert-Equal $resCleanFrozen.ExitCode 0 "clean repository with untouched frozen path returns 0"
    Assert-Equal $resCleanFrozen.Stdout.Trim() "" "clean repository with untouched frozen path produces empty stdout"

    # =======================================================================
    # 3. Owned File (Valid and Violation) & Partial Matching
    # =======================================================================

    $repoFiles = Join-Path $TmpRoot 'repo_files'
    Init-GitRepo $repoFiles
    [System.IO.File]::WriteAllText((Join-Path $repoFiles 'file_a.txt'), "content a`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $repoFiles 'file_b.txt'), "content b`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoFiles -ArgumentList @('add', '.') | Out-Null
    Invoke-Git -WorkingDirectory $repoFiles -ArgumentList @('commit', '-m', 'initial files', '-q') | Out-Null

    [System.IO.File]::AppendAllText((Join-Path $repoFiles 'file_a.txt'), "modified a`n", [System.Text.Encoding]::UTF8)

    # Valid: owned matches touched file exactly
    $resOwnedFile = Invoke-ScopeHelper -WorkingDirectory $repoFiles -ArgumentList @('--owned', 'file_a.txt')
    Assert-Equal $resOwnedFile.ExitCode 0 "owned modified file returns 0"
    Assert-Equal $resOwnedFile.Stdout.Trim() "" "owned modified file produces empty stdout"

    # Violation: modified file is not owned
    $resUnownedFile = Invoke-ScopeHelper -WorkingDirectory $repoFiles -ArgumentList @('--owned', 'file_b.txt')
    Assert-True ($resUnownedFile.ExitCode -ne 0) "unowned modified file returns nonzero"
    Assert-True ($resUnownedFile.Stdout.Contains('file_a.txt')) "unowned modified file lists path in stdout"

    # Partial match: file_a must not match file_a.txt
    $resPartial = Invoke-ScopeHelper -WorkingDirectory $repoFiles -ArgumentList @('--owned', 'file_a')
    Assert-True ($resPartial.ExitCode -ne 0) "partial filename match does not satisfy ownership"
    Assert-True ($resPartial.Stdout.Contains('file_a.txt')) "partial filename match lists path in stdout"

    # =======================================================================
    # 4. Owned Directory (Valid, Trailing Slash, Boundary Checks)
    # =======================================================================

    $repoDirs = Join-Path $TmpRoot 'repo_dirs'
    Init-GitRepo $repoDirs
    [System.IO.Directory]::CreateDirectory((Join-Path $repoDirs 'src/components')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $repoDirs 'src-extra')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repoDirs 'src/app.txt'), "app`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $repoDirs 'src/components/button.txt'), "btn`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $repoDirs 'src-extra/file.txt'), "extra`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoDirs -ArgumentList @('add', '.') | Out-Null
    Invoke-Git -WorkingDirectory $repoDirs -ArgumentList @('commit', '-m', 'initial dirs', '-q') | Out-Null

    [System.IO.File]::AppendAllText((Join-Path $repoDirs 'src/app.txt'), "mod app`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::AppendAllText((Join-Path $repoDirs 'src/components/button.txt'), "mod btn`n", [System.Text.Encoding]::UTF8)

    # Valid: owned directory without trailing slash
    $resDir = Invoke-ScopeHelper -WorkingDirectory $repoDirs -ArgumentList @('--owned', 'src')
    Assert-Equal $resDir.ExitCode 0 "owned directory without trailing slash returns 0"
    Assert-Equal $resDir.Stdout.Trim() "" "owned directory produces empty stdout"

    # Valid: owned directory with trailing slash
    $resDirSlash = Invoke-ScopeHelper -WorkingDirectory $repoDirs -ArgumentList @('--owned', 'src/')
    Assert-Equal $resDirSlash.ExitCode 0 "owned directory with trailing slash returns 0"
    Assert-Equal $resDirSlash.Stdout.Trim() "" "owned directory with trailing slash produces empty stdout"

    # Violation: nested directory scope does not cover parent directory files
    $resNestedDir = Invoke-ScopeHelper -WorkingDirectory $repoDirs -ArgumentList @('--owned', 'src/components')
    Assert-True ($resNestedDir.ExitCode -ne 0) "nested directory scope does not cover parent directory files"
    Assert-True ($resNestedDir.Stdout.Contains('src/app.txt')) "nested directory scope lists uncovered parent path"

    # Boundary check: src must NOT match src-extra
    [System.IO.File]::AppendAllText((Join-Path $repoDirs 'src-extra/file.txt'), "mod extra`n", [System.Text.Encoding]::UTF8)
    $resBoundary = Invoke-ScopeHelper -WorkingDirectory $repoDirs -ArgumentList @('--owned', 'src')
    Assert-True ($resBoundary.ExitCode -ne 0) "owned directory respects boundary and rejects prefix-sharing sibling"
    Assert-True ($resBoundary.Stdout.Contains('src-extra/file.txt')) "boundary violation lists sibling path"

    # =======================================================================
    # 5. Multiple Repeated --owned Arguments
    # =======================================================================

    $repoMulti = Join-Path $TmpRoot 'repo_multi'
    Init-GitRepo $repoMulti
    [System.IO.Directory]::CreateDirectory((Join-Path $repoMulti 'docs')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $repoMulti 'src')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repoMulti 'docs/guide.md'), "doc`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $repoMulti 'src/code.py'), "code`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $repoMulti 'config.json'), "cfg`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoMulti -ArgumentList @('add', '.') | Out-Null
    Invoke-Git -WorkingDirectory $repoMulti -ArgumentList @('commit', '-m', 'initial multi', '-q') | Out-Null

    [System.IO.File]::AppendAllText((Join-Path $repoMulti 'docs/guide.md'), "mod doc`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::AppendAllText((Join-Path $repoMulti 'src/code.py'), "mod code`n", [System.Text.Encoding]::UTF8)

    # Valid: both owned
    $resMulti = Invoke-ScopeHelper -WorkingDirectory $repoMulti -ArgumentList @('--owned', 'docs', '--owned', 'src/code.py')
    Assert-Equal $resMulti.ExitCode 0 "multiple repeated --owned arguments succeed"
    Assert-Equal $resMulti.Stdout.Trim() "" "multiple repeated --owned stdout is empty"

    # Violation: omitted path
    $resMultiOmit = Invoke-ScopeHelper -WorkingDirectory $repoMulti -ArgumentList @('--owned', 'docs')
    Assert-True ($resMultiOmit.ExitCode -ne 0) "omitted owned path among multiple changes reports violation"
    Assert-True ($resMultiOmit.Stdout.Contains('src/code.py')) "omitted owned path lists unowned path"

    # =======================================================================
    # 6. Frozen File
    # =======================================================================

    $repoFrozen = Join-Path $TmpRoot 'repo_frozen'
    Init-GitRepo $repoFrozen
    [System.IO.Directory]::CreateDirectory((Join-Path $repoFrozen 'config')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repoFrozen 'config/allowed.txt'), "allowed`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $repoFrozen 'config/secret.txt'), "secret`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoFrozen -ArgumentList @('add', '.') | Out-Null
    Invoke-Git -WorkingDirectory $repoFrozen -ArgumentList @('commit', '-m', 'initial frozen', '-q') | Out-Null

    # Case A: Untouched frozen file
    [System.IO.File]::AppendAllText((Join-Path $repoFrozen 'config/allowed.txt'), "mod allowed`n", [System.Text.Encoding]::UTF8)
    $resFrozenUntouched = Invoke-ScopeHelper -WorkingDirectory $repoFrozen -ArgumentList @('--owned', 'config', '--frozen', 'config/secret.txt')
    Assert-Equal $resFrozenUntouched.ExitCode 0 "untouched frozen file does not trigger violation"
    Assert-Equal $resFrozenUntouched.Stdout.Trim() "" "untouched frozen file produces empty stdout"

    # Case B: Modified frozen file (even when owned)
    [System.IO.File]::AppendAllText((Join-Path $repoFrozen 'config/secret.txt'), "mod secret`n", [System.Text.Encoding]::UTF8)
    $resFrozenMod = Invoke-ScopeHelper -WorkingDirectory $repoFrozen -ArgumentList @('--owned', 'config', '--frozen', 'config/secret.txt')
    Assert-True ($resFrozenMod.ExitCode -ne 0) "modified frozen file reports violation even when covered by --owned"
    Assert-True ($resFrozenMod.Stdout.Contains('config/secret.txt')) "modified frozen file lists path in stdout"

    # =======================================================================
    # 7. Frozen Directory
    # =======================================================================

    $repoFrozenDir = Join-Path $TmpRoot 'repo_frozendir'
    Init-GitRepo $repoFrozenDir
    [System.IO.Directory]::CreateDirectory((Join-Path $repoFrozenDir 'legacy/sub')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $repoFrozenDir 'legacy-v2')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repoFrozenDir 'legacy/sub/old.txt'), "old`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $repoFrozenDir 'legacy-v2/new.txt'), "new`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoFrozenDir -ArgumentList @('add', '.') | Out-Null
    Invoke-Git -WorkingDirectory $repoFrozenDir -ArgumentList @('commit', '-m', 'initial frozen dir', '-q') | Out-Null

    [System.IO.File]::AppendAllText((Join-Path $repoFrozenDir 'legacy/sub/old.txt'), "mod old`n", [System.Text.Encoding]::UTF8)

    # Violation: file in frozen directory
    $resFrozenSub = Invoke-ScopeHelper -WorkingDirectory $repoFrozenDir -ArgumentList @('--owned', 'legacy', '--frozen', 'legacy')
    Assert-True ($resFrozenSub.ExitCode -ne 0) "modified file inside frozen directory reports violation"
    Assert-True ($resFrozenSub.Stdout.Contains('legacy/sub/old.txt')) "frozen directory lists contained path"

    # Frozen directory with trailing slash
    $resFrozenSlash = Invoke-ScopeHelper -WorkingDirectory $repoFrozenDir -ArgumentList @('--owned', 'legacy', '--frozen', 'legacy/')
    Assert-True ($resFrozenSlash.ExitCode -ne 0) "frozen directory with trailing slash reports violation"
    Assert-True ($resFrozenSlash.Stdout.Contains('legacy/sub/old.txt')) "frozen directory with slash lists contained path"

    # Boundary check: legacy must NOT freeze legacy-v2
    Invoke-Git -WorkingDirectory $repoFrozenDir -ArgumentList @('checkout', '-q', 'legacy/sub/old.txt') | Out-Null
    [System.IO.File]::AppendAllText((Join-Path $repoFrozenDir 'legacy-v2/new.txt'), "mod new`n", [System.Text.Encoding]::UTF8)
    $resFrozenBoundary = Invoke-ScopeHelper -WorkingDirectory $repoFrozenDir -ArgumentList @('--owned', 'legacy-v2', '--frozen', 'legacy')
    Assert-Equal $resFrozenBoundary.ExitCode 0 "frozen directory respects boundary and does not freeze prefix-sharing sibling"
    Assert-Equal $resFrozenBoundary.Stdout.Trim() "" "frozen directory sibling produces empty stdout"

    # =======================================================================
    # 8. Modified Tracked Files (Staged and Unstaged)
    # =======================================================================

    $repoMod = Join-Path $TmpRoot 'repo_mod'
    Init-GitRepo $repoMod
    [System.IO.File]::WriteAllText((Join-Path $repoMod 'staged.txt'), "staged`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $repoMod 'unstaged.txt'), "unstaged`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoMod -ArgumentList @('add', '.') | Out-Null
    Invoke-Git -WorkingDirectory $repoMod -ArgumentList @('commit', '-m', 'initial mod', '-q') | Out-Null

    [System.IO.File]::AppendAllText((Join-Path $repoMod 'unstaged.txt'), "mod unstaged`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::AppendAllText((Join-Path $repoMod 'staged.txt'), "mod staged`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoMod -ArgumentList @('add', 'staged.txt') | Out-Null

    # Both owned
    $resModBoth = Invoke-ScopeHelper -WorkingDirectory $repoMod -ArgumentList @('--owned', 'staged.txt', '--owned', 'unstaged.txt')
    Assert-Equal $resModBoth.ExitCode 0 "modified tracked files (both staged and unstaged) pass when owned"
    Assert-Equal $resModBoth.Stdout.Trim() "" "modified tracked files stdout is empty"

    # Missing unstaged
    $resModMissingUnstaged = Invoke-ScopeHelper -WorkingDirectory $repoMod -ArgumentList @('--owned', 'staged.txt')
    Assert-True ($resModMissingUnstaged.ExitCode -ne 0) "unowned unstaged modification reports violation"
    Assert-True ($resModMissingUnstaged.Stdout.Contains('unstaged.txt')) "unowned unstaged lists path"

    # Missing staged
    $resModMissingStaged = Invoke-ScopeHelper -WorkingDirectory $repoMod -ArgumentList @('--owned', 'unstaged.txt')
    Assert-True ($resModMissingStaged.ExitCode -ne 0) "unowned staged modification reports violation"
    Assert-True ($resModMissingStaged.Stdout.Contains('staged.txt')) "unowned staged lists path"

    # =======================================================================
    # 9. Deleted Tracked Files (Staged and Unstaged, and Frozen)
    # =======================================================================

    $repoDel = Join-Path $TmpRoot 'repo_del'
    Init-GitRepo $repoDel
    [System.IO.File]::WriteAllText((Join-Path $repoDel 'del_staged.txt'), "del1`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $repoDel 'del_unstaged.txt'), "del2`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoDel -ArgumentList @('add', '.') | Out-Null
    Invoke-Git -WorkingDirectory $repoDel -ArgumentList @('commit', '-m', 'initial del', '-q') | Out-Null

    Remove-Item -LiteralPath (Join-Path $repoDel 'del_unstaged.txt') -Force
    Invoke-Git -WorkingDirectory $repoDel -ArgumentList @('rm', '-q', 'del_staged.txt') | Out-Null

    # Both owned
    $resDelBoth = Invoke-ScopeHelper -WorkingDirectory $repoDel -ArgumentList @('--owned', 'del_staged.txt', '--owned', 'del_unstaged.txt')
    Assert-Equal $resDelBoth.ExitCode 0 "deleted tracked files (staged and unstaged) pass when owned"
    Assert-Equal $resDelBoth.Stdout.Trim() "" "deleted tracked files stdout is empty"

    # Unowned unstaged delete
    $resDelUnowned = Invoke-ScopeHelper -WorkingDirectory $repoDel -ArgumentList @('--owned', 'del_staged.txt')
    Assert-True ($resDelUnowned.ExitCode -ne 0) "unowned unstaged deletion reports violation"
    Assert-True ($resDelUnowned.Stdout.Contains('del_unstaged.txt')) "unowned unstaged delete lists path"

    # Frozen deleted file
    $resDelFrozen = Invoke-ScopeHelper -WorkingDirectory $repoDel -ArgumentList @('--owned', 'del_staged.txt', '--owned', 'del_unstaged.txt', '--frozen', 'del_unstaged.txt')
    Assert-True ($resDelFrozen.ExitCode -ne 0) "frozen deleted file reports violation"
    Assert-True ($resDelFrozen.Stdout.Contains('del_unstaged.txt')) "frozen deleted file lists path"

    # =======================================================================
    # 10. Renamed Files (Both Paths Involved)
    # =======================================================================

    $repoRename = Join-Path $TmpRoot 'repo_rename'
    Init-GitRepo $repoRename
    [System.IO.File]::WriteAllText((Join-Path $repoRename 'old_path.txt'), "line 1`nline 2`nline 3`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoRename -ArgumentList @('add', '.') | Out-Null
    Invoke-Git -WorkingDirectory $repoRename -ArgumentList @('commit', '-m', 'initial rename', '-q') | Out-Null

    Invoke-Git -WorkingDirectory $repoRename -ArgumentList @('mv', 'old_path.txt', 'new_path.txt') | Out-Null

    # Both paths owned
    $resRenameBoth = Invoke-ScopeHelper -WorkingDirectory $repoRename -ArgumentList @('--owned', 'old_path.txt', '--owned', 'new_path.txt')
    Assert-Equal $resRenameBoth.ExitCode 0 "renamed file with both paths owned passes"
    Assert-Equal $resRenameBoth.Stdout.Trim() "" "renamed file with both paths owned stdout is empty"

    # Only new path owned: old path violation
    $resRenameNewOnly = Invoke-ScopeHelper -WorkingDirectory $repoRename -ArgumentList @('--owned', 'new_path.txt')
    Assert-True ($resRenameNewOnly.ExitCode -ne 0) "renamed file missing old path reports violation"
    Assert-True ($resRenameNewOnly.Stdout.Contains('old_path.txt')) "renamed file missing old path lists old path"

    # Only old path owned: new path violation
    $resRenameOldOnly = Invoke-ScopeHelper -WorkingDirectory $repoRename -ArgumentList @('--owned', 'old_path.txt')
    Assert-True ($resRenameOldOnly.ExitCode -ne 0) "renamed file missing new path reports violation"
    Assert-True ($resRenameOldOnly.Stdout.Contains('new_path.txt')) "renamed file missing new path lists new path"

    # Frozen old path
    $resRenameFrozenOld = Invoke-ScopeHelper -WorkingDirectory $repoRename -ArgumentList @('--owned', 'old_path.txt', '--owned', 'new_path.txt', '--frozen', 'old_path.txt')
    Assert-True ($resRenameFrozenOld.ExitCode -ne 0) "renamed file with frozen old path reports violation"
    Assert-True ($resRenameFrozenOld.Stdout.Contains('old_path.txt')) "renamed file with frozen old path lists old path"

    # Frozen new path
    $resRenameFrozenNew = Invoke-ScopeHelper -WorkingDirectory $repoRename -ArgumentList @('--owned', 'old_path.txt', '--owned', 'new_path.txt', '--frozen', 'new_path.txt')
    Assert-True ($resRenameFrozenNew.ExitCode -ne 0) "renamed file with frozen new path reports violation"
    Assert-True ($resRenameFrozenNew.Stdout.Contains('new_path.txt')) "renamed file with frozen new path lists new path"

    # =======================================================================
    # 11. Copied Files
    # =======================================================================

    $repoCopy = Join-Path $TmpRoot 'repo_copy'
    Init-GitRepo $repoCopy
    [System.IO.File]::WriteAllText((Join-Path $repoCopy 'orig.txt'), "seed 1`nseed 2`nseed 3`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoCopy -ArgumentList @('add', '.') | Out-Null
    Invoke-Git -WorkingDirectory $repoCopy -ArgumentList @('commit', '-m', 'initial copy', '-q') | Out-Null

    Copy-Item (Join-Path $repoCopy 'orig.txt') (Join-Path $repoCopy 'copy.txt')
    Invoke-Git -WorkingDirectory $repoCopy -ArgumentList @('add', 'copy.txt') | Out-Null

    # Both paths owned
    $resCopyBoth = Invoke-ScopeHelper -WorkingDirectory $repoCopy -ArgumentList @('--owned', 'orig.txt', '--owned', 'copy.txt')
    Assert-Equal $resCopyBoth.ExitCode 0 "copied file passes when copy is owned"
    Assert-Equal $resCopyBoth.Stdout.Trim() "" "copied file with both paths owned stdout is empty"

    # Unowned copy
    $resCopyUnowned = Invoke-ScopeHelper -WorkingDirectory $repoCopy -ArgumentList @('--owned', 'orig.txt')
    Assert-True ($resCopyUnowned.ExitCode -ne 0) "unowned copied file reports violation"
    Assert-True ($resCopyUnowned.Stdout.Contains('copy.txt')) "unowned copied file lists copy.txt"

    # Frozen copy
    $resCopyFrozen = Invoke-ScopeHelper -WorkingDirectory $repoCopy -ArgumentList @('--owned', 'orig.txt', '--owned', 'copy.txt', '--frozen', 'copy.txt')
    Assert-True ($resCopyFrozen.ExitCode -ne 0) "frozen copied file reports violation"
    Assert-True ($resCopyFrozen.Stdout.Contains('copy.txt')) "frozen copied file lists copy.txt"

    # =======================================================================
    # 12. Untracked Files (Not Ignored)
    # =======================================================================

    $repoUntracked = Join-Path $TmpRoot 'repo_untracked'
    Init-GitRepo $repoUntracked
    [System.IO.File]::WriteAllText((Join-Path $repoUntracked 'base.txt'), "base`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoUntracked -ArgumentList @('add', '.') | Out-Null
    Invoke-Git -WorkingDirectory $repoUntracked -ArgumentList @('commit', '-m', 'initial untracked', '-q') | Out-Null

    [System.IO.File]::WriteAllText((Join-Path $repoUntracked 'new_untracked.txt'), "new untracked`n", [System.Text.Encoding]::UTF8)
    [System.IO.Directory]::CreateDirectory((Join-Path $repoUntracked 'untracked_dir')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repoUntracked 'untracked_dir/nested.txt'), "nested untracked`n", [System.Text.Encoding]::UTF8)

    # Valid: both owned
    $resUntrackedOwned = Invoke-ScopeHelper -WorkingDirectory $repoUntracked -ArgumentList @('--owned', 'new_untracked.txt', '--owned', 'untracked_dir')
    Assert-Equal $resUntrackedOwned.ExitCode 0 "untracked files pass when owned"
    Assert-Equal $resUntrackedOwned.Stdout.Trim() "" "owned untracked files stdout is empty"

    # Violation: unowned untracked file
    $resUntrackedUnowned = Invoke-ScopeHelper -WorkingDirectory $repoUntracked -ArgumentList @('--owned', 'base.txt')
    Assert-True ($resUntrackedUnowned.ExitCode -ne 0) "unowned untracked files report violation"
    Assert-True ($resUntrackedUnowned.Stdout.Contains('new_untracked.txt')) "unowned untracked lists new_untracked.txt"
    Assert-True ($resUntrackedUnowned.Stdout.Contains('untracked_dir/nested.txt')) "unowned untracked lists nested path"

    # Frozen untracked file
    $resUntrackedFrozen = Invoke-ScopeHelper -WorkingDirectory $repoUntracked -ArgumentList @('--owned', 'new_untracked.txt', '--owned', 'untracked_dir', '--frozen', 'new_untracked.txt')
    Assert-True ($resUntrackedFrozen.ExitCode -ne 0) "frozen untracked file reports violation"
    Assert-True ($resUntrackedFrozen.Stdout.Contains('new_untracked.txt')) "frozen untracked lists path"

    # =======================================================================
    # 13. Ignored Files
    # =======================================================================

    $repoIgnored = Join-Path $TmpRoot 'repo_ignored'
    Init-GitRepo $repoIgnored
    [System.IO.File]::WriteAllText((Join-Path $repoIgnored '.gitignore'), "*.log`ntemp/`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $repoIgnored 'base.txt'), "base`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoIgnored -ArgumentList @('add', '.') | Out-Null
    Invoke-Git -WorkingDirectory $repoIgnored -ArgumentList @('commit', '-m', 'initial gitignore', '-q') | Out-Null

    [System.IO.File]::WriteAllText((Join-Path $repoIgnored 'debug.log'), "log output`n", [System.Text.Encoding]::UTF8)
    [System.IO.Directory]::CreateDirectory((Join-Path $repoIgnored 'temp')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repoIgnored 'temp/scratch.txt'), "temp data`n", [System.Text.Encoding]::UTF8)

    # Ignored files must not trigger violations
    $resIgnored = Invoke-ScopeHelper -WorkingDirectory $repoIgnored -ArgumentList @('--owned', 'base.txt')
    Assert-Equal $resIgnored.ExitCode 0 "ignored files are excluded from scope violations"
    Assert-Equal $resIgnored.Stdout.Trim() "" "ignored files stdout is empty"

    # =======================================================================
    # 14. Spaced Paths
    # =======================================================================

    $repoSpaces = Join-Path $TmpRoot 'repo_spaces'
    Init-GitRepo $repoSpaces
    [System.IO.Directory]::CreateDirectory((Join-Path $repoSpaces 'folder with spaces')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repoSpaces 'folder with spaces/file with spaces.txt'), "spaced file`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoSpaces -ArgumentList @('add', '.') | Out-Null
    Invoke-Git -WorkingDirectory $repoSpaces -ArgumentList @('commit', '-m', 'initial spaces', '-q') | Out-Null

    [System.IO.File]::AppendAllText((Join-Path $repoSpaces 'folder with spaces/file with spaces.txt'), "modified spaced`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $repoSpaces 'another spaced file.txt'), "untracked spaced`n", [System.Text.Encoding]::UTF8)

    # Valid: both owned
    $resSpacesOwned = Invoke-ScopeHelper -WorkingDirectory $repoSpaces -ArgumentList @('--owned', 'folder with spaces', '--owned', 'another spaced file.txt')
    Assert-Equal $resSpacesOwned.ExitCode 0 "spaced paths within owned scope succeed"
    Assert-Equal $resSpacesOwned.Stdout.Trim() "" "spaced paths stdout is empty"

    # Violation: unowned spaced file
    $resSpacesUnowned = Invoke-ScopeHelper -WorkingDirectory $repoSpaces -ArgumentList @('--owned', 'folder with spaces')
    Assert-True ($resSpacesUnowned.ExitCode -ne 0) "unowned spaced path reports violation"
    Assert-True ($resSpacesUnowned.Stdout.Contains('another spaced file.txt')) "unowned spaced lists path"

    # Frozen spaced file
    $resSpacesFrozen = Invoke-ScopeHelper -WorkingDirectory $repoSpaces -ArgumentList @('--owned', 'folder with spaces', '--owned', 'another spaced file.txt', '--frozen', 'folder with spaces/file with spaces.txt')
    Assert-True ($resSpacesFrozen.ExitCode -ne 0) "frozen spaced path reports violation"
    Assert-True ($resSpacesFrozen.Stdout.Contains('folder with spaces/file with spaces.txt')) "frozen spaced lists path"

    # =======================================================================
    # 15. Non-ASCII Paths
    # =======================================================================

    $repoNonAscii = Join-Path $TmpRoot 'repo_nonascii'
    Init-GitRepo $repoNonAscii
    [System.IO.Directory]::CreateDirectory((Join-Path $repoNonAscii 'dossier')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repoNonAscii 'dossier/café.txt'), "café`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $repoNonAscii 'résumé.md'), "résumé`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoNonAscii -ArgumentList @('add', '.') | Out-Null
    Invoke-Git -WorkingDirectory $repoNonAscii -ArgumentList @('commit', '-m', 'initial non-ascii', '-q') | Out-Null

    [System.IO.File]::AppendAllText((Join-Path $repoNonAscii 'dossier/café.txt'), "mod café`n", [System.Text.Encoding]::UTF8)
    [System.IO.Directory]::CreateDirectory((Join-Path $repoNonAscii 'münchen')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repoNonAscii 'münchen/stadt.txt'), "stadt`n", [System.Text.Encoding]::UTF8)

    # Valid: all owned
    $resNonAsciiOwned = Invoke-ScopeHelper -WorkingDirectory $repoNonAscii -ArgumentList @('--owned', 'dossier', '--owned', 'résumé.md', '--owned', 'münchen')
    Assert-Equal $resNonAsciiOwned.ExitCode 0 "non-ASCII paths within owned scope succeed"
    Assert-Equal $resNonAsciiOwned.Stdout.Trim() "" "non-ASCII paths stdout is empty"

    # Violation: unowned non-ASCII path
    $resNonAsciiUnowned = Invoke-ScopeHelper -WorkingDirectory $repoNonAscii -ArgumentList @('--owned', 'dossier', '--owned', 'résumé.md')
    Assert-True ($resNonAsciiUnowned.ExitCode -ne 0) "unowned non-ASCII path reports violation"
    Assert-True ($resNonAsciiUnowned.Stdout.Contains('münchen/stadt.txt')) "unowned non-ASCII lists path münchen/stadt.txt"

    # Frozen non-ASCII path
    $resNonAsciiFrozen = Invoke-ScopeHelper -WorkingDirectory $repoNonAscii -ArgumentList @('--owned', 'dossier', '--owned', 'résumé.md', '--owned', 'münchen', '--frozen', 'dossier/café.txt')
    Assert-True ($resNonAsciiFrozen.ExitCode -ne 0) "frozen non-ASCII path reports violation"
    Assert-True ($resNonAsciiFrozen.Stdout.Contains('dossier/café.txt')) "frozen non-ASCII lists path dossier/café.txt"

    # =======================================================================
    # 16. Valid Scope Prints Nothing and Creates No Comparison Files
    # =======================================================================

    $repoCleanliness = Join-Path $TmpRoot 'repo_cleanliness'
    Init-GitRepo $repoCleanliness
    [System.IO.File]::WriteAllText((Join-Path $repoCleanliness 'tracked.txt'), "tracked`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoCleanliness -ArgumentList @('add', '.') | Out-Null
    Invoke-Git -WorkingDirectory $repoCleanliness -ArgumentList @('commit', '-m', 'initial cleanliness', '-q') | Out-Null

    [System.IO.File]::AppendAllText((Join-Path $repoCleanliness 'tracked.txt'), "modified`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $repoCleanliness 'new_owned.txt'), "new`n", [System.Text.Encoding]::UTF8)

    $statusBefore = Invoke-Git -WorkingDirectory $repoCleanliness -ArgumentList @('status', '--porcelain', '-uall')

    $resValidScope = Invoke-ScopeHelper -WorkingDirectory $repoCleanliness -ArgumentList @('--owned', 'tracked.txt', '--owned', 'new_owned.txt')
    Assert-Equal $resValidScope.ExitCode 0 "valid scope check succeeds"
    Assert-Equal $resValidScope.Stdout.Trim() "" "valid scope check produces empty stdout"

    $statusAfter = Invoke-Git -WorkingDirectory $repoCleanliness -ArgumentList @('status', '--porcelain', '-uall')
    Assert-Equal $statusAfter $statusBefore "scope check does not alter git status"

    # Verify no extra comparison files created in repo
    $allowedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    @('.git', 'tracked.txt', 'new_owned.txt') | ForEach-Object { $allowedFiles.Add($_) | Out-Null }

    foreach ($item in (Get-ChildItem -LiteralPath $repoCleanliness -Force)) {
        Assert-True ($allowedFiles.Contains($item.Name)) "valid scope creates no comparison files: found '$($item.Name)'"
    }
    Pass "valid scope prints nothing, modifies no status, and creates no comparison files"

    # =======================================================================
    # 17. Violations Print Each Violating Path and Return Nonzero
    # =======================================================================

    $repoViolations = Join-Path $TmpRoot 'repo_violations'
    Init-GitRepo $repoViolations
    [System.IO.File]::WriteAllText((Join-Path $repoViolations 'clean.txt'), "clean file`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $repoViolations 'frozen_file.txt'), "frozen base`n", [System.Text.Encoding]::UTF8)
    Invoke-Git -WorkingDirectory $repoViolations -ArgumentList @('add', '.') | Out-Null
    Invoke-Git -WorkingDirectory $repoViolations -ArgumentList @('commit', '-m', 'initial violations', '-q') | Out-Null

    [System.IO.File]::WriteAllText((Join-Path $repoViolations 'unowned_one.txt'), "unowned 1`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $repoViolations 'unowned_two.txt'), "unowned 2`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::AppendAllText((Join-Path $repoViolations 'frozen_file.txt'), "mod frozen`n", [System.Text.Encoding]::UTF8)

    $statusViolBefore = Invoke-Git -WorkingDirectory $repoViolations -ArgumentList @('status', '--porcelain', '-uall')

    $resViol = Invoke-ScopeHelper -WorkingDirectory $repoViolations -ArgumentList @('--owned', 'clean.txt', '--frozen', 'frozen_file.txt')
    Assert-True ($resViol.ExitCode -ne 0) "violations produce nonzero exit code"
    Assert-True ($resViol.Stdout.Contains('unowned_one.txt')) "stdout lists unowned_one.txt"
    Assert-True ($resViol.Stdout.Contains('unowned_two.txt')) "stdout lists unowned_two.txt"
    Assert-True ($resViol.Stdout.Contains('frozen_file.txt')) "stdout lists frozen_file.txt"

    $statusViolAfter = Invoke-Git -WorkingDirectory $repoViolations -ArgumentList @('status', '--porcelain', '-uall')
    Assert-Equal $statusViolAfter $statusViolBefore "failed scope check does not alter git status"

    # Verify no comparison files left on failure either
    $allowedViolFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    @('.git', 'clean.txt', 'frozen_file.txt', 'unowned_one.txt', 'unowned_two.txt') | ForEach-Object { $allowedViolFiles.Add($_) | Out-Null }

    foreach ($item in (Get-ChildItem -LiteralPath $repoViolations -Force)) {
        Assert-True ($allowedViolFiles.Contains($item.Name)) "failed scope check creates no comparison files: found '$($item.Name)'"
    }
    Pass "violations print each violating path to stdout and return nonzero without creating comparison files"

    # -----------------------------------------------------------------------
    # All Checks Completed
    # -----------------------------------------------------------------------
    [Console]::Out.WriteLine("all powershell execution scope checks passed ($script:TotalTests tests)")
    exit 0
}
finally {
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
