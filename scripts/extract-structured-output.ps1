#!/usr/bin/env pwsh
# scripts/extract-structured-output.ps1
# Extracts structured_output from worker JSON results.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Show-Usage {
    [Console]::Error.WriteLine("Usage: extract-structured-output.ps1 [--array] RESULT.json...")
}

function Fail([string]$message, [int]$exitCode = 2) {
    [Console]::Error.WriteLine("ERROR: $message")
    exit $exitCode
}

$arrayMode = $false
$filePaths = [System.Collections.Generic.List[string]]::new()

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    if ($arg -eq '--array') {
        $arrayMode = $true
    } elseif ($arg -eq '-h' -or $arg -eq '--help') {
        Show-Usage
        exit 0
    } else {
        $filePaths.Add($arg)
    }
    $i++
}

if ($filePaths.Count -eq 0) {
    Show-Usage
    Fail "no result files specified"
}

$extractedOutputs = [System.Collections.Generic.List[string]]::new()

foreach ($filePath in $filePaths) {
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Fail "result file not found: $filePath"
    }

    $rawContent = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8)

    $rootNode = $null
    try {
        $rootNode = [System.Text.Json.Nodes.JsonNode]::Parse($rawContent)
    } catch {
        Fail "malformed JSON in file: $filePath ($($_.Exception.Message))"
    }

    if ($rootNode -isnot [System.Text.Json.Nodes.JsonObject]) {
        Fail "JSON root must be an object: $filePath"
    }

    $rootObj = $rootNode.AsObject()
    if (-not $rootObj.ContainsKey("structured_output")) {
        Fail "structured_output property missing in file: $filePath"
    }

    $soNode = $rootObj["structured_output"]
    if ($soNode -eq $null) {
        [void]$extractedOutputs.Add("null")
    } else {
        [void]$extractedOutputs.Add($soNode.ToJsonString())
    }
}

if ($arrayMode) {
    $jsonArray = [System.Text.Json.Nodes.JsonArray]::new()
    foreach ($item in $extractedOutputs) {
        [void]$jsonArray.Add([System.Text.Json.Nodes.JsonNode]::Parse($item))
    }
    Write-Output $jsonArray.ToJsonString()
} else {
    foreach ($item in $extractedOutputs) {
        Write-Output $item
    }
}

exit 0
