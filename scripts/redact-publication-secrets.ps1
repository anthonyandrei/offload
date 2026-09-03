#!/usr/bin/env pwsh
# Recursively redact credential-shaped values at the publication boundary.
$ErrorActionPreference = 'Stop'; Set-StrictMode -Version 3.0
$inputFile=''; $outputFile=''
for ($i=0; $i -lt $args.Count; $i++) {
    switch ([string]$args[$i]) {
        '--input' { $i++; if ($i -ge $args.Count) { throw '--input requires a file' }; $inputFile=[string]$args[$i] }
        '--output' { $i++; if ($i -ge $args.Count) { throw '--output requires a file' }; $outputFile=[string]$args[$i] }
        default { throw "unknown argument: $($args[$i])" }
    }
}
if ([string]::IsNullOrWhiteSpace($inputFile) -or [string]::IsNullOrWhiteSpace($outputFile)) { throw 'usage: --input <json> --output <json>' }
function Redact-String([string]$value) {
    if ($null -eq $value) { return $null }
    $value=[regex]::Replace($value,'(?is)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----','[REDACTED]')
    $value=[regex]::Replace($value,'(?i)([?&](?:access_token|refresh_token|id_token|token|api[_-]?key|secret|password|key)=)[^&#\s"'']+','${1}[REDACTED]')
    $value=[regex]::Replace($value,'(?i)\b(Bearer)\s+[^\s,;]+','${1} [REDACTED]')
    $value=[regex]::Replace($value,'(?i)\b(password|secret|token|api[_-]?key)\s*([=:])\s*(?:"[^"]*"|''[^'']*''|[^\s,;&]+)','${1}${2}[REDACTED]')
    return [regex]::Replace($value,'(?i)\b(cookie|set-cookie)\s*:\s*[^\r\n]+','${1}: [REDACTED]')
}
function Redact-Node($node) {
    if ($null -eq $node) { return $null }
    if ($node -is [System.Text.Json.Nodes.JsonObject]) {
        foreach ($name in $node.AsObject().Keys) {
            $name = [string]$name
            if ($name -match '(?i)^(authorization|proxy-authorization|cookie|set-cookie|password|secret|token|api[_-]?key)$') {
                if ($null -eq $node[$name]) {
                    $node[$name] = [System.Text.Json.Nodes.JsonValue]::Create('[REDACTED]')
                } else {
                    [void]$node[$name].ReplaceWith('[REDACTED]')
                }
            } else {
                Redact-Node $node[$name] | Out-Null
            }
        }
        return
    }
    if ($node -is [System.Text.Json.Nodes.JsonArray]) {
        for ($index = 0; $index -lt $node.Count; $index++) {
            Redact-Node $node[$index] | Out-Null
        }
        return
    }
    try {
        $element = $node.GetValue[System.Text.Json.JsonElement]()
        if ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
            [void]$node.ReplaceWith((Redact-String $element.GetString()))
        }
    } catch {
        # Non-string scalar: leave it unchanged.
    }
}
$parsed=[System.Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($inputFile,[Text.Encoding]::UTF8))
$null=Redact-Node $parsed
$options=[System.Text.Json.JsonSerializerOptions]::new(); $options.WriteIndented=$true
$json=$parsed.ToJsonString($options)
$parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($outputFile)); if ($parent -and -not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText($outputFile,$json+"`n",[Text.UTF8Encoding]::new($false))
