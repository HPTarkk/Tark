# The whole Tark release, shared by the three entry points. Dot-source it and
# call Invoke-Release; don't run it directly:
#
#   .\scripts\release-patch.ps1    1.0.21 -> 1.0.22   tag on release/1.0.0
#   .\scripts\release-minor.ps1    1.0.21 -> 1.1.0    new branch release/1.1.0
#   .\scripts\release-major.ps1    1.4.2  -> 2.0.0    new branch release/2.0.0
#
# ── Release model ───────────────────────────────────────────────────────────
# One permanent branch per major.minor line, release/<major>.<minor>.0. A
# patch is never a branch — it is the next annotated tag on its line. The
# version lives in pubspec.yaml and nowhere else.
#
# Features land on main. A patch run from main merges main into the current
# line first; a patch run while a release/* branch is checked out ships that
# branch as it is (a hotfix for an older line — commit or cherry-pick the fix
# there first). Minor and major always open their new line from main.
#
# ── What one run does ───────────────────────────────────────────────────────
#   1. checks tools, signing files and a clean tree; fetches
#   2. works out the next version and asks once to confirm
#   3. switches to (or creates) the release branch, merges main for a patch
#   4. commits the version bump
#   5. clean build: the .aab for Bazaar (+ its bundlesigner bin\) and the
#      universal APK for GitHub and ArvanCloud
#   6. tags v<version>, pushes the branch and the tag
#   7. creates the GitHub release with Tarkk.apk and notes from the commits
#   8. back to main: pulls it, merges the release branch in so main carries the
#      new version, pushes main
#
# If anything before the push fails, the version commit is undone and nothing
# has left this machine. Signing passwords come from android\key.properties
# (gitignored) — the same file Gradle signs the release build with.

$ErrorActionPreference = 'Stop'

# PowerShell 7.3+ turns a non-zero native exit code into a terminating error
# while ErrorActionPreference is Stop. Several probes below ("does this tag
# exist?") answer *no* with a non-zero exit, so opt out and check
# $LASTEXITCODE by hand.
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# Baked into the invite QR. Must match where the guest web app is hosted.
$guestUrl = 'https://app.tarkk.ir'

# The asset name every GitHub release uses. Keep it stable — people link to it.
$apkAssetName = 'Tarkk.apk'

function Step([string]$Text) {
    Write-Host ''
    Write-Host "  == $Text" -ForegroundColor Yellow
}

function Show-Size([string]$Path) {
    if (-not (Test-Path $Path)) { return '' }
    return ('{0:N1} MB' -f ((Get-Item $Path).Length / 1MB))
}

# Echo then run, and fail loudly.
#
# Call it as  Run 'gh' $argArray 'what'  — NOT  Run 'gh' @argArray 'what'.
# "@name" splats the array into separate parameters and silently drops all but
# the first, which once ran "gh release" instead of "gh release create ...".
function Run([string]$Exe, [string[]]$Arguments, [string]$What) {
    if ($args.Count -gt 0) {
        throw "Run '$Exe' got $($args.Count) stray argument(s) — an array was splatted with @: $($args -join ' ')"
    }
    Write-Host "> $Exe $($Arguments -join ' ')" -ForegroundColor Cyan
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$What failed" }
}

function Test-GitRef([string]$Ref) {
    git show-ref --verify --quiet $Ref
    return ($LASTEXITCODE -eq 0)
}

# ── Versions ────────────────────────────────────────────────────────────────

# Parses a pubspec "version:" value. Pre-release suffixes (-beta.9) are kept
# apart so a patch can finish them.
function ConvertTo-Version([string]$Text, [string]$Where) {
    if (-not ($Text -match '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?<pre>-[^+\s]+)?(?:\+(?<code>\d+))?$')) {
        throw "could not parse version '$Text' from $Where"
    }
    return [pscustomobject]@{
        Major = [int]$Matches['major']
        Minor = [int]$Matches['minor']
        Patch = [int]$Matches['patch']
        Pre   = [string]$Matches['pre']
        Code  = if ($Matches['code']) { [int]$Matches['code'] } else { 0 }
    }
}

# The version at a git ref ("HEAD", "origin/main", ...).
function Get-VersionAt([string]$Ref) {
    $line = git show "${Ref}:pubspec.yaml" 2>$null |
        Where-Object { $_ -match '^version:\s*\S' } | Select-Object -First 1
    if (-not $line) { throw "no version: line in pubspec.yaml at $Ref" }
    return ConvertTo-Version ($line -replace '^version:\s*', '').Trim() "pubspec.yaml at $Ref"
}

function Get-LineBranch([int]$Major, [int]$Minor) { "release/$Major.$Minor.0" }

# Rewrites the "version:" line and nothing else, keeping line endings intact.
function Set-PubspecVersion([string]$Version) {
    $path = Join-Path $repoRoot 'pubspec.yaml'
    $text = [System.IO.File]::ReadAllText($path)
    # No trailing $ anchor: in .NET multiline it matches only before a bare \n,
    # so it would silently miss the line in a CRLF checkout.
    $rx = [regex]'(?m)^version:[^\r\n]*'
    if (-not $rx.IsMatch($text)) { throw 'pubspec.yaml has no version: line to rewrite' }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $rx.Replace($text, "version: $Version", 1), $utf8NoBom)
}

# ── Signing ─────────────────────────────────────────────────────────────────

# android\key.properties, as Gradle reads it. storeFile is relative to
# android\app, because that is the module whose file() resolves it.
function Get-SigningConfig {
    $path = Join-Path $repoRoot 'android\key.properties'
    if (-not (Test-Path $path)) { throw "android\key.properties not found — it holds the signing passwords" }
    $props = @{}
    foreach ($raw in Get-Content $path) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $i = $line.IndexOf('=')
        if ($i -lt 1) { continue }
        $props[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
    }
    foreach ($key in 'storePassword', 'keyPassword', 'keyAlias') {
        if (-not $props[$key]) { throw "android\key.properties has no $key" }
    }
    $store = if ($props['storeFile']) { $props['storeFile'] } else { '../upload-keystore.jks' }
    if (-not [System.IO.Path]::IsPathRooted($store)) {
        $store = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "android\app\$store"))
    }
    if (-not (Test-Path $store)) { throw "keystore $store (storeFile in android\key.properties) not found" }
    return [pscustomobject]@{
        StoreFile     = $store
        StorePassword = $props['storePassword']
        KeyPassword   = $props['keyPassword']
        KeyAlias      = $props['keyAlias']
    }
}

# Bazaar's bin\ folder. Passwords reach bundlesigner through environment
# variables, never the command line, so the echoed command stays safe to
# paste and they never land in a process listing.
function Invoke-BazaarSigning([string]$Signer, $Signing, [string]$Aab, [string]$BinDir) {
    if (Test-Path $BinDir) { Remove-Item $BinDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    $env:TARK_KS_PASS = $Signing.StorePassword
    $env:TARK_KEY_PASS = $Signing.KeyPassword
    try {
        Run 'java' @(
            '-jar', $Signer, 'genbin',
            '--bundle', $Aab,
            '--bin', $BinDir,
            '--v2-signing-enabled', 'true',
            '--v3-signing-enabled', 'false',
            '--ks', $Signing.StoreFile,
            '--ks-key-alias', $Signing.KeyAlias,
            '--ks-pass', 'env:TARK_KS_PASS',
            '--key-pass', 'env:TARK_KEY_PASS',
            '-v'
        ) 'bundlesigner'
    } finally {
        Remove-Item Env:\TARK_KS_PASS, Env:\TARK_KEY_PASS -ErrorAction SilentlyContinue
    }
}

# ── Git steps ───────────────────────────────────────────────────────────────

# Release notes: the commits since the previous release tag on this line.
function Get-ReleaseNotes([string]$Tag) {
    # Tags on HEAD itself are excluded so a re-run for the same tag still lists
    # what that release added.
    $previous = git describe --tags --abbrev=0 --match 'v*' --exclude $Tag 'HEAD' 2>$null
    if ($LASTEXITCODE -eq 0 -and $previous) {
        $previous = $previous.Trim()
        $lines = @(git log --no-merges --pretty='format:- %s' "$previous..HEAD")
        $header = "Changes since ${previous}:"
    } else {
        $lines = @(git log --no-merges --pretty='format:- %s' -n 50 'HEAD')
        $header = 'Latest changes:'
    }
    # The version bump commit is noise in the notes.
    $lines = @($lines | Where-Object { $_ -notmatch '^- update version to ' })
    if ($lines.Count -eq 0) { $lines = @('- No code changes.') }
    return "$header`n`n$($lines -join "`n")"
}

function Write-TempUtf8([string]$Text) {
    $file = [System.IO.Path]::GetTempFileName()
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($file, $Text, $utf8NoBom)
    return $file
}

# Back on main with the release's version bump in it. Runs after the release is
# already public, so a failure here warns instead of throwing: the release
# stands, only main needs a hand.
function Sync-MainWithRelease([string]$Branch, [bool]$MergeBack) {
    Step 'Back to main'
    Run 'git' @('checkout', 'main') 'git checkout main'
    git merge --ff-only origin/main 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  Local main has diverged from origin/main — sort it out by hand.' -ForegroundColor Red
        return
    }
    if (-not $MergeBack) {
        # A hotfix on an older line: its version is lower than main's, and
        # merging it would drag main's version backwards.
        Write-Host "  $Branch is an older line — not merging it into main." -ForegroundColor DarkGray
        return
    }
    Write-Host "> git merge --no-edit $Branch" -ForegroundColor Cyan
    git merge --no-edit $Branch
    if ($LASTEXITCODE -ne 0) {
        git merge --abort 2>&1 | Out-Null
        Write-Host "  Merging $Branch into main conflicted — merge it by hand." -ForegroundColor Red
        return
    }
    git push origin main
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  Pushing main was refused (branch protection?). Local main has the new version; push or PR it.' -ForegroundColor Red
    }
}

# ── The release ─────────────────────────────────────────────────────────────

function Invoke-Release {
    param([Parameter(Mandatory)][ValidateSet('patch', 'minor', 'major')][string]$Bump)

    Write-Host ''
    Write-Host "  TARK — $Bump release" -ForegroundColor Yellow

    # 1. Everything that could fail cheaply, before anything changes.
    Step 'Checking tools, signing files and working tree'
    foreach ($tool in 'git', 'flutter', 'gh', 'java') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found on PATH" }
    }
    gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'gh is not authenticated — run: gh auth login' }
    $signer = Get-ChildItem $PSScriptRoot -Filter 'bundlesigner-*.jar' -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -Last 1
    if (-not $signer) { throw "bundlesigner-*.jar not found in $PSScriptRoot — copy it there first" }
    $signing = Get-SigningConfig

    # The tag has to name a real commit; a dirty tree names a build no one can
    # reproduce.
    $dirty = git status --porcelain
    if ($dirty) {
        $dirty | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        throw 'uncommitted changes — commit or stash them first'
    }
    Run 'git' @('fetch', 'origin', '--tags', '--prune', '--quiet') 'git fetch'

    # 2. Which line, and which version.
    $started = (git rev-parse --abbrev-ref HEAD).Trim()
    $main = Get-VersionAt 'origin/main'
    $hotfix = ($Bump -eq 'patch' -and $started -match '^release/\d+\.\d+\.0$')

    if ($Bump -eq 'patch') {
        $branch = if ($hotfix) { $started } else { Get-LineBranch $main.Major $main.Minor }
        # The line's own version is the one that shipped last; main may still
        # say beta. Fall back to main when the line has never been cut.
        $ref = if (Test-GitRef "refs/remotes/origin/$branch") { "origin/$branch" }
               elseif (Test-GitRef "refs/heads/$branch") { $branch }
               else { 'origin/main' }
        $cur = Get-VersionAt $ref
        $major = $cur.Major; $minor = $cur.Minor
        # A pre-release finishes as its own number; a shipped one moves on.
        $patch = if ($cur.Pre) { $cur.Patch } else { $cur.Patch + 1 }
        while (Test-GitRef "refs/tags/v$major.$minor.$patch") { $patch++ }
    } else {
        if ($Bump -eq 'minor') { $major = $main.Major; $minor = $main.Minor + 1 }
        else { $major = $main.Major + 1; $minor = 0 }
        $patch = 0
        $branch = Get-LineBranch $major $minor
        if ((Test-GitRef "refs/remotes/origin/$branch") -or (Test-GitRef "refs/tags/v$major.$minor.0")) {
            throw "$branch already exists — $major.$minor is out; use release-patch.ps1"
        }
    }

    $name = "$major.$minor.$patch"
    $tag = "v$name"
    # Stores reject a re-used versionCode, and an older line's hotfix still has
    # to outrank everything main has handed out.
    $codes = @($main.Code, (Get-VersionAt 'HEAD').Code)
    if (Test-GitRef "refs/remotes/origin/$branch") { $codes += (Get-VersionAt "origin/$branch").Code }
    $code = [int]($codes | Measure-Object -Maximum).Maximum + 1
    $version = "$name+$code"

    Write-Host ''
    Write-Host "  Release   $version" -ForegroundColor Green
    Write-Host "  Branch    $branch$(if ($hotfix) { '  (hotfix: main is not merged)' })"
    Write-Host "  Tag       $tag"
    $answer = Read-Host '  Go? [Y/n]'
    if ($answer -and -not $answer.Trim().ToLower().StartsWith('y')) { throw 'aborted' }

    # 3. Onto the line.
    Step "Switching to $branch"
    if ($started -ne $branch) {
        if (Test-GitRef "refs/heads/$branch") {
            Run 'git' @('checkout', $branch) 'git checkout'
        } elseif (Test-GitRef "refs/remotes/origin/$branch") {
            Run 'git' @('checkout', '-b', $branch, '--track', "origin/$branch") 'git checkout'
        } else {
            Write-Host "  New line — creating $branch from origin/main." -ForegroundColor DarkGray
            Run 'git' @('checkout', '-b', $branch, 'origin/main') 'git checkout'
        }
    }
    if (Test-GitRef "refs/remotes/origin/$branch") {
        git merge --ff-only "origin/$branch" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "$branch has diverged from origin/$branch — reconcile it by hand" }
    }
    if (-not $hotfix) {
        $incoming = @(git log --oneline 'HEAD..origin/main')
        if ($incoming.Count -gt 0) {
            Step "Merging main into $branch"
            $incoming | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            Write-Host '> git merge --no-edit origin/main' -ForegroundColor Cyan
            git merge --no-edit origin/main
            if ($LASTEXITCODE -ne 0) {
                # Never leave a half-merged tree behind: the next step builds it.
                git merge --abort 2>&1 | Out-Null
                throw 'merging main failed — resolve it by hand, commit, then run this again'
            }
        }
    }
    $beforeBump = (git rev-parse HEAD).Trim()

    # 4-7. Everything that can still fail. Until the push, a failure rewinds
    # the version commit so the next run starts from the same place.
    $pushed = $false
    try {
        Step "Setting the version to $version"
        Set-PubspecVersion $version
        Run 'git' @('add', 'pubspec.yaml') 'git add'
        Run 'git' @('commit', '-m', "update version to $version") 'git commit'

        # Clean build every release: stale output under build/ has shipped a
        # broken libflutter.so before.
        Step 'Building'
        $defines = @(
            "--dart-define=GUEST_APP_URL=$guestUrl",
            "--dart-define=GIT_COMMIT=$((git rev-parse HEAD).Trim())",
            '--dart-define=GIT_DIRTY=false',
            "--dart-define=BUILD_TIMESTAMP=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        )
        Run 'flutter' @('clean') 'flutter clean'
        Run 'flutter' @('pub', 'get') 'flutter pub get'
        Run 'flutter' (@('build', 'appbundle', '--release') + $defines) 'flutter build appbundle'
        Run 'flutter' (@('build', 'apk', '--release') + $defines) 'flutter build apk'

        $outDir = Join-Path $repoRoot "build\release\$name"
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        $aab = Join-Path $outDir 'Tarkk.aab'
        $apk = Join-Path $outDir $apkAssetName
        Copy-Item (Join-Path $repoRoot 'build\app\outputs\bundle\release\app-release.aab') $aab -Force
        Copy-Item (Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-release.apk') $apk -Force

        Step 'Signing for Bazaar'
        $binDir = Join-Path $outDir 'bin'
        Invoke-BazaarSigning $signer.FullName $signing $aab $binDir

        Step "Tagging $tag"
        $msgFile = Write-TempUtf8 "Tark $name`n`n$(Get-ReleaseNotes $tag)"
        try { Run 'git' @('tag', '-a', $tag, '-F', $msgFile) 'git tag' }
        finally { Remove-Item $msgFile -Force -ErrorAction SilentlyContinue }

        # Branch first: a tag on a commit the remote lacks can't be checked out.
        Run 'git' @('push', '-u', 'origin', $branch) 'git push'
        $pushed = $true
        Run 'git' @('push', 'origin', $tag) 'git push tag'
    } catch {
        if (-not $pushed) {
            Write-Host ''
            Write-Host '  Failed before anything was pushed — undoing the version commit.' -ForegroundColor Red
            git tag -d $tag 2>&1 | Out-Null
            git reset --hard $beforeBump 2>&1 | Out-Null
        }
        throw
    }

    Step 'Publishing the GitHub release'
    $notesFile = Write-TempUtf8 "$(Get-ReleaseNotes $tag)`n`nversionCode $code."
    try {
        Run 'gh' @('release', 'create', $tag, '--title', "Tark $name", '--notes-file', $notesFile, '--verify-tag', $apk) 'gh release create'
    } finally {
        Remove-Item $notesFile -Force -ErrorAction SilentlyContinue
    }
    # "gh release create" makes a draft, uploads, then publishes. An
    # interrupted upload leaves a draft nobody else can see.
    $isDraft = gh release view $tag --json isDraft --jq .isDraft 2>$null
    if ($isDraft -and $isDraft.Trim() -eq 'true') {
        Run 'gh' @('release', 'edit', $tag, '--draft=false') 'gh release edit'
    }
    $url = gh release view $tag --json url --jq .url 2>$null

    # 8. Main carries the version it just shipped, unless this was an older
    # line's hotfix.
    $mergeBack = ($major -gt $main.Major) -or ($major -eq $main.Major -and $minor -ge $main.Minor)
    Sync-MainWithRelease $branch $mergeBack

    Write-Host ''
    Write-Host "  Tark $version released." -ForegroundColor Green
    if ($url) { Write-Host "  GitHub:      $($url.Trim())" -ForegroundColor Cyan }
    Write-Host "  Bazaar:      upload $aab  $(Show-Size $aab)  with $binDir"
    Write-Host "  ArvanCloud:  upload $apk  $(Show-Size $apk)"
    Write-Host "  Update feed: once Bazaar has published it, bump website\update.json"
    Invoke-Item $outDir
}
