#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'
if ($args.Count -lt 1) { exit 64 }
$counter = $args[0]
$mode = if ($args.Count -ge 2) { $args[1] } else { 'launch' }
$count = 0
if (Test-Path -LiteralPath $counter -PathType Leaf) {
    $count = [int]([IO.File]::ReadAllText($counter).Trim())
}
[IO.File]::WriteAllText($counter, [string]($count + 1) + [Environment]::NewLine)

switch ($mode) {
    'quality-failure' { exit 20 }
    'quality-escalate' {
        if ($count -ge 2) { exit 30 }
        exit 20
    }
    default { exit 17 }
}
