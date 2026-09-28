# Ships the next patch of the current line as a tag on its release branch.
#
# From main: merges main into the current line (release/<major>.<minor>.0) and
# ships 1.0.21 -> 1.0.22. With a release/* branch checked out: ships that
# branch as it is, without main — the way to hotfix an older line.
#
#   .\scripts\release-patch.ps1
#
# One run does the whole release — version, build, Bazaar signing, tag, GitHub
# release, and main brought back up to date. See release-common.ps1.

. (Join-Path $PSScriptRoot 'release-common.ps1')
Invoke-Release -Bump patch
