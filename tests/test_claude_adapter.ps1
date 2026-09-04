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

$root = Split-Path -Parent $PSScriptRoot
$adapter = Join-Path $root 'scripts/run-claude-json.ps1'
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $pwsh) { $pwsh = (Get-Process -Id $PID).Path }
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "offload-claude-adapter-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null

$fakeClaude = Join-Path $tempRoot 'fake-claude.ps1'
$fakeScript = @'
$ErrorActionPreference = 'Stop'
$argsList = @($args)
if ($env:FAKE_CLAUDE_RECORD_ARGS) {
    $argsList | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:FAKE_CLAUDE_RECORD_ARGS -Encoding utf8
}
if ($args -contains '--version') { Write-Output 'claude-fake 1.0'; exit 0 }
if ($args -contains '--help') {
    Write-Output '--output-format --permission-mode --allowedTools --disallowedTools --resume'
    exit 0
}
switch ($env:FAKE_CLAUDE_MODE) {
    'malformed' { Write-Output 'not-json'; exit 0 }
    'cancel' { Start-Sleep -Seconds 30; exit 0 }
    'quota' { Write-Error 'quota exhausted'; exit 75 }
}
Write-Output '{"type":"result","subtype":"success","result":"ok","session_id":"s1"}'
'@
[IO.File]::WriteAllText($fakeClaude, $fakeScript)

$catalog = Join-Path $tempRoot 'catalog.json'
@{
    revision = 'test-claude-cat'
    models = @(
        @{ id = 'claude-3-5-sonnet-20241022'; family_hint = 'sonnet'; available = $true; quota_available = $true }
        @{ id = 'claude-3-haiku-20240307'; family_hint = 'haiku'; available = $true; quota_available = $true }
    )
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $catalog -Encoding utf8

$catalogRequest = Join-Path $tempRoot 'catalog-request.json'
@{
    protocol_version = 1
    role = 'worker'
    preference = 'balanced'
    effort = 'high'
    required_capabilities = @('structured-output')
    policy_revision = 'test-policy-1'
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $catalogRequest -Encoding utf8

function Invoke-Adapter {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Adapter,
        [Parameter(Mandatory = $true)][string]$Pwsh,
        [Parameter(Mandatory = $true)][string]$FakeClaude,
        [Parameter(Mandatory = $true)][string]$Artifacts,
        [string]$Mode = 'success',
        [string]$CancelFile = '',
        [int]$Timeout = 10,
        [string]$Prompt = 'Return a structured result without dispatching a child assignment.',
        [string]$RecordArgs = ''
    )
    $selectionPath = Join-Path $Artifacts "$Mode-selection.json"
    $outputPath = Join-Path $Artifacts "$Mode-result.json"
    $errorPath = Join-Path $Artifacts "$Mode-error.txt"
    @{
        protocol_version = 1
        model_id = 'claude-3-5-sonnet-20241022'
        effort = 'high'
        preference = 'balanced'
        vendor = 'anthropic'
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $selectionPath -Encoding utf8

    $environment = @{ CLAUDE_BIN = $FakeClaude; FAKE_CLAUDE_MODE = $Mode; CLAUDE_MODEL_CATALOG = $catalog }
    if ($RecordArgs) { $environment['FAKE_CLAUDE_RECORD_ARGS'] = $RecordArgs }

    $adapterArgs = @(
        '-NoProfile', '-NonInteractive', '-File', $Adapter,
        '--operation', 'launch',
        '--request', $selectionPath,
        '--output', $outputPath,
        '--error', $errorPath,
        '--claude', $FakeClaude
    )
    if ($CancelFile) {
        $adapterArgs += @('--cancel-file', $CancelFile)
    }
    $adapterArgs += @('--', '--cd', $Workspace, '--prompt', $Prompt)
    $processResult = Invoke-ToolProcess $Pwsh $adapterArgs $environment
    $document = $null
    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        try {
            $document = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -Depth 30
        } catch { }
    }
    return [pscustomobject]@{ Process = $processResult; Result = $document; OutputPath = $outputPath; ErrorPath = $errorPath }
}

try {
    # 1. Operation catalog test
    $cap = Invoke-ToolProcess $pwsh @('-NoProfile', '-NonInteractive', '-File', $adapter, '--operation', 'catalog', '--request', $catalogRequest, '--claude', $fakeClaude) @{ CLAUDE_MODEL_CATALOG = $catalog }
    Assert-Equal $cap.ExitCode 0 'catalog discovery exits successfully'
    $capDoc = $cap.Stdout | ConvertFrom-Json
    Assert-Equal $capDoc.vendor 'anthropic' 'catalog identifies anthropic'
    Assert-Equal $capDoc.adapter 'claude' 'catalog identifies claude adapter'
    Assert-Equal $capDoc.protocol_version 1 'catalog specifies protocol_version 1'
    Assert-True ($capDoc.models.Count -ge 1) 'catalog includes models'

    # 2. Successful launch test with space preservation
    $successWorkspace = New-Workspace $tempRoot
    $recordArgsFile = Join-Path $tempRoot 'success-args.json'
    $testPrompt = 'Return a structured result with spaces and "quotes".'
    $success = Invoke-Adapter -Workspace $successWorkspace -Adapter $adapter -Pwsh $pwsh -FakeClaude $fakeClaude -Artifacts $tempRoot -Prompt $testPrompt -RecordArgs $recordArgsFile
    Assert-Equal $success.Process.ExitCode 0 'success returns zero'
    Assert-Equal $success.Result.status 'success' 'success status is success'
    Assert-Equal $success.Result.response 'ok' 'success response is normalized'
    Assert-Equal $success.Result.session_id 's1' 'session id is normalized'
    Assert-True (Test-Path -LiteralPath $success.ErrorPath -PathType Leaf) 'error artifact is written'

    # Verify space preservation in arguments and denied tools
    $recordedArgs = Get-Content -LiteralPath $recordArgsFile -Raw | ConvertFrom-Json
    Assert-True ($recordedArgs -contains $testPrompt) 'prompt argument boundary with spaces is preserved'
    Assert-True ($recordedArgs -contains 'Task') 'Task child assignment tool is denied'
    Assert-True ($recordedArgs -contains 'Agent') 'Agent child assignment tool is denied'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $tempRoot 'resource-ledger.json'))) 'no private resource ledger is created'

    # 3. Malformed worker output
    $malformedWorkspace = New-Workspace $tempRoot
    $malformed = Invoke-Adapter -Workspace $malformedWorkspace -Adapter $adapter -Pwsh $pwsh -FakeClaude $fakeClaude -Artifacts $tempRoot -Mode 'malformed'
    Assert-Equal $malformed.Process.ExitCode 1 'malformed output returns failure'
    Assert-True ((Get-Content -LiteralPath $malformed.OutputPath -Raw) -match 'not-json') 'raw malformed output is retained'

    # 4. Cancellation
    $cancelFile = Join-Path $tempRoot 'cancel.request'
    [IO.File]::WriteAllText($cancelFile, 'cancel')
    $cancelWorkspace = New-Workspace $tempRoot
    $canceled = Invoke-Adapter -Workspace $cancelWorkspace -Adapter $adapter -Pwsh $pwsh -FakeClaude $fakeClaude -Artifacts $tempRoot -Mode 'cancel' -CancelFile $cancelFile
    Assert-Equal $canceled.Process.ExitCode 130 'cancellation returns normalized exit code'

    # 5. Unmarked workspace fails closed
    $unmarkedWorkspace = New-Workspace $tempRoot
    Remove-Item -LiteralPath (Join-Path $unmarkedWorkspace '.offload-execution-workspace') -Force
    $unmarkedRun = Invoke-Adapter -Workspace $unmarkedWorkspace -Adapter $adapter -Pwsh $pwsh -FakeClaude $fakeClaude -Artifacts $tempRoot -Mode 'unmarked'
    Assert-NotEqual $unmarkedRun.Process.ExitCode 0 'unmarked workspace fails closed'
    Assert-True ($unmarkedRun.Process.Stderr -match 'unmarked sandbox') 'unmarked failure explains isolation requirement'

    # 6. Missing catalog fails closed
    $noCatRun = Invoke-ToolProcess $pwsh @('-NoProfile', '-NonInteractive', '-File', $adapter, '--operation', 'catalog', '--request', $catalogRequest, '--claude', $fakeClaude) @{}
    Assert-NotEqual $noCatRun.ExitCode 0 'missing catalog fails closed'

} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

[Console]::Out.WriteLine("$script:TotalTests tests passed")
