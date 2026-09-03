#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$failed = $false
function Pass([string]$n) { "ok - $n" }
function Check([bool]$ok, [string]$n, [string]$why) { if ($ok) { Pass $n } else { $script:failed = $true; [Console]::Error.WriteLine("FAIL: $n - $why") } }
function Run([string]$file, [string[]]$a) {
    $p = [Diagnostics.ProcessStartInfo]::new(); $p.FileName = (Get-Command pwsh).Source
    foreach ($x in (@('-NoProfile','-NonInteractive','-File',$file) + $a)) { [void]$p.ArgumentList.Add($x) }
    $p.RedirectStandardOutput = $true; $p.RedirectStandardError = $true; $p.UseShellExecute = $false; $p.CreateNoWindow = $true
    $q = [Diagnostics.Process]::Start($p); $o = $q.StandardOutput.ReadToEnd(); $e = $q.StandardError.ReadToEnd(); $q.WaitForExit()
    [pscustomobject]@{ ExitCode = $q.ExitCode; Out = $o; Err = $e }
}
$root = Split-Path -Parent $PSScriptRoot
$anchor = Join-Path $root 'scripts/check-reality-anchor.ps1'; $anchorSh = Join-Path $root 'scripts/check-reality-anchor.sh'
$redact = Join-Path $root 'scripts/redact-publication-secrets.ps1'; $redactSh = Join-Path $root 'scripts/redact-publication-secrets.sh'
Check (Test-Path $anchor -PathType Leaf) 'anchor PowerShell helper exists' 'missing helper'
Check (Test-Path $anchorSh -PathType Leaf) 'anchor Bash helper exists' 'missing helper'
Check (Test-Path $redact -PathType Leaf) 'redaction PowerShell helper exists' 'missing helper'
Check (Test-Path $redactSh -PathType Leaf) 'redaction Bash helper exists' 'missing helper'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('offload-evidence-' + [guid]::NewGuid().ToString('N')); $in = Join-Path $tmp 'in'; New-Item -ItemType Directory -Path $in -Force | Out-Null
$inside = Join-Path $in 'capture.png'; [IO.File]::WriteAllBytes($inside, [byte[]](1,2,3)); $outside = Join-Path ([IO.Path]::GetTempPath()) ('outside-' + [guid]::NewGuid().ToString('N') + '.png'); [IO.File]::WriteAllBytes($outside, [byte[]](4,5,6))
$valid = Join-Path $tmp 'valid.json'; $bad = Join-Path $tmp 'bad.json'; $missing = Join-Path $tmp 'missing.json'; $plain = Join-Path $tmp 'plain.json'
@{claim_type='browser';artifact_type='screenshot';artifact_path=$inside}|ConvertTo-Json|Set-Content $valid
@{claim_type='browser';artifact_type='screenshot';artifact_path=$outside}|ConvertTo-Json|Set-Content $bad
@{claim_type='browser';artifact_type='screenshot';artifact_path=(Join-Path $in 'none.png')}|ConvertTo-Json|Set-Content $missing
@{claim_type='text';text='ordinary finding'}|ConvertTo-Json|Set-Content $plain
if (Test-Path $anchor -PathType Leaf) {
    $r = Run $anchor @('--input',$valid,'--scratch-root',$tmp,'--json'); Check ($r.ExitCode -eq 0 -and $r.Out -match '"status"\s*:\s*"verified"') 'anchor accepts in-scratch regular file' "exit=$($r.ExitCode) $($r.Err)"
    $r = Run $anchor @('--input',$bad,'--scratch-root',$tmp,'--json'); Check ($r.ExitCode -ne 0 -and $r.Out -notmatch '"status"\s*:\s*"verified"') 'anchor rejects out-of-scope file' 'unexpected verified result'
    $r = Run $anchor @('--input',$missing,'--scratch-root',$tmp,'--json'); Check ($r.ExitCode -ne 0) 'anchor rejects missing file' 'unexpected success'
    $r = Run $anchor @('--input',$plain,'--scratch-root',$tmp,'--json'); Check ($r.ExitCode -eq 0) 'anchor permits non-browser claim without anchor' "exit=$($r.ExitCode)"
}
$secret = 'super-secret-value-7f8a'; $positive = Join-Path $tmp 'positive.json'; $positiveOut = Join-Path $tmp 'positive.out.json'; $negative = Join-Path $tmp 'negative.json'; $negativeOut = Join-Path $tmp 'negative.out.json'
@{url="https://example.com/report?token=$secret&view=public";authorization="Bearer $secret";cookie="session=$secret";api_key=$secret;token_count=3;public_label='kept'}|ConvertTo-Json|Set-Content $positive
@{url='https://example.com/report?view=public';token_count=3;public_label='kept'}|ConvertTo-Json|Set-Content $negative
if (Test-Path $redact -PathType Leaf) {
    $r = Run $redact @('--input',$positive,'--output',$positiveOut); $t = if (Test-Path $positiveOut) {[IO.File]::ReadAllText($positiveOut)} else {''}
    Check ($r.ExitCode -eq 0) 'redaction positive fixture succeeds' "exit=$($r.ExitCode) $($r.Err)"; Check ($t -notmatch [regex]::Escape($secret)) 'redaction removes secret value' 'secret survived'; Check ($t -match '\[REDACTED\]') 'redaction uses stable marker' 'marker missing'; Check ($t -match 'token_count' -and $t -match '3') 'redaction preserves token_count' 'normal field changed'
    $r = Run $redact @('--input',$negative,'--output',$negativeOut); $t = [IO.File]::ReadAllText($negativeOut); Check ($r.ExitCode -eq 0 -and $t -match 'view=public' -and $t -match 'token_count') 'redaction preserves public negative fixture' "exit=$($r.ExitCode)"
}
Remove-Item $tmp,$outside -Recurse -Force -ErrorAction SilentlyContinue
if ($failed) { exit 1 }; exit 0
