#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'
if ($args.Count -ne 1) { exit 64 }
$counter = $args[0]
$count = 0
if (Test-Path -LiteralPath $counter -PathType Leaf) {
    $count = [int]([IO.File]::ReadAllText($counter).Trim())
}
[IO.File]::WriteAllText($counter, [string]($count + 1) + [Environment]::NewLine)
exit 17
