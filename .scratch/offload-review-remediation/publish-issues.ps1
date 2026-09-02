$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$repo = 'anthonyandrei/offload'
$root = $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $root 'tickets.json') -Raw | ConvertFrom-Json
$revision = 'cfc9f4edc219b199c5c243c95f91fa2c463d137d'
$baseUrl = "https://github.com/$repo"
$publicationDir = Join-Path $root 'github'
New-Item -ItemType Directory -Path $publicationDir -Force | Out-Null

function Invoke-GhChecked {
    param([string[]]$GhArgs)
    $result = & gh @GhArgs
    if ($LASTEXITCODE -ne 0) { throw "gh failed with exit $LASTEXITCODE for $($GhArgs[0])" }
    return $result
}

$existingLabels = @(Invoke-GhChecked @('label','list','--repo',$repo,'--limit','100','--json','name') | ConvertFrom-Json)
foreach ($definition in @(
    @{ name = 'ready-for-agent'; color = '0E8A16'; description = 'No outstanding prerequisite issues; scoped and ready for implementation' },
    @{ name = 'review-remediation'; color = '5319E7'; description = 'Confirmed findings from the 2026-09-03 whole-skill review' }
)) {
    if ($definition.name -notin @($existingLabels.name)) {
        Invoke-GhChecked @('label','create',$definition.name,'--repo',$repo,'--color',$definition.color,'--description',$definition.description) | Out-Null
    }
}

$existing = @(Invoke-GhChecked @('issue','list','--repo',$repo,'--state','all','--limit','200','--json','number,title,body,url,labels') | ConvertFrom-Json)
$published = [ordered]@{}
foreach ($ticket in $manifest.tickets) {
    $marker = "<!-- offload-review-remediation:$($ticket.id) -->"
    $matches = @($existing | Where-Object { $_.body.Contains($marker) })
    if ($matches.Count -gt 1) { throw "Duplicate publication markers for ticket $($ticket.id)" }
    if ($matches.Count -eq 1) {
        $published[$ticket.id] = [ordered]@{ id = $ticket.id; number = $matches[0].number; url = $matches[0].url; title = $ticket.title }
    }
}

function Resolve-TicketReferences {
    param([string]$Text)
    $Text = $Text.Replace("the audit's uninvoked-test-blocks.json", 'the Source evidence section below')
    $Text = [regex]::Replace($Text, '(?i)\btickets (\d{2}) (and|through) (\d{2})\b', {
        param($match)
        $first = $match.Groups[1].Value
        $last = $match.Groups[3].Value
        if ($published.Contains($first) -and $published.Contains($last)) {
            $ids = if ($match.Groups[2].Value -eq 'through') { @([int]$first..[int]$last | ForEach-Object { '{0:D2}' -f $_ }) } else { @($first, $last) }
            return (@($ids | ForEach-Object { "#$($published[$_].number)" }) -join ', ')
        }
        return $match.Value
    })
    return [regex]::Replace($Text, '(?i)\bticket (\d{2})\b', {
        param($match)
        $id = $match.Groups[1].Value
        if ($published.Contains($id)) { return "#$($published[$id].number)" }
        return "remediation ticket $id"
    })
}

function New-IssueBody {
    param($Ticket)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<!-- offload-review-remediation:$($Ticket.id) -->")
    $lines.Add('')
    $blockers = @($Ticket.blocked | ForEach-Object {
        if (-not $published.Contains($_)) { throw "Missing published blocker $_" }
        "#$($published[$_].number)"
    })
    $lines.Add($(if ($blockers.Count) { 'Blocked by: ' + ($blockers -join ', ') } else { 'Blocked by: None' }))
    $lines.Add('')
    $lines.Add("Priority: $($Ticket.priority). Review findings: $($Ticket.findings -join ', '). Remediation ticket $($Ticket.id) of 14.")
    $lines.Add('')
    $lines.Add("Reviewed 2026-09-03 against [$($revision.Substring(0,7))]($baseUrl/commit/$revision).")
    foreach ($section in @(
        @{ heading = 'Problem'; content = $Ticket.problem },
        @{ heading = 'Deliverable'; content = $Ticket.deliverable }
    )) {
        $lines.Add(''); $lines.Add("## $($section.heading)"); $lines.Add('')
        $lines.Add((Resolve-TicketReferences $section.content))
    }
    $lines.Add(''); $lines.Add('## Acceptance criteria'); $lines.Add('')
    foreach ($criterion in $Ticket.accept) { $lines.Add('- [ ] ' + (Resolve-TicketReferences $criterion)) }
    $lines.Add(''); $lines.Add('## Source evidence'); $lines.Add('')
    foreach ($reference in $Ticket.refs) {
        $parts = $reference -split ':'
        $lines.Add("- [$reference]($baseUrl/blob/$revision/$($parts[0])#L$($parts[1]))")
    }
    if ($Ticket.id -eq '01') {
        $groups = Get-Content -LiteralPath (Join-Path $root 'evidence/uninvoked-test-blocks.json') -Raw | ConvertFrom-Json
        $ranges = @($groups | ForEach-Object { "$($_.start)-$($_.end)" }) -join ', '
        $lines.Add('')
        $lines.Add("The audit identified these 50 uninvoked script-block line ranges in the linked test file at the reviewed revision: $ranges.")
    }
    $lines.Add(''); $lines.Add('## Implementation pointers'); $lines.Add('')
    foreach ($file in $Ticket.files) {
        $kind = if ($file.EndsWith('/')) { 'tree' } else { 'blob' }
        $lines.Add("- [$file]($baseUrl/$kind/$revision/$file)")
    }
    $lines.Add(''); $lines.Add('New helper or test filenames under listed directories are implementation choices.')
    $lines.Add(''); $lines.Add('## Verification'); $lines.Add('')
    $lines.Add((Resolve-TicketReferences $Ticket.verify))
    $lines.Add(''); $lines.Add('## Scope and constraints'); $lines.Add('')
    $lines.Add((Resolve-TicketReferences $Ticket.limits))
    $lines.Add('')
    $lines.Add('- Work in the source repository. Do not update installed skill copies as part of this issue.')
    $lines.Add('- Preserve the Gemini model policy, role routing, maximum two attempts, and immediate quota handoff.')
    $lines.Add('- Preserve Bash 3.2+ compatibility and native PowerShell 7 support. Add no Windows requirement for Bash, Python, or jq.')
    $lines.Add('- Keep the root SKILL.md router below 500 lines; place detailed workflow contracts in the mode documents or supporting files.')
    $lines.Add('- Use fake workers and disposable repositories for regressions. Verify resolved cleanup paths stay inside the test root.')
    $lines.Add('- Shared-file edits still require serialized integration even when issues have no dependency edge.')
    $lines.Add('- Do not use the existing shared-tree offload execution workflow for these fixes until its migration is complete. Use direct orchestration or independently verified isolated checkouts.')
    $lines.Add('')
    $lines.Add('The original review exercised PowerShell 7 and Git Bash on Windows. Native Linux, macOS, and Bash 3.2 were not exercised. Record the platforms used for this issue rather than claiming untested parity.')
    return ($lines -join "`n") + "`n"
}

foreach ($ticket in $manifest.tickets) {
    if ($published.Contains($ticket.id)) { continue }
    $bodyPath = Join-Path $publicationDir "$($ticket.id)-body.md"
    New-IssueBody $ticket | Set-Content -LiteralPath $bodyPath -Encoding utf8 -NoNewline
    $labels = if ($ticket.blocked.Count -eq 0) { 'bug,review-remediation,ready-for-agent' } else { 'bug,review-remediation' }
    $url = [string](Invoke-GhChecked @('issue','create','--repo',$repo,'--title',"[$($ticket.priority)] $($ticket.title)",'--body-file',$bodyPath,'--label',$labels))
    $url = $url.Trim()
    if ($url -notmatch '/issues/(\d+)$') { throw "Could not parse created issue URL: $url" }
    $published[$ticket.id] = [ordered]@{ id = $ticket.id; number = [int]$Matches[1]; url = $url; title = $ticket.title }
    @($published.Values) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'github-issues.json') -Encoding utf8
    Write-Output "$($ticket.id): $url"
}

# Resolve references to later tickets after all issue numbers exist.
foreach ($ticket in $manifest.tickets) {
    $bodyPath = Join-Path $publicationDir "$($ticket.id)-body.md"
    $body = New-IssueBody $ticket
    $oldBody = Get-Content -LiteralPath $bodyPath -Raw
    if ($body -cne $oldBody) {
        $body | Set-Content -LiteralPath $bodyPath -Encoding utf8 -NoNewline
        Invoke-GhChecked @('issue','edit',[string]$published[$ticket.id].number,'--repo',$repo,'--body-file',$bodyPath) | Out-Null
    }
}

$remote = @(Invoke-GhChecked @('issue','list','--repo',$repo,'--state','all','--label','review-remediation','--limit','100','--json','number,title,body,url,labels,state') | ConvertFrom-Json)
foreach ($ticket in $manifest.tickets) {
    $actual = @($remote | Where-Object { $_.number -eq $published[$ticket.id].number })
    if ($actual.Count -ne 1 -or $actual[0].state -ne 'OPEN') { throw "Missing open issue $($ticket.id)" }
    $expectedBody = New-IssueBody $ticket
    if ($actual[0].body.TrimEnd() -cne $expectedBody.TrimEnd()) { throw "Remote body mismatch for $($ticket.id)" }
    $ready = 'ready-for-agent' -in @($actual[0].labels.name)
    if ($ready -ne ($ticket.blocked.Count -eq 0)) { throw "Incorrect ready label for $($ticket.id)" }
}
[ordered]@{ status = 'verified'; repository = $repo; issues = $published.Count; ready = @($manifest.tickets | Where-Object { $_.blocked.Count -eq 0 }).Count; verified_at = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'github-publication.json') -Encoding utf8
Write-Output 'Verified all 14 remote issue bodies, open states, dependencies, and readiness labels.'
