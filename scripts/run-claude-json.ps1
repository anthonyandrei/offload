#!/usr/bin/env pwsh
# Launch one bounded Claude Code assignment and return an orchestrator-verifiable result.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$script:FailureOutputPath = ''

function Full([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path)
}

function Same([string]$A, [string]$B) {
    $left = (Full $A).TrimEnd('\', '/')
    $right = (Full $B).TrimEnd('\', '/')
    return [string]::Equals($left, $right, [System.StringComparison]::OrdinalIgnoreCase)
}

function Within([string]$Child, [string]$Parent) {
    $childPath = (Full $Child).TrimEnd('\', '/')
    $parentPath = (Full $Parent).TrimEnd('\', '/')
    return (Same $childPath $parentPath) -or
        $childPath.StartsWith("$parentPath\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $childPath.StartsWith("$parentPath/", [System.StringComparison]::OrdinalIgnoreCase)
}

function Iso {
    return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Write-Json([string]$Path, $Value) {
    $fullPath = Full $Path
    $directory = Split-Path -Parent $fullPath
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $temporaryPath = "$fullPath.tmp.$([Guid]::NewGuid().ToString('N'))"
    try {
        $json = ($Value | ConvertTo-Json -Depth 30) + "`n"
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $fullPath -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Fail([string]$Message, [int]$Code = 2) {
    [Console]::Error.WriteLine("ERROR: $Message")
    if ($script:FailureOutputPath) {
        try {
            Write-Json $script:FailureOutputPath ([ordered]@{
                schema_version = 1
                adapter = 'claude'
                status = 'failed'
                lifecycle = 'failed'
                error = $Message
            })
        } catch {
            # Preserve the original diagnostic if the result path is unusable.
        }
    }
    exit $Code
}

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "JSON file does not exist: $Path"
    }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 30 -ErrorAction Stop
    } catch {
        Fail "invalid JSON in $Path"
    }
}

function Has-Property($Object, [string]$Name) {
    return $null -ne $Object -and ($Object.PSObject.Properties.Name -contains $Name)
}

function Optional-String($Object, [string]$Name, [string]$Default = '') {
    if ($null -ne $Object -and (Has-Property $Object $Name) -and $null -ne $Object.$Name) {
        return [string]$Object.$Name
    }
    return $Default
}

function Optional-Array($Object, [string]$Name) {
    if ($null -ne $Object -and (Has-Property $Object $Name) -and $null -ne $Object.$Name) {
        return @($Object.$Name | ForEach-Object { [string]$_ })
    }
    return @()
}

function Resolve-Claude {
    $requested = if ($env:CLAUDE_BIN) { [string]$env:CLAUDE_BIN } else { '' }
    if ($requested) {
        $command = Get-Command $requested -ErrorAction SilentlyContinue
        if ($command) {
            return $(if ($command.Source) { $command.Source } else { $command.Name })
        }
        if (Test-Path -LiteralPath $requested -PathType Leaf) {
            return (Resolve-Path -LiteralPath $requested).Path
        }
        Fail "CLAUDE_BIN does not resolve to an executable: $requested" 1
    }

    $command = Get-Command claude -ErrorAction SilentlyContinue
    if ($command) {
        return $(if ($command.Source) { $command.Source } else { $command.Name })
    }
    Fail 'claude was not found; set CLAUDE_BIN or add claude to PATH' 1
}

function New-ProcessInfo([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory = '') {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $isPowerShellScript = $Executable.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)
    if ($isPowerShellScript) {
        $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $pwsh) { $pwsh = (Get-Process -Id $PID).Path }
        $psi.FileName = $pwsh
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-NonInteractive')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add($Executable)
    } else {
        $psi.FileName = $Executable
    }
    foreach ($argument in $Arguments) { $psi.ArgumentList.Add($argument) }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    return $psi
}

function Invoke-Probe([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory = '') {
    try {
        $process = [Diagnostics.Process]::Start((New-ProcessInfo $Executable $Arguments $WorkingDirectory))
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{ exit_code = $process.ExitCode; stdout = $stdout; stderr = $stderr }
    } catch {
        return [pscustomobject]@{ exit_code = 127; stdout = ''; stderr = $_.Exception.Message }
    }
}

function Discover([string]$Executable, $Assignment) {
    $version = Invoke-Probe $Executable @('--version')
    $help = Invoke-Probe $Executable @('--help')
    $helpText = "$($help.stdout)`n$($help.stderr)"
    $knownFlags = @('print', 'output-format', 'input-format', 'model', 'permission-mode', 'allowedTools', 'disallowedTools', 'resume', 'max-turns', 'add-dir', 'effort')
    $flags = @($knownFlags | Where-Object { $helpText -match "--$([regex]::Escape($_))(\s|=|$)" })

    $catalog = [System.Collections.Generic.List[string]]::new()
    $catalogSource = 'unavailable'
    $catalogStatus = 'unknown'
    $catalogFallback = if ($env:CLAUDE_MODEL_CATALOG) { [string]$env:CLAUDE_MODEL_CATALOG } else { '' }
    $catalogPath = Optional-String $Assignment 'model_catalog_path' $catalogFallback
    if ($catalogPath) {
        $catalogDocument = Read-Json $catalogPath
        if (-not (Has-Property $catalogDocument 'models')) {
            Fail "model catalog has no models array: $catalogPath"
        }
        foreach ($model in @($catalogDocument.models)) { [void]$catalog.Add([string]$model) }
        $catalogSource = Full $catalogPath
        $catalogStatus = 'available'
    }

    $assignmentAllowed = [System.Collections.Generic.List[string]]::new()
    foreach ($tool in @(Optional-Array $Assignment 'allowed_tools')) { [void]$assignmentAllowed.Add($tool) }
    $assignmentDenied = [System.Collections.Generic.List[string]]::new()
    foreach ($tool in @(Optional-Array $Assignment 'disallowed_tools')) { [void]$assignmentDenied.Add($tool) }
    [void]$assignmentDenied.Add('Task')
    [void]$assignmentDenied.Add('Agent')
    $effortLevels = [System.Collections.Generic.List[string]]::new()
    if ($flags -contains 'effort') {
        [void]$effortLevels.Add('low')
        [void]$effortLevels.Add('balanced')
        [void]$effortLevels.Add('deep')
    }

    return [ordered]@{
        version = $version.stdout.Trim()
        version_exit_code = $version.exit_code
        cli_exit_code = $help.exit_code
        supported_flags = $flags
        tools = [ordered]@{
            discovered = @('Read', 'Write', 'Edit', 'Bash', 'Glob', 'Grep', 'Task')
            assignment_allowed = $assignmentAllowed
            assignment_denied = $assignmentDenied
        }
        structured_output = [ordered]@{
            supported = ($flags -contains 'output-format')
            formats = if ($flags -contains 'output-format') { @('json', 'stream-json', 'text') } else { [System.Collections.Generic.List[string]]::new() }
        }
        model_catalog = [ordered]@{ source = $catalogSource; status = $catalogStatus; models = $catalog }
        effort_levels = $effortLevels
    }
}

function Add-Record($Ledger, [string]$Id, [string]$Type, [string]$Identity, [string]$State) {
    $record = [pscustomobject]@{
        resource_id = $Id
        assignment_id = [string]$Ledger.assignment_id
        parent_id = [string]$Ledger.assignment_id
        resource_type = $Type
        identity = $Identity
        owner_marker = 'offload-claude-adapter-v1'
        state = $State
        created_at = Iso
        updated_at = Iso
    }
    $Ledger.records = @($Ledger.records) + $record
}

function Update-Records($Ledger, [string]$Id, [string]$State, [hashtable]$Extra = @{}) {
    foreach ($record in @($Ledger.records)) {
        if ($record.resource_id -eq $Id) {
            $record.state = $State
            $record.updated_at = Iso
            foreach ($key in $Extra.Keys) {
                if ($record.PSObject.Properties.Name -contains $key) {
                    $record.$key = $Extra[$key]
                } else {
                    $record | Add-Member -NotePropertyName $key -NotePropertyValue $Extra[$key]
                }
            }
        }
    }
}

function Run-Verification($Assignment, [string]$Workdir) {
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
    if (-not $pwsh) { $pwsh = (Get-Process -Id $PID).Path }

    $scopeScript = Join-Path $PSScriptRoot 'check-execution-scope.ps1'
    $scopeArguments = @('-NoProfile', '-NonInteractive', '-File', $scopeScript, '--baseline', [string]$Assignment.baseline)
    foreach ($path in (Optional-Array $Assignment 'owned_paths')) { $scopeArguments += @('--owned', $path) }
    foreach ($path in (Optional-Array $Assignment 'frozen_paths')) { $scopeArguments += @('--frozen', $path) }
    $scope = Invoke-Probe $pwsh $scopeArguments $Workdir
    if ($scope.exit_code -ne 0) {
        return [ordered]@{ scope = 'failed'; gate = 'not-run'; reason = 'execution scope check failed'; detail = "$($scope.stdout)`n$($scope.stderr)" }
    }

    $gateScript = Join-Path $PSScriptRoot 'execute-gate.ps1'
    $gate = Invoke-Probe $pwsh @('-NoProfile', '-NonInteractive', '-File', $gateScript, '--command', [string]$Assignment.gate_command, '--workspace', $Workdir) $Workdir
    if ($gate.exit_code -ne 0) {
        return [ordered]@{ scope = 'passed'; gate = 'failed'; reason = 'final gate failed'; detail = "$($gate.stdout)`n$($gate.stderr)" }
    }
    try {
        $gateReport = $gate.stdout | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        if ($gateReport.verification_status -ne 'passed') {
            return [ordered]@{ scope = 'passed'; gate = 'failed'; reason = 'final gate did not pass'; detail = $gate.stdout }
        }
    } catch {
        return [ordered]@{ scope = 'passed'; gate = 'failed'; reason = 'final gate returned malformed report'; detail = $gate.stdout }
    }
    return [ordered]@{ scope = 'passed'; gate = 'passed'; reason = 'scope and final gate passed' }
}

$assignmentPath = ''
$outputPath = ''
$errorPath = ''
$capabilitiesOnly = $false
for ($i = 0; $i -lt $args.Count; $i++) {
    switch ([string]$args[$i]) {
        '--assignment' { $i++; if ($i -ge $args.Count) { Fail '--assignment requires a path' }; $assignmentPath = [string]$args[$i] }
        '--output' { $i++; if ($i -ge $args.Count) { Fail '--output requires a path' }; $outputPath = [string]$args[$i]; $script:FailureOutputPath = $outputPath }
        '--error' { $i++; if ($i -ge $args.Count) { Fail '--error requires a path' }; $errorPath = [string]$args[$i] }
        '--capabilities' { $capabilitiesOnly = $true }
        '-h' { Write-Output 'Usage: run-claude-json.ps1 --assignment FILE --output FILE --error FILE'; exit 0 }
        '--help' { Write-Output 'Usage: run-claude-json.ps1 --assignment FILE --output FILE --error FILE'; exit 0 }
        default { Fail "unknown option: $($args[$i])" }
    }
}
if (-not $assignmentPath) { Fail '--assignment is required' }
if (-not $outputPath) { Fail '--output is required' }
if (-not $errorPath) { Fail '--error is required' }

$assignment = Read-Json $assignmentPath
if ($assignment.schema_version -ne 1) { Fail 'assignment schema_version must be 1' }
foreach ($name in @('assignment_id', 'prompt', 'working_directory', 'baseline', 'gate_command', 'preference')) {
    if (-not (Has-Property $assignment $name) -or [string]::IsNullOrWhiteSpace([string]$assignment.$name)) {
        Fail "assignment field is required: $name"
    }
}
foreach ($name in @('owned_paths', 'frozen_paths')) {
    if (-not (Has-Property $assignment $name) -or $null -eq $assignment.$name) {
        Fail "assignment field is required: $name"
    }
}
if ([string]$assignment.preference -notin @('fast', 'balanced', 'deep')) { Fail 'preference must be fast, balanced, or deep' }

$workdir = Full ([string]$assignment.working_directory)
if (-not (Test-Path -LiteralPath $workdir -PathType Container)) { Fail "working directory does not exist: $workdir" }
$markerPath = Join-Path $workdir '.offload-execution-workspace'
$markerValue = 'offload-execution-workspace-v1'
if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    $markerPath = Join-Path $workdir '.offload-research-workspace'
    $markerValue = 'offload-research-workspace-v1'
}
if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { Fail 'unsupported or unmarked sandbox; use an isolated offload workspace' }
try {
    if (([IO.File]::ReadAllText($markerPath)).Trim() -ne $markerValue) { Fail 'invalid isolated workspace marker' }
} catch {
    Fail 'could not read isolated workspace marker'
}
if (Same $workdir (Get-Location).Path) { Fail 'working directory cannot be the caller current directory' }

foreach ($path in (Optional-Array $assignment 'owned_paths') + (Optional-Array $assignment 'frozen_paths')) {
    $normalized = $path.Replace('\', '/')
    if ([IO.Path]::IsPathRooted($path) -or $normalized.Split('/') -contains '..') {
        Fail "assignment path escapes repository: $path"
    }
}
$permissionMode = Optional-String $assignment 'permission_mode' 'acceptEdits'
if ($permissionMode -eq 'bypassPermissions') { Fail 'bypassPermissions is not allowed' }
$requestedTools = @(Optional-Array $assignment 'allowed_tools')
if ($requestedTools -contains 'Task' -or $requestedTools -contains 'Agent') {
    Fail 'child assignment tools cannot be allowed'
}

$out = Full $outputPath
$err = Full $errorPath
if (Within $out $workdir -or Within $err $workdir) { Fail 'result and error artifacts must be outside the worker directory' }

$executable = Resolve-Claude
$capabilities = Discover $executable $assignment
if ($capabilitiesOnly) {
    Write-Json $out ([ordered]@{ schema_version = 1; adapter = 'claude'; status = 'capabilities'; capabilities = $capabilities })
    exit 0
}
if (-not $capabilities.structured_output.supported) { Fail 'Claude CLI does not advertise structured JSON output' }

$models = @($capabilities.model_catalog.models)
$pinnedModel = Optional-String $assignment 'model'
if ($pinnedModel -and ($capabilities.model_catalog.status -ne 'available' -or $models -notcontains $pinnedModel)) {
    Fail 'pinned model is unavailable or model availability is unknown'
}
$requestedEffort = Optional-String $assignment 'effort' 'default'
if ($requestedEffort -ne 'default' -and @($capabilities.effort_levels) -notcontains $requestedEffort) {
    Fail 'requested effort is not supported by Claude host'
}

$ledgerPath = Optional-String $assignment 'ledger_path'
if ($ledgerPath) { $ledgerPath = Full $ledgerPath } else { $ledgerPath = Join-Path (Split-Path -Parent $out) 'resource-ledger.json' }
if (Within $ledgerPath $workdir) { Fail 'resource ledger must be outside the worker directory' }
$ledger = if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
    Read-Json $ledgerPath
} else {
    [pscustomobject]@{ schema_version = 1; owner = 'orchestrator'; assignment_id = [string]$assignment.assignment_id; records = @() }
}
if ($ledger.schema_version -ne 1 -or $ledger.owner -ne 'orchestrator') { Fail 'invalid resource ledger' }
$ledger.assignment_id = [string]$assignment.assignment_id
if ($null -eq $ledger.records) { $ledger.records = @() }

$rawOut = "$out.raw.json"
$rawErr = "$err.raw.txt"
$timeoutText = Optional-String $assignment 'timeout_seconds' '1200'
$timeout = 0
if (-not [int]::TryParse($timeoutText, [ref]$timeout) -or $timeout -lt 1) { Fail 'timeout_seconds must be a positive integer' }
Add-Record $ledger 'worktree' 'worktree' $workdir 'created'
Add-Record $ledger 'process' 'process' 'pending' 'created'
Add-Record $ledger 'raw-output' 'artifact' $rawOut 'created'
Add-Record $ledger 'raw-error' 'artifact' $rawErr 'created'
Add-Record $ledger 'result' 'artifact' $out 'created'
Add-Record $ledger 'verification' 'verification' 'scope-and-gate' 'created'
Write-Json $ledgerPath $ledger

$modelForResult = if ($pinnedModel) { $pinnedModel } else { $null }
$result = [ordered]@{
    schema_version = 1
    assignment_id = [string]$assignment.assignment_id
    adapter = 'claude'
    status = 'failed'
    lifecycle = 'created'
    exit_code = $null
    response = $null
    structured_output = $null
    session_id = $null
    capabilities = $capabilities
    model_selection = [ordered]@{
        preference = [string]$assignment.preference
        model = $modelForResult
        effort = $requestedEffort
        reason = 'selection is owned by the orchestrator; the adapter does not map preferences'
    }
    resources = [ordered]@{ ledger = $ledgerPath; worktree = $workdir; process = $null }
    artifacts = [ordered]@{ raw_output = $rawOut; raw_error = $rawErr; result = $out }
    verification = $null
    error = $null
}

$runArguments = @('-p', [string]$assignment.prompt, '--output-format', 'json', '--permission-mode', $permissionMode, '--disallowedTools', 'Task', '--disallowedTools', 'Agent')
foreach ($tool in (Optional-Array $assignment 'allowed_tools')) { $runArguments += @('--allowedTools', $tool) }
foreach ($tool in (Optional-Array $assignment 'disallowed_tools')) { $runArguments += @('--disallowedTools', $tool) }
if ($pinnedModel) { $runArguments += @('--model', $pinnedModel) }
$resumeSession = Optional-String $assignment 'resume_session_id'
if ($resumeSession) { $runArguments += @('--resume', $resumeSession) }

$process = $null
$timedOut = $false
$canceled = $false
try {
    $process = [Diagnostics.Process]::Start((New-ProcessInfo $executable $runArguments $workdir))
    Update-Records $ledger 'process' 'started' @{ identity = "pid:$($process.Id)" }
    $result.resources.process = "pid:$($process.Id)"
    Update-Records $ledger 'worktree' 'running'
    Update-Records $ledger 'raw-output' 'running'
    Update-Records $ledger 'raw-error' 'running'
    Write-Json $ledgerPath $ledger

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $process.HasExited) {
        $cancelFile = Optional-String $assignment 'cancel_file'
        if ($cancelFile -and (Test-Path -LiteralPath $cancelFile)) {
            $canceled = $true
            $process.Kill($true)
            break
        }
        if ($stopwatch.Elapsed.TotalSeconds -ge $timeout) {
            $timedOut = $true
            $process.Kill($true)
            break
        }
        Start-Sleep -Milliseconds 50
    }
    $process.WaitForExit()
    $rawStdout = $stdoutTask.GetAwaiter().GetResult()
    $rawStderr = $stderrTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText($rawOut, $rawStdout, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($rawErr, $rawStderr, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($err, $rawStderr, [Text.UTF8Encoding]::new($false))

    $result.exit_code = $process.ExitCode
    if ($canceled) {
        $result.lifecycle = 'canceled'
        $result.error = 'canceled'
    } elseif ($timedOut) {
        $result.lifecycle = 'failed'
        $result.error = 'timeout'
    } elseif ("$rawStdout`n$rawStderr" -match '(?i)quota|rate limit|too many requests|429') {
        $result.lifecycle = 'quota-handoff'
        $result.error = 'quota exhausted'
    } elseif ($process.ExitCode -eq 0) {
        try {
            $document = $rawStdout | ConvertFrom-Json -Depth 30 -ErrorAction Stop
            if ($document.subtype -eq 'success' -or $document.status -eq 'success') {
                $result.response = if ($document.result) { [string]$document.result } elseif ($document.response) { [string]$document.response } else { $null }
                $result.structured_output = $document
                $result.session_id = if ($document.session_id) { [string]$document.session_id } else { $null }
                $result.lifecycle = 'running'
            } else {
                $result.lifecycle = 'failed'
                $result.error = 'Claude returned a non-success result'
            }
        } catch {
            $result.lifecycle = 'failed'
            $result.error = 'malformed Claude JSON output'
        }
    } else {
        $result.lifecycle = 'failed'
        $result.error = "Claude exited with code $($process.ExitCode)"
    }

    if ($result.lifecycle -eq 'running') {
        Update-Records $ledger 'verification' 'running'
        $result.verification = Run-Verification $assignment $workdir
        if ($result.verification.scope -eq 'passed' -and $result.verification.gate -eq 'passed') {
            $result.status = 'completed'
            $result.lifecycle = 'completed'
            Update-Records $ledger 'verification' 'completed'
        } else {
            $result.error = $result.verification.reason
            Update-Records $ledger 'verification' 'failed'
        }
    }
} catch {
    $result.error = $_.Exception.Message
    $result.lifecycle = 'failed'
} finally {
    if ($null -ne $process -and -not $process.HasExited) {
        try { $process.Kill($true); $process.WaitForExit() } catch { }
    }
    Write-Json $out $result
    Update-Records $ledger 'process' $result.lifecycle
    Update-Records $ledger 'worktree' $(if ($result.status -eq 'completed') { 'completed' } else { 'retained' })
    Update-Records $ledger 'raw-output' 'retained'
    Update-Records $ledger 'raw-error' 'retained'
    Update-Records $ledger 'result' 'completed'
    if ($null -eq $result.verification) { Update-Records $ledger 'verification' 'not-run' }
    Write-Json $ledgerPath $ledger
    if ($null -ne $process) { $process.Dispose() }
}

if ($result.status -eq 'completed') { exit 0 }
if ($result.lifecycle -eq 'quota-handoff') { exit 75 }
if ($result.lifecycle -eq 'canceled') { exit 130 }
exit 1
