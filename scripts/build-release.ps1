# Cuts a full Tark release in one run:
#
#   .\scripts\build-release.ps1
#
#   1. build-bazaar.ps1  — merges main, sets the version, builds and signs the
#                          .aab, tags and pushes
#   2. build-github.ps1  — builds the universal APK and publishes the GitHub
#                          release on the same tag
#   3. opens build\release\<version>\ with Tarkk.aab (+ bin\) for Bazaar and
#      Tarkk.apk for ArvanCloud
#
# Stops at the first failure.

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'build-bazaar.ps1')
& (Join-Path $PSScriptRoot 'build-github.ps1')

. (Join-Path $PSScriptRoot 'release-common.ps1')
$outDir = Get-OutputDir (Get-PubspecVersion)

Write-Host ''
Write-Host '  Release done. Upload these by hand:' -ForegroundColor Green
Write-Host "   * Bazaar:      $outDir\Tarkk.aab  (+ bin\)"
Write-Host "   * ArvanCloud:  $outDir\Tarkk.apk"
Invoke-Item $outDir
