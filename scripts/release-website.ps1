# Version and publish the static marketing site (independent of the Android app)
# to the Tarkk server, which serves it at tarkk.ir (backend/deploy/vps).
[CmdletBinding()]
param(
    # SSH destination (user@host). Defaults to TARK_SERVER or .SERVER.
    [string]$Server = $env:TARK_SERVER,
    [int]$SshPort = 22,
    [string]$SshKey = '',
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
. (Join-Path $PSScriptRoot 'release-server.ps1')
$Server = Resolve-ReleaseServer $repoRoot $Server ($PSBoundParameters.ContainsKey('Server'))
$packagePath = Join-Path $repoRoot 'website/package.json'
$manifestPath = Join-Path $repoRoot 'website/site-version.json'
$publishScript = Join-Path $repoRoot 'backend/deploy/vps/publish-sites.ps1'
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
    if (-not (Test-Path -LiteralPath $publishScript -PathType Leaf)) { throw "$publishScript was not found." }
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
    $workingChanges = & git status --porcelain -- website scripts
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
    $publishArgs = @{ Server = $Server; Site = 'website'; WebsiteDir = (Join-Path $repoRoot 'website'); SshPort = $SshPort }
    if ($SshKey) { $publishArgs.SshKey = $SshKey }
    if ($DryRun) { $publishArgs.DryRun = $true }
    Write-Host "Publishing $tag to $Server$(if ($DryRun) { ' (dry run)' })"
    $global:LASTEXITCODE = 0
    & $publishScript @publishArgs
    if ($LASTEXITCODE -ne 0) { throw "Publishing to $Server failed (exit $LASTEXITCODE)." }
    if ($DryRun) {
        Write-Host 'Dry run passed. No upload or saved version change.'
    } else {
        $published = $true
        # The whole website/ folder was switched in at once on the server.
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
            throw "Published $tag to $Server, but live verification failed. Version files were retained; check tarkk.ir/site-version.json before retrying."
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
