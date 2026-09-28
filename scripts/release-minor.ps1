# Opens the next minor line: 1.0.21 -> 1.1.0 on a new branch release/1.1.0,
# cut from main.
#
#   .\scripts\release-minor.ps1
#
# One run does the whole release — version, build, Bazaar signing, tag, GitHub
# release, and main brought back up to date. See release-common.ps1.

. (Join-Path $PSScriptRoot 'release-common.ps1')
Invoke-Release -Bump minor
