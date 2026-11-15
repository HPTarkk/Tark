#requires -Version 7.0
# Clean, build and publish the Flutter guest app to the Tarkk server, which
# serves it at app.tarkk.ir (backend/deploy/vps/publish-sites.ps1).
# Examples: ./scripts/build-web-release.ps1
#           ./scripts/build-web-release.ps1 -BuildOnly
#           ./scripts/build-web-release.ps1 -Server root@203.0.113.10
[CmdletBinding()]
param(
    [switch]$Auto,
    [switch]$Deploy,
    [switch]$DryRun,
    [switch]$BuildOnly,
    [switch]$NonInteractive = $true,
    # user@host of the server. Default: $env:TARK_SERVER, else root@94.184.25.235.
    [string]$Server = $(if ($env:TARK_SERVER) { $env:TARK_SERVER } else { 'root@94.184.25.235' }),
    [int]$SshPort = 22,
    [string]$SshKey = '',
    [string]$GuestUrl = 'https://app.tarkk.ir',
    [string]$BaseHref,
    [bool]$MakeZip = $false,
    [bool]$CleanFirst = $true
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
    if ($guestUri.AbsolutePath -ne '/' -or $baseHref -ne '/' -or -not $guestUri.IsDefaultPort) {
        throw 'Publishing to the server requires a root Guest URL and BaseHref / (it serves the app at the root of its host). Use -BuildOnly for subpath hosting.'
    }
    if ($guestUri.Host -ne 'app.tarkk.ir') {
        throw "The guest URL must match the guest host the server serves, app.tarkk.ir (TARK_GUEST_DOMAIN), not $($guestUri.Host). Use -BuildOnly to build for another host."
    }
    if ($Server -notmatch '^[A-Za-z0-9._-]+@[A-Za-z0-9.:_-]+$') { throw "-Server does not look like user@host: $Server" }
    $script = Join-Path $repoRoot 'backend/deploy/vps/publish-sites.ps1'
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "$script was not found." }
    return [pscustomobject]@{ Script = $script }
}

Push-Location -LiteralPath $repoRoot
try {
    # Prevent native tools from opening prompts.
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
        $publish = AskYesNo "Publish this guest app to $Server now?" $false
    }
    if ($publish) {
        if ($null -eq $deployment) { $deployment = Read-DeploymentSettings }
        $tag = "web-v$($appVersion.Replace('+', '-'))"
        $publishArgs = @{ Server = $Server; Site = 'guest'; GuestDir = $outDir; SshPort = $SshPort }
        if ($SshKey) { $publishArgs.SshKey = $SshKey }
        if ($DryRun) { $publishArgs.DryRun = $true }
        Write-Host "> Publishing $tag to $Server$(if ($DryRun) { ' (dry run)' })" -ForegroundColor Cyan
        $global:LASTEXITCODE = 0
        & $deployment.Script @publishArgs
        if ($LASTEXITCODE -ne 0) { throw "Publishing to $Server failed (exit $LASTEXITCODE)." }
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
                throw "Published the guest app to $Server, but live verification failed. Check $guestUrl/web-release.json before retrying."
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
