# Creates an owner login for the local admin panel (http://localhost:8081)
# using backend/.env.development. Prints a one-time password; at first sign-in
# you choose your own password and add the account to an authenticator app.
# Usage (from anywhere):  pwsh backend/scripts/admin-local.ps1 you@example.com [Your name]
param(
    [Parameter(Mandatory = $true)][string]$Email,
    [string]$Name = 'Local owner'
)
$ErrorActionPreference = 'Stop'
$backend = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $backend '.env.development'
if (-not (Test-Path $envFile)) { throw "Missing $envFile - run .\backend\setup-backend.ps1 first." }

Get-Content $envFile | Where-Object { $_ -match '^\s*[A-Za-z_][A-Za-z0-9_]*=' } | ForEach-Object {
    $key, $value = $_ -split '=', 2
    Set-Item -Path "Env:$($key.Trim())" -Value $value.Trim()
}

Set-Location $backend
go run ./cmd/tarkd admin-create $Email owner $Name
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$addr = if ($env:TARK_ADMIN_ADDR) { $env:TARK_ADMIN_ADDR -replace '^127\.0\.0\.1', 'localhost' } else { 'localhost:8081' }
Write-Host ""
Write-Host "Open http://$addr while the API is running (setup-backend.ps1 or scripts/run-local.ps1)."
