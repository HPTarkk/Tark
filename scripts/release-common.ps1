# Shared steps for the release scripts. Dot-source it, don't run it:
#
#   . (Join-Path $PSScriptRoot 'release-common.ps1')
#
# Used by build-bazaar.ps1, build-github.ps1 and build-release.ps1.
#
# ── Release model ───────────────────────────────────────────────────────────
# One permanent branch per minor version; a release is an annotated tag on it.
# Both names come from pubspec.yaml:
#
#   version: 1.0.21+22  ->  branch release/1.0.0   tag v1.0.21
#   version: 1.4.2+18   ->  branch release/1.4.0   tag v1.4.2
#
# Features live on main, so every release merges main into the release branch
# first. Nothing is tagged or pushed until the build has succeeded.

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

# Reads pubspec.yaml and derives the tag and release branch from it.
function Get-PubspecVersion {
    $line = (Get-Content (Join-Path $repoRoot 'pubspec.yaml')) |
        Where-Object { $_ -match '^version:\s*\S' } |
        Select-Object -First 1
    if (-not ($line -match '^version:\s*(?<name>[^\s+]+)(?:\+(?<code>\d+))?\s*$')) {
        throw "could not parse the version out of pubspec.yaml (found: '$line')"
    }
    $name = $Matches['name']
    $code = $Matches['code']
    if (-not ($name -match '^(?<major>\d+)\.(?<minor>\d+)\.')) {
        throw "version '$name' in pubspec.yaml does not start with major.minor numbers"
    }
    return [pscustomobject]@{
        Name   = $name
        Code   = $code
        Tag    = "v$name"
        Branch = "release/$($Matches['major']).$($Matches['minor']).0"
    }
}

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

function AskYesNo([string]$Question, [bool]$Default) {
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $answer = Read-Host "$Question [$hint]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim().ToLower().StartsWith('y')
}

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

# Steps 1-3: tools and a clean tree, switch to the release branch, merge main.
# Returns the version the release branch carries after the merge.
function Initialize-ReleaseBranch([switch]$NeedGh) {
    Step 'Checking tools and working tree'
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git not found on PATH' }
    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { throw 'flutter not found on PATH' }
    if ($NeedGh) {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            throw 'gh (GitHub CLI) not found on PATH — needed to create the release'
        }
        gh auth status 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'gh is not authenticated — run: gh auth login' }
    }

    # The tag has to name a real commit; a dirty tree names a build no one can
    # reproduce.
    $dirty = git status --porcelain
    if ($dirty) {
        Write-Host '  Working tree is not clean:' -ForegroundColor Red
        $dirty | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        throw 'uncommitted changes — commit or stash them first'
    }

    Run 'git' @('fetch', 'origin', '--tags', '--quiet') 'git fetch'

    # main's version decides the release line, since main is merged in next.
    $current = (git rev-parse --abbrev-ref HEAD).Trim()
    $mainLine = git show 'origin/main:pubspec.yaml' | Where-Object { $_ -match '^version:\s*\d' } | Select-Object -First 1
    if (-not ($mainLine -match '^version:\s*(?<major>\d+)\.(?<minor>\d+)\.')) {
        throw "could not read the version from origin/main (found: '$mainLine')"
    }
    $branch = "release/$($Matches['major']).$($Matches['minor']).0"

    Step "Switching to $branch"
    if ($current -ne $branch) {
        git show-ref --verify --quiet "refs/heads/$branch"
        $localExists = ($LASTEXITCODE -eq 0)
        git show-ref --verify --quiet "refs/remotes/origin/$branch"
        $remoteExists = ($LASTEXITCODE -eq 0)

        if ($localExists) {
            Run 'git' @('checkout', $branch) 'git checkout'
        } elseif ($remoteExists) {
            Run 'git' @('checkout', '-b', $branch, '--track', "origin/$branch") 'git checkout'
        } else {
            # First release of this major.minor line.
            Write-Host "  $branch does not exist yet — creating it from origin/main." -ForegroundColor DarkGray
            Run 'git' @('checkout', '-b', $branch, 'origin/main') 'git checkout'
        }
    }

    git show-ref --verify --quiet "refs/remotes/origin/$branch"
    if ($LASTEXITCODE -eq 0) {
        $behind = [int](git rev-list --count "HEAD..origin/$branch").Trim()
        if ($behind -gt 0) {
            Write-Host "  origin/$branch has $behind commit(s) you do not have — pulling them." -ForegroundColor DarkGray
            Run 'git' @('merge', '--ff-only', "origin/$branch") 'git pull of the release branch'
        }
    }

    Step "Merging main into $branch"
    $incoming = @(git log --oneline 'HEAD..origin/main')
    if ($incoming.Count -eq 0) {
        Write-Host '  Already up to date with main.' -ForegroundColor DarkGray
    } else {
        $incoming | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host '> git merge --no-edit origin/main' -ForegroundColor Cyan
        git merge --no-edit origin/main
        if ($LASTEXITCODE -ne 0) {
            # Never leave a half-merged tree behind: the next step builds it.
            git merge --abort 2>&1 | Out-Null
            throw 'merging main failed — resolve it by hand, commit, then run this again'
        }
    }

    $v = Get-PubspecVersion
    if ($v.Branch -ne $branch) {
        throw "$branch now carries version $($v.Name), which belongs on $($v.Branch)"
    }
    return $v
}

# Release notes: the commits since the previous release tag on this branch.
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

# Creates the annotated tag on HEAD, or checks an existing one points here.
# Then pushes the branch and the tag.
function Publish-Tag($Version) {
    $tag = $Version.Tag
    $head = (git rev-parse HEAD).Trim()
    git show-ref --verify --quiet "refs/tags/$tag"
    if ($LASTEXITCODE -eq 0) {
        $tagCommit = (git rev-list -n1 $tag).Trim()
        if ($tagCommit -ne $head) {
            throw "tag $tag already exists on $($tagCommit.Substring(0,7)), not HEAD — that version has already shipped"
        }
        Write-Host "  $tag already points at this commit — keeping it." -ForegroundColor DarkGray
    } else {
        $msgFile = [System.IO.Path]::GetTempFileName()
        try {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($msgFile, "Tark $($Version.Name)`n`n$(Get-ReleaseNotes $tag)", $utf8NoBom)
            Run 'git' @('tag', '-a', $tag, '-F', $msgFile) 'git tag'
        } finally {
            Remove-Item $msgFile -Force -ErrorAction SilentlyContinue
        }
    }
    # Branch first: a tag on a commit the remote lacks can't be checked out.
    Run 'git' @('push', '-u', 'origin', $Version.Branch) 'git push'
    Run 'git' @('push', 'origin', $tag) 'git push tag'
}

function Get-OutputDir($Version) {
    $dir = Join-Path $repoRoot "build\release\$($Version.Name)"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

# Clean build every release: stale output under build/ has shipped a broken
# libflutter.so before.
function Invoke-FlutterBuild([string[]]$BuildArgs) {
    Step 'Building'
    Run 'flutter' @('clean') 'flutter clean'
    Run 'flutter' @('pub', 'get') 'flutter pub get'
    Run 'flutter' ($BuildArgs + "--dart-define=GUEST_APP_URL=$guestUrl") 'flutter build'
}

# Step 4: the version this release ships as.
#
#   1.0.21-beta.9+30  ->  1.0.21+31   a pre-release becomes its final version
#   1.0.21+31         ->  1.0.22+32   only if v1.0.21 is already tagged
#   1.0.21+31         ->  1.0.21+31   not tagged yet (e.g. a re-run after a failed build)
#
# The build number always rises with the name, because stores reject a re-used
# versionCode. Commits the change so the tag names a real commit.
function Update-ReleaseVersion($Version) {
    if (-not ($Version.Name -match '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?<pre>-.*)?$')) {
        throw "version $($Version.Name) is not major.minor.patch"
    }
    $base = '{0}.{1}.{2}' -f $Matches['major'], $Matches['minor'], $Matches['patch']
    $isPre = [bool]$Matches['pre']

    if ($isPre) {
        $name = $base
    } else {
        git show-ref --verify --quiet "refs/tags/v$base"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  $($Version.Name) has not shipped yet — keeping it." -ForegroundColor DarkGray
            return $Version
        }
        $name = '{0}.{1}.{2}' -f $Matches['major'], $Matches['minor'], ([int]$Matches['patch'] + 1)
    }
    $new = if ($Version.Code) { "$name+$([int]$Version.Code + 1)" } else { $name }

    Write-Host "  Version:  $($Version.Name)$(if ($Version.Code) { "+$($Version.Code)" })  ->  $new" -ForegroundColor Yellow
    Set-PubspecVersion $new
    Run 'git' @('add', 'pubspec.yaml') 'git add'
    Run 'git' @('commit', '-m', "update version to $new") 'git commit'
    return Get-PubspecVersion
}
