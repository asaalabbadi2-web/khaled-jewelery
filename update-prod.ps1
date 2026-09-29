<#
.SYNOPSIS
  Deploy one pinned, rehearsed release of the ERP to production -- or take the
  backup the rehearsal needs first.

.DESCRIPTION
  Production is C:\Projects\khaledjewels (docker-compose.prod.gitlab.yml +
  .env.production). A release is the 8-character tag GitLab CI builds for a
  commit on main (backend:<tag>, web:<tag>).

  Run it through update-prod.bat, next to it: a stock Windows client refuses to
  run a .ps1 directly (execution policy Restricted), and the wrapper passes
  -ExecutionPolicy Bypass. Every command this script prints is in that form.

  The protocol (docs/runbooks/release-rehearsal.md):
    1.  .\update-prod.bat -Tag <tag> -Backup
          checks both images exist, takes a backup with the database server's own
          pg_dump, and prints the rehearsal command to run on the Mac.
    2.  rehearse there; deploy only on GREEN.
    3.  .\update-prod.bat -Tag <tag> -Deploy -Rehearsed
          writes IMAGE_TAG and reads it back, pulls, migrates (a failed migration
          puts the old tag back and restarts nothing), restarts, verifies, and
          prints the rollback command.
    Rollback:  .\update-prod.bat -Tag <previous tag> -Deploy -Rollback

  -DryRun prints every step and changes nothing.

  Written for Windows PowerShell 5.1: no syntax newer than that.
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{8}$')]
    [string]$Tag,
    [switch]$Backup,
    [switch]$Deploy,
    [switch]$Rehearsed,
    [switch]$Rollback,
    [switch]$DryRun,
    [string]$Root = 'C:\Projects\khaledjewels',
    [string]$BaseUrl = 'http://localhost',
    [int]$SettleSeconds = 90
)

$ErrorActionPreference = 'Stop'
$Registry = 'registry.gitlab.com/sasalabbadi/khaledjewels'
$ComposeFile = 'docker-compose.prod.gitlab.yml'
$EnvFile = '.env.production'
$Compose = @('compose', '-f', $ComposeFile, '--env-file', $EnvFile)
# The only services a release changes. A deploy never pulls or restarts the
# database on purpose; it was also recreated by accident, because it read
# .env.production (IMAGE_TAG) -- fixed in docker-compose.prod.gitlab.yml.
$AppServices = @('backend', 'scheduler', 'nginx')
$OnWindows = ($env:OS -eq 'Windows_NT')
$Curl = 'curl'
$NullDevice = '/dev/null'
if ($OnWindows) { $Curl = 'curl.exe'; $NullDevice = 'NUL' }

function Say([string]$text) { Write-Host $text }
function Fail([string]$text) { Write-Host "ABORTED: $text" -ForegroundColor Red; exit 1 }

function Run-Docker([string[]]$arguments) {
    if ($DryRun) { Say ("  [dry-run] docker " + ($arguments -join ' ')); return 0 }
    & docker @arguments
    return $LASTEXITCODE
}

function Current-Tag {
    $line = Get-Content -Path $EnvFile | Where-Object { $_ -match '^IMAGE_TAG=' } | Select-Object -First 1
    if (-not $line) { return '' }
    return ($line -replace '^IMAGE_TAG=', '').Trim()
}

function Write-Tag([string]$newTag) {
    $path = (Resolve-Path $EnvFile).Path
    $text = [System.IO.File]::ReadAllText($path)
    if ($text -match '(?m)^IMAGE_TAG=.*$') {
        $text = [regex]::Replace($text, '(?m)^IMAGE_TAG=.*$', "IMAGE_TAG=$newTag")
    } else {
        $text = $text.TrimEnd("`r", "`n") + [Environment]::NewLine + "IMAGE_TAG=$newTag" + [Environment]::NewLine
    }
    if ($DryRun) { Say "  [dry-run] would set IMAGE_TAG=$newTag in $EnvFile"; return }
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
    $written = Current-Tag
    if ($written -ne $newTag) { Fail "$EnvFile reads IMAGE_TAG=$written after writing $newTag" }
}

function Images-Exist([string]$t) {
    if ($DryRun) {
        foreach ($name in @('backend', 'web')) { Say "  [dry-run] docker manifest inspect ${Registry}/${name}:$t" }
        Say "  images not checked (dry run)"
        return
    }
    foreach ($name in @('backend', 'web')) {
        & docker manifest inspect "${Registry}/${name}:$t" *> $null
        if ($LASTEXITCODE -ne 0) {
            Fail "image ${Registry}/${name}:$t not found. Has CI finished building it? (docker login registry.gitlab.com once if you are not logged in)"
        }
    }
    Say "  images ${Registry}/{backend,web}:$t exist"
}

function Http-Status([string]$url) {
    $code = & $Curl -s -o $NullDevice -w '%{http_code}' $url
    return "$code".Trim()
}

# ----------------------------------------------------------------------
if (-not (Test-Path $Root)) { Fail "production folder $Root not found" }
Set-Location $Root
if (-not (Test-Path $ComposeFile)) { Fail "$ComposeFile not found in $Root" }
if (-not (Test-Path $EnvFile)) { Fail "$EnvFile not found in $Root" }
if ($Backup -eq $Deploy) { Fail 'choose exactly one of -Backup or -Deploy' }

$current = Current-Tag
Say "production runs: $current    requested: $Tag"

if ($Backup) {
    Say '[1/2] checking the release images...'
    Images-Exist $Tag
    Say '[2/2] backing up with the database server''s own pg_dump...'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $name = "pre-$Tag-$stamp.dump"
    $db = 'yasargold-db'
    if ($DryRun) {
        Say "  [dry-run] docker exec $db pg_dump -Fc -f /tmp/$name  ->  backups\$name"
        exit 0
    }
    $user = (& docker exec $db printenv POSTGRES_USER).Trim()
    $dbname = (& docker exec $db printenv POSTGRES_DB).Trim()
    if (-not $user -or -not $dbname) { Fail "could not read POSTGRES_USER / POSTGRES_DB from $db" }
    & docker exec $db pg_dump -U $user -Fc -f "/tmp/$name" $dbname
    if ($LASTEXITCODE -ne 0) { Fail 'pg_dump failed' }
    New-Item -ItemType Directory -Force -Path 'backups' | Out-Null
    & docker cp "${db}:/tmp/$name" (Join-Path 'backups' $name)
    if ($LASTEXITCODE -ne 0) { Fail 'copying the dump out of the container failed' }
    & docker exec $db rm -f "/tmp/$name" | Out-Null
    $file = Get-Item (Join-Path 'backups' $name)
    Say ("  backup: {0} ({1:N1} MB)" -f $file.FullName, ($file.Length / 1MB))
    Say ''
    Say 'Next -- on the Mac, with this file copied to ~/Downloads:'
    Say "  python backend/tools/rehearse_release.py --backup ~/Downloads/$name --baseline $current --release $Tag"
    Say 'Only if the report is GREEN:'
    Say "  .\update-prod.bat -Tag $Tag -Deploy -Rehearsed"
    exit 0
}

# ---------------------------------------------------------------- deploy
if (-not ($Rehearsed -or $Rollback)) {
    Fail "a release is deployed only after a GREEN rehearsal on a fresh backup:`n  .\update-prod.bat -Tag $Tag -Backup   (then rehearse on the Mac)`n  .\update-prod.bat -Tag $Tag -Deploy -Rehearsed"
}
if ($Tag -eq $current) { Fail "production already runs $Tag" }

Say '[1/6] checking the release images...'
Images-Exist $Tag

Say "[2/6] writing IMAGE_TAG=$Tag (and reading it back)..."
Write-Tag $Tag
if (-not $DryRun) { Set-Content -Path '.previous-image-tag' -Value $current }

Say '[3/6] pulling the app images (never the database)...'
if ((Run-Docker ($Compose + @('pull') + $AppServices)) -ne 0) {
    Write-Tag $current
    Fail "pull failed -- IMAGE_TAG put back to $current, nothing restarted"
}

Say '[4/6] migrating the database before anything restarts...'
if ((Run-Docker ($Compose + @('run', '--rm', 'backend', 'bash', '-c', 'cd /app/backend && alembic upgrade head'))) -ne 0) {
    Write-Tag $current
    Fail "migration failed -- IMAGE_TAG put back to $current; the previous version is still running. Read the error above."
}
Run-Docker ($Compose + @('run', '--rm', 'backend', 'bash', '-c', 'cd /app/backend && alembic current')) | Out-Null

Say '[5/6] restarting the app services on the new images (the database keeps running)...'
if ((Run-Docker ($Compose + @('up', '-d', '--force-recreate') + $AppServices)) -ne 0) {
    Fail "services did not start. Roll back with:  .\update-prod.bat -Tag $current -Deploy -Rollback"
}

Say '[6/6] verifying...'
if ($DryRun) { Say '  [dry-run] would check the running image tags, then the /api answers'; exit 0 }
# No healthcheck guards the backend: nginx answers 502 until gunicorn is up.
# Wait for it (up to -SettleSeconds) rather than guess how long a boot takes.
$deadline = (Get-Date).AddSeconds($SettleSeconds)
$setup = Http-Status "$BaseUrl/api/auth/check-setup"
while ($setup -ne '200' -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    $setup = Http-Status "$BaseUrl/api/auth/check-setup"
}
$running = & docker @($Compose + @('images', '--format', 'json')) | Out-String
$ok = $true
foreach ($svc in @('yasargold-backend', 'yasargold-scheduler', 'yasargold-nginx')) {
    if ($running -notmatch ('"ContainerName"\s*:\s*"' + $svc + '"[^}]*"Tag"\s*:\s*"' + $Tag + '"')) {
        Say "  $svc is NOT on $Tag"; $ok = $false
    }
}
$anon = Http-Status "$BaseUrl/api/invoices"
Say "  /api/auth/check-setup -> $setup (expect 200)"
Say "  /api/invoices without a session -> $anon (expect 401)"
if ($setup -ne '200' -or $anon -ne '401') { $ok = $false }
& docker logs yasargold-scheduler --tail 10

Say ''
Say "rollback, if ever needed:  .\update-prod.bat -Tag $current -Deploy -Rollback"
if (-not $ok) { Fail "the release is running but did not verify -- read the lines above; roll back if in doubt" }
Say "production now runs $Tag. Reload the app in every browser (Ctrl+Shift+R)."
exit 0
