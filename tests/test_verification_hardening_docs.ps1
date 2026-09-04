#!/usr/bin/env pwsh
# tests/test_verification_hardening_docs.ps1
# Acceptance gate for offload verification hardening: docs-probe criterion.
# Implements contracts specified in:
#   - Functional Requirement 2: Plan-mode documentation and safety contract
#   - Functional Requirement 8: Maintainer-only compatibility probe
#   - Documentation decisions and test strategy
# Strict constraints: Standalone PowerShell 7 / .NET only, no Pester, Python, jq, Bash, or live Gemini calls.

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
        $r = if ($reason) { $reason } else { "Condition was false" }
        Fail $name $r
    }
}

function Assert-False([bool]$condition, [string]$name, [string]$reason = "") {
    if (-not $condition) {
        Pass $name
    } else {
        $r = if ($reason) { $reason } else { "Condition was true" }
        Fail $name $r
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

$RootDir = Split-Path -Parent $PSScriptRoot
$SkillMd = Join-Path $RootDir 'SKILL.md'
$ExecMd = Join-Path $RootDir 'modes/execution.md'
$RepoMd = Join-Path $RootDir 'modes/repo-research.md'
$WebMd = Join-Path $RootDir 'modes/web-research.md'
$ReadmeMd = Join-Path $RootDir 'README.md'
$AgentsMd = Join-Path $RootDir 'AGENTS.md'
$RoutingSpecMd = Join-Path $RootDir 'docs/specs/0003-gemini-model-routing.md'
$PolicyJson = Join-Path $RootDir 'model-policy.json'

# ===========================================================================
# 1. Structural Integrity & Line Count Constraints
# ===========================================================================

# 1.1 SKILL.md must remain strictly under 500 lines
$skillLines = (Get-Content -LiteralPath $SkillMd).Count
Assert-True ($skillLines -lt 500) "line-count: SKILL.md is under 500 lines (actual: $skillLines)"

# 1.2 Maintained files must exist
foreach ($f in @($SkillMd, $ExecMd, $RepoMd, $WebMd, $ReadmeMd, $AgentsMd, $RoutingSpecMd, $PolicyJson)) {
    $rel = [System.IO.Path]::GetRelativePath($RootDir, $f)
    Assert-True (Test-Path -LiteralPath $f -PathType Leaf) "file-exists: $rel exists"
}

# ===========================================================================
# 2. Plan-Mode Documentation and Safety Contract (Spec Section 2)
# ===========================================================================

# 2.1 Negative assertions across all maintained documentation:
# - No document calls plan mode a complete write barrier or sole safety control
# - No document claims --add-dir confines writes
# - No document claims plan mode is useless
# - Stale unqualified claims ("direct probes showed that plan-mode workers can write files")
#   must be removed or updated with the 1.1.25 probe findings
foreach ($pair in @(
    @{ Path = $SkillMd; Name = "SKILL.md" },
    @{ Path = $ExecMd; Name = "execution.md" },
    @{ Path = $RepoMd; Name = "repo-research.md" },
    @{ Path = $WebMd; Name = "web-research.md" },
    @{ Path = $ReadmeMd; Name = "README.md" },
    @{ Path = $AgentsMd; Name = "AGENTS.md" }
)) {
    $content = Get-Content -LiteralPath $pair.Path -Raw
    Assert-False ($content -match 'plan mode[^.]{0,80}(?:write barrier|prevents? writes?|cannot write|guarantees? no writes?)') "$($pair.Name): no plan mode write barrier or guarantee myth"
    Assert-False ($content -match '--add-dir[^.]{0,80}(?:confines? writes?|sandboxes?|prevents? writes?)') "$($pair.Name): no add-dir confinement myth"
    Assert-False ($content -match 'plan mode[^.]{0,80}(?:is useless|proves useless)') "$($pair.Name): does not dismiss plan mode as useless"
    Assert-False ($content -match '(?:direct probes?|direct tests?|direct testing)[^.]{0,80}showed that plan-mode workers can write files') "$($pair.Name): stale unqualified claim that plan workers can write files is updated with probe evidence"
}

# 2.2 Positive assertions for SKILL.md:
# - plan mode is a version-sensitive behavioral hint
# - mentions accepted probe observations on agy 1.1.25 (blocked tested direct write outside permitted artifact area)
# - plan mode MUST NOT be the sole containment or safety mechanism
# - --add-dir grants access but does not confine writes
# - filesystem isolation, scoped snapshots, execution-scope checks, frozen paths, and mechanical gates remain actual controls
$skillContent = Get-Content -LiteralPath $SkillMd -Raw
Assert-True ($skillContent -match 'behavioral hint') "skill: documents plan mode is a behavioral hint"
Assert-True ($skillContent -match '1\.1\.25') "skill: documents accepted probe observations on agy 1.1.25"
Assert-True ($skillContent -match 'sole containment|sole safety|not a write barrier') "skill: documents plan mode must not be sole containment"
Assert-True ($skillContent -match '--add-dir') "skill: documents add-dir grants access without confining writes"
Assert-True ($skillContent -match 'filesystem isolation') "skill: documents filesystem isolation as safety control"

# 2.3 Positive assertions for README.md:
$readmeContent = Get-Content -LiteralPath $ReadmeMd -Raw
Assert-True ($readmeContent -match 'behavioral hint') "readme: documents plan mode is a behavioral hint"
Assert-True ($readmeContent -match '1\.1\.25') "readme: documents accepted probe observations on agy 1.1.25"
Assert-True ($readmeContent -match 'filesystem isolation') "readme: documents filesystem isolation as safety control"

# 2.4 Positive assertions for AGENTS.md:
$agentsContent = Get-Content -LiteralPath $AgentsMd -Raw
Assert-True ($agentsContent -match '1\.1\.25|behavioral hint') "agents: documents updated plan mode evidence"

# 2.5 Read roles continue to receive --mode plan in command blocks
foreach ($pair in @(
    @{ Path = $ExecMd; Name = "execution.md" },
    @{ Path = $RepoMd; Name = "repo-research.md" },
    @{ Path = $WebMd; Name = "web-research.md" }
)) {
    $content = Get-Content -LiteralPath $pair.Path -Raw
    Assert-True ($content -match '--mode plan') "$($pair.Name) retains --mode plan for read roles"
}

# ===========================================================================
# 3. Documentation Decisions Across Maintained Contracts (Spec Lines 257-270)
# ===========================================================================

# 3.1 SKILL.md: per-worker attempt identity in routing-outcomes.json
Assert-True ($skillContent -match 'per-worker|at most two attempts per worker|worker_id') "skill: documents per-worker attempt identity"

# 3.2 SKILL.md: result acceptance separation
Assert-True ($skillContent -match 'process completed|accepted_attempt|result acceptance') "skill: documents result acceptance states"
Assert-True ($skillContent -match 'exit (?:code )?0[^.]{0,80}(?:does not|cannot|not establish)') "skill: documents exit 0 alone does not establish verified success"

# 3.3 SKILL.md: unrunnable gate handling
Assert-True ($skillContent -match 'unrunnable') "skill: documents unrunnable failure class"
Assert-True ($skillContent -match '126|127') "skill: documents unrunnable exit codes 126 and 127"

# 3.4 docs/specs/0003-gemini-model-routing.md: updated attempt invariant and failure vocabulary
$routingSpecContent = Get-Content -LiteralPath $RoutingSpecMd -Raw
Assert-True ($routingSpecContent -match 'unrunnable') "routing-spec: failure_class includes unrunnable"
Assert-True ($routingSpecContent -match 'per-worker|at most two attempts per worker|\(worker_id,\s*attempt\)') "routing-spec: documents per-worker attempt identity"

# 3.5 modes/web-research.md: reality anchors and publication redaction
$webContent = Get-Content -LiteralPath $WebMd -Raw
Assert-True ($webContent -match 'reality anchor|reality-anchor|anchor contract') "web-research: documents reality anchor requirements"
Assert-True ($webContent -match 'screenshot|DOM|network capture|console log') "web-research: enumerates acceptable anchor artifact types"
Assert-True ($webContent -match 'redact|\[REDACTED\]') "web-research: documents publication-boundary redaction"

# 3.6 modes/repo-research.md: isolation
$repoContent = Get-Content -LiteralPath $RepoMd -Raw
Assert-True ($repoContent -match 'isolation|disposable workspace') "repo-research: documents filesystem isolation"

# 3.7 README.md: deterministic test suite commands and maintainer probe command
Assert-True ($readmeContent -match 'probe') "readme: documents maintainer compatibility probe"
Assert-True ($readmeContent -match 'probe-agy-compatibility|probe-compatibility|probe-plan-mode') "readme: documents specific maintainer probe command"

# ===========================================================================
# 4. Maintainer-Only Compatibility Probe Contract & Parity (Spec Section 8)
# ===========================================================================

# 4.1 Probe script existence in scripts/
$candidateProbeScripts = @(
    (Join-Path $RootDir 'scripts/probe-agy-compatibility.ps1'),
    (Join-Path $RootDir 'scripts/probe-compatibility.ps1'),
    (Join-Path $RootDir 'scripts/probe-plan-mode.ps1')
)
$probeScriptPs = $null
foreach ($cand in $candidateProbeScripts) {
    if (Test-Path -LiteralPath $cand -PathType Leaf) {
        $probeScriptPs = $cand
        break
    }
}
if (-not $probeScriptPs) {
    $found = Get-ChildItem -Path (Join-Path $RootDir 'scripts') -Filter '*probe*.ps1' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $probeScriptPs = $found.FullName }
}

Assert-True ($null -ne $probeScriptPs) "probe: PowerShell compatibility probe script exists in scripts/" "Maintainer probe script not found in scripts/"

# 4.2 Shell parity: Bash probe script existence in scripts/
$probeScriptSh = $null
if ($probeScriptPs) {
    $shCand = [System.IO.Path]::ChangeExtension($probeScriptPs, '.sh')
    if (Test-Path -LiteralPath $shCand -PathType Leaf) {
        $probeScriptSh = $shCand
    }
}
if (-not $probeScriptSh) {
    $candidateBashScripts = @(
        (Join-Path $RootDir 'scripts/probe-agy-compatibility.sh'),
        (Join-Path $RootDir 'scripts/probe-compatibility.sh'),
        (Join-Path $RootDir 'scripts/probe-plan-mode.sh')
    )
    foreach ($cand in $candidateBashScripts) {
        if (Test-Path -LiteralPath $cand -PathType Leaf) {
            $probeScriptSh = $cand
            break
        }
    }
    if (-not $probeScriptSh) {
        $foundSh = Get-ChildItem -Path (Join-Path $RootDir 'scripts') -Filter '*probe*.sh' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($foundSh) { $probeScriptSh = $foundSh.FullName }
    }
}

Assert-True ($null -ne $probeScriptSh) "probe: shell-parity Bash compatibility probe script exists in scripts/" "Bash probe script not found in scripts/"

# 4.3 CI separation: probe MUST NOT run in deterministic CI
$ciFile = Join-Path $RootDir '.github/workflows/ci.yml'
if (Test-Path -LiteralPath $ciFile -PathType Leaf) {
    $ciContent = Get-Content -LiteralPath $ciFile -Raw
    Assert-False ($ciContent -match 'probe-agy-compatibility|probe-compatibility|probe-plan-mode') "ci: compatibility probe is not part of deterministic CI"
}

# 4.4 Probe script static content checks:
$probeContent = Get-Content -LiteralPath $probeScriptPs -Raw
Assert-True ($probeContent -match 'plan') "probe: tests plan mode arm"
Assert-True ($probeContent -match 'sentinel') "probe: performs intentional sentinel write check"
Assert-True ($probeContent -match 'version') "probe: captures agy version"
Assert-True ($probeContent -match 'disposable|workspace') "probe: runs in disposable workspace"

# ===========================================================================
# 5. Deterministic Probe Execution with Fake Runner (Spec Lines 271-315)
# ===========================================================================

$TmpRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "offload-docs-probe-$([System.Guid]::NewGuid().ToString('N'))")
[System.IO.Directory]::CreateDirectory($TmpRoot) | Out-Null

try {
    $fakeBin = Join-Path $TmpRoot 'bin'
    [System.IO.Directory]::CreateDirectory($fakeBin) | Out-Null
    $fakeAgyPs = Join-Path $fakeBin 'fake_agy.ps1'

    @'
if ($args -contains '--version') {
    [Console]::Out.WriteLine("agy 1.1.25")
    exit 0
}

$isPlan = ($args -contains '--mode' -and ($args[$args.IndexOf('--mode') + 1] -eq 'plan')) -or ($args -contains 'plan')
$outIdx = $args.IndexOf('--output')
$outputPath = if ($outIdx -ge 0 -and $outIdx + 1 -lt $args.Count) { $args[$outIdx + 1] } else { $null }

# If sentinel write requested and in unconstrained mode, write sentinel file
if ($env:FAKE_AGY_SENTINEL_TARGET -and -not $isPlan) {
    try {
        [System.IO.File]::WriteAllText($env:FAKE_AGY_SENTINEL_TARGET, "sentinel-ok", [System.Text.Encoding]::UTF8)
    } catch { }
}

$armName = if ($isPlan) { "plan" } else { "default" }
$sentinelResult = if ($isPlan) { "blocked" } else { "succeeded" }

$resObj = [ordered]@{
    status = "success"
    response = "probe observation for arm $armName"
    structured_output = [ordered]@{
        arm = $armName
        permission_mode = "always-proceed"
        tools = @("read_file", "write_file", "run_command")
        sentinel_result = $sentinelResult
    }
    duration_seconds = 2
    usage = [ordered]@{
        prompt_tokens = 50
        completion_tokens = 20
    }
}

$jsonText = ConvertTo-Json -InputObject $resObj -Compress
if ($outputPath) {
    [System.IO.File]::WriteAllText($outputPath, $jsonText, [System.Text.Encoding]::UTF8)
}
[Console]::Out.WriteLine($jsonText)
exit 0
'@ | Set-Content -LiteralPath $fakeAgyPs -Encoding utf8

    if ($IsWindows) {
        $fakeAgyCmd = Join-Path $fakeBin 'agy.cmd'
        @("@echo off", "pwsh -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake_agy.ps1`" %*") | Set-Content -LiteralPath $fakeAgyCmd -Encoding ascii
        $fakeAgyBat = Join-Path $fakeBin 'agy.bat'
        @("@echo off", "pwsh -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake_agy.ps1`" %*") | Set-Content -LiteralPath $fakeAgyBat -Encoding ascii
    } else {
        $fakeAgyUnix = Join-Path $fakeBin 'agy'
        @("#!/usr/bin/env pwsh", "pwsh -NoProfile -ExecutionPolicy Bypass -File `"`$PSScriptRoot/fake_agy.ps1`" `"`$@`"") | Set-Content -LiteralPath $fakeAgyUnix -Encoding utf8
        [System.IO.File]::SetUnixFileMode($fakeAgyUnix, [System.IO.UnixFileMode]509)
    }

    $pathSep = [System.IO.Path]::PathSeparator
    $testEnv = @{
        'AGY_BIN'                   = $fakeAgyPs
        'PATH'                      = "$fakeBin$pathSep$env:PATH"
        'FAKE_AGY_SENTINEL_TARGET'  = (Join-Path $TmpRoot 'sentinel.txt')
    }

    $probeWorkspace = Join-Path $TmpRoot 'probe-workspace'
    [System.IO.Directory]::CreateDirectory($probeWorkspace) | Out-Null
    $probeReport = Join-Path $TmpRoot 'probe-report.json'

    # Run the probe script in a disposable workspace
    $pwshBin = (Get-Process -Id $PID).MainModule.FileName
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwshBin
    $psi.Arguments = "-NoProfile -NonInteractive -File `"$probeScriptPs`" --workspace `"$probeWorkspace`" --output `"$probeReport`""
    $psi.WorkingDirectory = $probeWorkspace
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    foreach ($k in $testEnv.Keys) {
        $psi.Environment[$k] = $testEnv[$k]
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    # If the probe requires different invocation syntax, try running without flags
    if ($proc.ExitCode -ne 0 -and ($stderr -match 'unrecognized|unknown option|Usage:')) {
        $psi.Arguments = "-NoProfile -NonInteractive -File `"$probeScriptPs`""
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
    }

    Assert-Equal $proc.ExitCode 0 "probe: executes successfully with fake runner exiting 0"

    $reportContent = if (Test-Path -LiteralPath $probeReport -PathType Leaf) {
        Get-Content -LiteralPath $probeReport -Raw
    } else {
        $stdout
    }

    Assert-True ($reportContent -match '1\.1\.25|version') "probe output: records agy version"
    Assert-True ($reportContent -match 'plan') "probe output: records plan-mode arm"
    Assert-True ($reportContent -match 'sentinel') "probe output: records sentinel write check"
    Assert-True ($reportContent -match 'observation|warning|result|status') "probe output: reports observations and warnings"

    # Verify repository tree was not mutated by probe execution
    $gitStatusPsi = [System.Diagnostics.ProcessStartInfo]::new('git', 'status --porcelain')
    $gitStatusPsi.WorkingDirectory = $RootDir
    $gitStatusPsi.RedirectStandardOutput = $true
    $gitStatusPsi.UseShellExecute = $false
    $gitProc = [System.Diagnostics.Process]::Start($gitStatusPsi)
    $statusOut = $gitProc.StandardOutput.ReadToEnd().Trim()
    $gitProc.WaitForExit()

    $unrelatedChanges = @($statusOut -split "`r?`n" | Where-Object {
        $_ -and $_ -notmatch 'test_verification_hardening_docs\.ps1'
    })
    Assert-True ($unrelatedChanges.Count -eq 0) "probe: does not modify or contaminate git repository"
} finally {
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ===========================================================================
# 6. Checked-In Compatibility Probe Fixture Validation (If Present)
# ===========================================================================

$fixtureCandidate = Join-Path $RootDir 'tests/fixtures/compatibility-probe.json'
if (Test-Path -LiteralPath $fixtureCandidate -PathType Leaf) {
    $fixRaw = Get-Content -LiteralPath $fixtureCandidate -Raw
    Assert-True ($fixRaw -match 'plan') "fixture: compatibility probe fixture includes plan arm"
    Assert-True ($fixRaw -match 'sentinel') "fixture: compatibility probe fixture includes sentinel check"
    Assert-True ($fixRaw -match 'version') "fixture: compatibility probe fixture includes version capture"
}

[Console]::Out.WriteLine("all verification hardening docs and probe checks passed ($script:TotalTests tests)")
exit 0
