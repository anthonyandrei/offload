#!/usr/bin/env pwsh
# scripts/run-agy-json.ps1
# Offload worker launcher for PowerShell orchestrators.
# Runs agy with isolated stdout and stderr redirection.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Show-Usage {
    [Console]::Error.WriteLine("Usage: run-agy-json.ps1 --role ROLE [--route default|quality-retry] [--timeout-seconds N] --output FILE --error FILE [lifecycle options] [--ledger FILE --assignment-id ID --parent-id ID [--resource-id ID]] '--' agy-arguments...")
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
$lifecyclePath = ""
$attempt = 1
$mode = "unknown"
$verificationBaseline = ""
$resourceLedgerPath = ""
$timeoutSeconds = 0
$cancelFile = ""
$ledgerPath = ""
$assignmentId = ""
$parentId = ""
$resourceId = ""
$seenOutput = $false
$seenError = $false
$seenRole = $false
$seenRoute = $false
$seenLifecycle = $false
$seenAssignmentId = $false
$seenAttempt = $false
$seenMode = $false
$seenVerificationBaseline = $false
$seenResourceLedger = $false
$seenTimeout = $false
$seenCancelFile = $false
$seenDashDash = $false
$seenLedger = $false
$seenParent = $false
$seenResource = $false
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
    } elseif ($arg -eq '--lifecycle') {
        if ($seenLifecycle) { Fail "duplicate --lifecycle option" }
        $i++
        if ($i -ge $args.Count) { Show-Usage; Fail "--lifecycle requires a path" }
        $lifecyclePath = [string]$args[$i]
        $seenLifecycle = $true
    } elseif ($arg.StartsWith('--lifecycle=')) {
        if ($seenLifecycle) { Fail "duplicate --lifecycle option" }
        $lifecyclePath = $arg.Substring(12)
        if ([string]::IsNullOrWhiteSpace($lifecyclePath)) { Show-Usage; Fail "--lifecycle requires a path" }
        $seenLifecycle = $true
    } elseif ($arg -eq '--attempt') {
        if ($seenAttempt) { Fail "duplicate --attempt option" }
        $i++
        if ($i -ge $args.Count) { Show-Usage; Fail "--attempt requires an integer" }
        if (-not [int]::TryParse([string]$args[$i], [ref]$attempt)) { Fail "--attempt requires an integer" }
        $seenAttempt = $true
    } elseif ($arg.StartsWith('--attempt=')) {
        if ($seenAttempt) { Fail "duplicate --attempt option" }
        if (-not [int]::TryParse($arg.Substring(10), [ref]$attempt)) { Fail "--attempt requires an integer" }
        $seenAttempt = $true
    } elseif ($arg -eq '--mode') {
        if ($seenMode) { Fail "duplicate --mode option" }
        $i++
        if ($i -ge $args.Count) { Show-Usage; Fail "--mode requires a mode name" }
        $mode = [string]$args[$i]
        $seenMode = $true
    } elseif ($arg.StartsWith('--mode=')) {
        if ($seenMode) { Fail "duplicate --mode option" }
        $mode = $arg.Substring(7)
        if ([string]::IsNullOrWhiteSpace($mode)) { Show-Usage; Fail "--mode requires a mode name" }
        $seenMode = $true
    } elseif ($arg -eq '--verification-baseline') {
        if ($seenVerificationBaseline) { Fail "duplicate --verification-baseline option" }
        $i++
        if ($i -ge $args.Count) { Show-Usage; Fail "--verification-baseline requires a value" }
        $verificationBaseline = [string]$args[$i]
        $seenVerificationBaseline = $true
    } elseif ($arg.StartsWith('--verification-baseline=')) {
        if ($seenVerificationBaseline) { Fail "duplicate --verification-baseline option" }
        $verificationBaseline = $arg.Substring(24)
        if ([string]::IsNullOrWhiteSpace($verificationBaseline)) { Show-Usage; Fail "--verification-baseline requires a value" }
        $seenVerificationBaseline = $true
    } elseif ($arg -eq '--resource-ledger') {
        if ($seenResourceLedger) { Fail "duplicate --resource-ledger option" }
        $i++
        if ($i -ge $args.Count) { Show-Usage; Fail "--resource-ledger requires a path" }
        $resourceLedgerPath = [string]$args[$i]
        $seenResourceLedger = $true
    } elseif ($arg.StartsWith('--resource-ledger=')) {
        if ($seenResourceLedger) { Fail "duplicate --resource-ledger option" }
        $resourceLedgerPath = $arg.Substring(18)
        if ([string]::IsNullOrWhiteSpace($resourceLedgerPath)) { Show-Usage; Fail "--resource-ledger requires a path" }
        $seenResourceLedger = $true
    } elseif ($arg -eq '--timeout-seconds') {
        if ($seenTimeout) { Fail "duplicate --timeout-seconds option" }
        $i++
        if ($i -ge $args.Count) { Show-Usage; Fail "--timeout-seconds requires a positive number" }
        if (-not [int]::TryParse([string]$args[$i], [ref]$timeoutSeconds)) { Fail "--timeout-seconds requires a positive number" }
        $seenTimeout = $true
    } elseif ($arg.StartsWith('--timeout-seconds=')) {
        if ($seenTimeout) { Fail "duplicate --timeout-seconds option" }
        if (-not [int]::TryParse($arg.Substring(18), [ref]$timeoutSeconds)) { Fail "--timeout-seconds requires a positive number" }
        $seenTimeout = $true
    } elseif ($arg -eq '--cancel-file') {
        if ($seenCancelFile) { Fail "duplicate --cancel-file option" }
        $i++
        if ($i -ge $args.Count) { Show-Usage; Fail "--cancel-file requires a path" }
        $cancelFile = [string]$args[$i]
        $seenCancelFile = $true
    } elseif ($arg.StartsWith('--cancel-file=')) {
        if ($seenCancelFile) { Fail "duplicate --cancel-file option" }
        $cancelFile = $arg.Substring(14)
        if ([string]::IsNullOrWhiteSpace($cancelFile)) { Show-Usage; Fail "--cancel-file requires a path" }
        $seenCancelFile = $true
    } elseif ($arg -eq '--ledger') {
        if ($seenLedger) { Fail "duplicate --ledger option" }
        $i++
        if ($i -ge $args.Count) { Show-Usage; Fail "--ledger requires a path" }
        $ledgerPath = [string]$args[$i]
        $seenLedger = $true
    } elseif ($arg.StartsWith('--ledger=')) {
        if ($seenLedger) { Fail "duplicate --ledger option" }
        $ledgerPath = $arg.Substring(9)
        if ([string]::IsNullOrWhiteSpace($ledgerPath)) { Show-Usage; Fail "--ledger requires a path" }
        $seenLedger = $true
    } elseif ($arg -eq '--assignment-id') {
        if ($seenAssignmentId) { Fail "duplicate --assignment-id option" }
        $i++
        if ($i -ge $args.Count) { Show-Usage; Fail "--assignment-id requires a value" }
        $assignmentId = [string]$args[$i]
        $seenAssignmentId = $true
    } elseif ($arg.StartsWith('--assignment-id=')) {
        if ($seenAssignmentId) { Fail "duplicate --assignment-id option" }
        $assignmentId = $arg.Substring(16)
        if ([string]::IsNullOrWhiteSpace($assignmentId)) { Show-Usage; Fail "--assignment-id requires a value" }
        $seenAssignmentId = $true
    } elseif ($arg -eq '--parent-id') {
        if ($seenParent) { Fail "duplicate --parent-id option" }
        $i++
        if ($i -ge $args.Count) { Show-Usage; Fail "--parent-id requires a value" }
        $parentId = [string]$args[$i]
        $seenParent = $true
    } elseif ($arg.StartsWith('--parent-id=')) {
        if ($seenParent) { Fail "duplicate --parent-id option" }
        $parentId = $arg.Substring(12)
        if ([string]::IsNullOrWhiteSpace($parentId)) { Show-Usage; Fail "--parent-id requires a value" }
        $seenParent = $true
    } elseif ($arg -eq '--resource-id') {
        if ($seenResource) { Fail "duplicate --resource-id option" }
        $i++
        if ($i -ge $args.Count) { Show-Usage; Fail "--resource-id requires a value" }
        $resourceId = [string]$args[$i]
        $seenResource = $true
    } elseif ($arg.StartsWith('--resource-id=')) {
        if ($seenResource) { Fail "duplicate --resource-id option" }
        $resourceId = $arg.Substring(14)
        if ([string]::IsNullOrWhiteSpace($resourceId)) { Show-Usage; Fail "--resource-id requires a value" }
        $seenResource = $true
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

if ($env:OFFLOAD_WORKER_CONTEXT -eq '1') {
    Fail 'worker process cannot invoke the launcher; only the orchestrator may create worker processes' 126
}

if ($seenTimeout) {
    $parsedTimeout = 0
    if (-not [int]::TryParse($timeoutSeconds, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedTimeout) -or $parsedTimeout -le 0) {
        Fail '--timeout-seconds must be a positive integer'
    }
    $timeoutSeconds = $parsedTimeout
}

if ($seenLedger -or $seenAssignmentId -or $seenParent -or $seenResource) {
    if (-not $seenLedger -or [string]::IsNullOrWhiteSpace($ledgerPath)) { Fail "--ledger is required when resource ledger registration is enabled" }
    if (-not $seenAssignmentId -or [string]::IsNullOrWhiteSpace($assignmentId)) { Fail "--assignment-id is required when resource ledger registration is enabled" }
    if (-not $seenParent -or [string]::IsNullOrWhiteSpace($parentId)) { Fail "--parent-id is required when resource ledger registration is enabled" }
    if ([string]::IsNullOrWhiteSpace($resourceId)) { $resourceId = "worker:$assignmentId" }
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

$callerLocation = Get-Location
if ($null -eq $callerLocation.Provider -or $callerLocation.Provider.Name -ne 'FileSystem') {
    Fail "current location must use the FileSystem provider; refusing to launch agy from '$($callerLocation.Path)'"
}
$callerWorkingDirectory = $callerLocation.ProviderPath
if ([string]::IsNullOrWhiteSpace($callerWorkingDirectory) -or -not [System.IO.Directory]::Exists($callerWorkingDirectory)) {
    Fail "current filesystem location is not an existing directory: $($callerLocation.Path)"
}
$callerWorkingDirectory = [System.IO.Path]::GetFullPath($callerWorkingDirectory)

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

if ($attempt -lt 1 -or $attempt -gt 2) {
    Fail "attempt must be 1 or 2; policy allows at most one retry per assignment"
}
if ($timeoutSeconds -lt 0) {
    Fail "--timeout-seconds must be zero or a positive integer"
}
if ([string]::IsNullOrWhiteSpace($assignmentId)) {
    $assignmentId = "$role-$(Get-Date -Format 'yyyyMMddHHmmssfff')"
}
if ([string]::IsNullOrWhiteSpace($lifecyclePath)) {
    $lifecyclePath = "$outputPath.lifecycle.json"
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

# Resolve paths and validate output/error destinations
$resolvedOutputPath = [System.IO.Path]::GetFullPath($outputPath)
$resolvedErrorPath = [System.IO.Path]::GetFullPath($errorPath)
$resolvedLifecyclePath = [System.IO.Path]::GetFullPath($lifecyclePath)
$resolvedResourceLedgerPath = if ([string]::IsNullOrWhiteSpace($resourceLedgerPath)) { "" } else { [System.IO.Path]::GetFullPath($resourceLedgerPath) }

$pathComparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

if ([string]::Equals($resolvedOutputPath, $resolvedErrorPath, $pathComparison)) {
    Fail "output and error paths must not be identical: $resolvedOutputPath"
}

if ([System.IO.Directory]::Exists($resolvedOutputPath)) {
    Fail "output destination is an existing directory: $resolvedOutputPath"
}

if ([System.IO.Directory]::Exists($resolvedErrorPath)) {
    Fail "error destination is an existing directory: $resolvedErrorPath"
}

if ([System.IO.Directory]::Exists($resolvedLifecyclePath)) {
    Fail "lifecycle destination is an existing directory: $resolvedLifecyclePath"
}
if ($resolvedResourceLedgerPath -and [System.IO.Directory]::Exists($resolvedResourceLedgerPath)) {
    Fail "resource ledger destination is an existing directory: $resolvedResourceLedgerPath"
}

try {
    $outDir = [System.IO.Path]::GetDirectoryName($resolvedOutputPath)
    if (-not [string]::IsNullOrEmpty($outDir) -and -not [System.IO.Directory]::Exists($outDir)) {
        [System.IO.Directory]::CreateDirectory($outDir) | Out-Null
    }

    $errDir = [System.IO.Path]::GetDirectoryName($resolvedErrorPath)
    if (-not [string]::IsNullOrEmpty($errDir) -and -not [System.IO.Directory]::Exists($errDir)) {
        [System.IO.Directory]::CreateDirectory($errDir) | Out-Null
    }
} catch {
    Fail "failed to create parent directory for output or error: $($_.Exception.Message)" 1
}

$effort = if ($resolvedModel -match '-(low|medium|high)$') { $Matches[1] } else { 'unknown' }
$script:Lifecycle = [ordered]@{
    schema_version = 1
    assignment_id = $assignmentId
    attempt = $attempt
    role = $role
    mode = $mode
    policy_revision = [string]$policy.PSObject.Properties['policy_revision'].Value
    model = $resolvedModel
    effort = $effort
    verification_baseline = if ($verificationBaseline) { $verificationBaseline } else { $null }
    resource_ledger = if ($resolvedResourceLedgerPath) { $resolvedResourceLedgerPath } else { $null }
    state = 'created'
    events = @()
    exit_code = $null
    termination = 'none'
    failure_class = 'none'
    artifacts = [ordered]@{
        output = $resolvedOutputPath
        error = $resolvedErrorPath
        lifecycle = $resolvedLifecyclePath
    }
}

function Save-Lifecycle {
    $json = $script:Lifecycle | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($resolvedLifecyclePath, $json, [System.Text.Encoding]::UTF8)
}

function Set-LifecycleState([string]$state, [hashtable]$details = @{}) {
    $event = [ordered]@{
        state = $state
        at = [DateTime]::UtcNow.ToString('o')
    }
    foreach ($key in $details.Keys) { $event[$key] = $details[$key] }
    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($existing in @($script:Lifecycle.events)) { $events.Add($existing) }
    $events.Add([PSCustomObject]$event)
    $script:Lifecycle.events = @($events)
    $script:Lifecycle.state = $state
    foreach ($key in $details.Keys) {
        if ($script:Lifecycle.Contains($key)) { $script:Lifecycle[$key] = $details[$key] }
    }
    Save-Lifecycle
}

function Test-WorkerOutput {
    try {
        $rawOutput = [System.IO.File]::ReadAllText($resolvedOutputPath, [System.Text.Encoding]::UTF8)
        $parsedOutput = ConvertFrom-Json -InputObject $rawOutput -Depth 20 -ErrorAction Stop
        $structuredOutputProperty = $parsedOutput.PSObject.Properties['structured_output']
        return ($parsedOutput -is [System.Management.Automation.PSCustomObject] -and
            $parsedOutput.status -eq 'success' -and
            $null -ne $structuredOutputProperty -and
            $structuredOutputProperty.Value -is [System.Management.Automation.PSCustomObject])
    } catch {
        return $false
    }
}

function Test-QuotaSignal {
    try {
        $outputText = [System.IO.File]::ReadAllText($resolvedOutputPath, [System.Text.Encoding]::UTF8)
        $errorText = [System.IO.File]::ReadAllText($resolvedErrorPath, [System.Text.Encoding]::UTF8)
        return (($outputText + "`n" + $errorText) -match '(?i)quota|resource[_ -]?exhausted|rate limit|\b429\b')
    } catch {
        return $false
    }
}

try {
    $lifecycleDir = [System.IO.Path]::GetDirectoryName($resolvedLifecyclePath)
    if ($lifecycleDir -and -not [System.IO.Directory]::Exists($lifecycleDir)) {
        [System.IO.Directory]::CreateDirectory($lifecycleDir) | Out-Null
    }
    Save-Lifecycle
    Set-LifecycleState 'created'
} catch {
    Fail "failed to create lifecycle artifact '$resolvedLifecyclePath': $($_.Exception.Message)" 1
}

if ($resolvedResourceLedgerPath) {
    try {
        $ledgerDir = [System.IO.Path]::GetDirectoryName($resolvedResourceLedgerPath)
        if ($ledgerDir -and -not [System.IO.Directory]::Exists($ledgerDir)) {
            [System.IO.Directory]::CreateDirectory($ledgerDir) | Out-Null
        }
        if (Test-Path -LiteralPath $resolvedResourceLedgerPath -PathType Leaf) {
            $ledger = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($resolvedResourceLedgerPath, [System.Text.Encoding]::UTF8)) -Depth 12 -ErrorAction Stop
            if ($ledger.assignment_id -ne $assignmentId -or $ledger.model -ne $resolvedModel -or $ledger.effort -ne $effort) {
                Fail "resource ledger is pinned to a different assignment, model, or effort"
            }
            $ledgerBaselineProperty = $ledger.PSObject.Properties['verification_baseline']
            if ($ledgerBaselineProperty -and $ledgerBaselineProperty.Value) {
                if ($verificationBaseline -and $ledgerBaselineProperty.Value -ne $verificationBaseline) {
                    Fail "resource ledger is pinned to a different verification baseline"
                }
                if (-not $verificationBaseline) {
                    $verificationBaseline = [string]$ledgerBaselineProperty.Value
                    $script:Lifecycle.verification_baseline = $verificationBaseline
                    Save-Lifecycle
                }
            }
        } else {
            $ledger = [ordered]@{
                schema_version = 1
                assignment_id = $assignmentId
                model = $resolvedModel
                effort = $effort
                verification_baseline = if ($verificationBaseline) { $verificationBaseline } else { $null }
                attempts = @()
            }
        }
        $attemptEntry = [ordered]@{
            attempt = $attempt
            model = $resolvedModel
            effort = $effort
            verification_baseline = if ($verificationBaseline) { $verificationBaseline } else { $null }
            lifecycle = $resolvedLifecyclePath
        }
        $ledgerAttempts = [System.Collections.Generic.List[object]]::new()
        if ($ledger.PSObject.Properties['attempts']) {
            foreach ($existingAttempt in @($ledger.attempts)) { $ledgerAttempts.Add($existingAttempt) }
        }
        if (@($ledgerAttempts | Where-Object { $_.attempt -eq $attempt }).Count -gt 0) {
            Fail "resource ledger already contains attempt $attempt"
        }
        $ledgerAttempts.Add([PSCustomObject]$attemptEntry)
        $ledger.attempts = @($ledgerAttempts)
        [System.IO.File]::WriteAllText($resolvedResourceLedgerPath, ($ledger | ConvertTo-Json -Depth 12), [System.Text.Encoding]::UTF8)
    } catch {
        if ($_.Exception.Message -like 'resource ledger*') { throw }
        Fail "failed to read or write resource ledger '$resolvedResourceLedgerPath': $($_.Exception.Message)" 1
    }
}

$outFs = $null
$errFs = $null
$proc = $null
$processStarted = $false
$workerExitCode = 1
$terminalStateRecorded = $false
$ledgerRegistered = $false
$ledgerScript = Join-Path $PSScriptRoot 'resource-ledger.ps1'

try {
    try {
        $outFs = [System.IO.File]::Create($resolvedOutputPath)
    } catch {
        Fail "failed to open output destination '$resolvedOutputPath': $($_.Exception.Message)" 1
    }

    try {
        $errFs = [System.IO.File]::Create($resolvedErrorPath)
    } catch {
        Fail "failed to open error destination '$resolvedErrorPath': $($_.Exception.Message)" 1
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
    $psi.WorkingDirectory = $callerWorkingDirectory
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['OFFLOAD_WORKER_CONTEXT'] = '1'
    $psi.ArgumentList.Add('--model')
    $psi.ArgumentList.Add($resolvedModel)
    foreach ($arg in $forwardedArgs) {
        $psi.ArgumentList.Add($arg)
    }

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Fail "failed to start agy: $($_.Exception.Message)" 1
    }
    $processStarted = $true
    Set-LifecycleState 'started' @{ pid = $proc.Id }

    if ($seenLedger) {
        $startTime = $null
        try { $startTime = $proc.StartTime.ToUniversalTime().ToString('o') } catch { }
        $ledgerArgs = @('register', '--ledger', $ledgerPath, '--assignment-id', $assignmentId, '--parent-id', $parentId, '--resource-type', 'worker-process', '--process-id', [string]$proc.Id, '--owner-marker', 'agy-worker=agy-worker-v1', '--resource-id', $resourceId, '--state', 'active')
        if ($null -ne $startTime) { $ledgerArgs += @('--process-start-time', $startTime) }
        & pwsh -NoProfile -NonInteractive -File $ledgerScript @ledgerArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "failed to register worker process in resource ledger" }
        $ledgerRegistered = $true
    }

    try {
        $outTask = $proc.StandardOutput.BaseStream.CopyToAsync($outFs)
        $errTask = $proc.StandardError.BaseStream.CopyToAsync($errFs)
        Set-LifecycleState 'running'
        if ($env:FAKE_LAUNCHER_FAIL_POST_START -or $env:OFFLOAD_TEST_FAIL_POST_START) {
            if ($env:FAKE_AGY_STARTED_MARKER) {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                while (-not (Test-Path -LiteralPath $env:FAKE_AGY_STARTED_MARKER) -and $sw.ElapsedMilliseconds -lt 5000) {
                    [System.Threading.Thread]::Sleep(20)
                }
            }
            throw "simulated post-start failure"
        }
        $deadline = if ($timeoutSeconds -gt 0) { [DateTime]::UtcNow.AddSeconds($timeoutSeconds) } else { $null }
        $termination = 'natural'
        while (-not $proc.HasExited) {
            if ($cancelFile -and (Test-Path -LiteralPath $cancelFile -PathType Leaf)) {
                $termination = 'canceled'
                break
            }
            if ($deadline -and [DateTime]::UtcNow -ge $deadline) {
                $termination = 'timeout'
                break
            }
            [System.Threading.Thread]::Sleep(50)
        }
        if (-not $proc.HasExited) {
            $proc.Kill($true)
            $proc.WaitForExit()
        } else {
            $proc.WaitForExit()
        }
        [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask))
        $workerExitCode = $proc.ExitCode
        $outFs.Flush()
        $errFs.Flush()
        $outFs.Dispose()
        $outFs = $null
        $errFs.Dispose()
        $errFs = $null

        $script:Lifecycle.exit_code = $workerExitCode
        if ($termination -eq 'canceled') {
            $script:Lifecycle.termination = 'canceled'
            $script:Lifecycle.failure_class = 'canceled'
            Set-LifecycleState 'canceled'
            $terminalStateRecorded = $true
            $workerExitCode = 130
        } elseif ($termination -eq 'timeout') {
            $script:Lifecycle.termination = 'timeout'
            $script:Lifecycle.failure_class = 'timeout'
            Set-LifecycleState 'failed'
            $terminalStateRecorded = $true
            $workerExitCode = 124
        } elseif (Test-QuotaSignal) {
            $script:Lifecycle.termination = 'quota-handoff'
            $script:Lifecycle.failure_class = 'quota'
            Set-LifecycleState 'quota-handoff'
            $terminalStateRecorded = $true
            $workerExitCode = 75
        } elseif ($workerExitCode -ne 0) {
            $script:Lifecycle.termination = 'worker-exit'
            $script:Lifecycle.failure_class = 'tool_error'
            Set-LifecycleState 'failed'
            $terminalStateRecorded = $true
        } elseif (-not (Test-WorkerOutput)) {
            $script:Lifecycle.termination = 'malformed-output'
            $script:Lifecycle.failure_class = 'malformed_output'
            Set-LifecycleState 'failed' @{ error = 'worker output is not a successful JSON object with structured_output' }
            $terminalStateRecorded = $true
            $workerExitCode = 1
        } else {
            $script:Lifecycle.termination = 'natural'
            Set-LifecycleState 'completed'
            $terminalStateRecorded = $true
        }
        $script:Lifecycle.exit_code = $workerExitCode
        Save-Lifecycle
    } catch {
        if ($processStarted -and $null -ne $proc) {
            try {
                if (-not $proc.HasExited) {
                    $proc.Kill($true)
                    $proc.WaitForExit()
                }
            } catch { }
        }
        $script:Lifecycle.exit_code = if ($null -ne $proc -and $proc.HasExited) { $proc.ExitCode } else { $null }
        $script:Lifecycle.termination = 'launcher-error'
        $script:Lifecycle.failure_class = 'tool_error'
        if (-not $terminalStateRecorded) {
            Set-LifecycleState 'failed' @{ error = $_.Exception.Message }
            $terminalStateRecorded = $true
        }
        $workerExitCode = 1
    }
} finally {
    if ($null -ne $proc -and -not $terminalStateRecorded) {
        try {
            if (-not $proc.HasExited) {
                $proc.Kill($true)
                $proc.WaitForExit()
            }
        } catch [System.InvalidOperationException] {
            # Process already exited
        } catch {
            # Best effort kill
        }
        $script:Lifecycle.termination = 'launcher-error'
        $script:Lifecycle.failure_class = 'tool_error'
        try { Set-LifecycleState 'failed' } catch { }
    }
    if ($ledgerRegistered) {
        $ledgerState = 'failed'
        if ($script:Lifecycle.termination -eq 'timeout') {
            $ledgerState = 'timed_out'
        } elseif ($script:Lifecycle.termination -eq 'canceled') {
            $ledgerState = 'cancelled'
        } elseif ($script:Lifecycle.termination -eq 'quota-handoff') {
            $ledgerState = 'quota_handoff'
        } elseif ($script:Lifecycle.state -eq 'completed' -and $workerExitCode -eq 0) {
            $ledgerState = 'completed'
        }
        try {
            $updateArgs = @('update', '--ledger', $ledgerPath, '--resource-id', $resourceId, '--state', $ledgerState)
            if ($ledgerState -eq 'failed') { $updateArgs += @('--error', 'worker or launcher failed') }
            & pwsh -NoProfile -NonInteractive -File $ledgerScript @updateArgs | Out-Null
        } catch {
            # The worker result remains authoritative; reconciliation can repair a failed ledger update.
        }
    }
    if ($null -ne $outFs) {
        try { $outFs.Dispose() } catch { }
    }
    if ($null -ne $errFs) {
        try { $errFs.Dispose() } catch { }
    }
    if ($null -ne $proc) {
        try { $proc.Dispose() } catch { }
    }
    try {
        if ($script:Lifecycle.state -in @('completed', 'failed', 'canceled', 'quota-handoff')) {
            Set-LifecycleState 'retained'
            Set-LifecycleState 'cleaned'
        }
    } catch { }
}

exit $workerExitCode
