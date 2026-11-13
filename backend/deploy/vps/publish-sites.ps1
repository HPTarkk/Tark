<#
.SYNOPSIS
  Publish the website (tarkk.ir) and the browser guest app (app.tarkk.ir) to the
  server that runs the backend.

.DESCRIPTION
  Both are folders of static files. This packs a folder on this machine, copies
  it to the server over SSH and switches the server to it in one step, so no
  visitor gets a mix of old and new files. Caddy (already part of the stack)
  serves them; see the Caddyfile next to this script.

  The stack must have been deployed once with deploy.ps1. Until
  TARK_SITE_DOMAIN / TARK_GUEST_DOMAIN are set in .env.production on the server,
  the sites only answer under stand-in names, which is how to check them before
  the domain's DNS is switched:

      curl -H "Host: site.localhost"  http://<server address>/
      curl -H "Host: guest.localhost" http://<server address>/

  Website:    .\publish-sites.ps1 -Server root@203.0.113.10 -Site website
  Guest app:  .\publish-sites.ps1 -Server root@203.0.113.10 -Site guest
              (build it first: scripts\build-web-release.ps1 -BuildOnly)
  Both:       .\publish-sites.ps1 -Server root@203.0.113.10 -Site all
  Go back:    .\publish-sites.ps1 -Server root@203.0.113.10 -Site website -Rollback

.PARAMETER Server
  user@host of the server.

.PARAMETER Site
  website, guest or all.

.PARAMETER WebsiteDir
  The website's files. Default: the repository's website folder.

.PARAMETER GuestDir
  The built guest app. Default: the repository's build\web folder.

.PARAMETER SshPort
  SSH port (default 22).

.PARAMETER SshKey
  Path to a private key for ssh/scp (optional).

.PARAMETER RemotePath
  Directory on the server that holds the deployment (default /opt/tark).

.PARAMETER Rollback
  Return the site to the files published before the current ones. Uploads nothing.

.PARAMETER DryRun
  Print what would run, change nothing.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [Parameter(Mandatory = $true)][ValidateSet('website', 'guest', 'all')][string]$Site,
    [string]$WebsiteDir = '',
    [string]$GuestDir = '',
    [int]$SshPort = 22,
    [string]$SshKey = '',
    [string]$RemotePath = '/opt/tark',
    [switch]$Rollback,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Here = $PSScriptRoot
$RepoRoot = (Resolve-Path (Join-Path $Here '..\..\..')).Path
if ($WebsiteDir -eq '') { $WebsiteDir = Join-Path $RepoRoot 'website' }
if ($GuestDir -eq '') { $GuestDir = Join-Path (Join-Path $RepoRoot 'build') 'web' }

function Step($text) { Write-Host ''; Write-Host "==> $text" -ForegroundColor Cyan }

function Invoke-Native([string]$exe, [string[]]$arguments) {
    if ($DryRun) { Write-Host "    [dry run] $exe $($arguments -join ' ')" -ForegroundColor DarkGray; return }
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "$exe failed (exit code $LASTEXITCODE)." }
}

$sshArgs = @('-p', "$SshPort")
$scpArgs = @('-P', "$SshPort")
if ($SshKey -ne '') { $sshArgs += @('-i', $SshKey); $scpArgs += @('-i', $SshKey) }

function Invoke-Remote([string]$command) {
    Invoke-Native 'ssh' ($sshArgs + @($Server, $command))
}

# scp reads "C:\dir\file" as host "C", so run it from the file's directory and
# pass the bare name.
function Send-File([string]$localPath, [string]$remoteDir) {
    $dir = Split-Path -Parent $localPath
    $name = Split-Path -Leaf $localPath
    Push-Location $dir
    try { Invoke-Native 'scp' ($scpArgs + @($name, "${Server}:$remoteDir/")) } finally { Pop-Location }
}

function Publish-Folder([string]$name, [string]$folder) {
    if (-not (Test-Path -LiteralPath (Join-Path $folder 'index.html') -PathType Leaf)) {
        $hint = ''
        if ($name -eq 'guest') { $hint = ' Build the guest app first: scripts\build-web-release.ps1 -BuildOnly' }
        throw "$folder has no index.html, so it is not the $name site.$hint"
    }
    $folder = (Resolve-Path -LiteralPath $folder).Path
    $count = @(Get-ChildItem -LiteralPath $folder -Recurse -File).Count
    Step "Publishing $name ($count files from $folder)"

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $archiveName = "tark-site-$name-$stamp.tgz"
    $archive = Join-Path ([System.IO.Path]::GetTempPath()) $archiveName
    try {
        # Packed from inside the folder, so the archive holds the files
        # themselves, not the folder.
        Push-Location $folder
        try { Invoke-Native $Tar @('-czf', $archive, '.') } finally { Pop-Location }
        Send-File $archive $RemotePath
        Invoke-Remote "cd '$RemotePath' && bash remote.sh site-install '$name' '$archiveName'"
    } finally {
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    }
}

# Windows 10 and 11 ship a tar that understands "C:\..." paths. Git for
# Windows puts another one on PATH that reads "C:" as a host name, so the
# system one is named outright when it exists.
$Tar = 'tar'
if ($env:SystemRoot) {
    $systemTar = Join-Path (Join-Path $env:SystemRoot 'System32') 'tar.exe'
    if (Test-Path -LiteralPath $systemTar) { $Tar = $systemTar }
}

try {
    $tools = @('ssh', 'scp')
    if (-not $Rollback) { $tools += $Tar }
    foreach ($tool in $tools) {
        if (-not $DryRun -and -not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool was not found. ssh and scp come with the OpenSSH client (Windows: Settings > Optional features); tar comes with Windows 10 and 11."
        }
    }

    $names = @($Site)
    if ($Site -eq 'all') { $names = @('website', 'guest') }

    if ($Rollback) {
        foreach ($name in $names) {
            Step "Returning $name to its previous files on $Server"
            Invoke-Remote "cd '$RemotePath' && bash remote.sh site-rollback '$name'"
        }
        Write-Host ''; Write-Host 'Rolled back.' -ForegroundColor Green
        return
    }

    # The server's copy of remote.sh may be older than this script.
    Step 'Preparing the server'
    Invoke-Remote "mkdir -p '$RemotePath'"
    Send-File (Join-Path $Here 'remote.sh') $RemotePath

    foreach ($name in $names) {
        $folder = $WebsiteDir
        if ($name -eq 'guest') { $folder = $GuestDir }
        Publish-Folder $name $folder
    }

    Write-Host ''
    Write-Host "Done. If something looks wrong:  .\publish-sites.ps1 -Server $Server -Site $Site -Rollback" -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Host "Publish stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
