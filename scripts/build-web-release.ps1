#requires -Version 7.0
# Clean, build and publish the Flutter guest app with Wrangler by default.
# Examples: ./scripts/build-web-release.ps1
#           ./scripts/build-web-release.ps1 -BuildOnly
[CmdletBinding()]
param(
    [switch]$Auto,
    [switch]$Deploy,
    [switch]$DryRun,
    [switch]$BuildOnly,
    [switch]$NonInteractive = $true,
    [string]$WorkerName,
    [string]$WranglerConfig = 'wrangler.guest.jsonc',
    [string]$GuestUrl = 'https://app.tarkk.ir',
    [string]$BaseHref,
    [bool]$MakeZip = $false,
    [bool]$CleanFirst = $true,
    [string]$Message
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$utf8 = [Text.UTF8Encoding]::new($false)
if ($Auto) { $Deploy = $true; $NonInteractive = $true }
if ($BuildOnly -and ($Deploy -or $DryRun)) { throw '-BuildOnly cannot be combined with -Deploy or -DryRun.' }
if (-not $BuildOnly -and -not $DryRun -and -not $PSBoundParameters.ContainsKey('Deploy')) {
    $Deploy = $true
}
$savedCi = $env:CI

function Ask([string]$Question, [string]$Default) {
    if ($NonInteractive) { return $Default }
    $answer = Read-Host "$Question [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function AskYesNo([string]$Question, [bool]$Default) {
    if ($NonInteractive) { return $Default }
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $answer = Read-Host "$Question [$hint]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim().ToLowerInvariant().StartsWith('y')
}

function Invoke-CheckedCommand([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed (exit $LASTEXITCODE)." }
}

function Read-DeploymentSettings {
    $path = $WranglerConfig
    if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $repoRoot $path }
    $path = (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
    $config = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    $name = $WorkerName
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$config.name }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = Ask "Existing Cloudflare Worker name for $($guestUri.Host)" ''
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw 'Provide -WorkerName with the existing guest Worker name, or set name in wrangler.guest.jsonc.'
    }
    $name = $name.Trim()
    # Reject the marketing Worker's identity even if an override config is used.
    $siteText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'wrangler.website.jsonc')
    $site = ($siteText -replace '(?m)^\s*//[^\r\n]*', '') | ConvertFrom-Json
    if ($name -eq $site.name) { throw 'The guest release must not target the marketing website Worker.' }
    if ($guestUri.AbsolutePath -ne '/' -or $baseHref -ne '/' -or -not $guestUri.IsDefaultPort) {
        throw 'Wrangler custom-domain publishing requires a root Guest URL and BaseHref /. Use -BuildOnly for subpath hosting.'
    }
    $routes = @($config.routes)
    if ($routes.Count -eq 0 -or @($routes | Where-Object {
        $_.pattern -ne $guestUri.Host -or $_.custom_domain -ne $true
    }).Count -gt 0) {
        throw "Wrangler custom domains must match the guest host $($guestUri.Host). Update $path before publishing."
    }
    if ($config.assets.not_found_handling -ne 'single-page-application') {
        throw 'The guest Wrangler configuration must enable single-page-application asset routing.'
    }
    return [pscustomobject]@{
        Path = $path
        Name = $name
        Command = (Get-Command wrangler -ErrorAction Stop).Source
    }
}

Push-Location -LiteralPath $repoRoot
try {
    # Prevent native tools, including Wrangler login, from opening prompts.
    if ($NonInteractive) { $env:CI = 'true' }
    Write-Host ''
    Write-Host '  TARKK — web guest release' -ForegroundColor Yellow
    $flutterCommand = (Get-Command flutter -ErrorAction Stop).Source
    $guestUrl = (Ask 'Guest app URL (must match the mobile invite URL)' $GuestUrl).TrimEnd('/')
    $guestUri = [Uri]$guestUrl
    if (-not $guestUri.IsAbsoluteUri -or $guestUri.Scheme -ne 'https' -or
        $guestUri.Query -or $guestUri.Fragment -or $guestUri.UserInfo) {
        throw 'Guest URL must be an absolute HTTPS URL without a query, fragment or credentials.'
    }
    if (-not $BaseHref) { $BaseHref = $guestUri.AbsolutePath }
    $baseHref = Ask 'Base href (must start and end with /)' $BaseHref
    if (-not $baseHref.StartsWith('/')) { $baseHref = "/$baseHref" }
    if (-not $baseHref.EndsWith('/')) { $baseHref = "$baseHref/" }
    $makeZip = AskYesNo 'Zip the output for upload?' $MakeZip
    $cleanFirst = AskYesNo 'Run flutter clean first?' $CleanFirst

    # Explicit publishing modes validate their target before the expensive build.
    $deployment = $null
    if ($Deploy -or $DryRun) { $deployment = Read-DeploymentSettings }
    $versionMatch = [regex]::Match([IO.File]::ReadAllText((Join-Path $repoRoot 'pubspec.yaml')), '(?m)^version:\s*(\S+)')
    if (-not $versionMatch.Success) { throw 'Cannot identify the Flutter app version.' }
    $appVersion = $versionMatch.Groups[1].Value
    $commit = & git rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the source commit.' }
    $workingChanges = & git status --porcelain
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the source working tree.' }
    $builtAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $dirty = ([bool]$workingChanges).ToString().ToLowerInvariant()
    $defines = @(
        "--dart-define=GUEST_APP_URL=$guestUrl",
        '--dart-define=BUILD_CHANNEL=web',
        "--dart-define=GIT_COMMIT=$($commit.Trim())",
        "--dart-define=GIT_DIRTY=$dirty",
        "--dart-define=BUILD_TIMESTAMP=$builtAt"
    )
    if ($cleanFirst) { Invoke-CheckedCommand $flutterCommand @('clean') }
    Write-Host '> Building the Flutter guest app' -ForegroundColor Cyan
    Invoke-CheckedCommand $flutterCommand (@('build', 'web', '--release', '--target', 'lib/main_guest.dart', '--base-href', $baseHref) + $defines)
    $outDir = Join-Path $repoRoot 'build/web'
    foreach ($file in @('index.html', 'flutter_bootstrap.js')) {
        if (-not (Test-Path -LiteralPath (Join-Path $outDir $file) -PathType Leaf)) {
            throw "Flutter output is incomplete: $file is missing."
        }
    }
    $release = [ordered]@{
        version = $appVersion
        builtAt = $builtAt
        sourceCommit = $commit.Trim()
        sourceDirty = [bool]$workingChanges
        guestUrl = $guestUrl
    }
    [IO.File]::WriteAllText((Join-Path $outDir 'web-release.json'), (($release | ConvertTo-Json) + [Environment]::NewLine), $utf8)
    if ($makeZip) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $zipPath = Join-Path $repoRoot "build/tark-web-$stamp.zip"
        Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zipPath
    }
    Write-Host "  Build complete: $outDir" -ForegroundColor Green
    if ($makeZip) { Write-Host "  Zip: $zipPath" }

    $publish = $Deploy -or $DryRun
    if (-not $publish -and -not $BuildOnly) {
        $publish = AskYesNo 'Publish this guest app with Wrangler now?' $false
    }
    if ($publish) {
        if ($null -eq $deployment) { $deployment = Read-DeploymentSettings }
        $tag = "web-v$($appVersion.Replace('+', '-'))"
        if (-not $Message) { $Message = "Tarkk guest $appVersion ($($commit.Trim().Substring(0, 7)))" }
        $deployArgs = @('deploy', '--config', $deployment.Path, '--name', $deployment.Name,
            '--assets', $outDir, '--tag', $tag, '--message', $Message)
        if ($DryRun) { $deployArgs += '--dry-run' }
        Write-Host "> Wrangler $(if ($DryRun) { 'dry run' } else { 'deploy' }) -> $($deployment.Name)" -ForegroundColor Cyan
        Invoke-CheckedCommand $deployment.Command $deployArgs
        if ($DryRun) {
            Write-Host 'Dry run passed. Nothing was published.' -ForegroundColor Green
        } else {
            $verified = $false
            for ($attempt = 0; $attempt -lt 6; $attempt++) {
                try {
                    $nonce = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    $live = Invoke-RestMethod -Uri "$guestUrl/web-release.json?release=$nonce" -Headers @{ 'Cache-Control' = 'no-cache' } -TimeoutSec 20
                    $liveBuiltAt = if ($live.builtAt -is [DateTime]) { $live.builtAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } else { [string]$live.builtAt }
                    if ($live.version -eq $appVersion -and $liveBuiltAt -eq $builtAt -and
                        $live.sourceCommit -eq $release.sourceCommit -and $live.guestUrl -eq $guestUrl) {
                        $verified = $true
                        break
                    }
                } catch { Write-Verbose $_ }
                if ($attempt -lt 5) { Start-Sleep -Seconds 3 }
            }
            if (-not $verified) {
                throw "Wrangler uploaded the guest app, but live verification failed. Check $guestUrl/web-release.json before retrying."
            }
            Write-Host "Live: $guestUrl/ ($tag)" -ForegroundColor Green
        }
    } else {
        Write-Host "Output is ready for hosting at $guestUrl/."
    }
    Write-Host "Mobile invite URLs must also use GUEST_APP_URL=$guestUrl."
} finally {
    $env:CI = $savedCi
    Pop-Location
}
