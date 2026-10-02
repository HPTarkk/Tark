<#
.SYNOPSIS
  Deploy the Tark backend to a single Linux server (PostgreSQL + API + Caddy HTTPS).

.DESCRIPTION
  Builds the Docker image on this machine, ships it to the server over SSH, and
  starts it with docker compose. Nothing is built on the server, and the image
  does not have to come from Docker Hub (useful where it is hard to reach).

  The server needs: Docker Engine with the Compose plugin, an SSH login that can
  run docker, and a domain whose DNS points at it (Caddy gets the HTTPS
  certificate by itself). This machine needs: Docker, ssh and scp (Windows 10/11
  has the OpenSSH client).

  First deploy:   .\deploy.ps1 -Server deploy@203.0.113.10 -Init
                  (creates .env.production on the server with fresh secrets,
                  then stops so you can fill in the domain, SMTP and
                  Bazaar values; the Google client id is already set:  ssh deploy@203.0.113.10 nano /opt/tark/.env.production)
  Every update:   .\deploy.ps1 -Server deploy@203.0.113.10
  Go back:        .\deploy.ps1 -Server deploy@203.0.113.10 -Rollback

.PARAMETER Server
  user@host of the server.

.PARAMETER SshPort
  SSH port (default 22).

.PARAMETER SshKey
  Path to a private key for ssh/scp (optional).

.PARAMETER RemotePath
  Directory on the server that holds the deployment (default /opt/tark).

.PARAMETER Registry
  Optional registry/namespace, e.g. registry.example.com/myteam. When given, the
  image is pushed there and the server pulls it (the server must be logged in).
  Without it, the image is copied straight to the server.

.PARAMETER Tag
  Image tag. Default: date, time and git commit.

.PARAMETER Init
  First deploy: create .env.production with generated secrets, then stop.

.PARAMETER Rollback
  Return to the previously deployed image. Builds nothing.

.PARAMETER SkipBuild
  Reuse an image that is already built locally (needs -Tag).

.PARAMETER DryRun
  Print what would run, change nothing.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$SshPort = 22,
    [string]$SshKey = '',
    [string]$RemotePath = '/opt/tark',
    [string]$Registry = '',
    [string]$Tag = '',
    [switch]$Init,
    [switch]$Rollback,
    [switch]$SkipBuild,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Here = $PSScriptRoot
$BackendDir = (Resolve-Path (Join-Path $Here '..\..')).Path
$Files = 'docker-compose.prod.yml', 'Caddyfile', '.env.production.example', 'remote.sh'

function Step($text) { Write-Host ''; Write-Host "==> $text" -ForegroundColor Cyan }
function Info($text) { Write-Host "    $text" }

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

# scp reads "C:\dir\file" as host "C", so run it from the files' directory and
# pass bare names. All paths given must be in the same directory.
function Send-File([string[]]$localPaths, [string]$remoteDir) {
    $dir = Split-Path -Parent $localPaths[0]
    $names = @($localPaths | ForEach-Object { Split-Path -Leaf $_ })
    Push-Location $dir
    try { Invoke-Native 'scp' ($scpArgs + $names + @("${Server}:$remoteDir/")) } finally { Pop-Location }
}

try {
    foreach ($tool in 'ssh', 'scp') {
        if (-not $DryRun -and -not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool was not found. Install the OpenSSH client (Windows: Settings > Optional features)."
        }
    }

    if ($Rollback) {
        Step "Rolling back on $Server"
        Invoke-Remote "cd '$RemotePath' && bash remote.sh rollback"
        Write-Host ''; Write-Host 'Rolled back.' -ForegroundColor Green
        return
    }

    if (-not $DryRun -and -not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Docker was not found on this machine. Install Docker Desktop to build the image.'
    }
    if ($Tag -eq '') {
        $sha = 'nogit'
        if (Get-Command git -ErrorAction SilentlyContinue) {
            $short = (& git -C $BackendDir rev-parse --short HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and $short) { $sha = $short }
        }
        $Tag = "$(Get-Date -Format 'yyyyMMdd-HHmm')-$sha"
    }
    $repo = 'tark-api'
    if ($Registry -ne '') { $repo = "$($Registry.TrimEnd('/'))/tark-api" }
    $image = "${repo}:$Tag"
    Write-Host "Deploying $image to $Server`:$RemotePath" -ForegroundColor Green

    if (-not $SkipBuild) {
        Step 'Building the image'
        Invoke-Native 'docker' @('build', '-t', $image, $BackendDir)
    }

    Step 'Preparing the server'
    Invoke-Remote "mkdir -p '$RemotePath'"
    Send-File ($Files | ForEach-Object { Join-Path $Here $_ }) $RemotePath

    Step 'Shipping the image'
    if ($Registry -ne '') {
        Invoke-Native 'docker' @('push', $image)
        Invoke-Remote "docker pull '$image'"
    } else {
        $tar = Join-Path ([System.IO.Path]::GetTempPath()) "tark-api-$Tag.tar"
        try {
            Invoke-Native 'docker' @('save', '-o', $tar, $image)
            Send-File @($tar) $RemotePath
            Invoke-Remote "cd '$RemotePath' && docker load -i 'tark-api-$Tag.tar' && rm -f 'tark-api-$Tag.tar'"
        } finally {
            if (Test-Path $tar) { Remove-Item $tar -Force }
        }
    }

    if ($Init) {
        Step 'Creating .env.production on the server'
        Invoke-Remote "cd '$RemotePath' && bash remote.sh init '$image'"
        Write-Host ''
        Write-Host "Next: fill in the CHANGE_ME values, then deploy again without -Init:" -ForegroundColor Yellow
        Write-Host "  ssh -p $SshPort $Server nano $RemotePath/.env.production"
        return
    }

    Step 'Starting it'
    Invoke-Remote "cd '$RemotePath' && bash remote.sh up '$image'"
    Write-Host ''
    Write-Host "Done. If something looks wrong:  .\deploy.ps1 -Server $Server -Rollback" -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Host "Deploy stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
