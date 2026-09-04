#!/usr/bin/env pwsh
# scripts/run-codex-json.ps1
# Secure Codex adapter. The orchestrator owns assignment limits and verification.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Fail([string]$Message, [int]$Code = 2) {
    [Console]::Error.WriteLine("ERROR: $Message")
    exit $Code
}

function Usage {
    [Console]::Error.WriteLine("Usage: run-codex-json.ps1 capabilities --output FILE [--error FILE] [--codex PATH]")
    [Console]::Error.WriteLine("       run-codex-json.ps1 run --assignment FILE --output FILE --error FILE [--codex PATH] [--cancel-file FILE]")
}

function FullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path)
}

function Ensure-Parent([string]$Path) {
    $parent = [System.IO.Path]::GetDirectoryName((FullPath $Path))
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not [System.IO.Directory]::Exists($parent)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
}

function Write-Json([string]$Path, $Value) {
    Ensure-Parent $Path
    $json = $Value | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText((FullPath $Path), "$json`n", [System.Text.UTF8Encoding]::new($false))
}

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "JSON file does not exist: $Path" }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 30 -ErrorAction Stop
}

function Resolve-Executable([string]$Requested) {
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $cmd = Get-Command $Requested -ErrorAction SilentlyContinue
        if ($cmd) {
            if ($cmd.Source) { return $cmd.Source }
            return $cmd.Name
        }
        if (Test-Path -LiteralPath $Requested -PathType Leaf) { return (Resolve-Path -LiteralPath $Requested).Path }
        throw "Codex executable does not exist: $Requested"
    }
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd) {
        if ($cmd.Source) { return $cmd.Source }
        return $cmd.Name
    }
    throw 'Codex executable was not found on PATH'
}

function Invoke-Process([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSeconds = 30, [string]$CancelFile = '') {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    if ($FilePath.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add($FilePath)
    } else {
        $psi.FileName = $FilePath
    }
    foreach ($arg in $Arguments) { $psi.ArgumentList.Add([string]$arg) }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $reason = 'completed'
    while (-not $proc.HasExited) {
        if (-not [string]::IsNullOrWhiteSpace($CancelFile) -and (Test-Path -LiteralPath $CancelFile -PathType Leaf)) {
            $reason = 'canceled'
            try { $proc.Kill($true) } catch { }
            break
        }
        if ($TimeoutSeconds -gt 0 -and $watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $reason = 'timeout'
            try { $proc.Kill($true) } catch { }
            break
        }
        Start-Sleep -Milliseconds 25
    }
    try { $proc.WaitForExit() } catch { }
    [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
    $result = [pscustomobject]@{
        pid = $proc.Id
        exit_code = $proc.ExitCode
        stdout = $stdoutTask.Result
        stderr = $stderrTask.Result
        reason = $reason
    }
    $proc.Dispose()
    return $result
}

function Get-Catalog {
    $source = $env:CODEX_MODEL_CATALOG
    if ([string]::IsNullOrWhiteSpace($source)) { return $null }
    try {
        if (Test-Path -LiteralPath $source -PathType Leaf) { return Read-Json $source }
        return $source | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    } catch {
        return $null
    }
}

function Get-Capabilities([string]$CodexPath, [string]$OutputPath, [string]$ErrorPath) {
    $probe = Invoke-Process $CodexPath @('--help') (Get-Location).Path 30
    Ensure-Parent $ErrorPath
    [System.IO.File]::WriteAllText((FullPath $ErrorPath), $probe.stderr, [System.Text.UTF8Encoding]::new($false))
    $catalog = Get-Catalog
    $models = @()
    if ($null -ne $catalog -and $null -ne $catalog.models) { $models = @($catalog.models) }
    $efforts = @($models | ForEach-Object { @($_.efforts) } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
    $help = [string]$probe.stdout
    $supported = @('exec')
    $structured = $help.Contains('--json') -and $help.Contains('--output-schema') -and $help.Contains('--output-last-message')
    if ($probe.exit_code -ne 0 -or -not $structured) {
        $reason = if ($probe.exit_code -ne 0) { 'Codex capability probe failed' } else { 'host lacks required structured-output flags' }
        $doc = [ordered]@{
            schema_version = 1; vendor = 'codex'; adapter = 'run-codex-json'; supported_tools = $supported
            structured_output = [ordered]@{ supported = $false; reason = $reason }
            model_availability = [ordered]@{ available = $false; reason = $reason; revision = $null; models = @() }
            effort_levels = @(); process_identity = $null; artifacts = @($ErrorPath)
        }
        Write-Json $OutputPath $doc
        return [pscustomobject]@{ document = $doc; exit_code = 1 }
    }
    $modelAvailable = $models.Count -gt 0
    $modelReason = if ($modelAvailable) { 'host-provided model catalog' } else { 'host does not expose a model catalog' }
    $catalogRevision = if ($catalog -and $catalog.PSObject.Properties.Name -contains 'revision') { [string]$catalog.revision } else { $null }
    $doc = [ordered]@{
        schema_version = 1; vendor = 'codex'; adapter = 'run-codex-json'; supported_tools = $supported
        structured_output = [ordered]@{ supported = $true; format = 'json'; schema = 'orchestrator-assignment-result' }
        model_availability = [ordered]@{ available = $modelAvailable; reason = $modelReason; revision = $catalogRevision; models = $models }
        effort_levels = $efforts; process_identity = $null; artifacts = @($ErrorPath)
    }
    Write-Json $OutputPath $doc
    return [pscustomobject]@{ document = $doc; exit_code = if ($modelAvailable) { 0 } else { 1 } }
}

function Select-Model($Catalog, $Assignment) {
    $models = @($Catalog.models)
    $preference = [string]$Assignment.preference
    if ($preference -notin @('fast', 'balanced', 'deep')) { throw "preference must be fast, balanced, or deep: $preference" }
    $requestedEffort = if ($Assignment.PSObject.Properties.Name -contains 'effort') { [string]$Assignment.effort } else { '' }
    $pinned = ''
    if ($Assignment.PSObject.Properties.Name -contains 'model_id') { $pinned = [string]$Assignment.model_id }
    if ([string]::IsNullOrWhiteSpace($pinned) -and ($Assignment.PSObject.Properties.Name -contains 'model_selection') -and $Assignment.model_selection) {
        if ($Assignment.model_selection.PSObject.Properties.Name -contains 'model_id') { $pinned = [string]$Assignment.model_selection.model_id }
    }
    $candidates = if ($pinned) { @($models | Where-Object { $_.id -eq $pinned }) } else { @($models | Where-Object { $_.preference -eq $preference }) }
    if ($requestedEffort) { $candidates = @($candidates | Where-Object { @($_.efforts) -contains $requestedEffort }) }
    if ($candidates.Count -eq 0) { throw "no available Codex model satisfies preference '$preference' and effort '$requestedEffort'" }
    $selected = @($candidates | Sort-Object id)[0]
    $familyHint = if ($selected.PSObject.Properties.Name -contains 'family_hint') { [string]$selected.family_hint } else { $null }
    $catalogRevision = if ($Catalog.PSObject.Properties.Name -contains 'revision') { [string]$Catalog.revision } else { $null }
    return [ordered]@{
        vendor = 'codex'; adapter = 'run-codex-json'; model_id = [string]$selected.id; family_hint = $familyHint
        preference = $preference; effort = if ($requestedEffort) { $requestedEffort } else { [string]$selected.efforts[0] }; catalog_revision = $catalogRevision
        reason = if ($pinned) { 'pinned assignment model' } else { "first deterministic catalog match for $preference" }
    }
}

function Invoke-CommandArray([object[]]$Command, [string]$WorkingDirectory) {
    if ($null -eq $Command -or $Command.Count -eq 0) { throw 'verification command is required' }
    $path = [string]$Command[0]
    $args = @($Command | Select-Object -Skip 1 | ForEach-Object { [string]$_ })
    $res = Invoke-Process (Resolve-Executable $path) $args $WorkingDirectory 0
    return $res
}

function Add-LedgerRecords([string]$Path, $Assignment, $Resources, [string]$State) {
    Ensure-Parent $Path
    $parent = if ($Assignment.PSObject.Properties.Name -contains 'parent_assignment_id') { $Assignment.parent_assignment_id } else { $null }
    $records = @($Resources | ForEach-Object {
        [ordered]@{ schema_version = 1; assignment_id = [string]$Assignment.assignment_id; parent_assignment_id = $parent; resource_type = $_.type; identity = $_.identity; owner_marker = $_.owner_marker; state = $State; timestamp = [DateTime]::UtcNow.ToString('o') }
    })
    foreach ($record in $records) {
        $line = $record | ConvertTo-Json -Compress -Depth 12
        Add-Content -LiteralPath (FullPath $Path) -Value $line -Encoding utf8
    }
}

function Run-Assignment([string]$AssignmentPath, [string]$OutputPath, [string]$ErrorPath, [string]$CodexPath, [string]$CancelFile) {
    $assignment = Read-Json $AssignmentPath
    $worktree = FullPath ([string]$assignment.worktree)
    if (-not (Test-Path -LiteralPath $worktree -PathType Container)) { throw "assignment worktree does not exist: $worktree" }
    if ([string]$assignment.schema_version -ne '1') { throw 'assignment schema_version must be 1' }
    if ([string]$assignment.assignment_id -notmatch '^[A-Za-z0-9._-]+$') { throw 'assignment_id is invalid' }
    $depth = if ($assignment.PSObject.Properties.Name -contains 'depth') { [int]$assignment.depth } else { 0 }
    if ($depth -lt 0) { throw 'assignment depth cannot be negative' }
    $attempt = if ($assignment.PSObject.Properties.Name -contains 'attempt') { [int]$assignment.attempt } else { 1 }
    if ($attempt -notin @(1, 2)) { throw 'adapter accepts at most attempt 1 or attempt 2' }
    Ensure-Parent $ErrorPath
    [System.IO.File]::WriteAllText((FullPath $ErrorPath), '', [System.Text.UTF8Encoding]::new($false))
    $catalog = Get-Catalog
    if ($null -eq $catalog -or @($catalog.models).Count -eq 0) {
        $doc = [ordered]@{ schema_version = 1; status = 'unsupported'; lifecycle = 'failed'; assignment_id = $assignment.assignment_id; vendor = 'codex'; adapter = 'run-codex-json'; failure = [ordered]@{ kind = 'unsupported-capability'; reason = 'host does not expose a model catalog' }; artifacts = @($ErrorPath); resources = [ordered]@{ process = $null; worktree = $worktree; artifacts = @($ErrorPath) } }
        Write-Json $OutputPath $doc
        return 1
    }
    $probe = Invoke-Process $CodexPath @('--help') $worktree 30
    $structured = [string]$probe.stdout
    if ($probe.exit_code -ne 0 -or -not ($structured.Contains('--json') -and $structured.Contains('--output-schema') -and $structured.Contains('--output-last-message'))) {
        $reason = if ($probe.exit_code -ne 0) { 'Codex capability probe failed' } else { 'host lacks required structured-output flags' }
        [System.IO.File]::WriteAllText((FullPath $ErrorPath), [string]$probe.stderr, [System.Text.UTF8Encoding]::new($false))
        $doc = [ordered]@{ schema_version = 1; status = 'unsupported'; lifecycle = 'failed'; assignment_id = $assignment.assignment_id; vendor = 'codex'; adapter = 'run-codex-json'; failure = [ordered]@{ kind = 'unsupported-capability'; reason = $reason }; artifacts = @($ErrorPath); resources = [ordered]@{ process = $null; worktree = $worktree; artifacts = @($ErrorPath) } }
        Write-Json $OutputPath $doc
        return 1
    }
    $selection = Select-Model $catalog $assignment
    $rawOutput = "$OutputPath.raw.jsonl"
    $lastMessage = "$OutputPath.last-message.json"
    $schemaFile = "$OutputPath.output-schema.json"
    $schema = [ordered]@{ type = 'object'; additionalProperties = $true }
    Write-Json $schemaFile $schema
    $resources = @(
        [ordered]@{ type = 'worktree'; identity = $worktree; owner_marker = "offload-assignment:$($assignment.assignment_id)" }
        [ordered]@{ type = 'artifact'; identity = (FullPath $rawOutput); owner_marker = "offload-assignment:$($assignment.assignment_id)" }
        [ordered]@{ type = 'artifact'; identity = (FullPath $ErrorPath); owner_marker = "offload-assignment:$($assignment.assignment_id)" }
        [ordered]@{ type = 'artifact'; identity = (FullPath $lastMessage); owner_marker = "offload-assignment:$($assignment.assignment_id)" }
        [ordered]@{ type = 'artifact'; identity = (FullPath $schemaFile); owner_marker = "offload-assignment:$($assignment.assignment_id)" }
    )
    Ensure-Parent $rawOutput
    $execArgs = @('exec', '--json', '--ephemeral', '--cd', $worktree, '--sandbox', 'workspace-write', '--ask-for-approval', 'never', '--output-schema', (FullPath $schemaFile), '--output-last-message', (FullPath $lastMessage), '--model', $selection.model_id, '--', [string]$assignment.prompt)
    $resume = if ($assignment.PSObject.Properties.Name -contains 'resume_session_id') { [string]$assignment.resume_session_id } else { '' }
    if ($resume) { $execArgs = @('-C', $worktree, '--sandbox', 'workspace-write', '--ask-for-approval', 'never', 'exec', 'resume', $resume, '--json', '--ephemeral', '--output-schema', (FullPath $schemaFile), '--output-last-message', (FullPath $lastMessage), '--model', $selection.model_id, '--', [string]$assignment.prompt) }
    $timeout = if ($assignment.PSObject.Properties.Name -contains 'timeout_seconds') { [int]$assignment.timeout_seconds } else { 30 }
    $process = Invoke-Process $CodexPath $execArgs $worktree $timeout $CancelFile
    [System.IO.File]::WriteAllText((FullPath $rawOutput), $process.stdout, [System.Text.UTF8Encoding]::new($false))
    Ensure-Parent $ErrorPath
    [System.IO.File]::WriteAllText((FullPath $ErrorPath), $process.stderr, [System.Text.UTF8Encoding]::new($false))
    $ledgerPath = if ($assignment.PSObject.Properties.Name -contains 'resource_ledger' -and $assignment.resource_ledger) { FullPath ([string]$assignment.resource_ledger) } else { "$OutputPath.resource-ledger.jsonl" }
    $resources += [ordered]@{ type = 'process'; identity = "pid:$($process.pid)"; owner_marker = "offload-assignment:$($assignment.assignment_id)" }
    Add-LedgerRecords $ledgerPath $assignment $resources 'running'
    $parent = if ($assignment.PSObject.Properties.Name -contains 'parent_assignment_id') { $assignment.parent_assignment_id } else { $null }
    $base = [ordered]@{ schema_version = 1; assignment_id = $assignment.assignment_id; parent_assignment_id = $parent; vendor = 'codex'; adapter = 'run-codex-json'; attempt = $attempt; lifecycle = 'running'; model_selection = $selection; process = [ordered]@{ pid = $process.pid; exit_code = $process.exit_code }; resources = [ordered]@{ process = "pid:$($process.pid)"; worktree = $worktree; artifacts = @($resources | Where-Object type -eq 'artifact' | ForEach-Object identity) }; artifacts = @($resources | Where-Object type -eq 'artifact' | ForEach-Object identity); verification = [ordered]@{ scope_check = 'not-run'; final_gate = 'not-run' } }
    if ($process.reason -eq 'canceled') { $base.status = 'canceled'; $base.lifecycle = 'canceled'; $base.failure = [ordered]@{ kind = 'canceled'; reason = 'cancel file requested termination' }; Write-Json $OutputPath $base; Add-LedgerRecords $ledgerPath $assignment $resources 'canceled'; return 1 }
    if ($process.reason -eq 'timeout') { $base.status = 'failed'; $base.lifecycle = 'failed'; $base.failure = [ordered]@{ kind = 'timeout'; reason = 'assignment timeout exceeded' }; Write-Json $OutputPath $base; Add-LedgerRecords $ledgerPath $assignment $resources 'failed'; return 1 }
    if ($process.stdout -match '(?i)quota|rate.?limit' -or $process.stderr -match '(?i)quota|rate.?limit') { $base.status = 'quota-handoff'; $base.lifecycle = 'quota-handoff'; $base.failure = [ordered]@{ kind = 'quota'; reason = 'Codex reported quota or rate limit exhaustion' }; Write-Json $OutputPath $base; Add-LedgerRecords $ledgerPath $assignment $resources 'quota-handoff'; return 1 }
    if (-not (Test-Path -LiteralPath $lastMessage -PathType Leaf)) { $base.status = 'failed'; $base.lifecycle = 'failed'; $base.failure = [ordered]@{ kind = 'malformed-output'; reason = 'Codex did not produce the required last-message artifact' }; Write-Json $OutputPath $base; Add-LedgerRecords $ledgerPath $assignment $resources 'failed'; return 1 }
    try { $worker = Read-Json $lastMessage } catch { $base.status = 'failed'; $base.lifecycle = 'failed'; $base.failure = [ordered]@{ kind = 'malformed-output'; reason = $_.Exception.Message }; Write-Json $OutputPath $base; Add-LedgerRecords $ledgerPath $assignment $resources 'failed'; return 1 }
    if ($null -eq $worker -or $worker -isnot [pscustomobject]) { $base.status = 'failed'; $base.lifecycle = 'failed'; $base.failure = [ordered]@{ kind = 'malformed-output'; reason = 'last-message artifact must contain a JSON object' }; Write-Json $OutputPath $base; Add-LedgerRecords $ledgerPath $assignment $resources 'failed'; return 1 }
    $workerStatus = if ($worker.PSObject.Properties.Name -contains 'status') { [string]$worker.status } else { '' }
    $workerError = if ($worker.PSObject.Properties.Name -contains 'error') { [string]$worker.error } else { '' }
    if ($workerStatus -match '(?i)quota|rate.?limit' -or $workerError -match '(?i)quota|rate.?limit') { $base.status = 'quota-handoff'; $base.lifecycle = 'quota-handoff'; $base.failure = [ordered]@{ kind = 'quota'; reason = 'Codex reported quota or rate limit exhaustion' }; Write-Json $OutputPath $base; Add-LedgerRecords $ledgerPath $assignment $resources 'quota-handoff'; return 1 }
    if ($worker.PSObject.Properties.Name -notcontains 'structured_output' -or $null -eq $worker.structured_output) { $base.status = 'failed'; $base.lifecycle = 'failed'; $base.failure = [ordered]@{ kind = 'malformed-output'; reason = 'last-message lacks structured_output' }; Write-Json $OutputPath $base; Add-LedgerRecords $ledgerPath $assignment $resources 'failed'; return 1 }
    $scope = Invoke-CommandArray @($assignment.scope_check) $worktree
    $base.verification.scope_check = if ($scope.exit_code -eq 0) { 'passed' } else { 'failed' }
    if ($scope.exit_code -ne 0) { $base.status = 'scope-failure'; $base.lifecycle = 'failed'; $base.failure = [ordered]@{ kind = 'execution-scope'; reason = 'execution scope check failed'; exit_code = $scope.exit_code }; Write-Json $OutputPath $base; Add-LedgerRecords $ledgerPath $assignment $resources 'failed'; return 1 }
    $gate = Invoke-CommandArray @($assignment.final_gate) $worktree
    $base.verification.final_gate = if ($gate.exit_code -eq 0) { 'passed' } else { 'failed' }
    if ($gate.exit_code -ne 0) { $base.status = 'failed'; $base.lifecycle = 'failed'; $base.failure = [ordered]@{ kind = 'final-gate'; reason = 'final gate failed'; exit_code = $gate.exit_code }; Write-Json $OutputPath $base; Add-LedgerRecords $ledgerPath $assignment $resources 'failed'; return 1 }
    $base.status = 'completed'; $base.lifecycle = 'completed'; $base.structured_output = $worker.structured_output
    if ($worker.structured_output.PSObject.Properties.Name -contains 'child_assignment_request') { $base.orchestrator_requests = @($worker.structured_output.child_assignment_request) }
    Write-Json $OutputPath $base
    Add-LedgerRecords $ledgerPath $assignment $resources 'completed'
    return 0
}

$mode = ''
$outputPath = ''
$errorPath = ''
$assignmentPath = ''
$codexPath = ''
$cancelFile = ''
$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    if ($arg -in @('capabilities', 'run')) { if ($mode) { Fail 'mode specified more than once' }; $mode = $arg }
    elseif ($arg -eq '--output') { $i++; if ($i -ge $args.Count) { Fail '--output requires a path' }; $outputPath = [string]$args[$i] }
    elseif ($arg -eq '--error') { $i++; if ($i -ge $args.Count) { Fail '--error requires a path' }; $errorPath = [string]$args[$i] }
    elseif ($arg -eq '--assignment') { $i++; if ($i -ge $args.Count) { Fail '--assignment requires a path' }; $assignmentPath = [string]$args[$i] }
    elseif ($arg -eq '--codex') { $i++; if ($i -ge $args.Count) { Fail '--codex requires a path' }; $codexPath = [string]$args[$i] }
    elseif ($arg -eq '--cancel-file') { $i++; if ($i -ge $args.Count) { Fail '--cancel-file requires a path' }; $cancelFile = [string]$args[$i] }
    elseif ($arg -in @('-h', '--help')) { Usage; exit 0 }
    else { Fail "unknown option: $arg" }
    $i++
}
if (-not $mode) { Usage; Fail 'mode is required' }
if (-not $outputPath) { Usage; Fail '--output is required' }
if (-not $errorPath) { $errorPath = "$outputPath.err" }
try {
    $resolvedCodex = Resolve-Executable $codexPath
    if ($mode -eq 'capabilities') {
        $cap = Get-Capabilities $resolvedCodex $outputPath $errorPath
        exit $cap.exit_code
    }
    if (-not $assignmentPath) { Fail '--assignment is required for run' }
    exit (Run-Assignment $assignmentPath $outputPath $errorPath $resolvedCodex $cancelFile)
} catch {
    if ($outputPath) {
        $doc = [ordered]@{ schema_version = 1; status = 'failed'; lifecycle = 'failed'; vendor = 'codex'; adapter = 'run-codex-json'; failure = [ordered]@{ kind = 'adapter-error'; reason = $_.Exception.Message }; artifacts = @($errorPath) }
        try { Write-Json $outputPath $doc } catch { }
    }
    Fail $_.Exception.Message 1
}
