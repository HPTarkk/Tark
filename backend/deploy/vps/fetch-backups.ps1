<#
.SYNOPSIS
  Copy the server's encrypted database backups to this computer.

.DESCRIPTION
  The server makes an encrypted backup every night and keeps the last 14 days.
  A copy that only lives on the server is lost with the server, so run this
  script regularly (by hand, or daily from Windows Task Scheduler). It
  downloads every backup not already in -Destination and checks its size.
  Nothing on the server is changed.

  The files are encrypted with TARK_BACKUP_KEY, which stays on the server and
  in your password manager, never next to the files.

  Needs: ssh (Windows 10/11 has the OpenSSH client) and the same SSH login
  deploy.ps1 uses.

  Example:     .\fetch-backups.ps1 -Server deploy@203.0.113.10
  Scheduled:   Task Scheduler > Create Basic Task > Daily > Start a program:
               powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<path>\fetch-backups.ps1" -Server deploy@203.0.113.10
               (use an SSH key without a passphrase prompt, e.g. -SshKey, so it runs unattended)

.PARAMETER Server
  user@host of the server.

.PARAMETER SshPort
  SSH port (default 22).

.PARAMETER SshKey
  Path to a private key for ssh (optional).

.PARAMETER RemotePath
  Directory on the server that holds the deployment (default /opt/tark).

.PARAMETER Destination
  Local folder for the backups (default: TarkBackups in your user folder).

.PARAMETER DryRun
  List what would be downloaded, download nothing.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$SshPort = 22,
    [string]$SshKey = '',
    [string]$RemotePath = '/opt/tark',
    [string]$Destination = (Join-Path $HOME 'TarkBackups'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$sshArgs = @('-p', "$SshPort", '-o', 'BatchMode=yes')
if ($SshKey -ne '') { $sshArgs += @('-i', $SshKey) }

# Run ssh and stream its stdout into a file byte for byte. (PowerShell 5.1's
# ">" would re-encode the bytes as text and corrupt the backup.)
function Save-Remote([string]$command, [string]$path) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'ssh'
    $quoted = @($sshArgs + @($Server) | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } })
    $psi.Arguments = (($quoted + @("`"$command`"")) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $out = [System.IO.File]::Create($path)
    try { $proc.StandardOutput.BaseStream.CopyTo($out) } finally { $out.Close() }
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        throw "ssh failed (exit code $($proc.ExitCode)): $($errTask.Result)"
    }
}

try {
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        throw 'ssh was not found. Install the OpenSSH client (Windows: Settings > Optional features).'
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    Write-Host "Listing backups on $Server ..." -ForegroundColor Cyan
    $listing = & ssh @sshArgs $Server "cd '$RemotePath' && bash remote.sh backups"
    if ($LASTEXITCODE -ne 0) { throw "Could not list the backups (ssh exit code $LASTEXITCODE)." }

    $new = 0
    foreach ($line in @($listing)) {
        $parts = "$line".Split("`t")
        # Only names the server itself writes; anything else is ignored.
        if ($parts.Count -lt 2 -or $parts[0] -notmatch '^tark-[0-9]{8}-[0-9]{6}\.tbk$') { continue }
        $name = $parts[0]
        $size = [int64]$parts[1]
        $target = Join-Path $Destination $name
        if ((Test-Path $target) -and ((Get-Item $target).Length -eq $size)) { continue }

        if ($DryRun) { Write-Host "  would fetch $name ($size bytes)"; $new++; continue }
        Write-Host "  fetching $name ($size bytes)"
        $partial = "$target.partial"
        Save-Remote "cd '$RemotePath' && bash remote.sh backup-cat '$name'" $partial
        $got = (Get-Item $partial).Length
        if ($got -ne $size) {
            Remove-Item $partial -Force
            throw "$name arrived with $got bytes instead of $size."
        }
        Move-Item -Force $partial $target
        $new++
    }
    Write-Host ''
    if ($new -eq 0) {
        Write-Host "Up to date: every backup on the server is already in $Destination." -ForegroundColor Green
    } else {
        Write-Host "Fetched $new backup(s) into $Destination." -ForegroundColor Green
    }
} catch {
    Write-Host ''
    Write-Host "Fetching backups stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
