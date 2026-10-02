<#
.SYNOPSIS
  Build the Tark backend image and push it to a container registry, ready for
  ArvanCloud's container hosting (or any platform that pulls from a registry).

.DESCRIPTION
  This script only builds and pushes. Creating the app on the platform, its
  secrets and its database is done in the platform's panel: see
  backend\DEPLOYMENT.md ("ArvanCloud container hosting") for the checklist.

  Registry details come from your ArvanCloud panel; none are assumed here.

.PARAMETER Registry
  Registry host and namespace exactly as the panel shows them,
  e.g. registry.example.com/my-namespace

.PARAMETER Username
  Registry user. If given, the script runs docker login first and asks for the
  password (hidden). Leave it out if you are already logged in.

.PARAMETER Tag
  Image tag. Default: date, time and git commit.

.PARAMETER Latest
  Also push the image as :latest.

.PARAMETER DryRun
  Print what would run, change nothing.

.EXAMPLE
  .\build-and-push.ps1 -Registry registry.example.com/my-namespace -Username me
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Registry,
    [string]$Username = '',
    [string]$Tag = '',
    [switch]$Latest,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$BackendDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Step($text) { Write-Host ''; Write-Host "==> $text" -ForegroundColor Cyan }

function Invoke-Native([string]$exe, [string[]]$arguments) {
    if ($DryRun) { Write-Host "    [dry run] $exe $($arguments -join ' ')" -ForegroundColor DarkGray; return }
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "$exe failed (exit code $LASTEXITCODE)." }
}

try {
    if (-not $DryRun -and -not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Docker was not found. Install Docker Desktop and start it.'
    }
    $Registry = $Registry.Trim().TrimEnd('/')
    $registryHost = $Registry.Split('/')[0]
    if ($Tag -eq '') {
        $sha = 'nogit'
        if (Get-Command git -ErrorAction SilentlyContinue) {
            $short = (& git -C $BackendDir rev-parse --short HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and $short) { $sha = $short }
        }
        $Tag = "$(Get-Date -Format 'yyyyMMdd-HHmm')-$sha"
    }
    $image = "$Registry/tark-api:$Tag"

    if ($Username -ne '') {
        Step "Logging in to $registryHost"
        if ($DryRun) {
            Write-Host "    [dry run] docker login $registryHost -u $Username --password-stdin" -ForegroundColor DarkGray
        } else {
            $secure = Read-Host "    Password for $Username" -AsSecureString
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try {
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
                # Through stdin, so the password never appears in a process list or history.
                $plain | & docker login $registryHost -u $Username --password-stdin
                if ($LASTEXITCODE -ne 0) { throw 'docker login failed.' }
            } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        }
    }

    Step "Building $image"
    Invoke-Native 'docker' @('build', '-t', $image, $BackendDir)

    Step 'Pushing'
    Invoke-Native 'docker' @('push', $image)
    if ($Latest) {
        $latestImage = "$Registry/tark-api:latest"
        Invoke-Native 'docker' @('tag', $image, $latestImage)
        Invoke-Native 'docker' @('push', $latestImage)
    }

    Write-Host ''
    Write-Host "Pushed $image" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Next, on the platform (details: backend\DEPLOYMENT.md):' -ForegroundColor Yellow
    Write-Host '  1. Create the app from this image and set its secrets and environment variables.'
    Write-Host '  2. Generate the secrets once with:   docker run --rm ' -NoNewline; Write-Host "$image keygen"
    Write-Host '  3. Health checks: GET /healthz (alive) and GET /readyz (database reachable), port 8080.'
} catch {
    Write-Host ''
    Write-Host "Stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
