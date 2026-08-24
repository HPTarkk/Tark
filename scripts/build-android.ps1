# Builds the Tark Android app for Bazaar, interactively — and optionally cuts
# the GitHub release for it in the same run.
#
#   .\scripts\build-android.ps1
#
# Asks for everything it needs at run time; every prompt has a sensible
# default (just press Enter). Mirrors build-web-release.ps1 in style.
#
# No store billing channel is wired up yet (monetization is parked — see
# license_gate.dart), so this always builds an unlocked app. There is no
# billing key to configure.
#
# ── Build artifacts ─────────────────────────────────────────────────────────
# Every non-publishing build asks what to produce:
#
#   fat-apk     one universal APK, ~116 MB, installs on any device
#   split-apk   flutter build apk --split-per-abi — one APK per ABI, much smaller
#   appbundle   flutter build appbundle — a single .aab, split store-side
#
# A publish does not ask: the GitHub release carries one asset that works on any
# device, matching every release before it, so it is pinned to the fat APK.
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
# Features live on main, so a feature release needs main merged into the release
# branch first — offered in preflight, listing the commits, defaulting to yes.
# Decline it to ship only what is already on the release branch, which is the
# bugfix case. The merge happens before pubspec.yaml is re-read, because the
# merged tree is what gets compiled and what the tag has to name.
#
# Every build is then offered a patch bump (1.0.10+11 -> 1.0.11+12), defaulting
# to yes for release builds and no for debug. It is asked after the merge, so it
# lands on top of the tree about to be compiled, and before the tag checks, which
# are derived from it. Publishing commits the bump — the tag must name a real
# commit; otherwise the edit is left in the working tree for you to deal with.
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

# The next patch for a "1.2.3" / "1.2.3+45" pair, as the string that goes back
# into pubspec.yaml. The build number is raised too — stores reject a re-used
# versionCode outright. Returns $null for anything not major.minor.patch, so the
# caller can skip the offer rather than guess.
#
# A pre-release suffix is dropped: the patch after 1.0.8-beta.3 is 1.0.9. Type
# the version out in full at the prompt if that is not what you meant.
function Get-NextPatchVersion([string]$Name, [string]$Code) {
    if (-not ($Name -match '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)')) { return $null }
    $next = '{0}.{1}.{2}' -f $Matches['major'], $Matches['minor'], ([int]$Matches['patch'] + 1)
    if ($Code) { $next += '+' + ([int]$Code + 1) }
    return $next
}

# Rewrites the "version:" line and nothing else — comments, key order, line
# endings and the trailing newline all survive byte for byte, because this file
# is committed and a reformatted pubspec.yaml in a release diff is noise.
function Set-PubspecVersion([string]$Version) {
    $path = Join-Path $repoRoot 'pubspec.yaml'
    $text = [System.IO.File]::ReadAllText($path)
    # No trailing $ anchor: in .NET multiline it matches only before a bare \n,
    # so anchoring here would silently miss the line in a CRLF checkout.
    $rx = [regex]'(?m)^version:[^\r\n]*'
    if (-not $rx.IsMatch($text)) { throw 'pubspec.yaml has no version: line to rewrite' }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $rx.Replace($text, "version: $Version", 1), $utf8NoBom)
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

# A numbered menu. $Options is an array of objects with Value/Label/Hint, and the
# chosen Value comes back. $Default is a Value rather than an index, so reordering
# the menu cannot silently change what Enter picks. Either the number or the Value
# itself is accepted, and anything else re-asks — a typo here would otherwise pick
# an artifact silently and only show up minutes later in the output listing.
function AskChoice([string]$Question, $Options, [string]$Default) {
    Write-Host ''
    Write-Host "  $Question" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $o = $Options[$i]
        $mark = if ($o.Value -eq $Default) { '*' } else { ' ' }
        Write-Host ("   $mark {0}) {1}" -f ($i + 1), $o.Label)
        if ($o.Hint) { Write-Host "        $($o.Hint)" -ForegroundColor DarkGray }
    }
    while ($true) {
        $answer = Read-Host "  Choice [$Default]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        $answer = $answer.Trim()
        if ($answer -match '^\d+$') {
            $idx = [int]$answer
            if ($idx -ge 1 -and $idx -le $Options.Count) { return $Options[$idx - 1].Value }
        } else {
            $match = @($Options | Where-Object { $_.Value -eq $answer.ToLower() })
            if ($match.Count -eq 1) { return $match[0].Value }
        }
        Write-Host '  Not one of the choices.' -ForegroundColor DarkYellow
    }
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
#
# Call it as  Run 'gh' $argArray 'what'  — NOT  Run 'gh' @argArray 'what'.
# "@name" is splatting syntax: it explodes the array into separate positional
# parameters, so $Arguments would bind to the first element only and a simple
# function swallows the rest into $args without complaint. That silently ran
# "gh release" instead of "gh release create ..." once already, hence the guard.
function Run([string]$Exe, [string[]]$Arguments, [string]$What) {
    if ($args.Count -gt 0) {
        throw "Run '$Exe' got $($args.Count) stray argument(s) — an array was splatted with @ instead of passed as `$var: $($args -join ' ')"
    }
    Write-Host "> $Exe $($Arguments -join ' ')" -ForegroundColor Cyan
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$What failed" }
}

Write-Host ''
Write-Host '  TARK — Android release build' -ForegroundColor Yellow
Write-Host '  ----------------------------' -ForegroundColor DarkYellow
Write-Host ''

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
    Write-Host '  A locked build forces every premium gate SHUT, so the paywall can be'
    Write-Host '  exercised without waiting out the trial. No store billing channel is'
    Write-Host '  wired up yet, so this only tests the gate and paywall UI, not a real'
    Write-Host '  purchase. Never upload one as a public release.' -ForegroundColor DarkYellow
    $locked = AskYesNo 'Locked paywall-test build?' $false
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

# What the build produces. A publish is pinned to the fat APK below, so the
# question is only worth asking otherwise.
#
# Default: splits for a release (that is what a store upload wants), fat for a
# debug build (one file to shove onto whatever device is plugged in).
$artifact = 'fat-apk'
if (-not $publish) {
    $artifact = AskChoice 'What should this build produce?' @(
        [pscustomobject]@{
            Value = 'fat-apk'
            Label = 'Fat APK  — one universal file'
            Hint  = '~116 MB: every ABI''s native libs (Opus, RNNoise, WebRTC) ride along. Installs anywhere.'
        }
        [pscustomobject]@{
            Value = 'split-apk'
            Label = 'Split APKs — one per ABI'
            Hint  = 'Much smaller each. Upload the set; the store hands each device its own.'
        }
        [pscustomobject]@{
            Value = 'appbundle'
            Label = 'App bundle (.aab)'
            Hint  = 'One upload, split store-side. Only for a store that accepts AAB.'
        }
    ) $(if ($isRelease) { 'split-apk' } else { 'fat-apk' })
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

$mergedMain = 0

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
    }

    Run 'git' @('fetch', 'origin', '--tags', '--quiet') 'git fetch'

    # Nothing below should run on a branch that is missing commits the remote
    # already has — least of all a merge.
    git rev-parse --verify --quiet "origin/$releaseBranch" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  origin/$releaseBranch does not exist yet — it will be pushed." -ForegroundColor DarkGray
    } else {
        $behind = [int](git rev-list --count "HEAD..origin/$releaseBranch").Trim()
        if ($behind -gt 0) {
            Write-Host ''
            Write-Host "  origin/$releaseBranch has $behind commit(s) you do not have." -ForegroundColor Red
            Write-Host '  Run "git pull" and re-run, so the tag includes them.' -ForegroundColor DarkYellow
            throw 'release branch is behind origin'
        }
    }

    # ── Bring main in ───────────────────────────────────────────────────────
    #
    # Features land on main; the release branch only carries its own bugfixes.
    # So a feature release needs main merged first, while a bugfix-only release
    # does not — which is why this is offered rather than assumed.
    git rev-parse --verify --quiet 'origin/main' | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $incoming = @(git log --oneline 'HEAD..origin/main')
        if ($incoming.Count -gt 0) {
            Write-Host ''
            Write-Host "  origin/main has $($incoming.Count) commit(s) not on $releaseBranch" -ForegroundColor Yellow
            $incoming | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            Write-Host ''
            Write-Host '  Merge them to release these changes, or decline to ship only what is' -ForegroundColor DarkGray
            Write-Host "  already on $releaseBranch (the bugfix case)." -ForegroundColor DarkGray

            if (AskYesNo 'Merge origin/main into the release branch?' $true) {
                Write-Host "> git merge --no-edit origin/main" -ForegroundColor Cyan
                git merge --no-edit origin/main
                if ($LASTEXITCODE -eq 0) {
                    # Tracked so a later abort can say the commit is sitting
                    # there. It has to happen this early — pubspec.yaml and the
                    # tag both depend on the merged tree.
                    $mergedMain = $incoming.Count
                }
                if ($LASTEXITCODE -ne 0) {
                    # Never leave a half-merged tree behind: the next thing this
                    # script would do is build and tag it.
                    Write-Host ''
                    Write-Host '  Merge failed — backing it out.' -ForegroundColor Red
                    git merge --abort 2>&1 | Out-Null
                    Write-Host '  Resolve it by hand, commit, then run this again.' -ForegroundColor DarkYellow
                    throw 'merge of origin/main failed'
                }
            }
        } else {
            Write-Host "  origin/main  in sync with $releaseBranch" -ForegroundColor DarkGray
        }
    }

    # Re-read pubspec last: both a branch switch and a merge can change it, and
    # it is the version in the tree about to be COMPILED that must name the tag.
    $v = Get-PubspecVersion
    if ($v.Name -ne $versionName) {
        Write-Host ''
        Write-Host "  $releaseBranch now carries version $($v.Name), not the $versionName read earlier." -ForegroundColor DarkYellow
        Write-Host "  Building and tagging that instead: $($v.Tag)"
        $versionName = $v.Name
        $versionCode = $v.Code
        $tag = $v.Tag
        if (-not (AskYesNo 'Continue?' $true)) { throw 'aborted by user' }
    }
    # A major that disagrees with the branch it lives on means the branch is not
    # the line it claims to be, and no tag from here would be trustworthy.
    if ($v.Branch -ne $releaseBranch) {
        throw "$releaseBranch contains version $($v.Name), which belongs on $($v.Branch) — the release lines are crossed"
    }
}

# ── Version bump ────────────────────────────────────────────────────────────
#
# Offered on every build, because a version that has already shipped is a dead
# end in both directions: the stores reject a re-used versionCode, and the tag
# check below aborts a publish outright. Catching it here costs one Enter;
# catching it later costs a rebuild.
#
# Deliberately placed after the merge of origin/main (so it is the last commit on
# the release branch, not something the merge could conflict with) and before the
# tag and notes preflight, which all read the version this sets.

$bumped = $false
$suggested = Get-NextPatchVersion $versionName $versionCode
$currentVersion = if ($versionCode) { "$versionName+$versionCode" } else { $versionName }

if (-not $suggested) {
    Write-Host ''
    Write-Host "  version $versionName is not major.minor.patch — no bump offered." -ForegroundColor DarkGray
} else {
    Write-Host ''
    Write-Host "  Version bump:  $currentVersion  ->  $suggested" -ForegroundColor Yellow
    if (-not $isRelease) {
        Write-Host '  (debug build — usually not worth churning pubspec.yaml)' -ForegroundColor DarkGray
    }

    if (AskYesNo 'Bump the version in pubspec.yaml?' $isRelease) {
        $newVersion = Ask 'New version' $suggested
        if (-not ($newVersion -match '^\d+\.\d+\.\d+[^\s+]*(\+\d+)?$')) {
            throw "'$newVersion' is not a pubspec version — expected 1.2.3 or 1.2.3+45"
        }

        Set-PubspecVersion $newVersion
        $bumped = $true

        $v = Get-PubspecVersion
        $versionName = $v.Name
        $versionCode = $v.Code
        $tag = $v.Tag
        Write-Host "  pubspec.yaml now reads $newVersion  (tag $tag)" -ForegroundColor Green

        if ($publish) {
            # Typing a version from another major line would tag it on a branch
            # that is not its own, so put the file back rather than leave the
            # tree carrying a version this branch must never build.
            if ($v.Branch -ne $releaseBranch) {
                Set-PubspecVersion $currentVersion
                throw "version $newVersion belongs on $($v.Branch), not $releaseBranch — pubspec.yaml left unchanged"
            }
            # Committed, not left dirty: the tag has to point at a real commit,
            # and the clean-tree check above has already run.
            Run 'git' @('add', 'pubspec.yaml') 'git add'
            Run 'git' @('commit', '-m', "update version to $newVersion") 'git commit'
        } else {
            Write-Host '  Left uncommitted — commit it yourself if you keep this build.' -ForegroundColor DarkGray
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
    # Read after the merge above, so the tag is checked against the commit that
    # will actually be built.
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
            Write-Host '  That version has already shipped. Re-run and answer Yes to the'
            Write-Host '  version bump, or edit "version:" in pubspec.yaml by hand and commit'
            Write-Host '  it first.' -ForegroundColor DarkYellow
            throw "tag $tag already in use"
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
    if ($mergedMain -gt 0) {
        Write-Host "    merged    $mergedMain commit(s) from origin/main  (local only so far)" -ForegroundColor DarkGray
    }
    if ($bumped) {
        Write-Host "    bumped    $currentVersion  ->  $newVersion  (committed, local only so far)" -ForegroundColor DarkGray
    }
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
    if (-not (AskYesNo 'Proceed?' $true)) {
        if ($mergedMain -gt 0 -or $bumped) {
            $what = @()
            if ($mergedMain -gt 0) { $what += 'the merge of origin/main' }
            if ($bumped) { $what += "the bump to $newVersion" }
            Write-Host ''
            Write-Host "  Note: $($what -join ' and ') is already committed on $releaseBranch." -ForegroundColor DarkYellow
            Write-Host '  It was not pushed. To undo it:  git reset --hard @{u}' -ForegroundColor DarkGray
        }
        throw 'aborted by user'
    }
}

# ── Build ───────────────────────────────────────────────────────────────────

if ($cleanFirst) {
    Write-Host "`n> flutter clean" -ForegroundColor Cyan
    flutter clean
    if ($LASTEXITCODE -ne 0) { throw 'flutter clean failed' }

    Write-Host "> flutter pub get" -ForegroundColor Cyan
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }

    # # Injectable/l10n output lives under lib/, not build/, so clean does not
    # # remove it — but a clean is exactly when it is worth confirming the
    # # generated graph matches the source that will be compiled.
    # Write-Host "> dart run build_runner build" -ForegroundColor Cyan
    # dart run build_runner build
    # if ($LASTEXITCODE -ne 0) { throw 'build_runner failed' }
}

$target = if ($artifact -eq 'appbundle') { 'appbundle' } else { 'apk' }

$buildArgs = @('build', $target, "--$mode")
if ($artifact -eq 'split-apk') { $buildArgs += '--split-per-abi' }
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

if ($artifact -eq 'appbundle') {
    $aab = Join-Path $repoRoot "build\app\outputs\bundle\$mode\app-$mode.aab"
    Write-Host "  Bundle:  $aab  $(Show-Size $aab)"
} else {
    # --split-per-abi writes app-<abi>-$mode.apk and no universal one, so this
    # listing is also how you see which ABIs the build actually covered.
    $built = @(Get-ChildItem $apkDir -Filter "*$mode.apk" -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($f in $built) {
        Write-Host ("  APK:     {0}  {1}" -f $f.FullName, (Show-Size $f.FullName))
    }
    if ($artifact -eq 'split-apk') {
        Write-Host '  (per-ABI split — there is no single universal APK in this build.)' -ForegroundColor DarkGray
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
            Run 'gh' $ghArgs 'gh release create'
        }

        # "gh release create" works in three steps: make a DRAFT, upload the
        # assets, then flip the draft off. The upload of a ~116 MB APK takes
        # minutes, so anything that interrupts it (Ctrl-C, a dropped
        # connection) leaves a draft with no assets — invisible to everyone but
        # the repo owner. A retry then sees that draft as an existing release,
        # takes the --clobber path above, and would leave it drafted forever.
        # So publish it explicitly rather than trusting create to have finished.
        $isDraft = (gh release view $tag --json isDraft --jq .isDraft 2>$null)
        if ($isDraft -and $isDraft.Trim() -eq 'true') {
            Write-Host "  Release $tag is still a draft — publishing it." -ForegroundColor DarkYellow
            Run 'gh' @('release', 'edit', $tag, '--draft=false') 'gh release edit'
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
    Write-Host '  No store billing channel is wired up yet (Bazaar is planned, not' -ForegroundColor DarkYellow
    Write-Host '  built), so BillingService always reports unavailable and the paywall'
    Write-Host '  shows no prices. This only exercises the gate and paywall UI:'
    Write-Host '   * Open the paywall from Settings > transport, mute, or SHARE MUSIC.'
} else {
    Write-Host '  Reminders:' -ForegroundColor DarkYellow
    Write-Host "   * Guest URL baked in: $guestUrl — the web guest app must be live there."
    Write-Host '     (scripts\build-web-release.ps1 builds and bundles that side.)'
    if ($publish) {
        Write-Host "   * The GitHub asset is unsigned-for-store use only — Bazaar still needs"
        Write-Host '     its own upload through its console, once billing lands.'
        Write-Host "   * Next bugfix: commit on $releaseBranch, re-run this script and accept"
        Write-Host '     the version bump. Merge the fix back to main too.'
    }
}
Write-Host ''
