# Builds the universal Tark APK and publishes it as a GitHub release. The same
# APK is the one to upload to ArvanCloud.
#
#   .\scripts\build-github.ps1
#
# Steps:
#   1. check tools (git, flutter, gh) and a clean working tree
#   2. switch to release/MAJOR.MINOR.0 (created from main if missing)
#   3. merge main into it
#   4. build one universal release APK
#   5. tag v<version> (kept if build-bazaar.ps1 already tagged this commit) and
#      push the branch and the tag
#   6. create the GitHub release with Tarkk.apk, notes filled in from the
#      commits since the previous release (or replace the APK if the release
#      already exists)
#
# It never changes the version: run build-bazaar.ps1 first (build-release.ps1
# does both), or bump pubspec.yaml yourself. If the version is already tagged
# on another commit it stops before building.
#
# Output: build\release\<version>\Tarkk.apk

. (Join-Path $PSScriptRoot 'release-common.ps1')

# The asset name every release uses. Keep it stable — people link to it.
$assetName = 'Tarkk.apk'

Write-Host ''
Write-Host '  TARK — GitHub and ArvanCloud build' -ForegroundColor Yellow

$v = Initialize-ReleaseBranch -NeedGh

# Fail before the build, not after it, when this version already shipped.
$head = (git rev-parse HEAD).Trim()
git show-ref --verify --quiet "refs/tags/$($v.Tag)"
if ($LASTEXITCODE -eq 0 -and (git rev-list -n1 $v.Tag).Trim() -ne $head) {
    throw "$($v.Tag) already exists on another commit — bump the version (build-bazaar.ps1 does) and run again"
}

Invoke-FlutterBuild @('build', 'apk', '--release')

$built = Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path $built)) { throw "expected $built — the build produced no universal APK" }

$outDir = Get-OutputDir $v
$apk = Join-Path $outDir $assetName
Copy-Item $built $apk -Force

Step "Tagging $($v.Tag)"
Publish-Tag $v

Step 'Publishing the GitHub release'
gh release view $v.Tag 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Release $($v.Tag) already exists — replacing $assetName." -ForegroundColor DarkGray
    Run 'gh' @('release', 'upload', $v.Tag, $apk, '--clobber') 'gh release upload'
} else {
    $body = Get-ReleaseNotes $v.Tag
    if ($v.Code) { $body += "`n`nversionCode $($v.Code)." }
    $notesFile = [System.IO.Path]::GetTempFileName()
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($notesFile, $body, $utf8NoBom)
        $ghArgs = @('release', 'create', $v.Tag, '--title', "Tark $($v.Name)", '--notes-file', $notesFile)
        # 1.0.21-beta.9 is a pre-release; 1.0.21 is not.
        if ($v.Name -match '-') { $ghArgs += '--prerelease' }
        $ghArgs += $apk
        Run 'gh' $ghArgs 'gh release create'
    } finally {
        Remove-Item $notesFile -Force -ErrorAction SilentlyContinue
    }
}

# "gh release create" makes a draft, uploads, then publishes. An interrupted
# upload leaves a draft nobody else can see, so publish it explicitly.
$isDraft = (gh release view $v.Tag --json isDraft --jq .isDraft 2>$null)
if ($isDraft -and $isDraft.Trim() -eq 'true') {
    Run 'gh' @('release', 'edit', $v.Tag, '--draft=false') 'gh release edit'
}

$url = (gh release view $v.Tag --json url --jq .url 2>$null)
Write-Host ''
Write-Host '  GitHub release published.' -ForegroundColor Green
if ($url) { Write-Host "  $($url.Trim())" -ForegroundColor Cyan }
Write-Host "  APK for ArvanCloud:  $apk  $(Show-Size $apk)"
