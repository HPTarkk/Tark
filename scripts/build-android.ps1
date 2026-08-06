# Builds the Tark Android app for Bazaar/Myket, interactively — and optionally
# cuts the GitHub release for it in the same run.
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
#
# ── Release model ───────────────────────────────────────────────────────────
# Answer Yes to "Publish" and this script also tags and uploads.
#
# There is ONE permanent release branch per major version, and a release is an
# annotated tag on it — never a branch of its own. Both names come from
# pubspec.yaml, so bumping the version there is how you cut a release:
#
#   version: 1.0.10+11  ->  branch release/1.0.0   tag v1.0.10
#   version: 1.4.2+18   ->  branch release/1.0.0   tag v1.4.2
#   version: 2.0.0+20   ->  branch release/2.0.0   tag v2.0.0
#
# Only the MAJOR reaches the branch name; the whole line lives on one branch.
# A bugfix for a shipped version is therefore a commit on that branch plus the
# next tag, and a new major opens a new branch the first time it is published.
#
# Nothing is tagged, pushed or published until the build has succeeded. A
# failed build therefore leaves no orphan tag and no assetless release to go
# clean up by hand.

$ErrorActionPreference = 'Stop'

# PowerShell 7.3+ turns a non-zero native exit code into a terminating error
# while ErrorActionPreference is Stop. Several probes below ("does this tag
# exist?", "does this release exist?") answer *no* with a non-zero exit, so opt
# out and keep checking $LASTEXITCODE by hand as this script always has.
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# The asset name every release uses. Keep it stable — people link to it.
$assetName = 'Tarkk.apk'

# Reads pubspec.yaml and derives everything named after the version: the tag,
# and the release branch for its major line. Called again after any branch
# switch, because a different branch can carry a different version.
function Get-PubspecVersion {
    $line = (Get-Content (Join-Path $repoRoot 'pubspec.yaml')) |
        Where-Object { $_ -match '^version:\s*\S' } |
        Select-Object -First 1
    if (-not ($line -match '^version:\s*(?<name>[^\s+]+)(?:\+(?<code>\d+))?\s*$')) {
        throw "could not parse the version out of pubspec.yaml (found: '$line')"
    }
    # Read both captures out before the next -match clobbers $Matches.
    $name = $Matches['name']
    $code = $Matches['code']

    if (-not ($name -match '^(?<major>\d+)\.')) {
        throw "version '$name' in pubspec.yaml does not start with a major number"
    }
    $major = $Matches['major']

    return [pscustomobject]@{
        Name   = $name
        Code   = $code
        Major  = $major
        Tag    = "v$name"
        Branch = "release/$major.0.0"
    }
}

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

# Multi-line free text, finished with an empty line. Used for the tag message,
# which doubles as the GitHub release body.
function AskLines([string]$Prompt, [string]$Default) {
    Write-Host ''
    Write-Host "  $Prompt" -ForegroundColor Yellow
    Write-Host '  One line per paragraph. Finish with an empty line.' -ForegroundColor DarkGray
    Write-Host '  Enter on the first line accepts:' -ForegroundColor DarkGray
    Write-Host "    $Default" -ForegroundColor DarkGray
    Write-Host ''
    $lines = @()
    while ($true) {
        $line = Read-Host '  >'
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        $lines += $line.Trim()
    }
    if ($lines.Count -eq 0) { return $Default }
    return ($lines -join "`n`n")
}

function Show-Size([string]$Path) {
    if (-not (Test-Path $Path)) { return '' }
    $mb = (Get-Item $Path).Length / 1MB
    return ('{0:N1} MB' -f $mb)
}

# Echo then run, and fail loudly. Every git/gh mutation goes through this so a
# half-finished publish is always visible in the transcript.
function Run([string]$Exe, [string[]]$Arguments, [string]$What) {
    Write-Host "> $Exe $($Arguments -join ' ')" -ForegroundColor Cyan
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$What failed" }
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

# ── Version (names the tag and the release branch) ──────────────────────────

$v = Get-PubspecVersion
$versionName = $v.Name
$versionCode = $v.Code
$tag = $v.Tag
$releaseBranch = $v.Branch

Write-Host ''
Write-Host "  version   $versionName" -NoNewline
if ($versionCode) {
    Write-Host "  (versionCode $versionCode)" -ForegroundColor DarkGray
} else {
    Write-Host ''
}
Write-Host "  tag       $tag" -ForegroundColor DarkGray
Write-Host "  branch    $releaseBranch" -ForegroundColor DarkGray

# ── Gather props ────────────────────────────────────────────────────────────

$isRelease = AskYesNo 'Release build? (No = debug)' $true
$mode = if ($isRelease) { 'release' } else { 'debug' }

$locked = $false
if ($isRelease) {
    Write-Host ''
    Write-Host '  A locked build forces every premium gate SHUT and runs BillingProbe'
    Write-Host '  at startup, so the paywall and a real purchase can be tested without'
    Write-Host '  waiting out the trial. Never upload one as a public release.' -ForegroundColor DarkYellow
    $locked = AskYesNo 'Locked billing-test build?' $false
}

# Publishing a debug or locked build would put a knowingly broken artifact
# behind a public download link, so the question is not even asked for those.
$publish = $false
if ($isRelease -and -not $locked) {
    Write-Host ''
    Write-Host '  Publishing tags this commit on ' -NoNewline
    Write-Host $releaseBranch -ForegroundColor Yellow -NoNewline
    Write-Host " and uploads $assetName to the"
    Write-Host '  matching GitHub release. Tag name comes from pubspec.yaml. Nothing is'
    Write-Host '  pushed unless the build succeeds.'
    $publish = AskYesNo 'Publish this build as a GitHub release?' $false
}

$asBundle = $false
$splitPerAbi = $false
if ($isRelease -and -not $publish) {
    $asBundle = AskYesNo 'Build an .aab app bundle instead of APKs?' $false
    if (-not $asBundle) {
        # The universal APK is ~116 MB because every ABI's native libs (Opus,
        # RNNoise, WebRTC) ride along. Splitting is almost always what you
        # want for a store upload.
        $splitPerAbi = AskYesNo 'Split APKs per ABI (much smaller uploads)?' $true
    }
}
if ($publish) {
    # A release carries one asset that works on any device, matching every
    # release before it — so no bundle, no splits, no questions.
    Write-Host ''
    Write-Host "  Publishing, so the build is forced to a single universal APK" -ForegroundColor DarkGray
    Write-Host "  (~116 MB) to upload as $assetName." -ForegroundColor DarkGray
}

# ── Release preflight, part 1: tools and branch ─────────────────────────────
#
# Everything that can fail is checked BEFORE the multi-minute build.

if ($publish) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git not found on PATH' }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'gh (GitHub CLI) not found on PATH — needed to create the release'
    }

    gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'gh is not authenticated — run: gh auth login' }

    # An annotated tag has to describe a commit that actually exists. Tagging a
    # dirty tree would name a build that no one else can reproduce.
    $dirty = git status --porcelain
    if ($dirty) {
        Write-Host ''
        Write-Host '  Working tree is not clean:' -ForegroundColor Red
        $dirty | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host ''
        Write-Host '  Commit (or stash) first — the tag must point at a real commit.' -ForegroundColor DarkYellow
        throw 'uncommitted changes'
    }

    $currentBranch = (git rev-parse --abbrev-ref HEAD).Trim()
    if ($currentBranch -ne $releaseBranch) {
        Write-Host ''
        Write-Host "  You are on '$currentBranch', but releases are tagged on '$releaseBranch'." -ForegroundColor DarkYellow
        if (-not (AskYesNo "Switch to $releaseBranch?" $true)) {
            throw "not on $releaseBranch — aborted before building"
        }

        git show-ref --verify --quiet "refs/heads/$releaseBranch"
        $localExists = ($LASTEXITCODE -eq 0)
        git ls-remote --exit-code --heads origin $releaseBranch 2>&1 | Out-Null
        $remoteExists = ($LASTEXITCODE -eq 0)

        if ($localExists) {
            Run 'git' @('checkout', $releaseBranch) 'git checkout'
        } elseif ($remoteExists) {
            Run 'git' @('checkout', '-b', $releaseBranch, '--track', "origin/$releaseBranch") 'git checkout'
        } else {
            # A fresh clone, or the first ever publish of this major line.
            Write-Host "  $releaseBranch does not exist yet — creating it here." -ForegroundColor DarkGray
            Run 'git' @('checkout', '-b', $releaseBranch) 'git checkout'
            Run 'git' @('push', '-u', 'origin', $releaseBranch) 'git push'
        }
        $currentBranch = $releaseBranch

        # The branch that was just checked out has its own pubspec.yaml, and it
        # is that version — not the one read on the branch we came from — that
        # gets compiled. Re-derive everything from it.
        $v = Get-PubspecVersion
        if ($v.Name -ne $versionName) {
            Write-Host ''
            Write-Host "  $releaseBranch carries version $($v.Name), not $versionName." -ForegroundColor DarkYellow
            Write-Host "  Building and tagging that instead: $($v.Tag)"
            $versionName = $v.Name
            $versionCode = $v.Code
            $tag = $v.Tag
            if (-not (AskYesNo 'Continue?' $true)) { throw 'aborted by user' }
        }
        # A major that disagrees with the branch it lives on means the branch is
        # not the line it claims to be, and no tag from here would be trustworthy.
        if ($v.Branch -ne $releaseBranch) {
            throw "$releaseBranch contains version $($v.Name), which belongs on $($v.Branch) — the release lines are crossed"
        }
    }
}

# Must match the URL the guest web app is actually hosted at, or the invite
# QR points somewhere that does not serve the app.
$guestUrl = Ask 'Guest app URL (baked into the invite QR)' 'https://app.tarkk.ir'
$guestUrl = $guestUrl.TrimEnd('/')

$cleanFirst = AskYesNo 'Run "flutter clean" first (slow, use when in doubt)?' $false

# ── Release preflight, part 2: tag, remote, notes ───────────────────────────

$reuseTag = $false
$releaseExists = $false
$isPrerelease = $false
$notesFile = $null
$tagMessageFile = $null

if ($publish) {
    Run 'git' @('fetch', 'origin', '--tags', '--quiet') 'git fetch'

    $head = (git rev-parse HEAD).Trim()

    git show-ref --verify --quiet "refs/tags/$tag"
    if ($LASTEXITCODE -eq 0) {
        $tagCommit = (git rev-list -n1 $tag).Trim()
        if ($tagCommit -eq $head) {
            # Re-running for the same commit — a rebuild after a bad upload, say.
            # Keep the tag, replace the asset.
            Write-Host ''
            Write-Host "  $tag already exists and points at this exact commit." -ForegroundColor DarkYellow
            Write-Host "  The tag will be left alone and $assetName re-uploaded (--clobber)."
            if (-not (AskYesNo 'Continue?' $true)) { throw 'aborted by user' }
            $reuseTag = $true
        } else {
            Write-Host ''
            Write-Host "  $tag already exists, but points at $($tagCommit.Substring(0,7)) — not HEAD ($($head.Substring(0,7)))." -ForegroundColor Red
            Write-Host ''
            Write-Host '  That version has already shipped. Bump "version:" in pubspec.yaml'
            Write-Host '  (raise the +build number too — stores reject a re-used versionCode),'
            Write-Host '  commit it, then run this again.' -ForegroundColor DarkYellow
            throw "tag $tag already in use"
        }
    }

    # The release needs the commit to be on the remote, so make sure the branch
    # is not behind. Being ahead is fine — publishing pushes.
    git rev-parse --verify --quiet "origin/$releaseBranch" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  origin/$releaseBranch does not exist yet — it will be pushed." -ForegroundColor DarkGray
    } else {
        $behindRaw = (git rev-list --count "HEAD..origin/$releaseBranch").Trim()
        $behind = [int]$behindRaw
        if ($behind -gt 0) {
            Write-Host ''
            Write-Host "  origin/$releaseBranch has $behind commit(s) you do not have." -ForegroundColor Red
            Write-Host '  Run "git pull" and re-run, so the tag includes them.' -ForegroundColor DarkYellow
            throw 'release branch is behind origin'
        }
    }

    gh release view $tag 2>&1 | Out-Null
    $releaseExists = ($LASTEXITCODE -eq 0)

    # Notes are only asked for when they will actually be used. With both the
    # tag and the release already in place there is nothing left to write them
    # to — the run degrades to replacing the asset — and prompting for text
    # that gets silently dropped is worse than not asking.
    if ($reuseTag -and $releaseExists) {
        Write-Host ''
        Write-Host "  Release $tag already exists; its notes are left untouched." -ForegroundColor DarkGray
        Write-Host "  This run only rebuilds and replaces $assetName."
    } else {
        # A version with a pre-release suffix (1.0.8-beta.3) is a pre-release; a
        # plain one is not. Overridable, because "1.0.11 but only for testers"
        # is a real case.
        $isPrerelease = $versionName -match '-'
        $isPrerelease = AskYesNo 'Mark as a GitHub pre-release?' $isPrerelease

        $defaultNotes = "Tark $versionName."
        $notes = AskLines "Release notes for $tag — this becomes the tag message and the release body." $defaultNotes

        # Facts worth having in every tag, appended so they cannot be forgotten.
        $body = $notes
        if ($versionCode) { $body += "`n`nversionCode $versionCode." }
        $body += "`n`nVerified on Android. iOS is unbuilt and unverified in this release."

        $notesFile = [System.IO.Path]::GetTempFileName()
        $tagMessageFile = [System.IO.Path]::GetTempFileName()
        # Written through .NET rather than Set-Content because a BOM shows up as
        # a stray glyph at the top of the release body on github.com, and the
        # BOM-less encoding name differs between Windows PowerShell and pwsh.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($notesFile, $body, $utf8NoBom)
        [System.IO.File]::WriteAllText($tagMessageFile, "Tark $versionName`n`n$body", $utf8NoBom)
    }

    Write-Host ''
    Write-Host '  Ready to:' -ForegroundColor Yellow
    Write-Host "    build     universal release APK ($versionName)"
    if ($reuseTag) {
        Write-Host "    tag       $tag  (exists, reused)" -ForegroundColor DarkGray
    } else {
        Write-Host "    tag       $tag  ->  $($head.Substring(0,7))  on  $releaseBranch"
    }
    if ($releaseExists) {
        Write-Host "    publish   $assetName  ->  replaces the asset on existing release $tag"
    } else {
        $kind = if ($isPrerelease) { 'pre-release' } else { 'release' }
        Write-Host "    publish   $assetName  ->  new GitHub $kind $tag"
    }
    Write-Host ''
    if (-not (AskYesNo 'Proceed?' $true)) { throw 'aborted by user' }
}

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

# Used below to prove the APK we upload came from THIS run and is not left over
# from an earlier build.
$buildStart = Get-Date

Write-Host "`n> flutter $($buildArgs -join ' ')" -ForegroundColor Cyan
& flutter @buildArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '  Build failed.' -ForegroundColor Red
    Write-Host '  If it complained about a missing libflutter.so under'
    Write-Host '  stripped_native_libs, that is stale output from a previous'
    Write-Host '  build — re-run and answer Yes to "flutter clean".' -ForegroundColor DarkYellow
    if ($publish) {
        Write-Host '  Nothing was tagged or pushed.' -ForegroundColor DarkGray
    }
    throw 'flutter build failed'
}

$apkDir = Join-Path $repoRoot 'build\app\outputs\flutter-apk'

# ── Report ──────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  Build complete.' -ForegroundColor Green

if ($asBundle) {
    $aab = Join-Path $repoRoot "build\app\outputs\bundle\$mode\app-$mode.aab"
    Write-Host "  Bundle:  $aab  $(Show-Size $aab)"
} else {
    Get-ChildItem $apkDir -Filter "*$mode.apk" -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object {
            Write-Host ("  APK:     {0}  {1}" -f $_.FullName, (Show-Size $_.FullName))
        }
}

# ── Publish ─────────────────────────────────────────────────────────────────

if ($publish) {
    try {
        $universal = Join-Path $apkDir 'app-release.apk'
        if (-not (Test-Path $universal)) {
            throw "expected $universal — the build produced no universal APK"
        }
        # A leftover app-release.apk from an older run would upload silently and
        # look completely fine, so check it was written by the build that just
        # ran. Asked rather than thrown: if gradle ever declines to rewrite an
        # already-current APK this would otherwise block the release outright.
        if ((Get-Item $universal).LastWriteTime -lt $buildStart) {
            Write-Host ''
            Write-Host "  $universal is OLDER than the build that just ran." -ForegroundColor Red
            Write-Host '  It is probably stale output from an earlier build. Uploading it would'
            Write-Host '  publish the wrong binary under this tag.' -ForegroundColor DarkYellow
            if (-not (AskYesNo 'Upload it anyway?' $false)) {
                throw 'stale APK — re-run and answer Yes to "flutter clean"'
            }
        }

        $asset = Join-Path $apkDir $assetName
        Copy-Item $universal $asset -Force
        Write-Host ''
        Write-Host "  Asset:   $asset  $(Show-Size $asset)" -ForegroundColor Green

        if (-not $reuseTag) {
            Run 'git' @('tag', '-a', $tag, '-F', $tagMessageFile) 'git tag'
        }
        # Push the branch first: a tag pointing at a commit the remote does not
        # have is a release nobody can check out.
        Run 'git' @('push', 'origin', $releaseBranch) 'git push'
        # Pushed even when the tag is reused, because a reused tag may exist only
        # locally and "gh release create" needs it on the remote. Re-pushing an
        # identical tag is a no-op; a tag that moved was already rejected above.
        Run 'git' @('push', 'origin', $tag) 'git push tag'

        if ($releaseExists) {
            Write-Host "  Release $tag already exists — replacing the asset." -ForegroundColor DarkGray
            Run 'gh' @('release', 'upload', $tag, $asset, '--clobber') 'gh release upload'
        } else {
            $ghArgs = @(
                'release', 'create', $tag,
                '--title', "Tark $versionName",
                '--notes-file', $notesFile
            )
            if ($isPrerelease) { $ghArgs += '--prerelease' }
            $ghArgs += $asset
            Run 'gh' @ghArgs 'gh release create'
        }

        $url = (gh release view $tag --json url --jq .url 2>$null)
        Write-Host ''
        Write-Host '  Published.' -ForegroundColor Green
        if ($url) { Write-Host "  $($url.Trim())" -ForegroundColor Cyan }
    } finally {
        if ($notesFile -and (Test-Path $notesFile)) { Remove-Item $notesFile -Force }
        if ($tagMessageFile -and (Test-Path $tagMessageFile)) { Remove-Item $tagMessageFile -Force }
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
    if ($publish) {
        Write-Host "   * The GitHub asset is unsigned-for-store use only — Bazaar and Myket"
        Write-Host '     still need their own upload through each console.'
        Write-Host "   * Next bugfix: commit on $releaseBranch, bump version: in pubspec.yaml,"
        Write-Host '     re-run this script. Merge the fix back to main too.'
    }
}
Write-Host ''
