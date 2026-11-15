<#
.SYNOPSIS
  Make this computer download the server's backups every day by itself.

.DESCRIPTION
  Registers a Windows scheduled task that runs fetch-backups.ps1 (next to this
  script) once a day. If the computer was off or asleep at that time, the task
  runs as soon as it is on again, and it waits for a network connection. It
  runs as you, only while you are signed in to Windows, and needs no
  administrator rights and no password.

    Set it up:        .\schedule-backup-fetch.ps1 -Server root@203.0.113.10
    Look at it:       .\schedule-backup-fetch.ps1 -Status
    Run it now:       .\schedule-backup-fetch.ps1 -RunNow
    Take it away:     .\schedule-backup-fetch.ps1 -Remove

  Running the set-up again replaces the task (new server, new time, new folder).
  What each run printed is kept in fetch.log in the backup folder.

  The task uses the same SSH key login as deploy.ps1; the key must work
  without a passphrase prompt. The backups are encrypted with TARK_BACKUP_KEY,
  which is not stored on this computer by any of these scripts: keep it in a
  password manager, a backup cannot be restored without it.

  If this folder of the repository moves, run the set-up again: the task
  remembers where fetch-backups.ps1 was.

.PARAMETER Server
  user@host of the server.

.PARAMETER At
  Time of day for the daily run, HH:mm in this computer's time (default 09:00).

.PARAMETER Destination
  Local folder for the backups (default: TarkBackups in your user folder).

.PARAMETER SshPort
  SSH port (default 22).

.PARAMETER SshKey
  Path to a private key for ssh (optional).

.PARAMETER RemotePath
  Directory on the server that holds the deployment (default /opt/tark).

.PARAMETER TaskName
  Name of the scheduled task (default: Tarkk backup download).

.PARAMETER Status
  Show the task, when it last ran and how that went. Changes nothing.

.PARAMETER RunNow
  Start the task now, wait for it and show the end of its log.

.PARAMETER Remove
  Delete the task. Downloaded backups stay where they are.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Server = '',
    [string]$At = '09:00',
    [string]$Destination = (Join-Path $HOME 'TarkBackups'),
    [int]$SshPort = 22,
    [string]$SshKey = '',
    [string]$RemotePath = '/opt/tark',
    [string]$TaskName = 'Tarkk backup download',
    [switch]$Status,
    [switch]$RunNow,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-Task { Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }

function Show-Task {
    $task = Get-Task
    if (-not $task) { Write-Host "There is no task named '$TaskName' on this computer."; return }
    $info = $task | Get-ScheduledTaskInfo
    Write-Host "Task:      $TaskName ($($task.State))"
    Write-Host "Runs:      $($task.Actions[0].Execute) $($task.Actions[0].Arguments)"
    Write-Host "Next run:  $($info.NextRunTime)"
    if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) {
        $how = if ($info.LastTaskResult -eq 0) { 'it worked' } else { "it FAILED (code $($info.LastTaskResult)); see fetch.log in the backup folder" }
        Write-Host "Last run:  $($info.LastRunTime), $how"
    } else {
        Write-Host 'Last run:  not yet'
    }
}

try {
    if (@($Status, $RunNow, $Remove | Where-Object { $_ }).Count -gt 1) { throw 'Give one of -Status, -RunNow and -Remove at a time.' }
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) { throw 'This needs Windows (the ScheduledTasks commands were not found).' }
    if ($TaskName -notmatch '^[A-Za-z0-9 ._-]+$') { throw "-TaskName has characters that are not allowed: $TaskName" }

    if ($Status) { Show-Task; return }

    if ($Remove) {
        if (Get-Task) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Removed the task '$TaskName'. Downloaded backups were left alone." -ForegroundColor Green
        } else { Write-Host "There is no task named '$TaskName'." }
        return
    }

    if ($RunNow) {
        if (-not (Get-Task)) { throw "There is no task named '$TaskName'. Set it up first with -Server." }
        Start-ScheduledTask -TaskName $TaskName
        Write-Host 'Started; waiting for it to finish ...'
        $deadline = (Get-Date).AddMinutes(15)
        do { Start-Sleep -Seconds 2 } while ((Get-Task).State -eq 'Running' -and (Get-Date) -lt $deadline)
        Show-Task
        return
    }

    # Set-up.
    if ($Server -eq '') { throw 'Give -Server user@host.' }
    if ($Server -notmatch '^[A-Za-z0-9._-]+@[A-Za-z0-9.:_-]+$') { throw "-Server does not look like user@host: $Server" }
    if ($RemotePath -notmatch '^/[A-Za-z0-9._/-]+$') { throw "-RemotePath has characters that are not allowed: $RemotePath" }
    $time = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($At, 'HH:mm', [cultureinfo]::InvariantCulture, 'None', [ref]$time)) { throw "-At must be a time like 09:00, got: $At" }

    $fetch = Join-Path $PSScriptRoot 'fetch-backups.ps1'
    if (-not (Test-Path -LiteralPath $fetch -PathType Leaf)) { throw "$fetch was not found." }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $Destination = (Resolve-Path -LiteralPath $Destination).Path
    $log = Join-Path $Destination 'fetch.log'
    if ($SshKey -ne '') {
        if (-not (Test-Path -LiteralPath $SshKey -PathType Leaf)) { throw "$SshKey was not found." }
        $SshKey = (Resolve-Path -LiteralPath $SshKey).Path
    }
    # These paths are placed inside single quotes on the task's command line.
    foreach ($p in $fetch, $Destination, $SshKey) {
        if ($p -match "['`"``$]") { throw "This path has a quote, backtick or dollar sign in it, which the task cannot carry: $p" }
    }

    $call = "& '$fetch' -Server '$Server' -SshPort $SshPort -RemotePath '$RemotePath' -Destination '$Destination'"
    if ($SshKey -ne '') { $call += " -SshKey '$SshKey'" }
    # One dated line per run, then everything the run printed; the task's result
    # is the script's own exit code.
    $command = "'--- ' + (Get-Date -Format s) | Out-File -Append -Encoding utf8 '$log'; $call *>&1 | Out-File -Append -Encoding utf8 '$log'; exit `$LASTEXITCODE"
    $shell = (Get-Command powershell.exe).Source
    $action = New-ScheduledTaskAction -Execute $shell -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$command`""
    $trigger = New-ScheduledTaskTrigger -Daily -At $time
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description "Downloads the Tarkk server's encrypted database backups to $Destination every day (backend/deploy/vps/schedule-backup-fetch.ps1)." -Force | Out-Null

    Write-Host "Done. Every day at $At this computer downloads new backups from $Server into $Destination" -ForegroundColor Green
    Write-Host '(or as soon as it is on again, when it was off at that time).'
    Write-Host "Try it once now:  .\schedule-backup-fetch.ps1 -RunNow"
} catch {
    Write-Host ''
    Write-Host "Stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
