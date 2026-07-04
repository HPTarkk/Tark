# Builds the Tark web guest app for release, interactively.
#
#   .\scripts\build-web-release.ps1
#
# Asks for everything it needs at run time; every prompt has a sensible
# default (just press Enter). Output lands in build\web, optionally with the
# static landing page bundled and the whole thing zipped for upload.

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Ask([string]$Question, [string]$Default) {
    $answer = Read-Host "$Question [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function AskYesNo([string]$Question, [bool]$Default) {
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $answer = Read-Host "$Question [$hint]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim().ToLower().StartsWith('y')
}

Write-Host ''
Write-Host '  TARK — web guest release build' -ForegroundColor Yellow
Write-Host '  ------------------------------' -ForegroundColor DarkYellow
Write-Host ''

# ── Gather props ────────────────────────────────────────────────────────────

# The public URL this build will be hosted at — the SAME url the mobile
# app's invite QR must point to (guest_config.dart / --dart-define). Baked
# into the build so the two always agree.
$guestUrl = Ask 'Guest app URL (where this build will be hosted)' 'https://tarkk.runflare.run'
$guestUrl = $guestUrl.TrimEnd('/')

# Suggest the base href from that URL's path: '/' for a root domain,
# '/tark/' for a project subpath (e.g. GitHub Pages).
$suggestedBase = '/'
try {
    $uriPath = ([System.Uri]$guestUrl).AbsolutePath
    if ($uriPath -and $uriPath -ne '/') { $suggestedBase = $uriPath }
} catch {}
if (-not $suggestedBase.EndsWith('/')) { $suggestedBase = "$suggestedBase/" }

$baseHref = Ask 'Base href (must start and end with /)' $suggestedBase
if (-not $baseHref.StartsWith('/')) { $baseHref = "/$baseHref" }
if (-not $baseHref.EndsWith('/')) { $baseHref = "$baseHref/" }

$includeLanding = AskYesNo 'Bundle the static landing page at /landing/?' $true
$makeZip = AskYesNo 'Zip the output for upload?' $true
$cleanFirst = AskYesNo 'Run "flutter clean" first (slow, use when in doubt)?' $false

# ── Build ───────────────────────────────────────────────────────────────────

if ($cleanFirst) {
    Write-Host "`n> flutter clean" -ForegroundColor Cyan
    flutter clean
    if ($LASTEXITCODE -ne 0) { throw 'flutter clean failed' }
}

$dartDefine = "GUEST_APP_URL=$guestUrl"
Write-Host "`n> flutter build web --release -t lib/main_guest.dart --base-href $baseHref --dart-define=$dartDefine" -ForegroundColor Cyan
flutter build web --release -t lib/main_guest.dart --base-href $baseHref --dart-define=$dartDefine
if ($LASTEXITCODE -ne 0) { throw 'flutter build web failed' }

$outDir = Join-Path $repoRoot 'build\web'

if ($includeLanding) {
    $landingSrc = Join-Path $repoRoot 'website'
    if (Test-Path $landingSrc) {
        $landingDst = Join-Path $outDir 'landing'
        Write-Host "> Bundling landing page -> /landing/" -ForegroundColor Cyan
        New-Item -ItemType Directory -Force $landingDst | Out-Null
        Copy-Item "$landingSrc\*" $landingDst -Recurse -Force
    } else {
        Write-Host '! website/ not found — skipping landing page' -ForegroundColor DarkYellow
    }
}

if ($makeZip) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $zipPath = Join-Path $repoRoot "build\tark-web-$stamp.zip"
    Write-Host "> Zipping -> $zipPath" -ForegroundColor Cyan
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path "$outDir\*" -DestinationPath $zipPath
}

# ── Done ────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  Build complete.' -ForegroundColor Green
Write-Host "  Output:  $outDir"
if ($makeZip) { Write-Host "  Zip:     $zipPath" }
if ($includeLanding) { Write-Host '  Landing: <host>/landing/' }
Write-Host ''
Write-Host '  Reminders:' -ForegroundColor DarkYellow
Write-Host "   * Host this at:  $guestUrl  (over HTTPS — mic needs a secure context)."
Write-Host '   * Build the MOBILE app with the SAME url so its invite QR matches:'
Write-Host "       flutter build apk --release --dart-define=GUEST_APP_URL=$guestUrl"
Write-Host '     (or set the default in lib/core/config/guest_config.dart).'
Write-Host ''
