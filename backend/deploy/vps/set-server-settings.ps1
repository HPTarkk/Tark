<#
.SYNOPSIS
  Fill in the backend's settings on the server (.env.production) without
  opening an editor there.

.DESCRIPTION
  Asks for each setting that deploy.ps1 -Init leaves for you (mail server,
  Cafe Bazaar credentials, alert address) and writes the answers straight to
  the server over SSH. Passwords and tokens are typed hidden, are never shown,
  never stored on this computer and never put on a command line. Press Enter at
  a question to leave that setting as it is on the server.

    Ask for everything:   .\set-server-settings.ps1 -Server root@203.0.113.10
    Only the mail part:   .\set-server-settings.ps1 -Server root@203.0.113.10 -Only Mail
    One plain setting:    .\set-server-settings.ps1 -Server root@203.0.113.10 -Set TARK_ALERT_EMAILS=me@example.com
    What is still empty:  .\set-server-settings.ps1 -Server root@203.0.113.10 -Status

  A copy of the file as it was is kept next to it on the server each time
  (.env.production.bak-<time>, readable by root only). The running backend
  picks changes up at the next deploy:  .\deploy.ps1 -Server root@203.0.113.10

.PARAMETER Server
  user@host of the server.

.PARAMETER Only
  Ask about one group only: Mail, Bazaar or Alerts.

.PARAMETER Set
  NAME=value pairs to write without asking. For values that are not secret:
  what is typed here is visible on screen and in the shell's history.

.PARAMETER Status
  Show which settings are still unfilled and the ones that are not secret.
  Changes nothing and shows no secret.

.PARAMETER SshPort
  SSH port (default 22).

.PARAMETER SshKey
  Path to a private key for ssh (optional).

.PARAMETER RemotePath
  Directory on the server that holds the deployment (default /opt/tark).
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [ValidateSet('', 'Mail', 'Bazaar', 'Alerts')][string]$Only = '',
    [string[]]$Set = @(),
    [switch]$Status,
    [int]$SshPort = 22,
    [string]$SshKey = '',
    [string]$RemotePath = '/opt/tark'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$sshArgs = @('-p', "$SshPort")
if ($SshKey -ne '') { $sshArgs += @('-i', $SshKey) }

# name, group, question, secret
$Questions = @(
    @('TARK_MAIL_FROM', 'Mail', 'Sender address, e.g. noreply@example.com', $false),
    @('TARK_SMTP_HOST', 'Mail', 'Mail server (SMTP host), e.g. mail.example.com', $false),
    @('TARK_SMTP_PORT', 'Mail', 'SMTP port: 587 with starttls, or 465 with tls', $false),
    @('TARK_SMTP_SECURITY', 'Mail', 'SMTP security: starttls or tls', $false),
    @('TARK_SMTP_USERNAME', 'Mail', 'Mailbox user name (usually the full address)', $false),
    @('TARK_SMTP_PASSWORD', 'Mail', 'Mailbox password', $true),
    @('TARK_BAZAAR_CLIENT_ID', 'Bazaar', 'Cafe Bazaar API client id', $true),
    @('TARK_BAZAAR_CLIENT_SECRET', 'Bazaar', 'Cafe Bazaar API client secret', $true),
    @('TARK_BAZAAR_REFRESH_TOKEN', 'Bazaar', 'Cafe Bazaar API refresh token', $true),
    @('TARK_ALERT_EMAILS', 'Alerts', 'Who gets alert emails (comma-separated)', $false)
)

function Read-Secret([string]$prompt) {
    $secure = Read-Host -Prompt $prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Assert-Pair([string]$name, [string]$value) {
    if ($name -notmatch '^TARK_[A-Z0-9_]+$') { throw "$name is not a setting name (TARK_...)." }
    if ($value -match "[`r`n]") { throw "The value of $name has a line break in it." }
}

try {
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        throw 'ssh was not found. Install the OpenSSH client (Windows: Settings > Optional features).'
    }
    if ($RemotePath -notmatch '^/[A-Za-z0-9._/-]+$') { throw "-RemotePath has characters that are not allowed: $RemotePath" }

    if ($Status) {
        & ssh @sshArgs $Server "cd '$RemotePath' && bash remote.sh env-status"
        if ($LASTEXITCODE -ne 0) { throw "ssh failed (exit code $LASTEXITCODE)." }
        return
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($pair in $Set) {
        $at = $pair.IndexOf('=')
        if ($at -lt 1) { throw "-Set takes NAME=value, got: $pair" }
        $name = $pair.Substring(0, $at); $value = $pair.Substring($at + 1)
        Assert-Pair $name $value
        $lines.Add("$name=$value")
    }

    if ($Set.Count -eq 0) {
        Write-Host 'Press Enter to leave a setting as it is on the server. Hidden answers are passwords and tokens.' -ForegroundColor Cyan
        foreach ($q in $Questions) {
            $name, $group, $text, $secret = $q
            if ($Only -ne '' -and $group -ne $Only) { continue }
            if ($secret) { $value = Read-Secret "$text [$name]" } else { $value = Read-Host -Prompt "$text [$name]" }
            $value = "$value".Trim()
            if ($value -eq '') { continue }
            Assert-Pair $name $value
            $lines.Add("$name=$value")
        }
    }

    if ($lines.Count -eq 0) { Write-Host 'Nothing to change.'; return }

    # The values travel on ssh's standard input, never as command arguments, so
    # they are in no process list on either machine.
    $OutputEncoding = New-Object System.Text.UTF8Encoding $false
    ($lines -join "`n") | & ssh @sshArgs $Server "cd '$RemotePath' && bash remote.sh env-set"
    if ($LASTEXITCODE -ne 0) { throw "ssh failed (exit code $LASTEXITCODE)." }
    Write-Host ''
    Write-Host "Saved on the server. It takes effect at the next deploy:  .\deploy.ps1 -Server $Server" -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Host "Stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if (Test-Path variable:lines) { $lines = $null }
}
