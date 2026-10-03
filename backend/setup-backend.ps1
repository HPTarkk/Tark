<#
.SYNOPSIS
  One command to get the Tark backend running on your machine for testing.

.DESCRIPTION
  Run it from anywhere:  .\backend\setup-backend.ps1
  Re-running is safe: every step checks what is already done.

  What it does, in order:
    1. Makes sure Go is installed (offers to install it with winget).
    2. Starts PostgreSQL: in Docker if Docker is running, else a native
       PostgreSQL (installed with winget if you agree), or the one you point
       it at with -Database external.
    3. Creates backend\.env.development with freshly generated secrets
       (never committed: it is git-ignored).
    4. Builds the server and applies the database migrations.
    5. Runs the test suite against a separate "tark_test" database.
    6. Starts the API and waits until it answers, then prints the URLs.
       Press Ctrl+C to stop it.

  Works in Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER Database
  auto (default): Docker if it is running, otherwise native PostgreSQL.
  docker | native | external. "external" uses -DatabaseUrl and needs nothing installed.

.PARAMETER DatabaseUrl
  PostgreSQL URL for -Database external, e.g.
  postgres://tark:tark@localhost:5432/tark?sslmode=disable

.PARAMETER TestDatabaseUrl
  URL of a SEPARATE database for the tests (they wipe its public schema).
  Derived automatically for docker and native; required to run tests with external.

.PARAMETER DbPort
  Host port for the local PostgreSQL (default 5432).

.PARAMETER HttpPort
  Port the API listens on (default 8080).

.PARAMETER AdminPort
  Port the admin panel listens on, on this computer only (default 8081).
  Create a login for it with .\backend\scripts\admin-local.ps1.

.PARAMETER GoProxy
  Value for GOPROXY if the default Go module proxy is not reachable from your network.

.PARAMETER SkipTests
  Do not run the test suite.

.PARAMETER NoRun
  Set everything up but do not start the API.

.PARAMETER Reset
  Start from scratch: regenerate the secrets and, in Docker mode, wipe the database volume.

.PARAMETER Yes
  Answer yes to every question (installing software, resetting).

.EXAMPLE
  .\backend\setup-backend.ps1

.EXAMPLE
  .\backend\setup-backend.ps1 -Database external -DatabaseUrl 'postgres://tark:tark@localhost:5432/tark?sslmode=disable' -TestDatabaseUrl 'postgres://tark:tark@localhost:5432/tark_test?sslmode=disable'
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('auto', 'docker', 'native', 'external')]
    [string]$Database = 'auto',
    [string]$DatabaseUrl = '',
    [string]$TestDatabaseUrl = '',
    [int]$DbPort = 5432,
    [int]$HttpPort = 8080,
    [int]$AdminPort = 8081,
    [string]$GoProxy = '',
    [switch]$SkipTests,
    [switch]$NoRun,
    [switch]$Reset,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$BackendDir = $PSScriptRoot
$ComposeFile = Join-Path $BackendDir 'docker-compose.dev.yml'
$EnvFile = Join-Path $BackendDir '.env.development'
$EnvExample = Join-Path $BackendDir '.env.development.example'
$LocalDir = Join-Path $BackendDir '.local'
$IsWin = [System.IO.Path]::DirectorySeparatorChar -eq '\'
$ExeName = if ($IsWin) { 'tarkd.exe' } else { 'tarkd' }
$Exe = Join-Path (Join-Path $LocalDir 'bin') $ExeName
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---- small helpers -----------------------------------------------------------

function Step($text) { Write-Host ''; Write-Host "==> $text" -ForegroundColor Cyan }
function Ok($text) { Write-Host "    [ok] $text" -ForegroundColor Green }
function Info($text) { Write-Host "    $text" }
function Warn($text) { Write-Host "    [!] $text" -ForegroundColor Yellow }

function Test-Command($name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Confirm-Action($question) {
    if ($Yes) { return $true }
    $answer = Read-Host "    $question [Y/n]"
    return ($answer -eq '' -or $answer -match '^(y|yes)$')
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($machine -or $user) { $env:Path = "$machine;$user" }
}

# Runs a native command and shows its output. Out-Host matters: in PowerShell a
# function returns everything it writes to the pipeline, so without it a
# command's output would leak into the value some function returns.
# Stops on a non-zero exit code.
function Invoke-Checked([string]$what, [scriptblock]$block) {
    & $block | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit code $LASTEXITCODE)." }
}

# Runs a native probe quietly and reports success. In Windows PowerShell 5.1 a
# native command that writes to stderr raises a terminating error under
# $ErrorActionPreference = 'Stop', even when redirected, so relax it here.
function Test-Native([scriptblock]$block) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $block *> $null; return ($LASTEXITCODE -eq 0) } catch { return $false } finally { $ErrorActionPreference = $old }
}

function Wait-Until([scriptblock]$condition, [int]$seconds, [string]$what) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        try { if (& $condition) { return } } catch { }
        Start-Sleep -Seconds 1
    }
    throw "Timed out after $seconds s waiting for $what."
}

function Get-DbUrl([string]$name) {
    return "postgres://tark:tark@localhost:$DbPort/${name}?sslmode=disable"
}

# ---- env file ----------------------------------------------------------------

function Read-EnvLines { return @(Get-Content -LiteralPath $EnvFile) }

function Set-EnvValue([string[]]$lines, [string]$key, [string]$value) {
    $out = @(); $done = $false
    foreach ($l in $lines) {
        if ($l -match "^$([regex]::Escape($key))=") { $out += "$key=$value"; $done = $true } else { $out += $l }
    }
    if (-not $done) { $out += "$key=$value" }
    return $out
}

function Get-EnvValue([string[]]$lines, [string]$key) {
    foreach ($l in $lines) { if ($l -match "^$([regex]::Escape($key))=(.*)$") { return $Matches[1] } }
    return ''
}

function Import-EnvFile {
    foreach ($line in Read-EnvLines) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $t.Substring(0, $i).Trim()
        $v = $t.Substring($i + 1).Trim()
        if ($v.Length -ge 2 -and (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'")))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        [Environment]::SetEnvironmentVariable($k, $v, 'Process')
    }
}

# ---- 1. Go -------------------------------------------------------------------

function Initialize-Go {
    Step 'Go toolchain'
    if (-not (Test-Command 'go')) {
        Warn 'Go is not installed.'
        if ($IsWin -and (Test-Command 'winget') -and (Confirm-Action 'Install Go with winget?')) {
            Invoke-Checked 'winget install Go' { winget install --id GoLang.Go -e --accept-package-agreements --accept-source-agreements }
            Update-SessionPath
        }
        if (-not (Test-Command 'go')) {
            throw 'Go is required. Install it from https://go.dev/dl/, open a new terminal and run this script again.'
        }
    }
    $installed = (& go version) -join ' '
    $required = ''
    $goMod = Get-Content -LiteralPath (Join-Path $BackendDir 'go.mod') | Where-Object { $_ -match '^go\s+\d' } | Select-Object -First 1
    if ($goMod -match '^go\s+(\d+\.\d+)') { $required = $Matches[1] }
    if ($installed -match 'go(\d+\.\d+)') {
        $have = [version]$Matches[1]
        if ($required -and $have -lt [version]$required) {
            if ($have -lt [version]'1.21') {
                throw "$installed is too old: this project needs Go $required (or at least 1.21, which downloads it by itself). Update from https://go.dev/dl/."
            }
            Warn "$installed is older than the Go $required this project asks for. Go will fetch the right toolchain on first use (needs access to the Go module proxy)."
        }
    }
    Ok $installed
    if ($GoProxy -ne '') { $env:GOPROXY = $GoProxy; Info "GOPROXY=$GoProxy" }
}

# ---- 2. PostgreSQL -----------------------------------------------------------

function Test-DockerRunning {
    if (-not (Test-Command 'docker')) { return $false }
    return (Test-Native { docker info })
}

function Invoke-Compose {
    $env:TARK_DB_PORT = "$DbPort"
    & docker compose -f $ComposeFile @args | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "docker compose $($args -join ' ') failed (exit code $LASTEXITCODE)." }
}

function Start-DockerDatabase {
    Step 'PostgreSQL (Docker)'
    if ($Reset) {
        if (Confirm-Action 'Reset: this deletes the local development databases. Continue?') {
            Invoke-Compose 'down' '-v'
            Ok 'old database volume removed'
        }
    }
    Info 'Starting the container (the first run downloads the PostgreSQL image)...'
    Invoke-Compose 'up' '-d' 'db'
    Wait-Until {
        Test-Native { docker compose -f $ComposeFile exec -T db pg_isready -U tark -d tark }
    } 90 'PostgreSQL to accept connections'
    $has = (& docker compose -f $ComposeFile exec -T db psql -U tark -d tark -tAc "SELECT 1 FROM pg_database WHERE datname = 'tark_test'") -join ''
    if ($has.Trim() -ne '1') {
        Invoke-Checked 'create tark_test' { & docker compose -f $ComposeFile exec -T db psql -U tark -d tark -c 'CREATE DATABASE tark_test' }
    }
    Ok "PostgreSQL 16 on localhost:$DbPort with databases tark and tark_test"
    return @{ Url = (Get-DbUrl 'tark'); TestUrl = (Get-DbUrl 'tark_test') }
}

function Find-Psql {
    if (Test-Command 'psql') { return (Get-Command 'psql').Source }
    if ($IsWin) {
        $hit = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function ConvertTo-PlainText([securestring]$secure) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Start-NativeDatabase {
    Step 'PostgreSQL (native)'
    $psql = Find-Psql
    $superPw = $env:PGPASSWORD
    if (-not $psql) {
        Warn 'PostgreSQL is not installed.'
        if (-not ($IsWin -and (Test-Command 'winget'))) {
            throw 'Install PostgreSQL 14 or newer (https://www.postgresql.org/download/) or Docker, then run this script again.'
        }
        if (-not (Confirm-Action 'Install PostgreSQL 16 with winget? (needs an administrator prompt)')) {
            throw 'PostgreSQL is required. Install it, or use -Database docker / -Database external.'
        }
        $chars = (48..57) + (65..90) + (97..122)
        $superPw = -join ($chars | Get-Random -Count 24 | ForEach-Object { [char]$_ })
        Invoke-Checked 'winget install PostgreSQL' {
            winget install --id PostgreSQL.PostgreSQL.16 -e --accept-package-agreements --accept-source-agreements `
                --override "--mode unattended --unattendedmodeui none --superpassword $superPw --serverport $DbPort"
        }
        New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $LocalDir 'postgres-superuser.txt'), "user: postgres`npassword: $superPw`nport: $DbPort`n", $Utf8NoBom)
        Ok 'PostgreSQL installed (superuser password saved in backend\.local\postgres-superuser.txt, which is git-ignored)'
        Update-SessionPath
        $psql = Find-Psql
        if (-not $psql) { throw 'PostgreSQL was installed but psql was not found. Open a new terminal and run this script again.' }
    }
    $env:PGHOST = 'localhost'; $env:PGPORT = "$DbPort"
    if (-not $superPw) {
        $file = Join-Path $LocalDir 'postgres-superuser.txt'
        if (Test-Path $file) { $superPw = ((Get-Content $file | Where-Object { $_ -like 'password:*' } | Select-Object -First 1) -replace '^password:\s*', '') }
    }
    if (-not $superPw) {
        $secure = Read-Host "    Password of the PostgreSQL 'postgres' user on localhost:$DbPort" -AsSecureString
        $superPw = ConvertTo-PlainText $secure
    }
    $env:PGPASSWORD = $superPw
    try {
        Wait-Until { Test-Native { & $psql -U postgres -d postgres -tAc 'SELECT 1' } } 60 "PostgreSQL on localhost:$DbPort (is it running, and is the password right?)"
        $sql = @(
            "DO `$`$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'tark') THEN CREATE ROLE tark LOGIN PASSWORD 'tark'; END IF; END `$`$;"
        )
        Invoke-Checked 'create role' { & $psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c $sql[0] }
        foreach ($name in 'tark', 'tark_test') {
            $exists = (& $psql -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$name'") -join ''
            if ($exists.Trim() -ne '1') {
                Invoke-Checked "create $name" { & $psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE $name OWNER tark" }
            }
        }
    } finally {
        $env:PGPASSWORD = ''
    }
    Ok "PostgreSQL on localhost:$DbPort with databases tark and tark_test"
    return @{ Url = (Get-DbUrl 'tark'); TestUrl = (Get-DbUrl 'tark_test') }
}

function Use-ExternalDatabase {
    Step 'PostgreSQL (external)'
    if ($DatabaseUrl -eq '') { throw '-Database external needs -DatabaseUrl (and -TestDatabaseUrl to run the tests).' }
    Ok 'using the database you gave'
    return @{ Url = $DatabaseUrl; TestUrl = $TestDatabaseUrl }
}

function Initialize-Database {
    $mode = $Database
    if ($mode -eq 'auto') {
        if (Test-DockerRunning) { $mode = 'docker'; Info 'Docker is running: using it for PostgreSQL.' }
        else { $mode = 'native'; Info 'Docker is not running: using a native PostgreSQL.' }
    }
    if ($mode -eq 'docker' -and -not (Test-DockerRunning)) {
        throw 'Docker is not running. Start Docker Desktop, or use -Database native / -Database external.'
    }
    switch ($mode) {
        'docker'   { return Start-DockerDatabase }
        'native'   { return Start-NativeDatabase }
        'external' { return Use-ExternalDatabase }
    }
}

# ---- 3. secrets and .env.development -----------------------------------------

function Initialize-EnvFile($db) {
    Step 'Configuration (backend\.env.development)'
    if (-not (Test-Path $EnvExample)) { throw "Missing $EnvExample" }
    if ((Test-Path $EnvFile) -and $Reset) { Remove-Item $EnvFile -Force; Info 'old file removed (Reset)' }
    if (-not (Test-Path $EnvFile)) {
        Copy-Item -LiteralPath $EnvExample -Destination $EnvFile
        Info 'created from .env.development.example'
    }
    $lines = Read-EnvLines

    $secretNames = 'TARK_TOKEN_KEY', 'TARK_LOOKUP_KEY', 'TARK_DATA_KEY', 'TARK_PASSWORD_PEPPER', 'TARK_ENTITLEMENT_KEYS', 'TARK_ENTITLEMENT_ACTIVE_KID'
    $missing = @($secretNames | Where-Object { (Get-EnvValue $lines $_) -eq '' })
    if ($missing.Count -gt 0) {
        # Build once, so keygen can run even before the first full build.
        Build-Server
        $generated = @{}
        foreach ($l in (& $Exe keygen)) { if ($l -match '^(TARK_[A-Z_]+)=(.+)$') { $generated[$Matches[1]] = $Matches[2] } }
        if ($LASTEXITCODE -ne 0) { throw 'tarkd keygen failed.' }
        foreach ($n in $secretNames) {
            if ((Get-EnvValue $lines $n) -eq '') {
                if (-not $generated.ContainsKey($n)) { throw "keygen did not produce $n." }
                $lines = Set-EnvValue $lines $n $generated[$n]
            }
        }
        Ok 'fresh secrets generated'
    } else {
        Ok 'secrets already present (kept)'
    }

    $lines = Set-EnvValue $lines 'TARK_DATABASE_URL' $db.Url
    $lines = Set-EnvValue $lines 'TARK_HTTP_ADDR' ":$HttpPort"
    # The admin panel, reachable from this computer only.
    $lines = Set-EnvValue $lines 'TARK_ADMIN_ADDR' "127.0.0.1:$AdminPort"
    [System.IO.File]::WriteAllLines($EnvFile, [string[]]$lines, $Utf8NoBom)
    Import-EnvFile
    Ok "database: $((Get-EnvValue $lines 'TARK_DATABASE_URL') -replace ':[^:@/]+@', ':***@')"
}

# ---- 4. build and migrate ----------------------------------------------------

function Build-Server {
    New-Item -ItemType Directory -Force -Path (Split-Path $Exe) | Out-Null
    Push-Location $BackendDir
    try {
        Invoke-Checked 'go build' { & go build -o $Exe ./cmd/tarkd }
    } finally { Pop-Location }
}

function Initialize-Server {
    Step 'Build and database migrations'
    Push-Location $BackendDir
    try {
        Info 'Downloading Go modules (first run only)...'
        Invoke-Checked 'go mod download' { & go mod download }
    } finally { Pop-Location }
    Build-Server
    Ok "built $Exe"
    Invoke-Checked 'tarkd migrate' { & $Exe migrate }
    Ok 'migrations applied'
}

# ---- 5. tests ----------------------------------------------------------------

function Invoke-Tests($db) {
    Step 'Tests'
    if ($SkipTests) { Info 'skipped (-SkipTests)'; return $true }
    if (-not $db.TestUrl) { Warn 'No test database URL, so the database tests are skipped. Pass -TestDatabaseUrl to run them.'; return $true }
    if ($db.TestUrl -eq $db.Url) { throw 'The test database must be a different database from the development one: the tests wipe it.' }
    $env:TARK_TEST_DATABASE_URL = $db.TestUrl
    Push-Location $BackendDir
    try {
        & go test -p 1 -count=1 ./... | Out-Host
        $passed = ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
        Remove-Item Env:\TARK_TEST_DATABASE_URL -ErrorAction SilentlyContinue
    }
    if ($passed) { Ok 'all tests passed' } else { Warn 'some tests failed (see above). The server is still set up.' }
    return $passed
}

# ---- 6. run ------------------------------------------------------------------

function Write-Summary($testsPassed) {
    $base = "http://localhost:$HttpPort"
    Write-Host ''
    Write-Host '------------------------------------------------------------' -ForegroundColor Green
    Write-Host ' Tark backend is ready' -ForegroundColor Green
    Write-Host '------------------------------------------------------------' -ForegroundColor Green
    Write-Host "  API docs (Swagger UI) : $base/docs/"
    Write-Host "  OpenAPI contract      : $base/openapi.yaml"
    Write-Host "  Health / readiness    : $base/healthz   $base/readyz"
    Write-Host "  API base URL          : $base/v1"
    Write-Host "  Admin panel           : http://localhost:$AdminPort   (first login: .\backend\scripts\admin-local.ps1 you@example.com)"
    Write-Host '  Emails                : printed in this window (TARK_MAIL_DRIVER=log), with their codes'
    Write-Host '  Subscriptions         : fake Bazaar (a token starting with "invalid" is unknown, "down" simulates an outage)'
    if (-not $testsPassed) { Write-Host '  Tests                 : FAILED, see the output above' -ForegroundColor Yellow }
    $pub = (& $Exe pubkeys) -join ''
    if ($pub) { Write-Host "  Entitlement public key: $pub   (for the app's billing config)" }
    Write-Host ''
}

function Start-Server {
    Step 'Starting the API'
    $proc = Start-Process -FilePath $Exe -ArgumentList 'serve' -WorkingDirectory $BackendDir -PassThru -NoNewWindow
    $null = $proc.Handle   # keeps the exit code readable in Windows PowerShell 5.1
    try {
        $deadline = (Get-Date).AddSeconds(45)
        $ready = $false
        while (-not $ready) {
            if ($proc.HasExited) { throw "The server exited (code $($proc.ExitCode)). Its error is printed above." }
            if ((Get-Date) -gt $deadline) { throw 'Timed out waiting for the API to become ready.' }
            try { $ready = ((Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:$HttpPort/readyz" -TimeoutSec 2).StatusCode -lt 300) } catch { Start-Sleep -Milliseconds 500 }
        }
        Write-Summary $script:TestsPassed
        Write-Host 'Press Ctrl+C to stop the API.' -ForegroundColor Cyan
        $proc.WaitForExit()
    } finally {
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    }
}

# ---- go ----------------------------------------------------------------------

$script:TestsPassed = $true
try {
    Initialize-Go
    $db = Initialize-Database
    Initialize-EnvFile $db
    Initialize-Server
    $script:TestsPassed = Invoke-Tests $db
    if ($NoRun) {
        Write-Summary $script:TestsPassed
        Write-Host 'Start it later with:' -ForegroundColor Cyan
        Write-Host "  .\backend\setup-backend.ps1        (re-checks everything, then starts the API)"
    } else {
        Start-Server
    }
} catch {
    Write-Host ''
    Write-Host "Setup stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
