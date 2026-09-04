#!/usr/bin/env pwsh
# tests/test_review_redaction_contract.ps1
# Acceptance gate verifying that publication redactors (PowerShell and Bash)
# redact credentials in JSON string diagnostics for Authorization Basic,
# Authorization Digest, Proxy-Authorization Negotiate, and arbitrary schemes,
# replacing sensitive credentials with [REDACTED] while preserving ordinary public text.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$script:TotalTests = 0
$script:FailedTests = 0

function Pass([string]$name) {
    $script:TotalTests++
    [Console]::Out.WriteLine("ok - $name")
}

function Fail([string]$name, [string]$reason = "") {
    $script:TotalTests++
    $script:FailedTests++
    $msg = if ($reason) { "FAIL: $name - $reason" } else { "FAIL: $name" }
    [Console]::Error.WriteLine($msg)
}

function Assert-True([bool]$condition, [string]$name, [string]$reason = "") {
    if ($condition) {
        Pass $name
    } else {
        Fail $name $(if ($reason) { $reason } else { "Condition was false" })
    }
}

function Assert-False([bool]$condition, [string]$name, [string]$reason = "") {
    if (-not $condition) {
        Pass $name
    } else {
        Fail $name $(if ($reason) { $reason } else { "Condition was true" })
    }
}

function Assert-Equal($actual, $expected, [string]$name) {
    if ($actual -eq $expected) {
        Pass $name
    } else {
        Fail $name "Expected '$expected', got '$actual'"
    }
}

$RootDir = Split-Path -Parent $PSScriptRoot
$ScriptsDir = Join-Path $RootDir 'scripts'
$PwshScript = Join-Path $ScriptsDir 'redact-publication-secrets.ps1'
$ShScript = Join-Path $ScriptsDir 'redact-publication-secrets.sh'

$PwshBin = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $PwshBin) {
    $PwshBin = (Get-Process -Id $PID).Path
}

function Find-BashBin {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($env:BASH_BIN) { $candidates.Add($env:BASH_BIN) }
    if ($IsWindows) {
        $candidates.Add('C:\Program Files\Git\bin\bash.exe')
        $candidates.Add('C:\Program Files\Git\usr\bin\bash.exe')
        $gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
        if ($gitCmd) {
            $gitDir = Split-Path -Parent (Split-Path -Parent $gitCmd.Source)
            $candidates.Add((Join-Path $gitDir 'bin\bash.exe'))
            $candidates.Add((Join-Path $gitDir 'usr\bin\bash.exe'))
        }
    }
    $pathBash = (Get-Command bash -ErrorAction SilentlyContinue)?.Source
    if ($pathBash) { $candidates.Add($pathBash) }
    $pathSh = (Get-Command sh -ErrorAction SilentlyContinue)?.Source
    if ($pathSh) { $candidates.Add($pathSh) }

    foreach ($c in $candidates) {
        if ([System.IO.File]::Exists($c)) {
            try {
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName = $c
                $psi.ArgumentList.Add('-c')
                $psi.ArgumentList.Add('exit 0')
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $proc = [System.Diagnostics.Process]::Start($psi)
                $proc.WaitForExit()
                if ($proc.ExitCode -eq 0) {
                    return $c
                }
            } catch {}
        }
    }
    return $null
}

$BashBin = Find-BashBin

Assert-True (Test-Path -LiteralPath $PwshScript -PathType Leaf) "PowerShell publication redactor script exists"
Assert-True (Test-Path -LiteralPath $ShScript -PathType Leaf) "Bash publication redactor script exists"
Assert-True ($null -ne $BashBin) "Bash interpreter is available for Bash redactor tests"

function Invoke-Redactor([string]$target, [string]$inputFile, [string]$outputFile) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    if ($target -eq 'pwsh') {
        $psi.FileName = $PwshBin
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-NonInteractive')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add($PwshScript)
        $psi.ArgumentList.Add('--input')
        $psi.ArgumentList.Add($inputFile)
        $psi.ArgumentList.Add('--output')
        $psi.ArgumentList.Add($outputFile)
    } elseif ($target -eq 'bash') {
        if (-not $BashBin) {
            Fail "bash execution" "Bash interpreter is unavailable"
            return $null
        }
        $psi.FileName = $BashBin
        $psi.ArgumentList.Add($ShScript.Replace('\', '/'))
        $psi.ArgumentList.Add('--input')
        $psi.ArgumentList.Add($inputFile.Replace('\', '/'))
        $psi.ArgumentList.Add('--output')
        $psi.ArgumentList.Add($outputFile.Replace('\', '/'))
    } else {
        throw "Unsupported target redactor: $target"
    }

    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Stdout   = $stdout
        Stderr   = $stderr
    }
}

# Credentials to verify redaction against
$basicSecret1 = 'dXNlcm5hbWU6c3VwZXJfc2VjcmV0X3Bhc3N3b3JkXzEyMw=='
$basicSecret2 = 'c2VjcmV0X2Jhc2ljX3Rva2VuXzk4NzY1'
$digestSecret1 = '8ca523f5e9506fed4657c9700eebdbec'
$digestNonce = 'dcd98b7102dd2f0e8b11d0f600bfb0c093'
$digestSecret2 = 'digest_secret_response_hash_777888'
$negotiateSecret1 = 'YWxhZGRpbjpvcGVuc2VzYW1lX2tlcmJlcm9zX3NlY3JldA=='
$negotiateSecret2 = 'c2VjcmV0X25lZ290aWF0ZV90b2tlbl80NTY3'
$arbitrarySecret1 = 'custom_arbitrary_auth_secret_token_12345'
$arbitrarySecret2 = 'proxy_arbitrary_auth_secret_token_67890'
$arbitrarySecret3 = 'arbitrary_hawk_secret_mac_key_9999'

# Ordinary public text to verify preservation
$publicPrefix = 'HTTP transaction failed during upstream handshake:'
$publicSuffix = '- please verify network connectivity and target endpoint'
$publicHost = 'https://api.internal.example.org/v2/resources'
$publicMessage = 'Authentication challenge rejected by remote service'
$publicRequestId = 'req-trace-id-public-8877'
$publicStatusCode = 401
$publicNegativeNote = 'Diagnostic completed normally with no authentication headers present'

$TmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('offload-test-redact-contract-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($TmpRoot) | Out-Null

try {
    $targets = @('pwsh', 'bash')

    foreach ($target in $targets) {
        $suiteName = "$target redactor"

        # -------------------------------------------------------------------
        # Test 1: Combined JSON diagnostic containing all four auth schemes:
        # - Authorization Basic
        # - Authorization Digest
        # - Proxy-Authorization Negotiate
        # - Arbitrary scheme
        # -------------------------------------------------------------------
        $fixtureCombined = [ordered]@{
            request_id   = $publicRequestId
            status_code  = $publicStatusCode
            summary      = $publicMessage
            target_url   = $publicHost
            diagnostics  = @(
                "$publicPrefix Authorization: Basic $basicSecret1 $publicSuffix",
                "Trace diagnostic: Authorization Basic $basicSecret2 in plain header format",
                "Challenge diagnostic: Authorization: Digest username=`"admin`", realm=`"api-realm`", nonce=`"$digestNonce`", uri=`"/api/v2`", response=`"$digestSecret1`", qop=auth",
                "Alternative digest diagnostic: Authorization Digest username=`"service`", response=`"$digestSecret2`"",
                "Proxy diagnostic: Proxy-Authorization: Negotiate $negotiateSecret1 (proxy.internal.corp)",
                "Plain proxy diagnostic: Proxy-Authorization Negotiate $negotiateSecret2",
                "Arbitrary auth scheme: Authorization: CustomScheme $arbitrarySecret1 in auth header",
                "Arbitrary proxy scheme: Proxy-Authorization: CustomProxyScheme $arbitrarySecret2 in header",
                "Arbitrary hawk scheme: Authorization Hawk id=`"hawk-user`", mac=`"$arbitrarySecret3`""
            )
            nested = [ordered]@{
                detail_diagnostic = "Nested log: Authorization: Basic $basicSecret1 was supplied"
                public_context    = "Nested public context should remain intact"
            }
            public_footer = "End of report for $publicRequestId"
        }

        $inputCombined = Join-Path $TmpRoot "$target-combined-in.json"
        $outputCombined = Join-Path $TmpRoot "$target-combined-out.json"
        [IO.File]::WriteAllText($inputCombined, ($fixtureCombined | ConvertTo-Json -Depth 10), $Utf8NoBom)

        $res1 = Invoke-Redactor $target $inputCombined $outputCombined
        Assert-Equal $res1.ExitCode 0 "${suiteName}: combined fixture exits 0"
        Assert-True (Test-Path -LiteralPath $outputCombined -PathType Leaf) "${suiteName}: combined output file created"

        if (Test-Path -LiteralPath $outputCombined -PathType Leaf) {
            $rawCombined = [IO.File]::ReadAllText($outputCombined, [System.Text.Encoding]::UTF8)

            # Assert output is valid JSON
            $parsedCombined = $null
            try {
                $parsedCombined = $rawCombined | ConvertFrom-Json
                Pass "${suiteName}: combined output parses as valid JSON"
            } catch {
                Fail "${suiteName}: combined output parses as valid JSON" "JSON parse failed: $_"
            }

            # 1. Assert credentials are absent
            Assert-False ($rawCombined.Contains($basicSecret1)) "${suiteName}: Authorization Basic credential 1 is absent" "Secret survived: $basicSecret1"
            Assert-False ($rawCombined.Contains($basicSecret2)) "${suiteName}: Authorization Basic credential 2 is absent" "Secret survived: $basicSecret2"
            Assert-False ($rawCombined.Contains($digestSecret1)) "${suiteName}: Authorization Digest credential 1 is absent" "Secret survived: $digestSecret1"
            Assert-False ($rawCombined.Contains($digestSecret2)) "${suiteName}: Authorization Digest credential 2 is absent" "Secret survived: $digestSecret2"
            Assert-False ($rawCombined.Contains($negotiateSecret1)) "${suiteName}: Proxy-Authorization Negotiate credential 1 is absent" "Secret survived: $negotiateSecret1"
            Assert-False ($rawCombined.Contains($negotiateSecret2)) "${suiteName}: Proxy-Authorization Negotiate credential 2 is absent" "Secret survived: $negotiateSecret2"
            Assert-False ($rawCombined.Contains($arbitrarySecret1)) "${suiteName}: Arbitrary scheme credential 1 is absent" "Secret survived: $arbitrarySecret1"
            Assert-False ($rawCombined.Contains($arbitrarySecret2)) "${suiteName}: Arbitrary scheme credential 2 is absent" "Secret survived: $arbitrarySecret2"
            Assert-False ($rawCombined.Contains($arbitrarySecret3)) "${suiteName}: Arbitrary scheme credential 3 is absent" "Secret survived: $arbitrarySecret3"

            # 2. Assert redacted marker is present
            Assert-True ($rawCombined.Contains('[REDACTED]')) "${suiteName}: redacted marker [REDACTED] is present in combined output" "Marker [REDACTED] not found"

            # 3. Assert ordinary public text is preserved
            Assert-True ($rawCombined.Contains($publicPrefix)) "${suiteName}: public prefix preserved in combined output" "Missing: $publicPrefix"
            Assert-True ($rawCombined.Contains($publicSuffix)) "${suiteName}: public suffix preserved in combined output" "Missing: $publicSuffix"
            Assert-True ($rawCombined.Contains($publicHost)) "${suiteName}: public host URL preserved in combined output" "Missing: $publicHost"
            Assert-True ($rawCombined.Contains($publicMessage)) "${suiteName}: public message preserved in combined output" "Missing: $publicMessage"
            Assert-True ($rawCombined.Contains($publicRequestId)) "${suiteName}: public request ID preserved in combined output" "Missing: $publicRequestId"
            Assert-True ($rawCombined.Contains("Nested public context should remain intact")) "${suiteName}: nested public context preserved" "Missing nested context"
            Assert-True ($rawCombined.Contains("End of report for $publicRequestId")) "${suiteName}: public footer preserved" "Missing footer"

            if ($null -ne $parsedCombined) {
                Assert-Equal $parsedCombined.request_id $publicRequestId "${suiteName}: request_id property value preserved"
                Assert-Equal $parsedCombined.status_code $publicStatusCode "${suiteName}: status_code numeric value preserved"
                Assert-Equal $parsedCombined.summary $publicMessage "${suiteName}: summary property value preserved"
                Assert-Equal $parsedCombined.target_url $publicHost "${suiteName}: target_url property value preserved"
            }
        }

        # -------------------------------------------------------------------
        # Test 2: Individual scheme isolation fixtures
        # -------------------------------------------------------------------

        # 2a: Authorization Basic isolation
        $fixtureBasic = [ordered]@{
            diagnostic = "Connection error: Authorization: Basic $basicSecret1 while accessing endpoint"
            public_info = "Ordinary public note for Basic auth"
        }
        $inBasic = Join-Path $TmpRoot "$target-basic-in.json"
        $outBasic = Join-Path $TmpRoot "$target-basic-out.json"
        [IO.File]::WriteAllText($inBasic, ($fixtureBasic | ConvertTo-Json), $Utf8NoBom)
        $resBasic = Invoke-Redactor $target $inBasic $outBasic
        Assert-Equal $resBasic.ExitCode 0 "${suiteName}: basic isolation exits 0"
        if (Test-Path -LiteralPath $outBasic -PathType Leaf) {
            $rawBasic = [IO.File]::ReadAllText($outBasic, [System.Text.Encoding]::UTF8)
            Assert-False ($rawBasic.Contains($basicSecret1)) "${suiteName}: isolated Authorization Basic credential absent" "Secret survived: $basicSecret1"
            Assert-True ($rawBasic.Contains('[REDACTED]')) "${suiteName}: isolated Authorization Basic contains [REDACTED]"
            Assert-True ($rawBasic.Contains("Connection error:")) "${suiteName}: isolated Authorization Basic preserves prefix"
            Assert-True ($rawBasic.Contains("while accessing endpoint")) "${suiteName}: isolated Authorization Basic preserves suffix"
            Assert-True ($rawBasic.Contains("Ordinary public note for Basic auth")) "${suiteName}: isolated Authorization Basic preserves public field"
        }

        # 2b: Authorization Digest isolation
        $fixtureDigest = [ordered]@{
            diagnostic = "Challenge: Authorization: Digest username=`"admin`", nonce=`"$digestNonce`", response=`"$digestSecret1`" received"
            public_info = "Ordinary public note for Digest auth"
        }
        $inDigest = Join-Path $TmpRoot "$target-digest-in.json"
        $outDigest = Join-Path $TmpRoot "$target-digest-out.json"
        [IO.File]::WriteAllText($inDigest, ($fixtureDigest | ConvertTo-Json), $Utf8NoBom)
        $resDigest = Invoke-Redactor $target $inDigest $outDigest
        Assert-Equal $resDigest.ExitCode 0 "${suiteName}: digest isolation exits 0"
        if (Test-Path -LiteralPath $outDigest -PathType Leaf) {
            $rawDigest = [IO.File]::ReadAllText($outDigest, [System.Text.Encoding]::UTF8)
            Assert-False ($rawDigest.Contains($digestSecret1)) "${suiteName}: isolated Authorization Digest response credential absent" "Secret survived: $digestSecret1"
            Assert-True ($rawDigest.Contains('[REDACTED]')) "${suiteName}: isolated Authorization Digest contains [REDACTED]"
            Assert-True ($rawDigest.Contains("Challenge:")) "${suiteName}: isolated Authorization Digest preserves prefix"
            Assert-True ($rawDigest.Contains("received")) "${suiteName}: isolated Authorization Digest preserves suffix"
            Assert-True ($rawDigest.Contains("Ordinary public note for Digest auth")) "${suiteName}: isolated Authorization Digest preserves public field"
        }

        # 2c: Proxy-Authorization Negotiate isolation
        $fixtureNegotiate = [ordered]@{
            diagnostic = "Proxy failure: Proxy-Authorization: Negotiate $negotiateSecret1 rejected by gateway"
            public_info = "Ordinary public note for Negotiate auth"
        }
        $inNegotiate = Join-Path $TmpRoot "$target-negotiate-in.json"
        $outNegotiate = Join-Path $TmpRoot "$target-negotiate-out.json"
        [IO.File]::WriteAllText($inNegotiate, ($fixtureNegotiate | ConvertTo-Json), $Utf8NoBom)
        $resNegotiate = Invoke-Redactor $target $inNegotiate $outNegotiate
        Assert-Equal $resNegotiate.ExitCode 0 "${suiteName}: negotiate isolation exits 0"
        if (Test-Path -LiteralPath $outNegotiate -PathType Leaf) {
            $rawNegotiate = [IO.File]::ReadAllText($outNegotiate, [System.Text.Encoding]::UTF8)
            Assert-False ($rawNegotiate.Contains($negotiateSecret1)) "${suiteName}: isolated Proxy-Authorization Negotiate credential absent" "Secret survived: $negotiateSecret1"
            Assert-True ($rawNegotiate.Contains('[REDACTED]')) "${suiteName}: isolated Proxy-Authorization Negotiate contains [REDACTED]"
            Assert-True ($rawNegotiate.Contains("Proxy failure:")) "${suiteName}: isolated Proxy-Authorization Negotiate preserves prefix"
            Assert-True ($rawNegotiate.Contains("rejected by gateway")) "${suiteName}: isolated Proxy-Authorization Negotiate preserves suffix"
            Assert-True ($rawNegotiate.Contains("Ordinary public note for Negotiate auth")) "${suiteName}: isolated Proxy-Authorization Negotiate preserves public field"
        }

        # 2d: Arbitrary scheme isolation
        $fixtureArbitrary = [ordered]@{
            diagnostic = "Gateway notice: Authorization: CustomScheme $arbitrarySecret1 denied"
            public_info = "Ordinary public note for arbitrary scheme"
        }
        $inArbitrary = Join-Path $TmpRoot "$target-arbitrary-in.json"
        $outArbitrary = Join-Path $TmpRoot "$target-arbitrary-out.json"
        [IO.File]::WriteAllText($inArbitrary, ($fixtureArbitrary | ConvertTo-Json), $Utf8NoBom)
        $resArbitrary = Invoke-Redactor $target $inArbitrary $outArbitrary
        Assert-Equal $resArbitrary.ExitCode 0 "${suiteName}: arbitrary scheme isolation exits 0"
        if (Test-Path -LiteralPath $outArbitrary -PathType Leaf) {
            $rawArbitrary = [IO.File]::ReadAllText($outArbitrary, [System.Text.Encoding]::UTF8)
            Assert-False ($rawArbitrary.Contains($arbitrarySecret1)) "${suiteName}: isolated arbitrary scheme credential absent" "Secret survived: $arbitrarySecret1"
            Assert-True ($rawArbitrary.Contains('[REDACTED]')) "${suiteName}: isolated arbitrary scheme contains [REDACTED]"
            Assert-True ($rawArbitrary.Contains("Gateway notice:")) "${suiteName}: isolated arbitrary scheme preserves prefix"
            Assert-True ($rawArbitrary.Contains("denied")) "${suiteName}: isolated arbitrary scheme preserves suffix"
            Assert-True ($rawArbitrary.Contains("Ordinary public note for arbitrary scheme")) "${suiteName}: isolated arbitrary scheme preserves public field"
        }

        # -------------------------------------------------------------------
        # Test 3: Negative fixture (clean public diagnostic, no credentials)
        # -------------------------------------------------------------------
        $fixtureNegative = [ordered]@{
            diagnostic = $publicNegativeNote
            status = "healthy"
            count = 42
        }
        $inNegative = Join-Path $TmpRoot "$target-negative-in.json"
        $outNegative = Join-Path $TmpRoot "$target-negative-out.json"
        [IO.File]::WriteAllText($inNegative, ($fixtureNegative | ConvertTo-Json), $Utf8NoBom)
        $resNegative = Invoke-Redactor $target $inNegative $outNegative
        Assert-Equal $resNegative.ExitCode 0 "${suiteName}: negative fixture exits 0"
        if (Test-Path -LiteralPath $outNegative -PathType Leaf) {
            $rawNegative = [IO.File]::ReadAllText($outNegative, [System.Text.Encoding]::UTF8)
            Assert-False ($rawNegative.Contains('[REDACTED]')) "${suiteName}: negative fixture introduces no false redaction markers"
            Assert-True ($rawNegative.Contains($publicNegativeNote)) "${suiteName}: negative fixture preserves diagnostic note"
            Assert-True ($rawNegative.Contains("healthy")) "${suiteName}: negative fixture preserves status"
            Assert-True ($rawNegative.Contains("42")) "${suiteName}: negative fixture preserves count"
        }
    }
} finally {
    if (Test-Path -LiteralPath $TmpRoot) {
        Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:FailedTests -gt 0) {
    [Console]::Error.WriteLine("`n$($script:FailedTests) of $($script:TotalTests) tests failed.")
    exit 1
}

[Console]::Out.WriteLine("`nAll $($script:TotalTests) tests passed.")
exit 0
