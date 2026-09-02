#!/usr/bin/env pwsh
# scripts/run-agy-json.ps1
# Offload worker launcher for PowerShell orchestrators.
# Runs agy with isolated stdout and stderr redirection.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Show-Usage {
    [Console]::Error.WriteLine("Usage: run-agy-json.ps1 --role ROLE [--route default|quality-retry] --output FILE --error FILE '--' agy-arguments...")
    [Console]::Error.WriteLine("In PowerShell command expressions, quote '--' because PowerShell consumes the bare delimiter before the helper receives it.")
}

function Fail([string]$message, [int]$exitCode = 2) {
    [Console]::Error.WriteLine("ERROR: $message")
    exit $exitCode
}

$outputPath = ""
$errorPath = ""
$role = ""
$route = ""
$seenOutput = $false
$seenError = $false
$seenRole = $false
$seenRoute = $false
$seenDashDash = $false
$forwardedArgs = [System.Collections.Generic.List[string]]::new()

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    if ($arg -eq '--') {
        $seenDashDash = $true
        $i++
        while ($i -lt $args.Count) {
            $forwardedArgs.Add([string]$args[$i])
            $i++
        }
        break
    } elseif ($arg -eq '--output') {
        if ($seenOutput) {
            Fail "duplicate --output option"
        }
        $i++
        if ($i -ge $args.Count) {
            Show-Usage
            Fail "--output requires a path"
        }
        $outputPath = [string]$args[$i]
        $seenOutput = $true
    } elseif ($arg.StartsWith('--output=')) {
        if ($seenOutput) {
            Fail "duplicate --output option"
        }
        $outputPath = $arg.Substring(9)
        if ([string]::IsNullOrWhiteSpace($outputPath)) {
            Show-Usage
            Fail "--output requires a path"
        }
        $seenOutput = $true
    } elseif ($arg -eq '--error') {
        if ($seenError) {
            Fail "duplicate --error option"
        }
        $i++
        if ($i -ge $args.Count) {
            Show-Usage
            Fail "--error requires a path"
        }
        $errorPath = [string]$args[$i]
        $seenError = $true
    } elseif ($arg.StartsWith('--error=')) {
        if ($seenError) {
            Fail "duplicate --error option"
        }
        $errorPath = $arg.Substring(8)
        if ([string]::IsNullOrWhiteSpace($errorPath)) {
            Show-Usage
            Fail "--error requires a path"
        }
        $seenError = $true
    } elseif ($arg -eq '--role') {
        if ($seenRole) {
            Fail "duplicate --role option"
        }
        $i++
        if ($i -ge $args.Count) {
            Show-Usage
            Fail "--role requires a role name"
        }
        $role = [string]$args[$i]
        $seenRole = $true
    } elseif ($arg.StartsWith('--role=')) {
        if ($seenRole) {
            Fail "duplicate --role option"
        }
        $role = $arg.Substring(7)
        if ([string]::IsNullOrWhiteSpace($role)) {
            Show-Usage
            Fail "--role requires a role name"
        }
        $seenRole = $true
    } elseif ($arg -eq '--route') {
        if ($seenRoute) {
            Fail "duplicate --route option"
        }
        $i++
        if ($i -ge $args.Count) {
            Show-Usage
            Fail "--route requires a route name"
        }
        $route = [string]$args[$i]
        $seenRoute = $true
    } elseif ($arg.StartsWith('--route=')) {
        if ($seenRoute) {
            Fail "duplicate --route option"
        }
        $route = $arg.Substring(8)
        if ([string]::IsNullOrWhiteSpace($route)) {
            Show-Usage
            Fail "--route requires a route name"
        }
        $seenRoute = $true
    } else {
        Show-Usage
        Fail "unknown launcher option: $arg"
    }
    $i++
}

if (-not $seenDashDash) {
    Show-Usage
    Fail "-- delimiter is required"
}
if (-not $seenOutput -or [string]::IsNullOrWhiteSpace($outputPath)) {
    Show-Usage
    Fail "--output is required"
}
if (-not $seenError -or [string]::IsNullOrWhiteSpace($errorPath)) {
    Show-Usage
    Fail "--error is required"
}
if (-not $seenRole -or [string]::IsNullOrWhiteSpace($role)) {
    Show-Usage
    Fail "--role is required; specify a role and remove any caller --model flag"
}

$knownRoles = @('scout', 'gate-author', 'implementer', 'reviewer', 'researcher', 'synthesizer', 'auditor')
if ($knownRoles -notcontains $role) {
    Fail "unknown role: '$role'; must be one of $($knownRoles -join ', ')"
}

if ([string]::IsNullOrEmpty($route)) {
    $route = 'default'
}
if ($route -ne 'default' -and $route -ne 'quality-retry') {
    Fail "unknown route: '$route'; must be 'default' or 'quality-retry'"
}

if ($forwardedArgs.Count -eq 0) {
    Show-Usage
    Fail "agy arguments are required after --"
}

$knownValueTakingOptions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
@('-p', '--prompt', '--print', '--prompt-interactive', '-i', '--path', '--output-format', '--mode', '--json-schema', '--add-dir', '--agent', '--conversation', '--log-file', '--print-timeout', '--project', '--input-format') | ForEach-Object { $knownValueTakingOptions.Add($_) | Out-Null }

$idx = 0
while ($idx -lt $forwardedArgs.Count) {
    $fa = $forwardedArgs[$idx]
    if ($fa -eq '--output' -or $fa.StartsWith('--output=')) {
        Fail "do not pass --output to agy; use the launcher --output path instead"
    } elseif ($fa -eq '--model' -or $fa.StartsWith('--model=')) {
        Fail "caller cannot specify --model; model routing is controlled by --role"
    } elseif ($fa -eq '--effort' -or $fa.StartsWith('--effort=')) {
        Fail "caller cannot specify --effort; reasoning effort is controlled by policy"
    } elseif ($knownValueTakingOptions.Contains($fa)) {
        if ($idx + 1 -lt $forwardedArgs.Count) {
            $idx++
        }
    }
    $idx++
}

# Resolve policy file repository-root relative to launcher location
$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path)
}
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
$policyFile = Join-Path $repoRoot 'model-policy.json'

if (-not (Test-Path -LiteralPath $policyFile -PathType Leaf)) {
    Fail "model policy file not found at: $policyFile"
}

$policyRaw = ""
try {
    $policyRaw = [System.IO.File]::ReadAllText($policyFile, [System.Text.Encoding]::UTF8)
} catch {
    Fail "failed to read model policy file: $policyFile ($($_.Exception.Message))"
}

$policy = $null
try {
    $policy = ConvertFrom-Json -InputObject $policyRaw -Depth 20 -ErrorAction Stop
} catch {
    Fail "model policy file is not valid JSON: $policyFile ($($_.Exception.Message))"
}

if ($null -eq $policy -or $policy -isnot [System.Management.Automation.PSCustomObject]) {
    Fail "model policy must be a JSON object: $policyFile"
}

$schemaProp = $policy.PSObject.Properties['schema_version']
if ($null -eq $schemaProp -or ($schemaProp.Value -isnot [int] -and $schemaProp.Value -isnot [long]) -or $schemaProp.Value -ne 1) {
    Fail "unsupported schema_version in model policy: must be integer 1"
}

$revProp = $policy.PSObject.Properties['policy_revision']
if ($null -eq $revProp -or $revProp.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($revProp.Value)) {
    Fail "policy_revision in model policy must be a non-empty string"
}

$effortProp = $policy.PSObject.Properties['max_effort']
if ($null -eq $effortProp -or $effortProp.Value -ne 'high') {
    Fail "invalid max_effort in model policy: must be 'high'"
}

$retriesProp = $policy.PSObject.Properties['max_retries_per_worker']
if ($null -eq $retriesProp -or ($retriesProp.Value -isnot [int] -and $retriesProp.Value -isnot [long]) -or $retriesProp.Value -ne 1) {
    Fail "unsupported max_retries_per_worker in model policy: must be integer 1"
}

$quotaProp = $policy.PSObject.Properties['quota_action']
if ($null -eq $quotaProp -or $quotaProp.Value -ne 'handoff') {
    Fail "invalid quota_action in model policy: must be 'handoff'"
}

$rolesProp = $policy.PSObject.Properties['roles']
if ($null -eq $rolesProp -or $null -eq $rolesProp.Value -or $rolesProp.Value -isnot [System.Management.Automation.PSCustomObject]) {
    Fail "roles in model policy must be a JSON object"
}

$expectedRoles = @('scout', 'gate-author', 'implementer', 'reviewer', 'researcher', 'synthesizer', 'auditor')
$actualRoleNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($rp in $rolesProp.Value.PSObject.Properties) {
    $actualRoleNames.Add($rp.Name) | Out-Null
}

foreach ($reqRole in $expectedRoles) {
    if (-not $actualRoleNames.Contains($reqRole)) {
        Fail "model policy roles missing required role: $reqRole"
    }
}
foreach ($actRole in $actualRoleNames) {
    if ($expectedRoles -notcontains $actRole) {
        Fail "model policy roles contains unknown role: $actRole"
    }
}

$geminiModelRegex = '^gemini-[a-zA-Z0-9.-]+-(low|medium|high)$'

foreach ($rname in $expectedRoles) {
    $roleEntry = $rolesProp.Value.PSObject.Properties[$rname]
    if ($null -eq $roleEntry -or $null -eq $roleEntry.Value -or $roleEntry.Value -isnot [System.Management.Automation.PSCustomObject]) {
        Fail "role '$rname' in model policy must be an object"
    }
    $rObj = $roleEntry.Value

    $dmProp = $rObj.PSObject.Properties['default_model']
    if ($null -eq $dmProp -or $dmProp.Value -isnot [string] -or $dmProp.Value -notmatch $geminiModelRegex) {
        Fail "role '$rname' has invalid default_model (must match '$geminiModelRegex')"
    }
    $defaultModel = [string]$dmProp.Value

    $escProp = $rObj.PSObject.Properties['quality_escalation']
    if ($null -eq $escProp) {
        Fail "role '$rname' in model policy missing quality_escalation"
    }
    if ($null -ne $escProp.Value) {
        if ($escProp.Value -isnot [System.Management.Automation.PSCustomObject]) {
            Fail "role '$rname' quality_escalation must be null or an object"
        }
        $escObj = $escProp.Value

        $escModelProp = $escObj.PSObject.Properties['model']
        if ($null -eq $escModelProp -or $escModelProp.Value -isnot [string] -or $escModelProp.Value -notmatch $geminiModelRegex) {
            Fail "role '$rname' quality_escalation model is invalid (must match '$geminiModelRegex')"
        }
        if ($escModelProp.Value -eq $defaultModel) {
            Fail "role '$rname' quality_escalation model identical to default_model"
        }

        $evPathProp = $escObj.PSObject.Properties['evidence_path']
        if ($null -eq $evPathProp -or $evPathProp.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($evPathProp.Value)) {
            Fail "role '$rname' quality_escalation evidence_path must be non-empty string"
        }
        $evPath = [string]$evPathProp.Value
        if ($evPath.StartsWith('/') -or $evPath.StartsWith('\') -or $evPath.Contains(':') -or $evPath.Contains('..')) {
            Fail "role '$rname' quality_escalation evidence_path must not escape repository root: $evPath"
        }
        $fullEvPath = Join-Path $repoRoot $evPath
        if (-not (Test-Path -LiteralPath $fullEvPath -PathType Leaf)) {
            Fail "missing escalation evidence path: $evPath"
        }
    }
}

# Resolve model for role and route
$resolvedModel = $null
if ($route -eq 'default') {
    $resolvedModel = [string]$rolesProp.Value.PSObject.Properties[$role].Value.PSObject.Properties['default_model'].Value
} elseif ($route -eq 'quality-retry') {
    $escVal = $rolesProp.Value.PSObject.Properties[$role].Value.PSObject.Properties['quality_escalation'].Value
    if ($null -eq $escVal) {
        Fail "role '$role' has no quality escalation target configured for quality-retry route"
    }
    $escModel = $escVal.PSObject.Properties['model']
    if ($null -eq $escModel -or [string]::IsNullOrWhiteSpace($escModel.Value)) {
        Fail "role '$role' has no quality escalation target configured for quality-retry route"
    }
    $resolvedModel = [string]$escModel.Value
}

if ([string]::IsNullOrWhiteSpace($resolvedModel)) {
    Fail "failed to resolve model for role '$role' and route '$route'"
}

# Resolve agy executable
$resolvedAgy = $null

if ($env:AGY_BIN) {
    $explicit = $env:AGY_BIN.Trim()
    if ($explicit.Length -gt 0) {
        $cmd = Get-Command $explicit -ErrorAction SilentlyContinue
        if ($cmd) {
            $resolvedAgy = if ($cmd.Source) { $cmd.Source } else { $cmd.Name }
        } elseif (Test-Path -LiteralPath $explicit -PathType Leaf) {
            $resolvedAgy = (Resolve-Path -LiteralPath $explicit).Path
        } else {
            Fail "explicit AGY_BIN does not resolve to an executable file or command: $explicit" 1
        }
    }
}

if (-not $resolvedAgy) {
    $cmd = Get-Command agy -ErrorAction SilentlyContinue
    if ($cmd) {
        $resolvedAgy = if ($cmd.Source) { $cmd.Source } else { $cmd.Name }
    }
}

if (-not $resolvedAgy) {
    $userProfile = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    if ($userProfile) {
        $candidate1 = Join-Path $userProfile '.local\bin\agy.exe'
        $candidate2 = Join-Path $userProfile '.local/bin/agy'
        if (Test-Path -LiteralPath $candidate1 -PathType Leaf) {
            $resolvedAgy = $candidate1
        } elseif (Test-Path -LiteralPath $candidate2 -PathType Leaf) {
            $resolvedAgy = $candidate2
        }
    }
}

if (-not $resolvedAgy) {
    Fail "agy was not found (checked AGY_BIN, Get-Command agy, %USERPROFILE%\.local\bin\agy.exe)" 1
}

# Ensure parent directories exist
$resolvedOutputPath = [System.IO.Path]::GetFullPath($outputPath)
$resolvedErrorPath = [System.IO.Path]::GetFullPath($errorPath)

$outDir = [System.IO.Path]::GetDirectoryName($resolvedOutputPath)
if (-not [string]::IsNullOrEmpty($outDir) -and -not [System.IO.Directory]::Exists($outDir)) {
    [System.IO.Directory]::CreateDirectory($outDir) | Out-Null
}

$errDir = [System.IO.Path]::GetDirectoryName($resolvedErrorPath)
if (-not [string]::IsNullOrEmpty($errDir) -and -not [System.IO.Directory]::Exists($errDir)) {
    [System.IO.Directory]::CreateDirectory($errDir) | Out-Null
}

$psi = [System.Diagnostics.ProcessStartInfo]::new()
if ($resolvedAgy.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
    $pwshBin = (Get-Process -Id $PID).Path
    $psi.FileName = $pwshBin
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($resolvedAgy)
} else {
    $psi.FileName = $resolvedAgy
}

$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.ArgumentList.Add('--model')
$psi.ArgumentList.Add($resolvedModel)
foreach ($arg in $forwardedArgs) {
    $psi.ArgumentList.Add($arg)
}

$proc = $null
try {
    $proc = [System.Diagnostics.Process]::Start($psi)
} catch {
    Fail "failed to start agy: $($_.Exception.Message)" 1
}

$outFs = [System.IO.File]::Create($resolvedOutputPath)
$errFs = [System.IO.File]::Create($resolvedErrorPath)

try {
    $outTask = $proc.StandardOutput.BaseStream.CopyToAsync($outFs)
    $errTask = $proc.StandardError.BaseStream.CopyToAsync($errFs)
    $proc.WaitForExit()
    [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask))
} finally {
    $outFs.Dispose()
    $errFs.Dispose()
}

exit $proc.ExitCode
