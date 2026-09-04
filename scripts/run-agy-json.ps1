#!/usr/bin/env pwsh
# Vendor-neutral worker launcher. Model syntax belongs to the selected adapter.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Fail([string]$message, [int]$exitCode = 2) { [Console]::Error.WriteLine("ERROR: $message"); exit $exitCode }
function Usage { [Console]::Error.WriteLine("Usage: run-agy-json.ps1 --role ROLE [--route default|quality-retry] [--adapter FILE] [--selection-output FILE] [--pin FILE] [lifecycle options] --output FILE --error FILE '--' worker-arguments..."); [Console]::Error.WriteLine('The role selects policy preference and effort; the adapter catalog selects the exact model.') }
function Property($object, [string]$name) { if ($null -eq $object) { return $null }; $p=$object.PSObject.Properties[$name]; if ($null -eq $p) { return $null }; return $p.Value }
function Read-Json([string]$path, [string]$label) { try { return ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path)) -Depth 30 -ErrorAction Stop } catch { Fail "$label is not valid JSON: $($_.Exception.Message)" } }
function Read-OptionalText([string]$path) { if (Test-Path -LiteralPath $path -PathType Leaf) { return [System.IO.File]::ReadAllText($path) }; return '' }
function Resolve-Program([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { Fail 'adapter path is empty' }
    $candidate=$path
    if (-not [System.IO.Path]::IsPathRooted($candidate)) { $candidate=Join-Path (Get-Location).ProviderPath $candidate }
    $candidate=[System.IO.Path]::GetFullPath($candidate)
    if ($candidate.EndsWith('.ps1',[System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { Fail "adapter script not found: $candidate" 127 }
        return @{File=(Get-Command pwsh -ErrorAction Stop).Source;Prefix=@('-NoProfile','-NonInteractive','-File',$candidate)}
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { Fail "adapter not found: $candidate" 127 }
    return @{File=$candidate;Prefix=@()}
}
function Start-Program([hashtable]$program, [string[]]$arguments, [string]$workingDirectory) {
    $psi=[System.Diagnostics.ProcessStartInfo]::new(); $psi.FileName=$program.File; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.WorkingDirectory=$workingDirectory; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.Environment['OFFLOAD_WORKER_CONTEXT']='1'
    foreach($argument in ($program.Prefix+$arguments)){[void]$psi.ArgumentList.Add([string]$argument)}
    $process=[System.Diagnostics.Process]::new(); $process.StartInfo=$psi
    try { if(-not $process.Start()){Fail "failed to start adapter: $($program.File)" 127}; return $process } catch {$process.Dispose(); Fail "adapter invocation failed: $($_.Exception.Message)" 127}
}
function Ensure-WorkerJobType {
    if (-not $IsWindows -or $null -ne ('Offload.JobObjectNative' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Offload {
    public static class JobObjectNative {
        public const uint KillOnJobClose = 0x2000;
        public const int JobObjectExtendedLimitInformation = 9;

        [StructLayout(LayoutKind.Sequential)]
        public struct BasicLimitInformation {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public IntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct IoCounters {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct ExtendedLimitInformation {
            public BasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            ref ExtendedLimitInformation information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr handle);

        public static int LastError() {
            return Marshal.GetLastWin32Error();
        }
    }
}
'@
}
function New-WorkerJob {
    if (-not $IsWindows) { return [IntPtr]::Zero }
    Ensure-WorkerJobType
    $job=[Offload.JobObjectNative]::CreateJobObject([IntPtr]::Zero,$null)
    if($job -eq [IntPtr]::Zero){throw "CreateJobObject failed with Win32 error $([Offload.JobObjectNative]::LastError())"}
    try {
        $limits=[Offload.JobObjectNative+ExtendedLimitInformation]::new()
        $basic=$limits.BasicLimitInformation
        $basic.LimitFlags=[Offload.JobObjectNative]::KillOnJobClose
        $limits.BasicLimitInformation=$basic
        $size=[System.Runtime.InteropServices.Marshal]::SizeOf($limits)
        if(-not [Offload.JobObjectNative]::SetInformationJobObject($job,[Offload.JobObjectNative]::JobObjectExtendedLimitInformation,[ref]$limits,[uint32]$size)){throw "SetInformationJobObject failed with Win32 error $([Offload.JobObjectNative]::LastError())"}
        return $job
    } catch {
        [Offload.JobObjectNative]::CloseHandle($job)|Out-Null
        throw
    }
}
function Add-ProcessToWorkerJob([IntPtr]$job,[System.Diagnostics.Process]$process) {
    if($job -eq [IntPtr]::Zero){return $true}
    return [Offload.JobObjectNative]::AssignProcessToJobObject($job,$process.Handle)
}
function Start-WorkerWatchdog([System.Diagnostics.Process]$process) {
    $targetStartTicks=0L
    try { $targetStartTicks=$process.StartTime.ToUniversalTime().Ticks } catch { }
    $watchdogCode=@'
$parent=Get-Process -Id __PARENT_PID__ -ErrorAction SilentlyContinue
while($null -ne $parent -and -not $parent.HasExited){Start-Sleep -Milliseconds 100;$parent=Get-Process -Id __PARENT_PID__ -ErrorAction SilentlyContinue}
try{$target=Get-Process -Id __TARGET_PID__ -ErrorAction Stop;$matches=__TARGET_START_TICKS__ -eq 0 -or $target.StartTime.ToUniversalTime().Ticks -eq __TARGET_START_TICKS__;if($matches -and -not $target.HasExited){$target.Kill($true);$target.WaitForExit()}}catch{}
'@
    $watchdogCode=$watchdogCode.Replace('__PARENT_PID__',[string]$PID).Replace('__TARGET_PID__',[string]$process.Id).Replace('__TARGET_START_TICKS__',[string]$targetStartTicks)
    $encoded=[Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($watchdogCode))
    $psi=[System.Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Get-Command pwsh -ErrorAction Stop).Source;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WorkingDirectory=(Get-Location).ProviderPath
    [void]$psi.ArgumentList.Add('-NoProfile');[void]$psi.ArgumentList.Add('-NonInteractive');[void]$psi.ArgumentList.Add('-EncodedCommand');[void]$psi.ArgumentList.Add($encoded)
    $watchdog=[System.Diagnostics.Process]::new();$watchdog.StartInfo=$psi
    try { if(-not $watchdog.Start()){$watchdog.Dispose();return $null};return $watchdog } catch {$watchdog.Dispose();return $null}
}
function Stop-WorkerWatchdog([System.Diagnostics.Process]$watchdog) {
    if($null -eq $watchdog){return}
    try { if(-not $watchdog.HasExited){$watchdog.Kill($true);$watchdog.WaitForExit()} } catch { }
    try {$watchdog.Dispose()} catch { }
}
function Stop-Worker([IntPtr]$job,[System.Diagnostics.Process]$process) {
    $terminated=$false
    if($job -ne [IntPtr]::Zero){$terminated=[Offload.JobObjectNative]::TerminateJobObject($job,1)}
    if(-not $terminated -and $process -and -not $process.HasExited){$process.Kill($true)}
    if($process -and -not $process.HasExited){$process.WaitForExit()}
}
function Close-WorkerJob([IntPtr]$job) {
    if($job -ne [IntPtr]::Zero){[Offload.JobObjectNative]::CloseHandle($job)|Out-Null}
}
function Invoke-Program([hashtable]$program, [string[]]$arguments, [string]$workingDirectory, [string]$stdoutPath, [string]$stderrPath) {
    $process=$null;$workerJob=[IntPtr]::Zero;$workerWatchdog=$null
    try { $process=Start-Program $program $arguments $workingDirectory;$workerJob=New-WorkerJob;if(-not (Add-ProcessToWorkerJob $workerJob $process)){Close-WorkerJob $workerJob;$workerJob=[IntPtr]::Zero};$workerWatchdog=Start-WorkerWatchdog $process;if($workerJob -eq [IntPtr]::Zero -and $null -eq $workerWatchdog){Stop-Worker $workerJob $process;throw 'worker containment could not be established'};$outTask=$process.StandardOutput.ReadToEndAsync(); $errTask=$process.StandardError.ReadToEndAsync(); $process.WaitForExit(); [System.IO.File]::WriteAllText($stdoutPath,$outTask.GetAwaiter().GetResult(),[System.Text.Encoding]::UTF8); [System.IO.File]::WriteAllText($stderrPath,$errTask.GetAwaiter().GetResult(),[System.Text.Encoding]::UTF8); return $process.ExitCode } finally {Stop-WorkerWatchdog $workerWatchdog;if($process -and -not $process.HasExited){try{Stop-Worker $workerJob $process}catch{}};Close-WorkerJob $workerJob;if($process){$process.Dispose()}}
}
function Ensure-Path([string]$path,[string]$label,[string]$caller) {
    if([string]::IsNullOrWhiteSpace($path)){Fail "$label is required"}; if(-not [System.IO.Path]::IsPathRooted($path)){$path=Join-Path $caller $path}; try{$path=[System.IO.Path]::GetFullPath($path)}catch{Fail "$label is not a valid path: $path"}; $parent=[System.IO.Path]::GetDirectoryName($path); if($parent -and -not [System.IO.Directory]::Exists($parent)){[System.IO.Directory]::CreateDirectory($parent)|Out-Null}; return $path
}
function Invoke-ResourceLedger([string]$verb,[string[]]$arguments) {
    $ledgerScript=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'resource-ledger.ps1'));$psi=[System.Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Get-Command pwsh -ErrorAction Stop).Source;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WorkingDirectory=(Get-Location).ProviderPath;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($argument in (@('-NoProfile','-NonInteractive','-File',$ledgerScript,$verb)+$arguments)){[void]$psi.ArgumentList.Add([string]$argument)}
    $process=$null;try{$process=[System.Diagnostics.Process]::Start($psi);if($null -eq $process){throw 'resource ledger process did not start'};$stdout=$process.StandardOutput.ReadToEnd();$stderr=$process.StandardError.ReadToEnd();$process.WaitForExit();if($process.ExitCode -ne 0){$message=$stderr.Trim();if([string]::IsNullOrWhiteSpace($message)){$message=$stdout.Trim()};throw "resource ledger $verb failed$(if($message){": $message"})"};return $stdout}finally{if($process){$process.Dispose()}}
}

$outputPath='';$errorPath='';$selectionOutputPath='';$pinPath='';$adapterPath='';$role='';$route='default';$lifecyclePath='';$attempt=1;$mode='unknown';$verificationBaseline='';$resourceLedgerPath='';$timeoutSeconds=0;$cancelFile='';$ledgerPath='';$assignmentId='';$parentId='';$resourceId=''
$options=@{};$forwardedArgs=[System.Collections.Generic.List[string]]::new();$requiredCapabilities=[System.Collections.Generic.List[string]]::new();$delimiter=$false
$valueOptions=@('--output','--error','--selection-output','--pin','--adapter','--role','--route','--lifecycle','--attempt','--mode','--verification-baseline','--resource-ledger','--timeout-seconds','--cancel-file','--ledger','--assignment-id','--parent-id','--resource-id')
$i=0
while($i -lt $args.Count){$arg=[string]$args[$i];if($arg -eq '--'){$delimiter=$true;$i++;while($i -lt $args.Count){$forwardedArgs.Add([string]$args[$i]);$i++};break};$name='';$value=$null;if($arg -match '^(--[^=]+)=(.*)$'){$name=$Matches[1];$value=$Matches[2]}elseif($valueOptions -contains $arg -or $arg -eq '--require-capability'){$name=$arg;$i++;if($i -ge $args.Count){Usage;Fail "$name requires a value"};$value=[string]$args[$i]}else{Usage;Fail "unknown launcher option: $arg"};if($name -eq '--require-capability'){if([string]::IsNullOrWhiteSpace($value)){Fail '--require-capability requires a non-empty value'};$requiredCapabilities.Add($value)}else{if($options.ContainsKey($name)){Fail "duplicate $name option"};$options[$name]=$value};$i++}
if(-not $delimiter){Usage;Fail '-- delimiter is required'};if($forwardedArgs.Count -eq 0){Usage;Fail 'worker arguments are required after --'};foreach($name in @('--output','--error','--role')){if(-not ($options.ContainsKey($name)) -or [string]::IsNullOrWhiteSpace([string]$options[$name])){Usage;Fail "$name is required"}}
$outputPath=[string]$options['--output'];$errorPath=[string]$options['--error'];$role=[string]$options['--role'];if($options.ContainsKey('--selection-output')){$selectionOutputPath=[string]$options['--selection-output']};if($options.ContainsKey('--pin')){$pinPath=[string]$options['--pin']};if($options.ContainsKey('--adapter')){$adapterPath=[string]$options['--adapter']};if($options.ContainsKey('--route')){$route=[string]$options['--route']};if($options.ContainsKey('--lifecycle')){$lifecyclePath=[string]$options['--lifecycle']};if($options.ContainsKey('--attempt')){if(-not [int]::TryParse([string]$options['--attempt'],[ref]$attempt)){Fail '--attempt requires an integer'}};if($options.ContainsKey('--mode')){$mode=[string]$options['--mode']};if($options.ContainsKey('--verification-baseline')){$verificationBaseline=[string]$options['--verification-baseline']};if($options.ContainsKey('--resource-ledger')){$resourceLedgerPath=[string]$options['--resource-ledger']};if($options.ContainsKey('--timeout-seconds')){if(-not [int]::TryParse([string]$options['--timeout-seconds'],[ref]$timeoutSeconds)){Fail '--timeout-seconds requires an integer'}};if($options.ContainsKey('--cancel-file')){$cancelFile=[string]$options['--cancel-file']};if($options.ContainsKey('--ledger')){$ledgerPath=[string]$options['--ledger']};if($options.ContainsKey('--assignment-id')){$assignmentId=[string]$options['--assignment-id']};if($options.ContainsKey('--parent-id')){$parentId=[string]$options['--parent-id']};if($options.ContainsKey('--resource-id')){$resourceId=[string]$options['--resource-id']}
if($route -notin @('default','quality-retry')){Fail "unknown route: '$route'; must be default or quality-retry"};if($role -notin @('scout','gate-author','implementer','reviewer','researcher','synthesizer','auditor')){Fail "unknown role: '$role'"};if($env:OFFLOAD_WORKER_CONTEXT -eq '1'){Fail 'worker process cannot invoke the launcher; only the orchestrator may create worker processes' 126};foreach($forwarded in $forwardedArgs){if($forwarded -eq '--output' -or $forwarded.StartsWith('--output=') -or $forwarded -eq '--model' -or $forwarded.StartsWith('--model=') -or $forwarded -eq '--effort' -or $forwarded.StartsWith('--effort=')){Fail 'caller cannot pass --output, --model, or --effort to the worker'}};if($timeoutSeconds -lt 0){Fail '--timeout-seconds must be zero or a positive integer'}
$currentLocation=Get-Location;if($currentLocation.Provider.Name -ne 'FileSystem'){Fail 'current location must use the FileSystem provider'};$callerDirectory=[System.IO.Path]::GetFullPath($currentLocation.ProviderPath);$outputPath=Ensure-Path $outputPath 'output path' $callerDirectory;$errorPath=Ensure-Path $errorPath 'error path' $callerDirectory;if($outputPath -eq $errorPath){Fail 'output and error paths must be different'};if($selectionOutputPath){$selectionOutputPath=Ensure-Path $selectionOutputPath 'selection output path' $callerDirectory};if($ledgerPath){$ledgerPath=Ensure-Path $ledgerPath 'ledger path' $callerDirectory;if($resourceLedgerPath){$resourceLedgerPath=Ensure-Path $resourceLedgerPath 'resource ledger path' $callerDirectory;if($ledgerPath -ne $resourceLedgerPath){Fail '--ledger and --resource-ledger must name the same path'}}else{$resourceLedgerPath=$ledgerPath}}elseif($resourceLedgerPath){$resourceLedgerPath=Ensure-Path $resourceLedgerPath 'resource ledger path' $callerDirectory}
$scriptDir=[System.IO.Path]::GetFullPath($PSScriptRoot);$repoRoot=[System.IO.Path]::GetFullPath((Join-Path $scriptDir '..'));$policyFile=Join-Path $repoRoot 'model-policy.json';$policy=Read-Json $policyFile 'model policy file';if((Property $policy 'schema_version') -ne 2 -or (Property $policy 'max_effort') -ne 'high' -or (Property $policy 'max_retries_per_worker') -ne 1 -or (Property $policy 'quota_action') -ne 'handoff'){Fail 'model policy has unsupported schema or safety settings'}
$roles=Property $policy 'roles';$rolePolicy=Property $roles $role;if($null -eq $rolePolicy -or (Property $rolePolicy 'preference') -notin @('fast','balanced','deep') -or (Property $rolePolicy 'effort') -notin @('low','medium','high')){Fail "role '$role' has invalid policy"};$preference=[string](Property $rolePolicy 'preference');$effort=[string](Property $rolePolicy 'effort');$policyCapabilities=@((Property $rolePolicy 'required_capabilities'))|Where-Object{ -not [string]::IsNullOrWhiteSpace([string]$_)};$allCapabilities=@($policyCapabilities+$requiredCapabilities.ToArray())|Sort-Object -Unique;if($route -eq 'quality-retry' -and [string]::IsNullOrWhiteSpace($pinPath)){Fail 'quality-retry requires --pin with the prior selection; use an explicit fallback or handoff when it is unavailable' 3}
$adapterDefault=Join-Path $scriptDir 'agy-adapter.ps1';if([string]::IsNullOrWhiteSpace($adapterPath)){$adapterPath=[Environment]::GetEnvironmentVariable('OFFLOAD_ADAPTER_BIN')};if([string]::IsNullOrWhiteSpace($adapterPath)){$adapterPath=$adapterDefault};$adapter=Resolve-Program $adapterPath;$tempRequest=[System.IO.Path]::GetTempFileName();$tempCatalog=[System.IO.Path]::GetTempFileName();$tempAdapterError=[System.IO.Path]::GetTempFileName();$tempLaunchSelection=[System.IO.Path]::GetTempFileName()
try {
    $request=[ordered]@{protocol_version=1;operation='catalog';role=$role;preference=$preference;effort=$effort;required_capabilities=@($allCapabilities);policy_revision=[string](Property $policy 'policy_revision')};[System.IO.File]::WriteAllText($tempRequest,($request|ConvertTo-Json -Depth 20),[System.Text.Encoding]::UTF8);$catalogCode=Invoke-Program $adapter @('--operation','catalog','--request',$tempRequest) $callerDirectory $tempCatalog $tempAdapterError;if($catalogCode -ne 0){$diagnostic=[System.IO.File]::ReadAllText($tempAdapterError).Trim();Fail "adapter catalog discovery failed with exit code $catalogCode$(if($diagnostic){": $diagnostic"})" 127}
    $catalog=Read-Json $tempCatalog 'adapter catalog';if((Property $catalog 'protocol_version') -ne 1){Fail 'adapter catalog has unsupported protocol_version' 127};$catalogAdapter=[string](Property $catalog 'adapter');$catalogVendor=[string](Property $catalog 'vendor');$catalogRevision=[string](Property $catalog 'catalog_revision');$adapterRevision=[string](Property $catalog 'adapter_revision');if(@($catalogAdapter,$catalogVendor,$catalogRevision,$adapterRevision|Where-Object{[string]::IsNullOrWhiteSpace([string]$_)}).Count -gt 0){Fail 'adapter catalog is missing required metadata' 127}
    $eligible=[System.Collections.Generic.List[object]]::new();foreach($model in @((Property $catalog 'models'))){$id=[string](Property $model 'id');$supported=@((Property $model 'supported_efforts'))|ForEach-Object{[string]$_};$caps=@((Property $model 'capabilities'))|ForEach-Object{[string]$_};$scores=Property $model 'scores';$scoreValue=Property $scores $preference;if([string]::IsNullOrWhiteSpace($id) -or (Property $model 'available') -ne $true -or ((Property $model 'quota_available') -ne $null -and (Property $model 'quota_available') -ne $true) -or $supported -notcontains $effort){continue};if(@($allCapabilities|Where-Object{$caps -notcontains $_}).Count -gt 0){continue};if($null -eq $scoreValue){$scoreValue=1000000};try{$score=[double]$scoreValue}catch{continue};$vendor=[string](Property $model 'vendor');if([string]::IsNullOrWhiteSpace($vendor)){$vendor=$catalogVendor};$eligible.Add([pscustomobject]@{Model=$model;Id=$id;Vendor=$vendor;Score=$score})}
    if($eligible.Count -eq 0){Fail "adapter catalog has no eligible model for role '$role', effort '$effort', and required capabilities" 4};$selected=$null;$selectionReason="catalog selection preference=$preference effort=$effort; filtered unavailable, quota, effort, capability, and static-policy-incompatible candidates";if($pinPath){if(-not(Test-Path -LiteralPath $pinPath -PathType Leaf)){Fail "pinned selection file not found: $pinPath" 3};$pin=Read-Json $pinPath 'pinned selection';$pinId=[string](Property $pin 'model_id');if(-not $pinId){$pinId=[string](Property $pin 'model')};if([string](Property $pin 'adapter') -ne $catalogAdapter -or [string](Property $pin 'vendor') -ne $catalogVendor -or [string](Property $pin 'effort') -ne $effort -or -not $pinId){Fail 'pinned selection does not match the current adapter, vendor, or policy effort; explicit fallback or handoff is required' 3};$selected=$eligible|Where-Object{$_.Id -eq $pinId -and $_.Vendor -eq $catalogVendor}|Select-Object -First 1;if($null -eq $selected){Fail "pinned model '$pinId' is unavailable in catalog revision '$catalogRevision'; explicit fallback or handoff is required" 3};$selectionReason="pinned selection adapter=$catalogAdapter vendor=$catalogVendor model_id=$pinId; catalog_revision=$catalogRevision"}else{$selected=$eligible|Sort-Object Score,Vendor,Id|Select-Object -First 1}
    $selection=[ordered]@{protocol_version=1;adapter=$catalogAdapter;adapter_revision=$adapterRevision;vendor=$selected.Vendor;model_id=$selected.Id;model=$selected.Id;family_hint=[string](Property $selected.Model 'family_hint');preference=$preference;effort=$effort;catalog_revision=$catalogRevision;policy_revision=[string](Property $policy 'policy_revision');required_capabilities=@($allCapabilities);selection_reason=$selectionReason;route=$route};$selectionJson=$selection|ConvertTo-Json -Depth 20;if($selectionOutputPath){[System.IO.File]::WriteAllText($selectionOutputPath,$selectionJson,[System.Text.Encoding]::UTF8)}
    $lifecycle=$options.ContainsKey('--lifecycle') -or $options.ContainsKey('--attempt') -or $options.ContainsKey('--resource-ledger') -or $options.ContainsKey('--ledger') -or $options.ContainsKey('--timeout-seconds') -or $options.ContainsKey('--cancel-file');if(-not $lifecycle){[System.IO.File]::WriteAllText($tempLaunchSelection,$selectionJson,[System.Text.Encoding]::UTF8);$code=Invoke-Program $adapter (@('--operation','launch','--request',$tempLaunchSelection,'--output',$outputPath,'--error',$errorPath,'--')+$forwardedArgs.ToArray()) $callerDirectory $tempCatalog $tempAdapterError;if($code -ne 0){$diag=[System.IO.File]::ReadAllText($tempAdapterError).Trim();if($diag){[Console]::Error.WriteLine("ERROR: adapter launch failed with exit code ${code}: $diag")}};exit $code}
    if(-not $assignmentId){$assignmentId="$role-$(Get-Date -Format 'yyyyMMddHHmmssfff')"};if(-not $lifecyclePath){$lifecyclePath="$outputPath.lifecycle.json"};$lifecyclePath=Ensure-Path $lifecyclePath 'lifecycle path' $callerDirectory;if($attempt -lt 1 -or $attempt -gt 2){Fail 'attempt must be 1 or 2; policy allows at most one retry per assignment'};if($resourceLedgerPath){Invoke-ResourceLedger 'init' @('--ledger',$resourceLedgerPath)|Out-Null}
    $workerResourceId=if($resourceId){$resourceId}else{"worker-process:$($assignmentId):attempt:$attempt"};$resourceParentId=if($parentId){$parentId}else{'orchestrator'};$resourceRegistered=$false;$resourceState='failed';$resourceError='';$script:Record=[ordered]@{schema_version=1;assignment_id=$assignmentId;attempt=$attempt;role=$role;mode=$mode;policy_revision=[string](Property $policy 'policy_revision');model=[string]$selection.model_id;effort=$effort;verification_baseline=if($verificationBaseline){$verificationBaseline}else{$null};resource_ledger=if($resourceLedgerPath){$resourceLedgerPath}else{$null};resource_id=if($resourceLedgerPath){$workerResourceId}else{$null};state='created';events=@();exit_code=$null;termination='none';failure_class='none';artifacts=[ordered]@{output=$outputPath;error=$errorPath;lifecycle=$lifecyclePath}}
    function Save-Record{[System.IO.File]::WriteAllText($lifecyclePath,($script:Record|ConvertTo-Json -Depth 20),[System.Text.Encoding]::UTF8)};function State([string]$name,[hashtable]$details=@{}){$event=[ordered]@{state=$name;at=[DateTime]::UtcNow.ToString('o')};foreach($key in $details.Keys){$event[$key]=$details[$key]};$script:Record.events=@(@($script:Record.events)+@([pscustomobject]$event));$script:Record.state=$name;foreach($key in $details.Keys){if($script:Record.Contains($key)){$script:Record[$key]=$details[$key]}};Save-Record};Save-Record;State 'created'
    $process=$null;$workerJob=[IntPtr]::Zero;$workerWatchdog=$null;try{[System.IO.File]::WriteAllText($tempLaunchSelection,$selectionJson,[System.Text.Encoding]::UTF8);$process=Start-Program $adapter (@('--operation','launch','--request',$tempLaunchSelection,'--output',$outputPath,'--error',$errorPath,'--')+$forwardedArgs.ToArray()) $callerDirectory;$workerJob=New-WorkerJob;if(-not (Add-ProcessToWorkerJob $workerJob $process)){Close-WorkerJob $workerJob;$workerJob=[IntPtr]::Zero};$workerWatchdog=Start-WorkerWatchdog $process;if($workerJob -eq [IntPtr]::Zero -and $null -eq $workerWatchdog){Stop-Worker $workerJob $process;throw 'worker containment could not be established'};$processStartTime='';try{$processStartTime=$process.StartTime.ToUniversalTime().ToString('o')}catch{};if($resourceLedgerPath){$registerArgs=[System.Collections.Generic.List[string]]::new();foreach($argument in @('--ledger',$resourceLedgerPath,'--assignment-id',$assignmentId,'--parent-id',$resourceParentId,'--resource-type','worker-process','--process-id',[string]$process.Id,'--owner-marker','agy-worker=agy-worker-v1','--resource-id',$workerResourceId,'--state','active')){$registerArgs.Add($argument)};if($processStartTime){$registerArgs.Add('--process-start-time');$registerArgs.Add($processStartTime)};Invoke-ResourceLedger 'register' $registerArgs.ToArray()|Out-Null;$resourceRegistered=$true};State 'started' @{pid=$process.Id};$outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync();State 'running';$termination='natural';$deadline=if($timeoutSeconds -gt 0){[DateTime]::UtcNow.AddSeconds($timeoutSeconds)}else{$null};while(-not $process.HasExited){if($cancelFile -and (Test-Path -LiteralPath $cancelFile -PathType Leaf)){$termination='canceled';break};if($deadline -and [DateTime]::UtcNow -ge $deadline){$termination='timeout';break};Start-Sleep -Milliseconds 50};if(-not $process.HasExited){Stop-Worker $workerJob $process}else{$process.WaitForExit()};[System.Threading.Tasks.Task]::WaitAll(@($outTask,$errTask));$code=$process.ExitCode;$valid=$false;try{$parsed=ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($outputPath))-Depth 30 -ErrorAction Stop;$valid=($parsed.status -eq 'success' -and $parsed.PSObject.Properties['structured_output'] -and $parsed.structured_output -is [System.Management.Automation.PSCustomObject])}catch{$valid=$false};$text=(Read-OptionalText $outputPath)+"`n"+(Read-OptionalText $errorPath);if($termination -eq 'canceled'){$code=130;$resourceState='cancelled';$resourceError='worker cancelled';State 'canceled' @{exit_code=$code;termination='canceled';failure_class='canceled'}}elseif($termination -eq 'timeout'){$code=124;$resourceState='timed_out';$resourceError='worker timed out';State 'failed' @{exit_code=$code;termination='timeout';failure_class='timeout'}}elseif($code -eq 75 -or $text -match '(?i)quota|resource[_ -]?exhausted|rate limit|\b429\b'){$code=75;$resourceState='quota_handoff';$resourceError='worker quota exhausted';State 'quota-handoff' @{exit_code=$code;termination='quota';failure_class='quota'}}elseif($code -eq 0 -and $valid){$resourceState='completed';State 'completed' @{exit_code=0;termination='natural';failure_class='none'}}else{$code=if($code -eq 0){1}else{$code};$resourceState='failed';$resourceError='malformed worker output';State 'failed' @{exit_code=$code;termination='natural';failure_class='malformed_output'}};State 'retained';State 'cleaned';exit $code}finally{Stop-WorkerWatchdog $workerWatchdog;if($process -and -not $process.HasExited){try{Stop-Worker $workerJob $process}catch{}};if($resourceRegistered){try{$updateArgs=[System.Collections.Generic.List[string]]::new();foreach($argument in @('--ledger',$resourceLedgerPath,'--resource-id',$workerResourceId,'--state',$resourceState)){$updateArgs.Add($argument)};if($resourceError){$updateArgs.Add('--error');$updateArgs.Add($resourceError)};Invoke-ResourceLedger 'update' $updateArgs.ToArray()|Out-Null}catch{[Console]::Error.WriteLine("WARNING: could not update resource ledger: $($_.Exception.Message)")}};Close-WorkerJob $workerJob;if($process){$process.Dispose()}}
} finally { Remove-Item -LiteralPath $tempRequest,$tempCatalog,$tempAdapterError,$tempLaunchSelection -Force -ErrorAction SilentlyContinue }
