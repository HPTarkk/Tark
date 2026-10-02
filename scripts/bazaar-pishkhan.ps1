# Cafe Bazaar's Pishkhan API: puts a release on Bazaar without the web panel.
#
#   .\scripts\bazaar-pishkhan.ps1 status              last published / committed / draft release
#   .\scripts\bazaar-pishkhan.ps1 upload 1.1.1        draft release from build\release\1.1.1
#   .\scripts\bazaar-pishkhan.ps1 commit              send the draft to Bazaar for review
#   .\scripts\bazaar-pishkhan.ps1 delete              delete the draft (only before commit)
#
# release-common.ps1 dot-sources this file and runs "upload" at the end of a
# release, so a normal release leaves a processed draft on Bazaar. Sending it
# for review is always a separate, deliberate "commit".
#
# ── How Pishkhan works ──────────────────────────────────────────────────────
# A release starts as a draft ("uncommitted"). The AAB route is: create the
# draft, upload the .aab, upload the bundlesigner .bin made from that same
# .aab, then poll bundle-status (at most once a minute, Bazaar asks) until
# Bazaar has built the APKs. "commit" sends the draft for review with its
# changelog; with auto_publish it goes live as soon as review passes,
# otherwise someone presses "publish" in the panel afterwards. Only one draft
# exists at a time, and it can be deleted until it is committed.
#
# ── The token ───────────────────────────────────────────────────────────────
# $env:PISHKHAN_API_TOKEN when set (CI), otherwise the .PISHKHAN file at the
# repo root (gitignored). One token belongs to one app. It only ever travels
# in the CAFEBAZAAR-PISHKHAN-API-SECRET header and is never printed.
#
# $env:PISHKHAN_API_URL overrides the endpoint, for testing against a mock.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'upload', 'commit', 'delete')]
    [string]$Command,

    # upload: the release under build\release\ to send (default: pubspec.yaml's).
    [Parameter(Position = 1)]
    [string]$Version,

    # commit: the "what's new" text Bazaar users see.
    [string]$ChangelogFa,
    [string]$ChangelogEn,
    # commit: a note for Bazaar's reviewers only.
    [string]$DeveloperNote = '',
    [ValidateRange(1, 100)]
    [int]$Rollout = 100,
    # commit: go live by itself once review passes.
    [switch]$AutoPublish,

    # upload: delete a draft already on Bazaar instead of stopping.
    [switch]$ReplaceDraft
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$pishkhanRoot = Split-Path -Parent $PSScriptRoot
$pishkhanBaseUrl = if ($env:PISHKHAN_API_URL) { $env:PISHKHAN_API_URL.TrimEnd('/') }
                   else { 'https://api.pishkhan.cafebazaar.ir/v1' }
$pishkhanHeader = 'CAFEBAZAAR-PISHKHAN-API-SECRET'

# Bazaar asks for no more than one bundle-status call a minute.
$pishkhanPollSeconds = if ($env:PISHKHAN_POLL_SECONDS) { [int]$env:PISHKHAN_POLL_SECONDS } else { 60 }
$pishkhanPollLimitMinutes = 60

# ── Token ───────────────────────────────────────────────────────────────────

function Test-PishkhanToken {
    if ($env:PISHKHAN_API_TOKEN) { return $true }
    return (Test-Path (Join-Path $pishkhanRoot '.PISHKHAN'))
}

function Get-PishkhanToken {
    if ($env:PISHKHAN_API_TOKEN) {
        $token = $env:PISHKHAN_API_TOKEN
        $from = 'PISHKHAN_API_TOKEN'
    } else {
        $path = Join-Path $pishkhanRoot '.PISHKHAN'
        if (-not (Test-Path $path)) {
            throw "no Pishkhan token: put it in $path or set PISHKHAN_API_TOKEN"
        }
        $token = [System.IO.File]::ReadAllText($path)
        $from = '.PISHKHAN'
    }
    # The file may end in a newline or carry a BOM; the token itself never
    # has whitespace.
    $token = $token.Trim().TrimStart([char]0xFEFF)
    if (-not $token -or $token -match '\s') {
        throw "the Pishkhan token in $from is empty or spans more than one line"
    }
    return $token
}

# ── HTTP ────────────────────────────────────────────────────────────────────

# A form part. Content-Disposition is set by hand: .NET would also add a
# filename* parameter, which not every server parses.
function New-PishkhanFilePart([string]$Name, [string]$Path, [string]$ContentType) {
    $part = New-Object System.Net.Http.StreamContent([System.IO.File]::OpenRead($Path))
    $part.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue($ContentType)
    $disposition = New-Object System.Net.Http.Headers.ContentDispositionHeaderValue('form-data')
    $disposition.Name = "`"$Name`""
    $disposition.FileName = "`"$([System.IO.Path]::GetFileName($Path))`""
    $part.Headers.ContentDisposition = $disposition
    return $part
}

function New-PishkhanTextPart([string]$Name, [string]$Value) {
    $part = New-Object System.Net.Http.StringContent($Value)
    $part.Headers.ContentType = $null
    $disposition = New-Object System.Net.Http.Headers.ContentDispositionHeaderValue('form-data')
    $disposition.Name = "`"$Name`""
    $part.Headers.ContentDisposition = $disposition
    return $part
}

# One call. $Body is a hashtable sent as JSON; $Files maps a form field to a
# file, with $Fields as extra form text. Returns the parsed JSON answer, or
# throws with Bazaar's own "type: message". A 429 waits and retries.
function Invoke-Pishkhan {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Body,
        [hashtable]$Files,
        [hashtable]$Fields,
        [hashtable]$FileTypes
    )
    $token = Get-PishkhanToken
    $url = "$pishkhanBaseUrl/$Path"
    $client = New-Object System.Net.Http.HttpClient
    # An .aab is tens of MB and the link to Bazaar can be slow.
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    try {
        for ($attempt = 1; ; $attempt++) {
            $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new($Method), $url)
            [void]$request.Headers.TryAddWithoutValidation($pishkhanHeader, $token)
            [void]$request.Headers.TryAddWithoutValidation('Accept', 'application/json')
            if ($Files) {
                $form = New-Object System.Net.Http.MultipartFormDataContent
                if ($Fields) {
                    foreach ($key in $Fields.Keys) { $form.Add((New-PishkhanTextPart $key ([string]$Fields[$key]))) }
                }
                foreach ($key in $Files.Keys) {
                    $type = if ($FileTypes -and $FileTypes[$key]) { $FileTypes[$key] } else { 'application/octet-stream' }
                    $form.Add((New-PishkhanFilePart $key $Files[$key] $type))
                }
                $request.Content = $form
            } elseif ($Body) {
                $json = $Body | ConvertTo-Json -Depth 5 -Compress
                $request.Content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, 'application/json')
            }

            try {
                $response = $client.SendAsync($request).GetAwaiter().GetResult()
            } catch {
                $inner = $_.Exception
                while ($inner.InnerException) { $inner = $inner.InnerException }
                throw "Pishkhan $Method $Path`: $($inner.Message)"
            } finally {
                $request.Dispose()
            }
            $status = [int]$response.StatusCode
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $response.Dispose()

            $answer = $null
            if ($text) { try { $answer = $text | ConvertFrom-Json } catch { } }

            if ($status -eq 429 -and $attempt -lt 5) {
                $wait = 30 * $attempt
                Write-Host "  Pishkhan says too many requests — waiting ${wait}s." -ForegroundColor DarkGray
                Start-Sleep -Seconds $wait
                continue
            }
            if ($status -ge 200 -and $status -lt 300) { return $answer }

            $why = if ($answer -and $answer.message) { "$($answer.type): $($answer.message)" }
                   elseif ($text) { $text.Substring(0, [Math]::Min(300, $text.Length)) }
                   else { 'no body' }
            if ($status -eq 403) { $why += ' (is the token right, and for this app?)' }
            throw "Pishkhan $Method $Path`: HTTP $status — $why"
        }
    } finally {
        $client.Dispose()
    }
}

# ── The API, one function per endpoint ──────────────────────────────────────

# last-published / last-committed / last-uncommitted. $null when there is none.
function Get-BazaarRelease([ValidateSet('published', 'committed', 'uncommitted')][string]$Which) {
    $answer = Invoke-Pishkhan GET "apps/releases/last-$Which/"
    if ($answer.type -eq 'success') { return $answer.release }
    return $null
}

function New-BazaarRelease { (Invoke-Pishkhan POST 'apps/releases/').release }

function Remove-BazaarRelease { [void](Invoke-Pishkhan DELETE 'apps/releases/') }

# The plain-APK route; Tark ships an AAB, but the endpoint is here for
# completeness. Architecture is all, armeabi-v7a or arm64-v8a.
function Add-BazaarApk([string]$Apk, [ValidateSet('all', 'armeabi-v7a', 'arm64-v8a')][string]$Architecture = 'all') {
    (Invoke-Pishkhan POST 'apps/releases/upload/' -Files @{ apk = $Apk } -Fields @{ architecture = $Architecture } `
        -FileTypes @{ apk = 'application/vnd.android.package-archive' }).package
}

function Add-BazaarAab([string]$Aab) {
    $answer = Invoke-Pishkhan POST 'apps/releases/upload-aab/' -Files @{ aab = $Aab }
    foreach ($w in @($answer.warnings)) { if ($w) { Write-Host "  Bazaar warning: $w" -ForegroundColor Yellow } }
    return $answer.bundle
}

function Add-BazaarBin([string]$Bin) {
    (Invoke-Pishkhan POST 'apps/releases/upload-bin/' -Files @{ file = $Bin }).bundle
}

function Get-BazaarBundleStatus { (Invoke-Pishkhan GET 'apps/releases/bundle-status/').bundle }

function Submit-BazaarRelease {
    param(
        [string]$ChangelogFa,
        [string]$ChangelogEn,
        [string]$DeveloperNote = '',
        [int]$Rollout = 100,
        [bool]$AutoPublish = $false
    )
    $body = @{
        changelog_fa              = $ChangelogFa
        changelog_en              = $ChangelogEn
        developer_note            = $DeveloperNote
        staged_rollout_percentage = $Rollout
        auto_publish              = $AutoPublish
    }
    (Invoke-Pishkhan POST 'apps/releases/commit/' -Body $body).release
}

# ── Flows ───────────────────────────────────────────────────────────────────

# U: .aab in, waiting for the .bin. S: .bin in, queued. P: processing.
# D: done. E: failed.
function Wait-BazaarBundle {
    $deadline = (Get-Date).AddMinutes($pishkhanPollLimitMinutes)
    while ($true) {
        $bundle = Get-BazaarBundleStatus
        switch ($bundle.state) {
            'D' { Write-Host '  Bazaar has processed the bundle.' -ForegroundColor Green; return $bundle }
            'E' {
                $errors = @($bundle.errors) | Where-Object { $_ } | ForEach-Object { "    $_" }
                throw "Bazaar could not process the bundle:`n$($errors -join "`n")"
            }
            'U' { throw 'Bazaar still waits for the .bin — upload it first' }
        }
        if ((Get-Date) -gt $deadline) {
            throw "Bazaar is still processing after $pishkhanPollLimitMinutes minutes (state $($bundle.state)); check later with: .\scripts\bazaar-pishkhan.ps1 status"
        }
        $what = if ($bundle.state -eq 'S') { 'queued' } else { 'processing' }
        Write-Host "  Bundle $what — checking again in ${pishkhanPollSeconds}s." -ForegroundColor DarkGray
        Start-Sleep -Seconds $pishkhanPollSeconds
    }
}

# The one .bin bundlesigner wrote into bin\.
function Find-BazaarBin([string]$BinDir) {
    $bins = @(Get-ChildItem $BinDir -Filter '*.bin' -File -ErrorAction SilentlyContinue)
    if ($bins.Count -ne 1) {
        throw "expected exactly one .bin in $BinDir, found $($bins.Count)"
    }
    return $bins[0].FullName
}

function Format-BazaarRelease($Release) {
    if (-not $Release) { return 'none' }
    $packages = @($Release.packages) | Where-Object { $_ } |
        ForEach-Object { "$($_.version_name) ($($_.version_code))" }
    $what = if ($packages) { $packages -join ', ' } else { 'no package yet' }
    # PowerShell 7 turns the ISO date into a DateTime; 5.1 leaves the text.
    $created = $Release.creation_date
    $created = if ($created -is [datetime]) { $created.ToString('yyyy-MM-dd HH:mm') }
               else { ([string]$created -replace 'T', ' ' -replace ':\d\d(\.\d+)?$', '') }
    $parts = @($what, "created $created")
    if ($null -ne $Release.staged_rollout_percentage) { $parts += "rollout $($Release.staged_rollout_percentage)%" }
    if ($Release.auto_publish) { $parts += 'auto-publish' }
    return $parts -join ' · '
}

function Show-BazaarStatus {
    Write-Host ''
    Write-Host "  Last published   $(Format-BazaarRelease (Get-BazaarRelease published))"
    Write-Host "  Last committed   $(Format-BazaarRelease (Get-BazaarRelease committed))"
    Write-Host "  Draft            $(Format-BazaarRelease (Get-BazaarRelease uncommitted))"
}

# A processed draft on Bazaar from a built .aab and its bin\. Nothing is sent
# for review. Asks before deleting a draft that is already there, unless
# -ReplaceDraft.
function Publish-BazaarDraft([string]$Aab, [string]$BinDir, [bool]$ReplaceDraft = $false) {
    if (-not (Test-Path $Aab)) { throw "$Aab not found" }
    $bin = Find-BazaarBin $BinDir

    $existing = Get-BazaarRelease uncommitted
    if ($existing) {
        Write-Host "  Bazaar already has a draft: $(Format-BazaarRelease $existing)" -ForegroundColor Yellow
        if (-not $ReplaceDraft) {
            $answer = Read-Host '  Delete it and upload this build instead? [y/N]'
            if (-not ($answer -and $answer.Trim().ToLower().StartsWith('y'))) {
                throw 'Bazaar already has a draft; left it as it is'
            }
        }
        Remove-BazaarRelease
        Write-Host '  Deleted the old draft.' -ForegroundColor DarkGray
    }

    Write-Host '  Creating the draft release.'
    [void](New-BazaarRelease)
    Write-Host "  Uploading $([System.IO.Path]::GetFileName($Aab)) ($('{0:N1} MB' -f ((Get-Item $Aab).Length / 1MB)))."
    [void](Add-BazaarAab $Aab)
    Write-Host "  Uploading $([System.IO.Path]::GetFileName($bin))."
    [void](Add-BazaarBin $bin)
    [void](Wait-BazaarBundle)
    Write-Host "  Draft on Bazaar: $(Format-BazaarRelease (Get-BazaarRelease uncommitted))" -ForegroundColor Green
}

function Read-Changelog([string]$Language) {
    Write-Host "  What's new ($Language). End with an empty line:"
    $lines = @()
    while ($true) {
        $line = Read-Host ' '
        if (-not $line) { break }
        $lines += $line
    }
    return ($lines -join "`n")
}

# ── Command line ────────────────────────────────────────────────────────────

# Dot-sourced (release-common.ps1): define the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Command) {
    Get-Content $PSCommandPath | Select-Object -Skip 1 -First 6 | ForEach-Object { $_ -replace '^# ?', '' }
    return
}

switch ($Command) {
    'status' { Show-BazaarStatus }

    'upload' {
        if (-not $Version) {
            $line = Get-Content (Join-Path $pishkhanRoot 'pubspec.yaml') |
                Where-Object { $_ -match '^version:\s*\S' } | Select-Object -First 1
            $Version = (($line -replace '^version:\s*', '') -replace '[+-].*$', '').Trim()
        }
        $outDir = Join-Path $pishkhanRoot "build\release\$Version"
        Publish-BazaarDraft (Join-Path $outDir 'Tarkk.aab') (Join-Path $outDir 'bin') $ReplaceDraft.IsPresent
        Write-Host '  Send it for review with: .\scripts\bazaar-pishkhan.ps1 commit'
    }

    'commit' {
        $draft = Get-BazaarRelease uncommitted
        if (-not $draft) { throw 'Bazaar has no draft to send — upload one first' }
        if (-not $PSBoundParameters.ContainsKey('ChangelogFa')) { $ChangelogFa = Read-Changelog 'Persian' }
        if (-not $PSBoundParameters.ContainsKey('ChangelogEn')) { $ChangelogEn = Read-Changelog 'English' }

        Write-Host ''
        Write-Host "  Draft         $(Format-BazaarRelease $draft)"
        Write-Host "  Rollout       $Rollout%"
        Write-Host "  After review  $(if ($AutoPublish) { 'goes live by itself' } else { 'waits for you to press publish in Pishkhan' })"
        Write-Host '  Changelog fa:'; $ChangelogFa -split "`n" | ForEach-Object { Write-Host "    $_" }
        Write-Host '  Changelog en:'; $ChangelogEn -split "`n" | ForEach-Object { Write-Host "    $_" }
        # Committing cannot be undone from here: the draft is gone and Bazaar
        # starts reviewing. So it takes a typed word, not just Enter.
        $answer = Read-Host "  Type 'send' to send this release to Bazaar for review"
        if ($answer.Trim() -ne 'send') { throw 'not sent' }
        $release = Submit-BazaarRelease -ChangelogFa $ChangelogFa -ChangelogEn $ChangelogEn `
            -DeveloperNote $DeveloperNote -Rollout $Rollout -AutoPublish $AutoPublish.IsPresent
        Write-Host "  Sent for review: $(Format-BazaarRelease $release)" -ForegroundColor Green
    }

    'delete' {
        $draft = Get-BazaarRelease uncommitted
        if (-not $draft) { Write-Host '  Bazaar has no draft.'; return }
        Write-Host "  Draft: $(Format-BazaarRelease $draft)"
        $answer = Read-Host '  Delete it? [y/N]'
        if ($answer -and $answer.Trim().ToLower().StartsWith('y')) {
            Remove-BazaarRelease
            Write-Host '  Deleted.' -ForegroundColor Green
        }
    }
}
