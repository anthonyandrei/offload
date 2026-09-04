#!/usr/bin/env pwsh
# Vendor-neutral worker launcher. Model syntax belongs to the selected adapter.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Show-Usage {
    [Console]::Error.WriteLine("Usage: run-agy-json.ps1 --role ROLE [--route default|quality-retry] [--adapter FILE] [--selection-output FILE] [--pin FILE] --output FILE --error FILE '--' worker-arguments...")
    [Console]::Error.WriteLine("The role selects an internal preference and effort from model-policy.json. Exact models are selected by the adapter catalog and may be pinned for retries.")
}

function Fail([string]$message, [int]$exitCode = 2) {
    [Console]::Error.WriteLine("ERROR: $message")
    exit $exitCode
}

function Property($object, [string]$name) {
    if ($null -eq $object) { return $null }
    $property = $object.PSObject.Properties[$name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Read-JsonFile([string]$path, [string]$label) {
    try { return ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path)) -Depth 30 -ErrorAction Stop }
    catch { Fail "$label is not valid JSON: $($_.Exception.Message)" }
}

function Resolve-Program([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { Fail 'adapter path is empty' }
    $candidate = $path
    if (-not [System.IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path (Get-Location).ProviderPath $candidate }
    if ($candidate.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { Fail "adapter script not found: $candidate" 127 }
        return @{ File = (Get-Command pwsh -ErrorAction Stop).Source; Prefix = @('-NoProfile', '-NonInteractive', '-File', ([System.IO.Path]::GetFullPath($candidate))) }
    }
    return @{ File = $candidate; Prefix = @() }
}

function Invoke-Adapter([hashtable]$program, [string[]]$arguments, [string]$stdoutPath, [string]$stderrPath, [string]$workingDirectory) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $program.File
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if (-not [string]::IsNullOrWhiteSpace($workingDirectory)) { $psi.WorkingDirectory = $workingDirectory }
    foreach ($argument in ($program.Prefix + $arguments)) { [void]$psi.ArgumentList.Add([string]$argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { Fail "failed to start adapter: $($program.File)" 127 }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [System.IO.File]::WriteAllText($stdoutPath, $stdoutTask.Result, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($stderrPath, $stderrTask.Result, [System.Text.Encoding]::UTF8)
        return $process.ExitCode
    } catch {
        Fail "adapter invocation failed: $($_.Exception.Message)" 127
    } finally {
        $process.Dispose()
    }
}

function Ensure-OutputPath([string]$path, [string]$label, [string]$callerDirectory) {
    if ([string]::IsNullOrWhiteSpace($path)) { Fail "$label is required" }
    $fullPath = $path
    if (-not [System.IO.Path]::IsPathRooted($fullPath)) { $fullPath = Join-Path $callerDirectory $fullPath }
    try { $fullPath = [System.IO.Path]::GetFullPath($fullPath) } catch { Fail "$label is not a valid path: $path" }
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($parent)) { Fail "$label has no parent directory: $fullPath" }
    if (-not [System.IO.Directory]::Exists($parent)) {
        try { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
        catch { Fail "could not create $label parent directory '$parent': $($_.Exception.Message)" }
    }
    return $fullPath
}

$outputPath = ''
$errorPath = ''
$selectionOutputPath = ''
$pinPath = ''
$adapterPath = ''
$role = ''
$route = 'default'
$seen = @{}
$seenDelimiter = $false
$forwardedArgs = [System.Collections.Generic.List[string]]::new()
$requiredCapabilities = [System.Collections.Generic.List[string]]::new()

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    if ($arg -eq '--') {
        $seenDelimiter = $true
        $i++
        while ($i -lt $args.Count) { $forwardedArgs.Add([string]$args[$i]); $i++ }
        break
    }
    $option = $null
    $value = $null
    if ($arg -match '^(--(?:output|error|selection-output|pin|adapter|role|route|require-capability))=(.*)$') {
        $option = $Matches[1]
        $value = $Matches[2]
    } elseif ($arg -in @('--output', '--error', '--selection-output', '--pin', '--adapter', '--role', '--route', '--require-capability')) {
        $option = $arg
        $i++
        if ($i -ge $args.Count) { Show-Usage; Fail "$option requires a value" }
        $value = [string]$args[$i]
    } else {
        Show-Usage
        Fail "unknown launcher option: $arg"
    }
    if ($option -eq '--require-capability') {
        if ([string]::IsNullOrWhiteSpace($value)) { Fail '--require-capability requires a non-empty value' }
        $requiredCapabilities.Add($value)
    } else {
        if ($seen.ContainsKey($option)) { Fail "duplicate $option option" }
        $seen[$option] = $true
        switch ($option) {
            '--output' { $outputPath = $value }
            '--error' { $errorPath = $value }
            '--selection-output' { $selectionOutputPath = $value }
            '--pin' { $pinPath = $value }
            '--adapter' { $adapterPath = $value }
            '--role' { $role = $value }
            '--route' { $route = $value }
        }
    }
    $i++
}

if (-not $seenDelimiter) { Show-Usage; Fail '-- delimiter is required' }
if (-not $seen.ContainsKey('--output')) { Show-Usage; Fail '--output is required' }
if (-not $seen.ContainsKey('--error')) { Show-Usage; Fail '--error is required' }
if (-not $seen.ContainsKey('--role') -or [string]::IsNullOrWhiteSpace($role)) { Show-Usage; Fail '--role is required' }
if ($route -ne 'default' -and $route -ne 'quality-retry') { Fail "unknown route: '$route'; must be default or quality-retry" }
if ($forwardedArgs.Count -eq 0) { Show-Usage; Fail 'worker arguments are required after --' }

$knownRoles = @('scout', 'gate-author', 'implementer', 'reviewer', 'researcher', 'synthesizer', 'auditor')
if ($knownRoles -notcontains $role) { Fail "unknown role: '$role'; must be one of $($knownRoles -join ', ')" }

$callerLocation = Get-Location
if ($null -eq $callerLocation.Provider -or $callerLocation.Provider.Name -ne 'FileSystem') { Fail "current location must use the FileSystem provider (got '$($callerLocation.Provider.Name)')" }
$callerDirectory = $callerLocation.ProviderPath
if ([string]::IsNullOrWhiteSpace($callerDirectory) -or -not [System.IO.Directory]::Exists($callerDirectory)) { Fail 'current location must be an existing filesystem directory' }
$callerDirectory = [System.IO.Path]::GetFullPath($callerDirectory)
$outputPath = Ensure-OutputPath $outputPath 'output path' $callerDirectory
$errorPath = Ensure-OutputPath $errorPath 'error path' $callerDirectory
if ($outputPath -eq $errorPath) { Fail 'output and error paths must be different' }
if ($selectionOutputPath) { $selectionOutputPath = Ensure-OutputPath $selectionOutputPath 'selection output path' $callerDirectory }

$knownValueTakingOptions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
@('-p', '--prompt', '--print', '--prompt-interactive', '-i', '--path', '--output-format', '--mode', '--json-schema', '--add-dir', '--agent', '--conversation', '--log-file', '--print-timeout', '--project', '--input-format') | ForEach-Object { [void]$knownValueTakingOptions.Add($_) }
$idx = 0
while ($idx -lt $forwardedArgs.Count) {
    $workerArg = $forwardedArgs[$idx]
    if ($workerArg -eq '--output' -or $workerArg.StartsWith('--output=')) { Fail 'do not pass --output to the worker; use the launcher --output path instead' }
    if ($workerArg -eq '--model' -or $workerArg.StartsWith('--model=')) { Fail 'caller cannot specify a model; model routing is controlled by --role and the adapter catalog' }
    if ($workerArg -eq '--effort' -or $workerArg.StartsWith('--effort=')) { Fail 'caller cannot specify effort; reasoning effort is controlled by policy' }
    if ($knownValueTakingOptions.Contains($workerArg) -and $idx + 1 -lt $forwardedArgs.Count) { $idx++ }
    $idx++
}

$scriptDir = [System.IO.Path]::GetFullPath($PSScriptRoot)
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
$policyFile = Join-Path $repoRoot 'model-policy.json'
if (-not (Test-Path -LiteralPath $policyFile -PathType Leaf)) { Fail "model policy file not found at: $policyFile" }
$policy = Read-JsonFile $policyFile 'model policy file'
if ($null -eq $policy -or $policy -isnot [System.Management.Automation.PSCustomObject]) { Fail 'model policy must be a JSON object' }
if ((Property $policy 'schema_version') -ne 2) { Fail 'unsupported schema_version in model policy: must be integer 2' }
if ([string]::IsNullOrWhiteSpace([string](Property $policy 'policy_revision'))) { Fail 'policy_revision must be a non-empty string' }
if ((Property $policy 'max_effort') -ne 'high') { Fail "invalid max_effort: must be 'high'" }
if ((Property $policy 'max_retries_per_worker') -ne 1) { Fail 'max_retries_per_worker must be integer 1' }
if ((Property $policy 'quota_action') -ne 'handoff') { Fail "invalid quota_action: must be 'handoff'" }
$roles = Property $policy 'roles'
if ($null -eq $roles) { Fail 'roles must be an object' }
$policyRoleNames = @($roles.PSObject.Properties.Name)
if ($policyRoleNames.Count -ne $knownRoles.Count -or @($policyRoleNames | Where-Object { $knownRoles -notcontains $_ }).Count -gt 0) {
    Fail "roles must contain exactly: $($knownRoles -join ', ')"
}
foreach ($knownRole in $knownRoles) {
    $rolePolicy = Property $roles $knownRole
    if ($null -eq $rolePolicy) { Fail "role missing from policy: $knownRole" }
    if ((Property $rolePolicy 'preference') -notin @('fast', 'balanced', 'deep')) { Fail "role $knownRole has invalid preference" }
    if ((Property $rolePolicy 'effort') -notin @('low', 'medium', 'high')) { Fail "role $knownRole has invalid effort" }
    if ($null -eq $rolePolicy.PSObject.Properties['required_capabilities']) { Fail "role $knownRole is missing required_capabilities" }
}
$rolePolicy = Property $roles $role
$preference = [string](Property $rolePolicy 'preference')
$effort = [string](Property $rolePolicy 'effort')
$policyCapabilities = @((Property $rolePolicy 'required_capabilities')) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
$allCapabilities = @($policyCapabilities + $requiredCapabilities.ToArray()) | Sort-Object -Unique

if ($route -eq 'quality-retry' -and [string]::IsNullOrWhiteSpace($pinPath)) {
    Fail 'quality-retry requires --pin with the prior selection; use an explicit fallback or handoff when it is unavailable' 3
}
$adapterDefault = Join-Path $scriptDir 'agy-adapter.ps1'
if ([string]::IsNullOrWhiteSpace($adapterPath)) { $adapterPath = [Environment]::GetEnvironmentVariable('OFFLOAD_ADAPTER_BIN') }
if ([string]::IsNullOrWhiteSpace($adapterPath)) { $adapterPath = $adapterDefault }
$adapter = Resolve-Program $adapterPath

$tempRequest = [System.IO.Path]::GetTempFileName()
$tempCatalog = [System.IO.Path]::GetTempFileName()
$tempAdapterError = [System.IO.Path]::GetTempFileName()
$tempLaunchSelection = [System.IO.Path]::GetTempFileName()
try {
    $request = [ordered]@{
        protocol_version = 1
        operation = 'catalog'
        role = $role
        preference = $preference
        effort = $effort
        required_capabilities = @($allCapabilities)
        policy_revision = [string](Property $policy 'policy_revision')
    }
    [System.IO.File]::WriteAllText($tempRequest, ($request | ConvertTo-Json -Depth 20), [System.Text.Encoding]::UTF8)
    $catalogCode = Invoke-Adapter $adapter @('--operation', 'catalog', '--request', $tempRequest) $tempCatalog $tempAdapterError $callerDirectory
    if ($catalogCode -ne 0) {
        $diagnostic = [System.IO.File]::ReadAllText($tempAdapterError).Trim()
        $suffix = if ($diagnostic) { ": $diagnostic" } else { '' }
        Fail "adapter catalog discovery failed with exit code $catalogCode$suffix" 127
    }
    $catalog = Read-JsonFile $tempCatalog 'adapter catalog'
    if ((Property $catalog 'protocol_version') -ne 1) { Fail 'adapter catalog has unsupported protocol_version' 127 }
    $catalogAdapter = [string](Property $catalog 'adapter')
    $catalogVendor = [string](Property $catalog 'vendor')
    $catalogRevision = [string](Property $catalog 'catalog_revision')
    $adapterRevision = [string](Property $catalog 'adapter_revision')
    if ([string]::IsNullOrWhiteSpace($catalogAdapter) -or [string]::IsNullOrWhiteSpace($catalogVendor) -or [string]::IsNullOrWhiteSpace($catalogRevision) -or [string]::IsNullOrWhiteSpace($adapterRevision)) { Fail 'adapter catalog is missing adapter, vendor, or revision metadata' 127 }
    $models = @((Property $catalog 'models'))
    if ($models.Count -eq 0) { Fail "adapter catalog has no models for role '$role'" 4 }

    $eligible = [System.Collections.Generic.List[object]]::new()
    foreach ($model in $models) {
        $modelId = [string](Property $model 'id')
        if ([string]::IsNullOrWhiteSpace($modelId) -or (Property $model 'available') -ne $true) { continue }
        $quotaAvailable = Property $model 'quota_available'
        if ($null -ne $quotaAvailable -and $quotaAvailable -ne $true) { continue }
        $supportedEfforts = @((Property $model 'supported_efforts')) | ForEach-Object { [string]$_ }
        if ($supportedEfforts -notcontains $effort) { continue }
        $modelCapabilities = @((Property $model 'capabilities')) | ForEach-Object { [string]$_ }
        $missingCapability = $false
        foreach ($capability in $allCapabilities) { if ($modelCapabilities -notcontains $capability) { $missingCapability = $true; break } }
        if ($missingCapability) { continue }
        $scores = Property $model 'scores'
        $scoreValue = Property $scores $preference
        if ($null -eq $scoreValue) { $scoreValue = 1000000 }
        try { $score = [double]$scoreValue } catch { continue }
        $modelVendor = [string](Property $model 'vendor')
        if ([string]::IsNullOrWhiteSpace($modelVendor)) { $modelVendor = $catalogVendor }
        $eligible.Add([pscustomobject]@{ Model = $model; Id = $modelId; Vendor = $modelVendor; Score = $score })
    }
    if ($eligible.Count -eq 0) { Fail "adapter catalog has no eligible model for role '$role', effort '$effort', and required capabilities" 4 }

    $selected = $null
    $selectionReason = "catalog selection preference=$preference effort=$effort; filtered unavailable, quota, effort, capability, and static-policy-incompatible candidates"
    if ($pinPath) {
        if (-not (Test-Path -LiteralPath $pinPath -PathType Leaf)) { Fail "pinned selection file not found: $pinPath" 3 }
        $pin = Read-JsonFile $pinPath 'pinned selection'
        $pinAdapter = [string](Property $pin 'adapter')
        $pinVendor = [string](Property $pin 'vendor')
        $pinId = [string](Property $pin 'model_id')
        if ([string]::IsNullOrWhiteSpace($pinId)) { $pinId = [string](Property $pin 'model') }
        $pinEffort = [string](Property $pin 'effort')
        if ($pinAdapter -ne $catalogAdapter -or $pinVendor -ne $catalogVendor -or $pinEffort -ne $effort -or [string]::IsNullOrWhiteSpace($pinId)) { Fail 'pinned selection does not match the current adapter, vendor, or policy effort; explicit fallback or handoff is required' 3 }
        $selected = $eligible | Where-Object { $_.Id -eq $pinId -and $_.Vendor -eq $pinVendor } | Select-Object -First 1
        if ($null -eq $selected) { Fail "pinned model '$pinId' is unavailable in catalog revision '$catalogRevision'; explicit fallback or handoff is required" 3 }
        $selectionReason = "pinned selection adapter=$catalogAdapter vendor=$catalogVendor model_id=$pinId; catalog_revision=$catalogRevision"
    } else {
        $selected = $eligible | Sort-Object Score, Vendor, Id | Select-Object -First 1
    }

    $model = $selected.Model
    $selection = [ordered]@{
        protocol_version = 1
        adapter = $catalogAdapter
        adapter_revision = $adapterRevision
        vendor = $selected.Vendor
        model_id = $selected.Id
        model = $selected.Id
        family_hint = [string](Property $model 'family_hint')
        preference = $preference
        effort = $effort
        catalog_revision = $catalogRevision
        policy_revision = [string](Property $policy 'policy_revision')
        required_capabilities = @($allCapabilities)
        selection_reason = $selectionReason
        route = $route
    }
    $selectionJson = $selection | ConvertTo-Json -Depth 20
    if ($selectionOutputPath) { [System.IO.File]::WriteAllText($selectionOutputPath, $selectionJson, [System.Text.Encoding]::UTF8) }
    [System.IO.File]::WriteAllText($tempLaunchSelection, $selectionJson, [System.Text.Encoding]::UTF8)

    $launchArguments = @('--operation', 'launch', '--request', $tempLaunchSelection, '--output', $outputPath, '--error', $errorPath, '--') + $forwardedArgs.ToArray()
    $launchCode = Invoke-Adapter $adapter $launchArguments $tempCatalog $tempAdapterError $callerDirectory
    if ($launchCode -ne 0) {
        $diagnostic = [System.IO.File]::ReadAllText($tempAdapterError).Trim()
        if ($diagnostic) { [Console]::Error.WriteLine("ERROR: adapter launch failed with exit code ${launchCode}: $diagnostic") }
    }
    exit $launchCode
} finally {
    Remove-Item -LiteralPath $tempRequest, $tempCatalog, $tempAdapterError, $tempLaunchSelection -Force -ErrorAction SilentlyContinue
}
