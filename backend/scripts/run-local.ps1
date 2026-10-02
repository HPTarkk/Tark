# Starts the backend on http://localhost:8080 using backend/.env.development.
# Usage (from anywhere):  pwsh backend/scripts/run-local.ps1
$ErrorActionPreference = 'Stop'
$backend = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $backend '.env.development'
if (-not (Test-Path $envFile)) { throw "Missing $envFile - copy .env.development.example and run 'go run ./cmd/tarkd keygen'." }

Get-Content $envFile | Where-Object { $_ -match '^\s*[A-Za-z_][A-Za-z0-9_]*=' } | ForEach-Object {
    $name, $value = $_ -split '=', 2
    Set-Item -Path "Env:$($name.Trim())" -Value $value.Trim()
}

Set-Location $backend
go run ./cmd/tarkd serve
