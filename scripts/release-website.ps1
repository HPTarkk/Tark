# Version and publish the static marketing site (independent of the Android app).
[CmdletBinding()]
param(
    [ValidateSet('patch', 'minor', 'major')]
    [string]$Bump = 'patch',
    [ValidatePattern('^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$')]
    [string]$Version,
    [string]$Message,
    [switch]$DryRun,
    # Commit the version files but leave pushing to you.
    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$packagePath = Join-Path $repoRoot 'website/package.json'
$manifestPath = Join-Path $repoRoot 'website/site-version.json'
$configPath = Join-Path $repoRoot 'wrangler.website.jsonc'
$utf8 = [Text.UTF8Encoding]::new($false)
$originalPackage = [IO.File]::ReadAllBytes($packagePath)
$hadManifest = Test-Path -LiteralPath $manifestPath
$originalManifest = if ($hadManifest) { [IO.File]::ReadAllBytes($manifestPath) }
$published = $false
$staged = $false

function Invoke-CheckedCommand {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed (exit $LASTEXITCODE)." }
}

Push-Location -LiteralPath $repoRoot
try {
    $nodeCommand = (Get-Command node -ErrorAction Stop).Source
    $wranglerCommand = (Get-Command wrangler -ErrorAction Stop).Source
    $packageText = [IO.File]::ReadAllText($packagePath)
    $package = $packageText | ConvertFrom-Json
    $currentVersion = [version]$package.version
    if (-not $Version) {
        $Version = switch ($Bump) {
            'major' { '{0}.0.0' -f ($currentVersion.Major + 1) }
            'minor' { '{0}.{1}.0' -f $currentVersion.Major, ($currentVersion.Minor + 1) }
            'patch' { '{0}.{1}.{2}' -f $currentVersion.Major, $currentVersion.Minor, ($currentVersion.Build + 1) }
        }
    }
    if ([version]$Version -le $currentVersion) {
        throw "Version $Version must be newer than $currentVersion."
    }
    $tag = "website-v$Version"
    if (-not $Message) { $Message = "Website $Version" }
    $commit = & git rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the source commit.' }
    $workingChanges = & git status --porcelain -- website scripts wrangler.website.jsonc
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the source working tree.' }
    Write-Host "Website $currentVersion -> $Version ($tag)"

    foreach ($generator in @('build-website-i18n.mjs', 'build-legal-pages.mjs')) {
        Invoke-CheckedCommand $nodeCommand @((Join-Path $PSScriptRoot $generator))
    }
    Invoke-CheckedCommand $nodeCommand @((Join-Path $PSScriptRoot 'check-website.mjs'))

    # Keep package formatting and preserve both version files byte-for-byte on failure.
    $nextPackage = [regex]::Replace($packageText, '("version"\s*:\s*")[^"]+(")', "`${1}$Version`${2}")
    $manifest = [ordered]@{
        version = $Version
        tag = $tag
        builtAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        sourceCommit = "$commit".Trim()
        sourceDirty = [bool]$workingChanges
    }
    $staged = $true
    [IO.File]::WriteAllText($packagePath, $nextPackage, $utf8)
    [IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json) + "`n"), $utf8)
    $deployArgs = @('deploy', '--config', $configPath, '--tag', $tag, '--message', $Message)
    if ($DryRun) { $deployArgs += '--dry-run' }
    Invoke-CheckedCommand $wranglerCommand $deployArgs
    if ($DryRun) {
        Write-Host 'Dry run passed. No upload or saved version change.'
    } else {
        $published = $true
        # An assets-only Worker deploy includes every file in website/.
        # Verify the public marker rather than treating a successful upload as live proof.
        $verified = $false
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            try {
                $nonce = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                $live = Invoke-RestMethod -Uri "https://tarkk.ir/site-version.json?release=$nonce" -Headers @{ 'Cache-Control' = 'no-cache' } -TimeoutSec 20
                $liveBuiltAt = if ($live.builtAt -is [DateTime]) { $live.builtAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { [string]$live.builtAt }
                if ($live.version -eq $Version -and $liveBuiltAt -eq $manifest.builtAt -and $live.sourceCommit -eq $manifest.sourceCommit) {
                    $verified = $true
                    break
                }
            } catch { Write-Verbose $_ }
            if ($attempt -lt 5) { Start-Sleep -Seconds 3 }
        }
        if (-not $verified) {
            throw "Wrangler published $tag, but live verification failed. Version files were retained; check tarkk.ir/site-version.json before retrying."
        }
        Write-Host "Live: https://tarkk.ir/ ($tag)."

        # Record the release. Commit only the two version files: the generators above
        # can leave line-ending-only noise in website/*.html that must not ride along.
        $versionFiles = @('website/package.json', 'website/site-version.json')
        try {
            $branch = (& git symbolic-ref --quiet --short HEAD)
            if ($LASTEXITCODE -ne 0 -or -not $branch) { throw 'HEAD is detached.' }
            $branch = "$branch".Trim()
            # A marker that has never been committed must be added before a pathspec commit can take it.
            Invoke-CheckedCommand git (@('add', '--') + $versionFiles)
            Invoke-CheckedCommand git (@('commit', '--quiet', '-m', $Message, '--') + $versionFiles)
            if ($NoPush) {
                Write-Host "Committed $tag on $branch (not pushed)."
            } else {
                # --autostash: the tree is usually dirty with the generators' line-ending noise.
                Invoke-CheckedCommand git @('pull', '--rebase', '--autostash', 'origin', $branch)
                Invoke-CheckedCommand git @('push', 'origin', "HEAD:$branch")
                Write-Host "Committed and pushed $tag to origin/$branch ($((& git rev-parse --short HEAD)))."
            }
        } catch {
            throw "Site is live as $tag, but recording the release failed: $_ Commit and push $($versionFiles -join ' and ') by hand."
        }
    }
} finally {
    if ($staged -and -not $published) {
        [IO.File]::WriteAllBytes($packagePath, $originalPackage)
        if ($hadManifest) { [IO.File]::WriteAllBytes($manifestPath, $originalManifest) }
        elseif (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath }
    }
    Pop-Location
}
