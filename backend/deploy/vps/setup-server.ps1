<#
.SYNOPSIS
  Prepare a fresh Linux server for the Tarkk backend, or check one.

.DESCRIPTION
  Everything a new server needs before deploy.ps1 can ship to it, in one place,
  so moving to another server is the same few commands again:

    1. Key login (once per server; asks for the server's password one time):
         .\setup-server.ps1 -Server root@203.0.113.10 -InstallKey
    2. Look at the server without changing it:
         .\setup-server.ps1 -Server root@203.0.113.10 -Check
    3. Install Docker with the Compose plugin, open ports 80 and 443 in the
       server's firewall, add swap when it has none:
         .\setup-server.ps1 -Server root@203.0.113.10
    4. Turn off password logins, so only the key gets in:
         .\setup-server.ps1 -Server root@203.0.113.10 -LockSsh
    5. Then:  .\deploy.ps1 -Server root@203.0.113.10 -Init

  The work on the server is done by server-setup.sh (next to this script), which
  is safe to run again: each step first looks at what is already there.

  Supported servers: AlmaLinux, Rocky, CentOS Stream, RHEL, Fedora, Ubuntu, Debian.

.PARAMETER Server
  user@host of the server. The user must be root.

.PARAMETER InstallKey
  Add this computer's public SSH key to the server, so later commands need no
  password. ssh asks for the server's password itself; this script never sees it.

.PARAMETER PublicKey
  The public key file for -InstallKey. Default: id_ed25519.pub in your .ssh
  folder (make one with:  ssh-keygen -t ed25519).

.PARAMETER Check
  Only report: the machine, what it can reach (Google sign-in, Let's Encrypt,
  Cafe Bazaar, Docker, mail), Docker, the firewall. Changes nothing.

.PARAMETER LockSsh
  Make the server accept SSH logins with a key only. It first proves that this
  computer's key works, so it cannot lock you out; if the key is ever lost, the
  provider's console in its panel still gets in.

.PARAMETER DockerRepoBase
  Where Docker's packages come from. Default https://download.docker.com. Give a
  mirror with the same layout where that host refuses the server.

.PARAMETER DockerMirrors
  Registry mirrors for pulling the PostgreSQL and Caddy images, comma-separated,
  e.g. https://mirror.example.com. Default: none (Docker Hub directly).

.PARAMETER SwapMB
  Size of the swap file made when the server has no swap (default 2048, 0 = none).

.PARAMETER SmtpCheck
  An extra host:port to test from the server, e.g. mail.example.com:587.

.PARAMETER SshPort
  SSH port (default 22).

.PARAMETER SshKey
  Path to a private key for ssh/scp (optional).

.PARAMETER RemotePath
  Directory on the server that holds the deployment (default /opt/tark).

.PARAMETER DryRun
  Print what would run, change nothing.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [switch]$InstallKey,
    [string]$PublicKey = '',
    [switch]$Check,
    [switch]$LockSsh,
    [string]$DockerRepoBase = '',
    [string]$DockerMirrors = '',
    [int]$SwapMB = 2048,
    [string]$SmtpCheck = '',
    [int]$SshPort = 22,
    [string]$SshKey = '',
    [string]$RemotePath = '/opt/tark',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Here = $PSScriptRoot

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

# These values end up inside a single-quoted word of a shell command on the
# server, so anything that could end the quote is refused, not escaped.
function Assert-Plain([string]$name, [string]$value, [string]$pattern) {
    if ($value -ne '' -and $value -notmatch $pattern) { throw "-$name has characters that are not allowed: $value" }
}

try {
    foreach ($tool in 'ssh', 'scp') {
        if (-not $DryRun -and -not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool was not found. Install the OpenSSH client (Windows: Settings > Optional features)."
        }
    }
    Assert-Plain 'DockerRepoBase' $DockerRepoBase '^https?://[A-Za-z0-9._~:/-]+$'
    Assert-Plain 'DockerMirrors' $DockerMirrors '^[A-Za-z0-9._~:/,-]+$'
    Assert-Plain 'SmtpCheck' $SmtpCheck '^[A-Za-z0-9.-]+:[0-9]+$'
    Assert-Plain 'RemotePath' $RemotePath '^/[A-Za-z0-9._/-]+$'
    if ($SwapMB -lt 0) { throw '-SwapMB cannot be negative.' }

    if (@($InstallKey, $Check, $LockSsh | Where-Object { $_ }).Count -gt 1) { throw 'Give one of -InstallKey, -Check and -LockSsh at a time.' }

    if ($InstallKey) {
        if ($PublicKey -eq '') { $PublicKey = Join-Path (Join-Path $HOME '.ssh') 'id_ed25519.pub' }
        if (-not (Test-Path -LiteralPath $PublicKey -PathType Leaf)) {
            throw "$PublicKey was not found. Make a key first:  ssh-keygen -t ed25519"
        }
        if ($PublicKey -notlike '*.pub') { throw "$PublicKey is not a public key file (.pub). Never send the private key anywhere." }
        $key = (Get-Content -LiteralPath $PublicKey -TotalCount 1).Trim()
        if ($key -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+( [A-Za-z0-9._@:+ -]*)?$') {
            throw "$PublicKey does not look like a public SSH key."
        }
        Step "Adding this computer's key to $Server (ssh asks for the server's password)"
        # Added only when the server does not have it already.
        Invoke-Remote "umask 077 && mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && (grep -qxF '$key' ~/.ssh/authorized_keys || echo '$key' >> ~/.ssh/authorized_keys) && echo 'The key is on the server.'"
        Step 'Trying a login with the key'
        Invoke-Native 'ssh' ($sshArgs + @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', $Server, 'echo Key login works.'))
        return
    }

    $keyOnly = @('-o', 'BatchMode=yes', '-o', 'PreferredAuthentications=publickey', '-o', 'ConnectTimeout=15')
    $mode = 'install'
    if ($Check) { $mode = 'check' }
    if ($LockSsh) {
        $mode = 'lock-ssh'
        Step 'Proving that the key works before passwords are turned off'
        Invoke-Native 'ssh' ($sshArgs + $keyOnly + @($Server, 'echo Key login works.'))
    }

    $settings = "TARK_SWAP_MB='$SwapMB'"
    if ($DockerRepoBase -ne '') { $settings += " TARK_DOCKER_REPO_BASE='$DockerRepoBase'" }
    if ($DockerMirrors -ne '') { $settings += " TARK_DOCKER_MIRRORS='$DockerMirrors'" }
    if ($SmtpCheck -ne '') { $settings += " TARK_SMTP_CHECK='$SmtpCheck'" }

    Step "Sending the setup script to $Server"
    Invoke-Remote "mkdir -p '$RemotePath'"
    Send-File (Join-Path $Here 'server-setup.sh') $RemotePath

    if ($Check) { Step "Checking $Server (changes nothing)" } elseif ($LockSsh) { Step "Turning off password logins on $Server" } else { Step "Setting up $Server" }
    Invoke-Remote "cd '$RemotePath' && $settings bash server-setup.sh $mode"

    if ($LockSsh) {
        Step 'Trying a login with the key again'
        Invoke-Native 'ssh' ($sshArgs + $keyOnly + @($Server, 'echo Key login still works.'))
    } elseif (-not $Check) {
        Write-Host ''
        Write-Host "The server is ready. Next:  .\deploy.ps1 -Server $Server -Init" -ForegroundColor Green
    }
} catch {
    Write-Host ''
    Write-Host "Setup stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
