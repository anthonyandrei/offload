#!/usr/bin/env pwsh
# Acceptance tests for the bounded Claude adapter.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:TotalTests = 0
$script:FailedTests = 0

function Pass([string]$Name) {
    $script:TotalTests++
    [Console]::Out.WriteLine("ok - $Name")
}

function Fail([string]$Name, [string]$Reason = '') {
    $script:TotalTests++
    $script:FailedTests++
    if ($Reason) { [Console]::Error.WriteLine("FAIL: $Name - $Reason") }
    else { [Console]::Error.WriteLine("FAIL: $Name") }
    throw "test failed: $Name"
}

function Assert-True([bool]$Condition, [string]$Name, [string]$Reason = '') {
    if ($Condition) { Pass $Name } else { Fail $Name (if ($Reason) { $Reason } else { 'condition was false' }) }
}

function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -eq $Expected) { Pass $Name }
    else { Fail $Name "expected '$Expected', got '$Actual'" }
}

function Assert-NotEqual($Actual, $Expected, [string]$Name) {
    if ($Actual -ne $Expected) { Pass $Name }
    else { Fail $Name "expected a value other than '$Expected'" }
}

function Invoke-ToolProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = ''
    )
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($argument in $ArgumentList) { $psi.ArgumentList.Add($argument) }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    foreach ($key in $Environment.Keys) { $psi.EnvironmentVariables[$key] = [string]$Environment[$key] }
    $process = [Diagnostics.Process]::Start($psi)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdoutTask.GetAwaiter().GetResult()
        Stderr = $stderrTask.GetAwaiter().GetResult()
    }
}

function Invoke-Git([string]$WorkingDirectory, [string[]]$Arguments) {
    $result = Invoke-ToolProcess -FilePath 'git' -ArgumentList (@('-C', $WorkingDirectory) + $Arguments)
    if ($result.ExitCode -ne 0) { throw "git failed: $($result.Stderr)" }
    return $result.Stdout.Trim()
}

function New-Workspace([string]$Root) {
    $workspace = Join-Path $Root ([Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    Invoke-Git $workspace @('init', '-q') | Out-Null
    Invoke-Git $workspace @('config', 'user.email', 'claude-adapter@test.invalid') | Out-Null
    Invoke-Git $workspace @('config', 'user.name', 'Claude adapter test') | Out-Null
    [IO.File]::WriteAllText((Join-Path $workspace 'owned.txt'), "baseline`n")
    [IO.File]::WriteAllText((Join-Path $workspace 'frozen.txt'), "frozen`n")
    [IO.Directory]::CreateDirectory((Join-Path $workspace '.git/info')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $workspace '.git/info/exclude'), ".offload-execution-workspace`n")
    [IO.File]::WriteAllText((Join-Path $workspace '.offload-execution-workspace'), "offload-execution-workspace-v1`n")
    Invoke-Git $workspace @('add', 'owned.txt', 'frozen.txt') | Out-Null
    Invoke-Git $workspace @('commit', '-qm', 'baseline') | Out-Null
    return $workspace
}

function New-Assignment([string]$Workspace, [string]$Path, [string]$CancelFile = '', [int]$Timeout = 10) {
    $baseline = Invoke-Git $Workspace @('rev-parse', 'HEAD')
    $assignment = [ordered]@{
        schema_version = 1
        assignment_id = "test-$([Guid]::NewGuid().ToString('N'))"
        prompt = 'Return a structured result without dispatching a child assignment.'
        working_directory = $Workspace
        owned_paths = @('owned.txt')
        frozen_paths = @('frozen.txt')
        baseline = $baseline
        gate_command = 'Test-Path -LiteralPath owned.txt'
        preference = 'balanced'
        timeout_seconds = $Timeout
    }
    if ($CancelFile) { $assignment.cancel_file = $CancelFile }
    $assignment | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
    return $assignment
}

function Invoke-Adapter {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Adapter,
        [Parameter(Mandatory = $true)][string]$Pwsh,
        [Parameter(Mandatory = $true)][string]$FakeClaude,
        [Parameter(Mandatory = $true)][string]$Artifacts,
        [string]$Mode = 'success',
        [string]$CancelFile = '',
        [int]$Timeout = 10
    )
    $assignmentPath = Join-Path $Artifacts "$Mode-assignment.json"
    $outputPath = Join-Path $Artifacts "$Mode-result.json"
    $errorPath = Join-Path $Artifacts "$Mode-error.txt"
    $assignment = New-Assignment $Workspace $assignmentPath $CancelFile $Timeout
    $environment = @{ CLAUDE_BIN = $FakeClaude; FAKE_CLAUDE_MODE = $Mode }
    $arguments = @('-NoProfile', '-NonInteractive', '-File', $Adapter, '--assignment', $assignmentPath, '--output', $outputPath, '--error', $errorPath)
    $processResult = Invoke-ToolProcess $Pwsh $arguments $environment
    $document = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -Depth 30
    return [pscustomobject]@{ Process = $processResult; Result = $document; OutputPath = $outputPath; ErrorPath = $errorPath; Assignment = $assignment }
}

$root = Split-Path -Parent $PSScriptRoot
$adapter = Join-Path $root 'scripts/run-claude-json.ps1'
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $pwsh) { $pwsh = (Get-Process -Id $PID).Path }
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "offload-claude-adapter-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$fakeClaude = Join-Path $tempRoot 'fake-claude.ps1'
$fakeScript = @'
$ErrorActionPreference = 'Stop'
if ($args -contains '--version') { Write-Output 'claude-fake 1.0'; exit 0 }
if ($args -contains '--help') {
    Write-Output '--output-format --permission-mode --allowedTools --disallowedTools --resume'
    exit 0
}
switch ($env:FAKE_CLAUDE_MODE) {
    'malformed' { Write-Output 'not-json'; exit 0 }
    'cancel' { Start-Sleep -Seconds 30; exit 0 }
    'scope-failure' { Set-Content -LiteralPath (Join-Path (Get-Location) 'unowned.txt') -Value 'unexpected'; }
    'quota' { Write-Error 'quota exhausted'; exit 75 }
}
Write-Output '{"type":"result","subtype":"success","result":"ok","session_id":"s1"}'
'@
[IO.File]::WriteAllText($fakeClaude, $fakeScript)

try {
    $successWorkspace = New-Workspace $tempRoot
    $success = Invoke-Adapter $successWorkspace $adapter $pwsh $fakeClaude $tempRoot
    Assert-Equal $success.Process.ExitCode 0 'success returns zero'
    Assert-Equal $success.Result.status 'completed' 'success is completed'
    Assert-Equal $success.Result.lifecycle 'completed' 'success lifecycle completes'
    Assert-Equal $success.Result.response 'ok' 'success response is normalized'
    Assert-Equal $success.Result.session_id 's1' 'session id is normalized'
    Assert-True ($success.Result.capabilities.tools.assignment_denied -contains 'Task') 'child assignment tool is denied'
    Assert-True ($success.Result.capabilities.tools.assignment_denied -contains 'Agent') 'alternate child assignment tool is denied'
    Assert-True (Test-Path -LiteralPath $success.ErrorPath -PathType Leaf) 'error artifact is written'
    $ledger = Get-Content -LiteralPath (Join-Path $tempRoot 'resource-ledger.json') -Raw | ConvertFrom-Json -Depth 30
    Assert-True (@($ledger.records).resource_type -contains 'process') 'process is registered'
    Assert-True (@($ledger.records).resource_type -contains 'worktree') 'worktree is registered'
    Assert-True (@($ledger.records).resource_type -contains 'artifact') 'artifacts are registered'
    Assert-Equal ((@($ledger.records) | Where-Object resource_id -eq 'process').state) 'completed' 'process is reconciled'

    $malformedWorkspace = New-Workspace $tempRoot
    $malformed = Invoke-Adapter $malformedWorkspace $adapter $pwsh $fakeClaude $tempRoot 'malformed'
    Assert-Equal $malformed.Process.ExitCode 1 'malformed output returns failure'
    Assert-Equal $malformed.Result.lifecycle 'failed' 'malformed output has failed lifecycle'
    Assert-Equal $malformed.Result.error 'malformed Claude JSON output' 'malformed output is classified'
    Assert-True ((Get-Content -LiteralPath "$($malformed.OutputPath).raw.json" -Raw) -match 'not-json') 'raw malformed output is retained'

    $cancelFile = Join-Path $tempRoot 'cancel.request'
    [IO.File]::WriteAllText($cancelFile, 'cancel')
    $cancelWorkspace = New-Workspace $tempRoot
    $canceled = Invoke-Adapter $cancelWorkspace $adapter $pwsh $fakeClaude $tempRoot 'cancel' $cancelFile
    Assert-Equal $canceled.Process.ExitCode 130 'cancellation returns normalized exit code'
    Assert-Equal $canceled.Result.lifecycle 'canceled' 'cancellation lifecycle is recorded'
    Assert-Equal $canceled.Result.error 'canceled' 'cancellation reason is recorded'

    $scopeWorkspace = New-Workspace $tempRoot
    $scopeFailure = Invoke-Adapter $scopeWorkspace $adapter $pwsh $fakeClaude $tempRoot 'scope-failure'
    Assert-Equal $scopeFailure.Process.ExitCode 1 'scope failure returns failure'
    Assert-Equal $scopeFailure.Result.verification.scope 'failed' 'scope failure is verified'
    Assert-Equal $scopeFailure.Result.verification.gate 'not-run' 'gate is withheld after scope failure'
    Assert-Equal $scopeFailure.Result.error 'execution scope check failed' 'scope failure reason is recorded'

    $unmarkedWorkspace = New-Workspace $tempRoot
    Remove-Item -LiteralPath (Join-Path $unmarkedWorkspace '.offload-execution-workspace') -Force
    $unmarkedAssignment = Join-Path $tempRoot 'unmarked-assignment.json'
    $null = New-Assignment $unmarkedWorkspace $unmarkedAssignment
    $unmarkedOutput = Join-Path $tempRoot 'unmarked-result.json'
    $unmarkedError = Join-Path $tempRoot 'unmarked-error.txt'
    $unmarkedRun = Invoke-ToolProcess $pwsh @('-NoProfile', '-NonInteractive', '-File', $adapter, '--assignment', $unmarkedAssignment, '--output', $unmarkedOutput, '--error', $unmarkedError) @{ CLAUDE_BIN = $fakeClaude; FAKE_CLAUDE_MODE = 'success' }
    Assert-NotEqual $unmarkedRun.ExitCode 0 'unmarked workspace fails closed'
    Assert-True ($unmarkedRun.Stderr -match 'unmarked sandbox') 'unmarked failure explains isolation requirement'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

[Console]::Out.WriteLine("$script:TotalTests tests passed")
