# Opens the next major line: 1.4.2 -> 2.0.0 on a new branch release/2.0.0,
# cut from main.
#
#   .\scripts\release-major.ps1
#
# One run does the whole release — version, build, Bazaar signing, tag, GitHub
# release, and main brought back up to date. See release-common.ps1.

. (Join-Path $PSScriptRoot 'release-common.ps1')
Invoke-Release -Bump major
