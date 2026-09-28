# Builds the signed Tark app bundle for Cafe Bazaar.
#
#   .\scripts\build-bazaar.ps1
#
# Steps:
#   1. check tools and a clean working tree
#   2. switch to release/MAJOR.MINOR.0 (created from main if missing)
#   3. merge main into it
#   4. set the release version and commit it (see Update-ReleaseVersion)
#   5. build the release .aab and sign it with bundlesigner (asks for the
#      keystore password)
#   6. tag v<version> and push the branch and the tag
#
# Output: build\release\<version>\Tarkk.aab and its bin\ folder, ready to
# upload in the Bazaar console. Nothing is tagged or pushed if the build or the
# signing fails.
#
# Needs, next to this script (both are gitignored, never commit them):
#   scripts\bundlesigner-*.jar
#   scripts\upload-keystore.jks
#
# build-release.ps1 runs this and then build-github.ps1.

. (Join-Path $PSScriptRoot 'release-common.ps1')

Write-Host ''
Write-Host '  TARK — Bazaar build' -ForegroundColor Yellow

# Checked before anything else so a missing file never costs a build.
$signer = Get-ChildItem $PSScriptRoot -Filter 'bundlesigner-*.jar' -ErrorAction SilentlyContinue |
    Sort-Object Name | Select-Object -Last 1
if (-not $signer) { throw "bundlesigner-*.jar not found in $PSScriptRoot — copy it there first" }
$keystore = Join-Path $PSScriptRoot 'upload-keystore.jks'
if (-not (Test-Path $keystore)) { throw "upload-keystore.jks not found in $PSScriptRoot — copy it there first" }
if (-not (Get-Command java -ErrorAction SilentlyContinue)) { throw 'java not found on PATH — needed to sign the bundle' }

$v = Initialize-ReleaseBranch

Step 'Setting the release version'
$v = Update-ReleaseVersion $v

Invoke-FlutterBuild @('build', 'appbundle', '--release')

$built = Join-Path $repoRoot 'build\app\outputs\bundle\release\app-release.aab'
if (-not (Test-Path $built)) { throw "expected $built — the build produced no bundle" }

$outDir = Get-OutputDir $v
$aab = Join-Path $outDir 'Tarkk.aab'
Copy-Item $built $aab -Force

Step 'Signing for Bazaar'
$binDir = Join-Path $outDir 'bin'
if (Test-Path $binDir) { Remove-Item $binDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Run 'java' @(
    '-jar', $signer.FullName, 'genbin',
    '--bundle', $aab,
    '--bin', $binDir,
    '--v2-signing-enabled', 'true',
    '--v3-signing-enabled', 'false',
    '--ks', $keystore,
    '-v'
) 'bundlesigner'

Step "Tagging $($v.Tag)"
Publish-Tag $v

Write-Host ''
Write-Host '  Bazaar build ready.' -ForegroundColor Green
Write-Host "  Bundle:  $aab  $(Show-Size $aab)"
Write-Host "  Bin:     $binDir"
