#requires -Version 7.0
# Exercise deployment boundaries with fake Flutter/Wrangler commands and HTTP.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path $repoRoot ('build/guest-release-test-' + [Guid]::NewGuid().ToString('N'))
$savedPath = $env:PATH
$utf8 = [Text.UTF8Encoding]::new($false)
$webTestProbe = @{ FetchCount = 0 }
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
    if ($Prompt.StartsWith('Publish this guest app')) { return 'y' }
    return ''
}
function Reset-Calls {
    $webTestProbe.FetchCount = 0
    foreach ($name in @('flutter-args.json', 'wrangler-args.json')) {
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
    foreach ($dir in @('scripts', 'website', 'bin')) {
        New-Item -ItemType Directory -Path (Join-Path $fixtureRoot $dir) -Force | Out-Null
    }
    $fixtureRelease = Join-Path $fixtureRoot 'scripts/build-web-release.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'build-web-release.ps1') -Destination $fixtureRelease
    Copy-Item -LiteralPath (Join-Path $repoRoot 'wrangler.guest.jsonc') -Destination $fixtureRoot
    $fixtureConfigPath = Join-Path $fixtureRoot 'wrangler.guest.jsonc'
    $fixtureConfig = Get-Content -Raw -LiteralPath $fixtureConfigPath | ConvertFrom-Json
    $fixtureConfig.name = 'guest-config-test'
    [IO.File]::WriteAllText($fixtureConfigPath, ($fixtureConfig | ConvertTo-Json -Depth 10), $utf8)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'wrangler.website.jsonc'), '{"name":"marketing-test"}', $utf8)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'pubspec.yaml'), 'version: 1.2.3+42', $utf8)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'bin/flutter.ps1'), @'
$root = Split-Path -Parent $PSScriptRoot
$args | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'flutter-args.json')
if (Test-Path -LiteralPath (Join-Path $root 'fail-build')) { exit 7 }
$out = Join-Path $root 'build/web'
New-Item -ItemType Directory -Path $out -Force | Out-Null
Set-Content -LiteralPath (Join-Path $out 'index.html') -Value '<html>fixture</html>'
Set-Content -LiteralPath (Join-Path $out 'flutter_bootstrap.js') -Value '// fixture'
exit 0
'@, $utf8)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'bin/wrangler.ps1'), @'
$root = Split-Path -Parent $PSScriptRoot
$args | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'wrangler-args.json')
if (Test-Path -LiteralPath (Join-Path $root 'fail-upload')) { exit 9 }
exit 0
'@, $utf8)
    # Unix command discovery requires an executable filename without .ps1.
    if ([IO.Path]::DirectorySeparatorChar -eq '/') {
        foreach ($command in @('flutter', 'wrangler')) {
            $scriptPath = Join-Path $fixtureRoot "bin/$command.ps1"
            $commandPath = Join-Path $fixtureRoot "bin/$command"
            [IO.File]::WriteAllText($commandPath, ("#!/usr/bin/env pwsh`n" + [IO.File]::ReadAllText($scriptPath)), $utf8)
            & chmod +x $commandPath
            if ($LASTEXITCODE -ne 0) { throw 'Could not make fixture command executable.' }
        }
    }
    $env:PATH = (Join-Path $fixtureRoot 'bin') + [IO.Path]::PathSeparator + $savedPath
    $originalLocation = (Get-Location).Path
    $options = @{ NonInteractive = $true; WorkerName = 'guest-test'; MakeZip = $false; IncludeLanding = $false }

    & $fixtureRelease @options -BuildOnly
    Assert-Release (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'wrangler-args.json'))) 'build-only must not upload'
    Assert-Release ((Get-Location).Path -eq $originalLocation) 'restore caller directory on success'

    $configDefaults = $options.Clone()
    $configDefaults.Remove('WorkerName')
    & $fixtureRelease @configDefaults -DryRun
    $upload = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'wrangler-args.json') | ConvertFrom-Json
    Assert-Release ($upload -contains 'guest-config-test') 'use the existing Worker name from configuration'

    & $fixtureRelease @options -DryRun
    $upload = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'wrangler-args.json') | ConvertFrom-Json
    Assert-Release ($upload -contains '--dry-run' -and $upload -contains 'guest-test') 'dry run targets the requested guest Worker'
    Assert-Release ($upload -contains (Join-Path $fixtureRoot 'build/web')) 'publish Flutter build assets'
    Assert-Release ($webTestProbe.FetchCount -eq 0) 'dry run must not verify a live upload'
    $build = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'flutter-args.json') | ConvertFrom-Json
    Assert-Release ($build -contains 'lib/main_guest.dart' -and $build -contains '--dart-define=GUEST_APP_URL=https://app.tarkk.ir') 'guest entrypoint and invite URL'
    $metadata = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'build/web/web-release.json') | ConvertFrom-Json
    Assert-Release ($metadata.version -eq '1.2.3+42' -and $metadata.sourceCommit -match '^[0-9a-f]{40}$') 'release provenance'
    Assert-Release ((Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'pubspec.yaml')) -eq 'version: 1.2.3+42') 'web publish must not bump Android version'

    Reset-Calls
    & $fixtureRelease @options -Deploy
    $upload = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'wrangler-args.json') | ConvertFrom-Json
    Assert-Release ($upload -notcontains '--dry-run' -and $upload -contains 'web-v1.2.3-42') 'production deploy arguments'
    Assert-Release ($webTestProbe.FetchCount -eq 1) 'successful release verifies its public marker'

    Reset-Calls
    $interactive = $options.Clone()
    $interactive.Remove('NonInteractive')
    & $fixtureRelease @interactive
    Assert-Release (Test-Path -LiteralPath (Join-Path $fixtureRoot 'wrangler-args.json')) 'interactive publishing offered after building'

    Reset-Calls
    New-Item -ItemType File -Path (Join-Path $fixtureRoot 'fail-build') | Out-Null
    Expect-Failure ($options + @{ Deploy = $true }) 'exit 7'
    Assert-Release (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'wrangler-args.json'))) 'failed build must not publish stale output'
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
    $wrongWorker = $options.Clone()
    $wrongWorker.WorkerName = 'marketing-test'
    Expect-Failure ($wrongWorker + @{ Deploy = $true }) 'marketing website Worker'
    Expect-Failure ($options + @{ Deploy = $true; GuestUrl = 'https://tarkk.ir' }) 'must match the guest host'
    Expect-Failure ($options + @{ Deploy = $true; BaseHref = '/guest/' }) 'requires a root Guest URL'
    Assert-Release (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'flutter-args.json'))) 'invalid targets rejected before building'
    Assert-Release (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'wrangler-args.json'))) 'invalid targets never uploaded'
    Write-Host 'Guest web release regression checks passed.'
} finally {
    $env:PATH = $savedPath
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $buildBoundary = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixture.StartsWith($buildBoundary, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
