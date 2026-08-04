# Builds the Tark Android app for Bazaar/Myket, interactively.
#
#   .\scripts\build-android.ps1
#
# Asks for everything it needs at run time; every prompt has a sensible
# default (just press Enter). Mirrors build-web-release.ps1 in style.
#
# The one thing this script exists to prevent: shipping a build with no
# billing key. billing.json is gitignored, so a fresh clone silently produces
# an app where every purchase path reports "unavailable" and nothing looks
# broken until a user tries to pay. That case is a hard stop below.

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

function Show-Size([string]$Path) {
    if (-not (Test-Path $Path)) { return '' }
    $mb = (Get-Item $Path).Length / 1MB
    return ('{0:N1} MB' -f $mb)
}

Write-Host ''
Write-Host '  TARK — Android release build' -ForegroundColor Yellow
Write-Host '  ----------------------------' -ForegroundColor DarkYellow
Write-Host ''

# ── Billing key (hard requirement) ──────────────────────────────────────────

# The RSA public key is a compile-time constant (String.fromEnvironment), so
# a missing or empty value cannot be detected at run time by anything except
# billing failing. Catch it here instead.
$billingFile = Join-Path $repoRoot 'billing.json'
if (-not (Test-Path $billingFile)) {
    Write-Host '  billing.json not found.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  It is gitignored on purpose (per-store keys), so a fresh clone'
    Write-Host '  will not have it. Create it at the repo root:'
    Write-Host ''
    Write-Host '    { "MYKET_RSA_KEY": "<key from the Myket developer panel>" }'
    Write-Host ''
    throw 'billing.json missing'
}

$billingKeys = Get-Content $billingFile -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($billingKeys.MYKET_RSA_KEY)) {
    throw 'billing.json has no MYKET_RSA_KEY — billing would be dead in this build'
}
Write-Host '  billing.json  OK' -ForegroundColor DarkGray

# ── Gather props ────────────────────────────────────────────────────────────

$isRelease = AskYesNo 'Release build? (No = debug)' $true
$mode = if ($isRelease) { 'release' } else { 'debug' }

$asBundle = $false
$splitPerAbi = $false
if ($isRelease) {
    $asBundle = AskYesNo 'Build an .aab app bundle instead of APKs?' $false
    if (-not $asBundle) {
        # The universal APK is ~116 MB because every ABI's native libs ride
        # along (Opus, RNNoise, WebRTC). Splitting is almost always what you
        # want for a store upload.
        $splitPerAbi = AskYesNo 'Split APKs per ABI (much smaller uploads)?' $true
    }
}

Write-Host ''
Write-Host '  A locked build forces every premium gate SHUT and runs BillingProbe'
Write-Host '  at startup, so the paywall and a real purchase can be tested without'
Write-Host '  waiting out the trial. Never upload one as a public release.' -ForegroundColor DarkYellow
$locked = AskYesNo 'Locked billing-test build?' $false

# Must match the URL the guest web app is actually hosted at, or the invite
# QR points somewhere that does not serve the app.
$guestUrl = Ask 'Guest app URL (baked into the invite QR)' 'https://app.tarkk.ir'
$guestUrl = $guestUrl.TrimEnd('/')

$cleanFirst = AskYesNo 'Run "flutter clean" first (slow, use when in doubt)?' $false

# ── Build ───────────────────────────────────────────────────────────────────

if ($cleanFirst) {
    Write-Host "`n> flutter clean" -ForegroundColor Cyan
    flutter clean
    if ($LASTEXITCODE -ne 0) { throw 'flutter clean failed' }

    Write-Host "> flutter pub get" -ForegroundColor Cyan
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }

    # Injectable/l10n output lives under lib/, not build/, so clean does not
    # remove it — but a clean is exactly when it is worth confirming the
    # generated graph matches the source that will be compiled.
    Write-Host "> dart run build_runner build" -ForegroundColor Cyan
    dart run build_runner build
    if ($LASTEXITCODE -ne 0) { throw 'build_runner failed' }
}

$target = if ($asBundle) { 'appbundle' } else { 'apk' }

$buildArgs = @('build', $target, "--$mode")
if ($splitPerAbi) { $buildArgs += '--split-per-abi' }
$buildArgs += "--dart-define-from-file=billing.json"
$buildArgs += "--dart-define=GUEST_APP_URL=$guestUrl"
if ($locked) { $buildArgs += '--dart-define=TARK_LOCK_PREMIUM=true' }

Write-Host "`n> flutter $($buildArgs -join ' ')" -ForegroundColor Cyan
& flutter @buildArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '  Build failed.' -ForegroundColor Red
    Write-Host '  If it complained about a missing libflutter.so under'
    Write-Host '  stripped_native_libs, that is stale output from a previous'
    Write-Host '  build — re-run and answer Yes to "flutter clean".' -ForegroundColor DarkYellow
    throw 'flutter build failed'
}

# ── Report ──────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  Build complete.' -ForegroundColor Green

if ($asBundle) {
    $aab = Join-Path $repoRoot "build\app\outputs\bundle\$mode\app-$mode.aab"
    Write-Host "  Bundle:  $aab  $(Show-Size $aab)"
} else {
    $apkDir = Join-Path $repoRoot 'build\app\outputs\flutter-apk'
    Get-ChildItem $apkDir -Filter "*$mode.apk" -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object {
            Write-Host ("  APK:     {0}  {1}" -f $_.FullName, (Show-Size $_.FullName))
        }
}

Write-Host ''
if ($locked) {
    Write-Host '  THIS IS A LOCKED TEST BUILD — do not publish it.' -ForegroundColor Red
    Write-Host '  Every premium feature is gated regardless of trial or purchase.'
    Write-Host ''
    Write-Host '  To test billing:' -ForegroundColor DarkYellow
    Write-Host '   1. Upload to Myket as a draft/test release.'
    Write-Host '   2. Install FROM Myket on a real device — billing only binds when'
    Write-Host '      the installer and signature match; a sideloaded APK will not.'
    Write-Host '   3. Watch the probe and the native handler:'
    Write-Host '        adb logcat -s flutter TarkBilling'
    Write-Host '   4. Open the paywall from Settings > transport, mute, or SHARE MUSIC.'
} else {
    Write-Host '  Reminders:' -ForegroundColor DarkYellow
    Write-Host "   * Guest URL baked in: $guestUrl — the web guest app must be live there."
    Write-Host '     (scripts\build-web-release.ps1 builds and bundles that side.)'
    Write-Host '   * Billing cannot be tested from a sideloaded APK. Install from the'
    Write-Host '     store, or re-run this script and answer Yes to the locked build.'
}
Write-Host ''
