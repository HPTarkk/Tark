#requires -Version 7.0
# Exercise deployment boundaries with a fake Flutter, a stand-in for
# backend/deploy/vps/publish-sites.ps1 and mocked HTTP.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path $repoRoot ('build/guest-release-test-' + [Guid]::NewGuid().ToString('N'))
$savedPath = $env:PATH
$savedServer = $env:TARK_SERVER
$utf8 = [Text.UTF8Encoding]::new($false)
$webTestProbe = @{ FetchCount = 0; PromptCount = 0; RejectPrompts = $false }
function Assert-Release($Condition, [string]$Description) {
    if (-not $Condition) { throw "Guest release regression: $Description" }
}
function Invoke-RestMethod {
    param($Uri, $Headers, $TimeoutSec)
    $webTestProbe.FetchCount++
    Assert-Release ($Uri.StartsWith('https://app.tarkk.ir/web-release.json?release=')) 'verify the guest host'
    $marker = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'build/web/web-release.json') | ConvertFrom-Json
    if (Test-Path -LiteralPath (Join-Path $fixtureRoot 'stale-live')) { $marker.builtAt = '2000-01-01T00:00:00.000Z' }
    return $marker
}
function Start-Sleep { param($Seconds) }
function Read-Host {
    param($Prompt)
    $webTestProbe.PromptCount++
    if ($webTestProbe.RejectPrompts) { throw 'Auto mode must not ask questions.' }
    if ($Prompt.StartsWith('Publish this guest app')) { return 'y' }
    return ''
}
function Reset-Calls {
    $webTestProbe.FetchCount = 0
    foreach ($name in @('flutter-args.json', 'flutter-calls.jsonl', 'publish-args.json')) {
        $path = Join-Path $fixtureRoot $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
}
function Expect-Failure([hashtable]$Options, [string]$Reason) {
    $failed = $false
    try { & $fixtureRelease @Options } catch {
        $failed = $true
        Assert-Release ($_.Exception.Message -like "*$Reason*") "failure reason: $Reason"
    }
    Assert-Release $failed "must reject: $Reason"
    Assert-Release ((Get-Location).Path -eq $originalLocation) 'restore caller directory on failure'
}
try {
    foreach ($dir in @('scripts', 'bin', 'backend/deploy/vps')) {
        New-Item -ItemType Directory -Path (Join-Path $fixtureRoot $dir) -Force | Out-Null
    }
    $fixtureRelease = Join-Path $fixtureRoot 'scripts/build-web-release.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'build-web-release.ps1') -Destination $fixtureRelease
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'release-server.ps1') -Destination (Join-Path $fixtureRoot 'scripts')
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'pubspec.yaml'), 'version: 1.2.3+42', $utf8)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'bin/flutter.ps1'), @'
$root = Split-Path -Parent $PSScriptRoot
$commandArgs = $args
if ($null -ne $env:TARK_FIXTURE_ARGC) {
    $commandArgs = @(for ($i = 0; $i -lt [int]$env:TARK_FIXTURE_ARGC; $i++) { [Environment]::GetEnvironmentVariable("TARK_FIXTURE_ARG_$i") })
}
$commandArgs | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'flutter-args.json')
$commandArgs | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $root 'flutter-calls.jsonl')
if (Test-Path -LiteralPath (Join-Path $root 'fail-build')) { exit 7 }
$out = Join-Path $root 'build/web'
New-Item -ItemType Directory -Path $out -Force | Out-Null
Set-Content -LiteralPath (Join-Path $out 'index.html') -Value '<html>fixture</html>'
Set-Content -LiteralPath (Join-Path $out 'flutter_bootstrap.js') -Value '// fixture'
exit 0
'@, $utf8)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'backend/deploy/vps/publish-sites.ps1'), @'
param([string]$Server, [string]$Site, [string]$WebsiteDir, [string]$GuestDir, [int]$SshPort, [string]$SshKey, [switch]$DryRun)
$root = Join-Path $PSScriptRoot '../../..'
@{ Server = $Server; Site = $Site; GuestDir = $GuestDir; DryRun = [bool]$DryRun } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'publish-args.json')
if (Test-Path -LiteralPath (Join-Path $root 'fail-upload')) { exit 9 }
'@, $utf8)
    # Unix command discovery requires an executable filename without .ps1.
    # Each command is a sh shim around the real .ps1: an extensionless pwsh
    # script gets no $PSScriptRoot, and `pwsh -File` splits an argument such as
    # --dart-define=GUEST_APP_URL=https://... at its colon, so the shim passes
    # each argument through the environment exactly as the release script gave it.
    if ([IO.Path]::DirectorySeparatorChar -eq '/') {
        $pwshPath = (Get-Process -Id $PID).Path.Replace("'", "'\''")
        foreach ($command in @('flutter')) {
            $commandPath = Join-Path $fixtureRoot "bin/$command"
            $shim = @"
#!/bin/sh
i=0
for arg in "`$@"; do export "TARK_FIXTURE_ARG_`$i=`$arg"; i=`$((i + 1)); done
export TARK_FIXTURE_ARGC=`$i
exec '$pwshPath' -NoLogo -NoProfile -NonInteractive -File "`$(dirname "`$0")/$command.ps1"

"@
            [IO.File]::WriteAllText($commandPath, $shim, $utf8)
            & chmod +x $commandPath
            if ($LASTEXITCODE -ne 0) { throw 'Could not make fixture command executable.' }
        }
    }
    $env:PATH = (Join-Path $fixtureRoot 'bin') + [IO.Path]::PathSeparator + $savedPath
    $env:TARK_SERVER = 'root@fixture.invalid'
    $originalLocation = (Get-Location).Path
    $options = @{ NonInteractive = $true; Server = 'root@guest-test.invalid'; MakeZip = $false }

    & $fixtureRelease @options -BuildOnly
    Assert-Release (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'publish-args.json'))) 'build-only must not upload'
    Assert-Release ((Get-Location).Path -eq $originalLocation) 'restore caller directory on success'

    $serverDefault = $options.Clone()
    $serverDefault.Remove('Server')
    [IO.File]::WriteAllText((Join-Path $fixtureRoot '.SERVER'), "root@local.invalid`n", $utf8)
    & $fixtureRelease @serverDefault -DryRun
    $upload = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'publish-args.json') | ConvertFrom-Json
    Assert-Release ($upload.Server -eq 'root@fixture.invalid') 'use the server from TARK_SERVER by default'

    & $fixtureRelease @options -DryRun
    $upload = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'publish-args.json') | ConvertFrom-Json
    Assert-Release ($upload.DryRun -and $upload.Site -eq 'guest' -and $upload.Server -eq 'root@guest-test.invalid') 'dry run publishes the guest app to the requested server in dry-run mode'
    Assert-Release ($upload.GuestDir -eq (Join-Path $fixtureRoot 'build/web')) 'publish Flutter build assets'
    Assert-Release ($webTestProbe.FetchCount -eq 0) 'dry run must not verify a live upload'
    $build = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'flutter-args.json') | ConvertFrom-Json
    Assert-Release ($build -contains 'lib/main_guest.dart' -and $build -contains '--dart-define=GUEST_APP_URL=https://app.tarkk.ir') 'guest entrypoint and invite URL'
    $metadata = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'build/web/web-release.json') | ConvertFrom-Json
    Assert-Release ($metadata.version -eq '1.2.3+42' -and $metadata.sourceCommit -match '^[0-9a-f]{40}$') 'release provenance'
    Assert-Release ((Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'pubspec.yaml')) -eq 'version: 1.2.3+42') 'web publish must not bump Android version'

    Reset-Calls
    & $fixtureRelease @options -Deploy
    $upload = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'publish-args.json') | ConvertFrom-Json
    Assert-Release (-not $upload.DryRun -and $upload.Site -eq 'guest') 'production deploy arguments'
    Assert-Release ($webTestProbe.FetchCount -eq 1) 'successful release verifies its public marker'

    Reset-Calls
    $webTestProbe.RejectPrompts = $true
    $autoPromptCount = $webTestProbe.PromptCount
    $autoOriginalCi = $env:CI
    & $fixtureRelease
    $upload = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'publish-args.json') | ConvertFrom-Json
    Assert-Release ($upload.Server -eq 'root@fixture.invalid' -and -not $upload.DryRun) 'plain execution publishes to the default server'
    Assert-Release ($webTestProbe.FetchCount -eq 1 -and $webTestProbe.PromptCount -eq $autoPromptCount) 'plain execution builds, publishes and verifies without switches or answers'
    $defaultCalls = @(Get-Content -LiteralPath (Join-Path $fixtureRoot 'flutter-calls.jsonl') | ForEach-Object { ,@($_ | ConvertFrom-Json) })
    Assert-Release ($defaultCalls.Count -eq 2 -and $defaultCalls[0][0] -eq 'clean' -and $defaultCalls[1][1] -eq 'web') 'plain execution cleans and builds Flutter web'
    Assert-Release ($env:CI -ceq $autoOriginalCi) 'plain execution restores caller CI environment'
    Reset-Calls
    & $fixtureRelease -Auto
    $webTestProbe.RejectPrompts = $false
    $upload = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'publish-args.json') | ConvertFrom-Json
    Assert-Release ($upload.Server -eq 'root@fixture.invalid' -and -not $upload.DryRun) 'auto publishes to the default server'
    Assert-Release ($webTestProbe.FetchCount -eq 1 -and $webTestProbe.PromptCount -eq $autoPromptCount) 'auto builds, publishes and verifies without prompts'
    Assert-Release (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'build/web/landing'))) 'guest releases only contain the Flutter web app'
    Assert-Release (@(Get-ChildItem -LiteralPath (Join-Path $fixtureRoot 'build') -Filter 'tark-web-*.zip').Count -eq 0) 'auto skips ZIP packaging by default'
    $autoCalls = @(Get-Content -LiteralPath (Join-Path $fixtureRoot 'flutter-calls.jsonl') | ForEach-Object { ,@($_ | ConvertFrom-Json) })
    Assert-Release ($autoCalls.Count -eq 2 -and $autoCalls[0][0] -eq 'clean' -and $autoCalls[1][0] -eq 'build' -and $autoCalls[1][1] -eq 'web') 'auto cleans first and only builds Flutter web, without an APK'
    Assert-Release ($env:CI -ceq $autoOriginalCi) 'restore caller CI environment'

    Reset-Calls
    $interactive = $options.Clone()
    $interactive.NonInteractive = $false
    & $fixtureRelease @interactive
    Assert-Release (Test-Path -LiteralPath (Join-Path $fixtureRoot 'publish-args.json')) 'interactive build options still allow publishing'

    Reset-Calls
    New-Item -ItemType File -Path (Join-Path $fixtureRoot 'fail-build') | Out-Null
    Expect-Failure ($options + @{ Deploy = $true }) 'exit 7'
    Assert-Release ($env:CI -ceq $autoOriginalCi) 'restore caller CI environment after a failure'
    Assert-Release (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'publish-args.json'))) 'failed build must not publish stale output'
    Remove-Item -LiteralPath (Join-Path $fixtureRoot 'fail-build')

    Reset-Calls
    New-Item -ItemType File -Path (Join-Path $fixtureRoot 'fail-upload') | Out-Null
    Expect-Failure ($options + @{ Deploy = $true }) 'exit 9'
    Assert-Release ($webTestProbe.FetchCount -eq 0) 'failed upload must not be reported live'
    Remove-Item -LiteralPath (Join-Path $fixtureRoot 'fail-upload')

    Reset-Calls
    New-Item -ItemType File -Path (Join-Path $fixtureRoot 'stale-live') | Out-Null
    Expect-Failure ($options + @{ Deploy = $true }) 'live verification failed'
    Assert-Release ($webTestProbe.FetchCount -eq 6) 'reject a stale public build even when upload succeeds'
    Remove-Item -LiteralPath (Join-Path $fixtureRoot 'stale-live')

    Reset-Calls
    $badServer = $options.Clone()
    $badServer.Server = 'not a server'
    Expect-Failure ($badServer + @{ Deploy = $true }) 'does not look like user@host'
    Expect-Failure ($options + @{ Deploy = $true; GuestUrl = 'https://tarkk.ir' }) 'must match the guest host'
    Expect-Failure ($options + @{ Deploy = $true; BaseHref = '/guest/' }) 'requires a root Guest URL'
    Assert-Release (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'flutter-args.json'))) 'invalid targets rejected before building'
    Assert-Release (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'publish-args.json'))) 'invalid targets never uploaded'
    Write-Host 'Guest web release regression checks passed.'
} finally {
    $env:PATH = $savedPath
    $env:TARK_SERVER = $savedServer
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $buildBoundary = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixture.StartsWith($buildBoundary, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
