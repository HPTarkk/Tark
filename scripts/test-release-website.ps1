# Isolated release regression checks; Wrangler and the public fetch are mocked.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path $repoRoot ('build/website-release-test-' + [Guid]::NewGuid().ToString('N'))
$savedPath = $env:PATH
$utf8 = [Text.UTF8Encoding]::new($false)
function Assert-Release($Condition, [string]$Description) {
    if (-not $Condition) { throw "Release regression: $Description" }
}
function Invoke-RestMethod {
    param($Uri, $Headers, $TimeoutSec)
    Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'website/site-version.json') | ConvertFrom-Json
}
try {
    foreach ($dir in @('scripts', 'website', 'bin')) {
        New-Item -ItemType Directory -Path (Join-Path $fixtureRoot $dir) -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'release-website.ps1') -Destination (Join-Path $fixtureRoot 'scripts/release-website.ps1')
    foreach ($name in @('build-website-i18n.mjs', 'build-legal-pages.mjs', 'check-website.mjs')) {
        [IO.File]::WriteAllText((Join-Path $fixtureRoot "scripts/$name"), '// fixture generator', $utf8)
    }
    $fixturePackage = Join-Path $fixtureRoot 'website/package.json'
    $fixtureManifest = Join-Path $fixtureRoot 'website/site-version.json'
    $fixtureRelease = Join-Path $fixtureRoot 'scripts/release-website.ps1'
    [IO.File]::WriteAllText($fixturePackage, "{`r`n  `"version`": `"1.2.3`",`r`n  `"private`": true`r`n}`r`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'wrangler.website.jsonc'), '{}', $utf8)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'bin/wrangler.ps1'), @'
$args | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot '../wrangler-args.json')
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '../fail-upload')) { exit 9 }
exit 0
'@, $utf8)
    $env:PATH = (Join-Path $fixtureRoot 'bin') + [IO.Path]::PathSeparator + $savedPath
    & git -C $fixtureRoot init --quiet
    & git -C $fixtureRoot add .
    & git -C $fixtureRoot -c user.name=ReleaseTest -c user.email=release-test@example.invalid commit --quiet -m fixture
    Assert-Release ($LASTEXITCODE -eq 0) 'fixture commit'
    $original = [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixturePackage))

    & $fixtureRelease -DryRun -Bump minor
    Assert-Release ($original -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixturePackage))) 'dry run must restore package bytes'
    Assert-Release (-not (Test-Path -LiteralPath $fixtureManifest)) 'dry run must remove a newly staged marker'
    $uploadArgs = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'wrangler-args.json') | ConvertFrom-Json
    Assert-Release ($uploadArgs -contains '--dry-run' -and $uploadArgs -contains 'website-v1.3.0') 'Wrangler dry-run tag'

    [IO.File]::WriteAllText($fixtureManifest, '{"version":"1.2.3"}', $utf8)
    $oldManifest = [IO.File]::ReadAllText($fixtureManifest)
    New-Item -ItemType File -Path (Join-Path $fixtureRoot 'fail-upload') | Out-Null
    $failed = $false
    try { & $fixtureRelease -Version 2.0.0 } catch { $failed = $true }
    Assert-Release $failed 'upload failure must be reported'
    Assert-Release ($original -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixturePackage))) 'upload failure must restore package'
    Assert-Release ($oldManifest -eq [IO.File]::ReadAllText($fixtureManifest)) 'upload failure must restore existing marker'
    Remove-Item -LiteralPath (Join-Path $fixtureRoot 'fail-upload')

    $failed = $false
    try { & $fixtureRelease -Version 1.2.3 } catch { $failed = $true }
    Assert-Release $failed 'same/older version must be rejected'

    $env:GIT_AUTHOR_NAME = $env:GIT_COMMITTER_NAME = 'ReleaseTest'
    $env:GIT_AUTHOR_EMAIL = $env:GIT_COMMITTER_EMAIL = 'release-test@example.invalid'
    Assert-Release ((& git -C $fixtureRoot rev-list --count HEAD) -eq '1') 'dry run and failed uploads must not commit'
    & $fixtureRelease -Bump major -Message 'Fixture release' -NoPush
    $package = Get-Content -Raw -LiteralPath $fixturePackage | ConvertFrom-Json
    $manifest = Get-Content -Raw -LiteralPath $fixtureManifest | ConvertFrom-Json
    Assert-Release ($package.version -eq '2.0.0' -and $manifest.version -eq '2.0.0') 'successful release must keep matching versions'
    Assert-Release ($manifest.tag -eq 'website-v2.0.0' -and $manifest.sourceCommit -match '^[0-9a-f]{40}$') 'source metadata'
    $uploadArgs = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'wrangler-args.json') | ConvertFrom-Json
    Assert-Release ($uploadArgs -notcontains '--dry-run' -and $uploadArgs -contains 'Fixture release') 'production Wrangler arguments'
    Assert-Release ((& git -C $fixtureRoot log -1 --format=%s) -eq 'Fixture release') 'successful release must commit the version files'
    Assert-Release ((& git -C $fixtureRoot show --name-only --format= HEAD) -join ',' -eq 'website/package.json,website/site-version.json') 'release commit holds only the version files'
    Assert-Release (-not (& git -C $fixtureRoot status --porcelain -- website)) 'release must leave the version files committed'
    Write-Host 'Website release regression checks passed.'
} finally {
    $env:PATH = $savedPath
    foreach ($name in @('GIT_AUTHOR_NAME', 'GIT_COMMITTER_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_EMAIL')) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    # Only remove the newly created fixture, after verifying its resolved boundary.
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $buildBoundary = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixture.StartsWith($buildBoundary, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
