#!/usr/bin/env pwsh
# scripts/collect-provenance.ps1
# Provenance collector and validator for Offload runs.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Show-Usage {
    [Console]::Error.WriteLine("Usage: collect-provenance.ps1 [--validate <file.json>] [build options] [--output <file.json>]")
}

function Fail([string]$message, [int]$exitCode = 1) {
    [Console]::Error.WriteLine("Error: $message")
    exit $exitCode
}

$validateFile = ""
$outputFile = ""
$runId = ""
$requestSummary = ""
$selectedMode = "web-research"
$profile = "standard"
$deepTrigger = ""
$deepTriggerSet = $false
$startTime = ""
$endTime = ""
$durationSeconds = ""
$scratchPath = ""
$workersJson = "[]"
$snapshotPathsJson = ""
$snapshotPaths = [System.Collections.Generic.List[string]]::new()
$finalCitationsJson = "[]"
$auditVerdictsJson = "[]"
$finalStatus = ""
$incompleteStageReasonsJson = "[]"

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    switch ($arg) {
        { $_ -in '--validate', '--check', '-f', '--input' } {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a file path" }
            $validateFile = [string]$args[$i]
        }
        { $_ -in '--output', '-o' } {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a file path" }
            $outputFile = [string]$args[$i]
        }
        '--run-id' {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $runId = [string]$args[$i]
        }
        '--request-summary' {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $requestSummary = [string]$args[$i]
        }
        '--selected-mode' {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $selectedMode = [string]$args[$i]
        }
        '--profile' {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $profile = [string]$args[$i]
        }
        '--deep-trigger' {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $deepTrigger = [string]$args[$i]
            $deepTriggerSet = $true
        }
        '--start-time' {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $startTime = [string]$args[$i]
        }
        '--end-time' {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $endTime = [string]$args[$i]
        }
        '--duration-seconds' {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $durationSeconds = [string]$args[$i]
        }
        '--scratch-path' {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $scratchPath = [string]$args[$i]
        }
        '--workers' {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $workersJson = [string]$args[$i]
        }
        '--snapshot-paths' {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $snapshotPathsJson = [string]$args[$i]
        }
        { $_ -in '--snapshot-path', '--repo-path', '--path' } {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $snapshotPaths.Add([string]$args[$i])
        }
        '--final-citations' {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $finalCitationsJson = [string]$args[$i]
        }
        '--audit-verdicts' {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $auditVerdictsJson = [string]$args[$i]
        }
        '--final-status' {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $finalStatus = [string]$args[$i]
        }
        '--incomplete-stage-reasons' {
            $i++
            if ($i -ge $args.Count) { Fail "option $arg requires a value" }
            $incompleteStageReasonsJson = [string]$args[$i]
        }
        { $_ -in '-h', '--help' } {
            Show-Usage
            exit 0
        }
        default {
            if ([string]::IsNullOrEmpty($validateFile) -and (Test-Path -LiteralPath $arg -PathType Leaf)) {
                $validateFile = $arg
            } else {
                Fail "unrecognized argument: $arg"
            }
        }
    }
    $i++
}

function Parse-JsonInput([string]$raw, [string]$fieldName, [System.Text.Json.Nodes.JsonNode]$defaultValue) {
    $trimmed = if ($raw) { $raw.Trim() } else { "" }
    if ([string]::IsNullOrEmpty($trimmed)) {
        return ,$defaultValue
    }
    if (Test-Path -LiteralPath $trimmed -PathType Leaf) {
        try {
            $fileContent = [System.IO.File]::ReadAllText($trimmed, [System.Text.Encoding]::UTF8)
            return ,([System.Text.Json.Nodes.JsonNode]::Parse($fileContent))
        } catch {
            Fail "failed to parse ${fieldName} from file '$trimmed': $($_.Exception.Message)"
        }
    }
    try {
        return ,([System.Text.Json.Nodes.JsonNode]::Parse($trimmed))
    } catch {
        Fail "failed to parse ${fieldName}: $($_.Exception.Message)"
    }
}

function Get-NodeString([System.Text.Json.Nodes.JsonNode]$node) {
    if ($node -eq $null) { return $null }
    try {
        $elem = $node.GetValue[System.Text.Json.JsonElement]()
        if ($elem.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
            return $elem.GetString()
        }
        return $null
    } catch {
        try {
            return $node.GetValue[string]()
        } catch {
            return $null
        }
    }
}

function Test-Duration([System.Text.Json.Nodes.JsonNode]$durNode) {
    if ($durNode -is [System.Text.Json.Nodes.JsonValue]) {
        $literal = $durNode.ToJsonString()
        if ($literal -notmatch '^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$') {
            return $false
        }
        $value = 0.0
        if (-not [double]::TryParse($literal, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
            return $false
        }
        return $value -ge 0 -and -not [double]::IsNaN($value) -and -not [double]::IsInfinity($value)
    }
    return $false
}

function Validate-WorkerRouting([System.Text.Json.Nodes.JsonNode]$workerNode) {
    if ($workerNode -isnot [System.Text.Json.Nodes.JsonObject]) {
        Fail "worker entry must be a JSON object"
    }
    $workerObj = $workerNode.AsObject()
    if (-not $workerObj.ContainsKey("routing") -or $workerObj["routing"] -eq $null) {
        return
    }

    $routingNode = $workerObj["routing"]
    if ($routingNode -isnot [System.Text.Json.Nodes.JsonObject]) {
        Fail "worker routing must be a JSON object"
    }
    $routingObj = $routingNode.AsObject()

    if (-not $routingObj.ContainsKey("schema_version") -or $routingObj["schema_version"] -eq $null) {
        Fail "routing missing required schema_version"
    }
    $svNode = $routingObj["schema_version"]
    $svVal = 0
    $svOk = $false
    if ($svNode -is [System.Text.Json.Nodes.JsonValue]) {
        try {
            $elem = $svNode.GetValue[System.Text.Json.JsonElement]()
            if ($elem.ValueKind -eq [System.Text.Json.JsonValueKind]::Number -and $elem.TryGetInt32([ref]$svVal)) {
                $svOk = $true
            }
        } catch {}
    }
    if (-not $svOk -or $svVal -ne 1) {
        Fail "routing schema_version must be integer 1"
    }

    if (-not $routingObj.ContainsKey("attempts") -or $routingObj["attempts"] -eq $null -or $routingObj["attempts"] -isnot [System.Text.Json.Nodes.JsonArray]) {
        Fail "routing attempts must be an array"
    }
    $attemptsArr = $routingObj["attempts"].AsArray()
    if ($attemptsArr.Count -gt 2) {
        Fail "routing attempts cannot contain more than 2 attempts"
    }

    $knownRoles = @('scout', 'gate-author', 'implementer', 'reviewer', 'researcher', 'synthesizer', 'auditor')
    $knownModes = @('execution', 'repo-research', 'web-research')
    $knownStates = @('running', 'completed', 'failed', 'interrupted')
    $knownFailureClasses = @('none', 'quality', 'timeout', 'tool_error', 'quota', 'unknown')
    $knownVerStatuses = @('pending', 'passed', 'failed', 'not_performed')
    $geminiModelRegex = '^gemini-[a-zA-Z0-9.-]+-(low|medium|high)$'

    $seenAttemptNumbers = [System.Collections.Generic.HashSet[int]]::new()

    foreach ($attNode in $attemptsArr) {
        if ($attNode -isnot [System.Text.Json.Nodes.JsonObject]) {
            Fail "routing attempt must be a JSON object"
        }
        $attObj = $attNode.AsObject()

        $requiredAttemptKeys = @(
            'worker_id', 'role', 'mode', 'attempt', 'policy_revision',
            'route', 'model', 'effort', 'reason', 'started_at',
            'ended_at', 'duration_seconds', 'exit_code', 'state',
            'failure_class', 'evidence_paths', 'usage'
        )
        foreach ($k in $requiredAttemptKeys) {
            if (-not $attObj.ContainsKey($k)) {
                Fail "routing attempt missing required field: $k"
            }
        }
        if (-not $attObj.ContainsKey("verification_status") -and -not $attObj.ContainsKey("verification")) {
            Fail "routing attempt missing verification_status or verification field"
        }

        $wid = Get-NodeString $attObj["worker_id"]
        if ([string]::IsNullOrWhiteSpace($wid)) {
            Fail "attempt worker_id must be a non-empty string"
        }

        $roleVal = Get-NodeString $attObj["role"]
        if ($roleVal -notin $knownRoles) {
            Fail "attempt role must be one of: $($knownRoles -join ', ')"
        }

        $modeVal = Get-NodeString $attObj["mode"]
        if ($modeVal -notin $knownModes) {
            Fail "attempt mode must be one of: $($knownModes -join ', ')"
        }

        $attNumNode = $attObj["attempt"]
        $attNum = 0
        $attNumOk = $false
        if ($attNumNode -ne $null -and $attNumNode -is [System.Text.Json.Nodes.JsonValue]) {
            try {
                $elem = $attNumNode.GetValue[System.Text.Json.JsonElement]()
                if ($elem.ValueKind -eq [System.Text.Json.JsonValueKind]::Number -and $elem.TryGetInt32([ref]$attNum)) {
                    $attNumOk = $true
                }
            } catch {}
        }
        if (-not $attNumOk -or ($attNum -ne 1 -and $attNum -ne 2)) {
            Fail "attempt number must be integer 1 or 2"
        }
        if ($seenAttemptNumbers.Contains($attNum)) {
            Fail "duplicate attempt number $attNum in routing attempts"
        }
        $seenAttemptNumbers.Add($attNum) | Out-Null

        $polRev = Get-NodeString $attObj["policy_revision"]
        if ([string]::IsNullOrWhiteSpace($polRev)) {
            Fail "attempt policy_revision must be a non-empty string"
        }

        $routeVal = Get-NodeString $attObj["route"]
        if ($routeVal -notin @('default', 'quality-retry')) {
            Fail "attempt route must be 'default' or 'quality-retry'"
        }

        $modelVal = Get-NodeString $attObj["model"]
        if ($modelVal -eq $null -or $modelVal -notmatch $geminiModelRegex) {
            Fail "attempt model must be a Gemini model ID with effort suffix (matching '$geminiModelRegex')"
        }

        $effortVal = Get-NodeString $attObj["effort"]
        if ($effortVal -notin @('low', 'medium', 'high')) {
            Fail "attempt effort must be 'low', 'medium', or 'high'"
        }
        if (-not $modelVal.EndsWith("-$effortVal")) {
            Fail "attempt effort '$effortVal' does not match model suffix in '$modelVal'"
        }

        $reasonVal = Get-NodeString $attObj["reason"]
        if ([string]::IsNullOrWhiteSpace($reasonVal)) {
            Fail "attempt reason must be a non-empty string"
        }

        $startedVal = Get-NodeString $attObj["started_at"]
        if ([string]::IsNullOrWhiteSpace($startedVal)) {
            Fail "attempt started_at must be a non-empty string timestamp"
        }

        $endedNode = $attObj["ended_at"]
        if ($endedNode -ne $null) {
            $endedVal = Get-NodeString $endedNode
            if ([string]::IsNullOrWhiteSpace($endedVal)) {
                Fail "attempt ended_at must be a non-empty string timestamp or null"
            }
        }

        $durNode = $attObj["duration_seconds"]
        if ($durNode -ne $null) {
            if (-not (Test-Duration $durNode)) {
                Fail "attempt duration_seconds must be a non-negative number or null"
            }
        }

        $ecNode = $attObj["exit_code"]
        if ($ecNode -ne $null) {
            $ecVal = 0
            $ecOk = $false
            if ($ecNode -is [System.Text.Json.Nodes.JsonValue]) {
                try {
                    $elem = $ecNode.GetValue[System.Text.Json.JsonElement]()
                    if ($elem.ValueKind -eq [System.Text.Json.JsonValueKind]::Number -and $elem.TryGetInt32([ref]$ecVal)) {
                        $ecOk = $true
                    }
                } catch {}
            }
            if (-not $ecOk) {
                Fail "attempt exit_code must be an integer or null"
            }
        }

        $stateVal = Get-NodeString $attObj["state"]
        if ($stateVal -notin $knownStates) {
            Fail "attempt state must be one of: $($knownStates -join ', ')"
        }

        $fcVal = Get-NodeString $attObj["failure_class"]
        if ($fcVal -notin $knownFailureClasses) {
            Fail "attempt failure_class must be one of: $($knownFailureClasses -join ', ')"
        }

        $vNode = if ($attObj.ContainsKey("verification_status")) { $attObj["verification_status"] } else { $attObj["verification"] }
        $vVal = Get-NodeString $vNode
        if ($vVal -notin $knownVerStatuses) {
            Fail "attempt verification_status must be one of: $($knownVerStatuses -join ', ')"
        }

        $epNode = $attObj["evidence_paths"]
        if ($epNode -eq $null -or $epNode -isnot [System.Text.Json.Nodes.JsonArray]) {
            Fail "attempt evidence_paths must be an array"
        }
        foreach ($ep in $epNode.AsArray()) {
            $epStr = Get-NodeString $ep
            if ($epStr -eq $null) {
                Fail "attempt evidence_paths elements must be strings"
            }
        }

        $usageNode = $attObj["usage"]
        if ($usageNode -ne $null -and $usageNode -isnot [System.Text.Json.Nodes.JsonObject]) {
            Fail "attempt usage must be null or a JSON object with explicit units"
        }
    }
}

$requiredFields = @(
    'run_id', 'request_summary', 'selected_mode', 'profile', 'deep_trigger',
    'start_time', 'end_time', 'duration_seconds', 'scratch_path', 'workers',
    'repository_snapshot_paths', 'final_citations', 'audit_verdicts',
    'final_status', 'incomplete_stage_reasons'
)

$record = $null

if (-not [string]::IsNullOrEmpty($validateFile)) {
    $content = ""
    if ($validateFile -eq '-') {
        $content = [Console]::In.ReadToEnd()
    } else {
        if (-not (Test-Path -LiteralPath $validateFile -PathType Leaf)) {
            Fail "validation file does not exist: $validateFile"
        }
        $content = [System.IO.File]::ReadAllText($validateFile, [System.Text.Encoding]::UTF8)
    }
    try {
        $record = [System.Text.Json.Nodes.JsonNode]::Parse($content)
    } catch {
        Fail "failed to parse JSON in ${validateFile}: $($_.Exception.Message)"
    }
} else {
    # Build mode - check mandatory parameters
    $missingParams = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrEmpty($runId)) { $missingParams.Add("run_id") }
    if ([string]::IsNullOrEmpty($requestSummary)) { $missingParams.Add("request_summary") }
    if ([string]::IsNullOrEmpty($startTime)) { $missingParams.Add("start_time") }
    if ([string]::IsNullOrEmpty($endTime)) { $missingParams.Add("end_time") }
    if ([string]::IsNullOrEmpty($durationSeconds)) { $missingParams.Add("duration_seconds") }
    if ([string]::IsNullOrEmpty($scratchPath)) { $missingParams.Add("scratch_path") }
    if ([string]::IsNullOrEmpty($finalStatus)) { $missingParams.Add("final_status") }

    if ($missingParams.Count -gt 0) {
        Fail "missing mandatory build parameters: $($missingParams -join ', ')"
    }

    # If snapshot_paths was used instead of --snapshot-paths
    if ($snapshotPaths.Count -gt 0 -and [string]::IsNullOrEmpty($snapshotPathsJson)) {
        $arr = [System.Text.Json.Nodes.JsonArray]::new()
        foreach ($p in $snapshotPaths) {
            $arr.Add([System.Text.Json.Nodes.JsonValue]::Create($p))
        }
        $snapNode = $arr
    } else {
        $snapNode = Parse-JsonInput $snapshotPathsJson "repository_snapshot_paths" ([System.Text.Json.Nodes.JsonArray]::new())
    }

    $workersNode = Parse-JsonInput $workersJson "workers" ([System.Text.Json.Nodes.JsonArray]::new())
    $citsNode = Parse-JsonInput $finalCitationsJson "final_citations" ([System.Text.Json.Nodes.JsonArray]::new())
    $verdsNode = Parse-JsonInput $auditVerdictsJson "audit_verdicts" ([System.Text.Json.Nodes.JsonArray]::new())
    $incompNode = Parse-JsonInput $incompleteStageReasonsJson "incomplete_stage_reasons" ([System.Text.Json.Nodes.JsonArray]::new())

    $obj = [System.Text.Json.Nodes.JsonObject]::new()
    $obj["run_id"] = [System.Text.Json.Nodes.JsonValue]::Create($runId)
    $obj["request_summary"] = [System.Text.Json.Nodes.JsonValue]::Create($requestSummary)
    $obj["selected_mode"] = [System.Text.Json.Nodes.JsonValue]::Create($selectedMode)
    $obj["profile"] = [System.Text.Json.Nodes.JsonValue]::Create($profile)
    if ($deepTriggerSet -and -not [string]::IsNullOrEmpty($deepTrigger)) {
        $obj["deep_trigger"] = [System.Text.Json.Nodes.JsonValue]::Create($deepTrigger)
    } else {
        $obj["deep_trigger"] = $null
    }
    $obj["start_time"] = [System.Text.Json.Nodes.JsonValue]::Create($startTime)
    $obj["end_time"] = [System.Text.Json.Nodes.JsonValue]::Create($endTime)

    # Parse duration_seconds
    $intVal = 0L
    $doubleVal = 0.0
    if ([long]::TryParse($durationSeconds, [ref]$intVal)) {
        if ($intVal -lt 0) { Fail "duration_seconds must be a non-negative number" }
        $obj["duration_seconds"] = [System.Text.Json.Nodes.JsonValue]::Create($intVal)
    } elseif ([double]::TryParse($durationSeconds, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$doubleVal)) {
        if ($doubleVal -lt 0) { Fail "duration_seconds must be a non-negative number" }
        $obj["duration_seconds"] = [System.Text.Json.Nodes.JsonValue]::Create($doubleVal)
    } else {
        Fail "duration_seconds must be a non-negative number"
    }

    $obj["scratch_path"] = [System.Text.Json.Nodes.JsonValue]::Create($scratchPath)
    $obj["workers"] = $workersNode
    $obj["repository_snapshot_paths"] = $snapNode
    $obj["final_citations"] = $citsNode
    $obj["audit_verdicts"] = $verdsNode
    $obj["final_status"] = [System.Text.Json.Nodes.JsonValue]::Create($finalStatus)
    $obj["incomplete_stage_reasons"] = $incompNode

    $record = $obj
}

# Validation of $record
if ($record -isnot [System.Text.Json.Nodes.JsonObject]) {
    Fail "provenance record must be a JSON object"
}

$recordObj = $record.AsObject()
$missingKeys = [System.Collections.Generic.List[string]]::new()
foreach ($key in $requiredFields) {
    if (-not $recordObj.ContainsKey($key)) {
        $missingKeys.Add($key)
    }
}
if ($missingKeys.Count -gt 0) {
    Fail "missing mandatory provenance fields: $($missingKeys -join ', ')"
}

$selModeVal = Get-NodeString $recordObj["selected_mode"]
if ($selModeVal -notin @("execution", "repo-research", "web-research")) {
    Fail "selected_mode must be execution, repo-research, or web-research"
}

$profVal = Get-NodeString $recordObj["profile"]
if ($profVal -notin @("standard", "deep")) {
    Fail "profile must be standard or deep"
}

$dtNode = $recordObj["deep_trigger"]
if ($dtNode -ne $null) {
    $dtStr = Get-NodeString $dtNode
    if ($dtStr -eq $null) {
        Fail "deep_trigger must be a string or null"
    }
}

if (-not (Test-Duration $recordObj["duration_seconds"])) {
    Fail "duration_seconds must be a non-negative number"
}

$statusVal = Get-NodeString $recordObj["final_status"]
if ($statusVal -notin @("success", "partial", "failed")) {
    Fail "final_status must be success, partial, or failed"
}

$arrayFields = @("workers", "repository_snapshot_paths", "final_citations", "audit_verdicts", "incomplete_stage_reasons")
foreach ($af in $arrayFields) {
    if ($recordObj[$af] -isnot [System.Text.Json.Nodes.JsonArray]) {
        Fail "provenance field $af must be an array"
    }
}

foreach ($w in $recordObj["workers"].AsArray()) {
    Validate-WorkerRouting $w
}

$serializerOptions = [System.Text.Json.JsonSerializerOptions]::new()
$serializerOptions.WriteIndented = $true
$outputJson = $record.ToJsonString($serializerOptions)

if (-not [string]::IsNullOrEmpty($outputFile)) {
    $outDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($outputFile))
    if (-not [string]::IsNullOrEmpty($outDir) -and -not [System.IO.Directory]::Exists($outDir)) {
        [System.IO.Directory]::CreateDirectory($outDir) | Out-Null
    }
    [System.IO.File]::WriteAllText($outputFile, $outputJson + "`n", [System.Text.UTF8Encoding]::new($false))
} else {
    [Console]::Out.Write($outputJson + "`n")
}

exit 0
