#!/usr/bin/env pwsh
# Validate a saved artifact supporting a browser/headless claim.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
function Fail([string]$message) {
    [Console]::Out.WriteLine((([ordered]@{ status = 'unverified'; reason = $message }) | ConvertTo-Json -Compress))
    exit 1
}
$inputFile = ''; $scratchRoot = ''
for ($i = 0; $i -lt $args.Count; $i++) {
    switch ([string]$args[$i]) {
        '--input' { $i++; if ($i -ge $args.Count) { Fail '--input requires a file' }; $inputFile = [string]$args[$i] }
        '--scratch-root' { $i++; if ($i -ge $args.Count) { Fail '--scratch-root requires a directory' }; $scratchRoot = [string]$args[$i] }
        '--json' { }
        default { Fail "unknown argument: $($args[$i])" }
    }
}
if ([string]::IsNullOrWhiteSpace($inputFile) -or [string]::IsNullOrWhiteSpace($scratchRoot)) { Fail 'usage: --input <json> --scratch-root <dir> [--json]' }
try { $claim = Get-Content -LiteralPath $inputFile -Raw | ConvertFrom-Json } catch { Fail "invalid anchor JSON: $($_.Exception.Message)" }
$claimType = [string]$claim.claim_type
if ($claimType -notmatch '(?i)browser|headless|gui|render') {
    [Console]::Out.WriteLine((([ordered]@{ status = 'not_required'; reason = 'claim is not browser or headless' }) | ConvertTo-Json -Compress)); exit 0
}
$artifactType = [string]$claim.artifact_type; $artifactPath = [string]$claim.artifact_path
$claimText = ''; if ($claim.PSObject.Properties.Name -contains 'claim') { $claimText = [string]$claim.claim }
if ([string]::IsNullOrWhiteSpace($claimText) -and $claim.PSObject.Properties.Name -contains 'criterion') { $claimText = [string]$claim.criterion }
if ([string]::IsNullOrWhiteSpace($claimText)) { $claimText = $claimType }
if ([string]::IsNullOrWhiteSpace($artifactType) -or [string]::IsNullOrWhiteSpace($artifactPath) -or [string]::IsNullOrWhiteSpace($claimText)) { Fail 'browser/headless anchor requires artifact_type, artifact_path, and claim or criterion' }
try {
    $root = [IO.Path]::GetFullPath($scratchRoot)
    $candidate = if ([IO.Path]::IsPathRooted($artifactPath)) { [IO.Path]::GetFullPath($artifactPath) } else { [IO.Path]::GetFullPath([IO.Path]::Combine($root, $artifactPath)) }
} catch { Fail "could not resolve anchor path: $($_.Exception.Message)" }
$rootPrefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not ($candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or $candidate.Equals($root, [StringComparison]::OrdinalIgnoreCase))) { Fail "anchor path is outside scratch root: $candidate" }
if (-not [IO.File]::Exists($candidate)) { Fail "anchor artifact does not exist: $candidate" }
try { $attrs = [IO.File]::GetAttributes($candidate) } catch { Fail "cannot inspect anchor artifact: $candidate" }
if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail "anchor artifact must be a regular file: $candidate" }
[Console]::Out.WriteLine((([ordered]@{ status = 'verified'; artifact_type = $artifactType; artifact_path = $candidate; claim = $claimText }) | ConvertTo-Json -Compress))
exit 0
