#requires -Version 5.1
<#
PostgreSQL backup -> (encrypted) upload to Google Drive via rclone (Windows).

Recommended approach:
- Configure rclone Google Drive remote (e.g. "gdrive")
- Configure rclone crypt remote on top of it (e.g. "gdrive-crypt") for end-to-end encryption
- Run this script hourly via Task Scheduler.

Prereqs:
- rclone in PATH
- One of:
  - pg_dump in PATH (PostgreSQL client tools), OR
  - `docker` in PATH (if you want to run pg_dump inside the Postgres container)

Examples:
  pwsh -File .\backend\backup_postgres_to_gdrive.ps1 -DatabaseUrl "postgresql://user:pass@host:5432/db" -RcloneRemote "gdrive-crypt:yasargold/postgres"

Docker (recommended if Postgres runs in Docker and you don't want to install pg_dump on Windows):
  pwsh -File .\backend\backup_postgres_to_gdrive.ps1 -UseDockerPgDump -DockerContainerName "yasargold-db" -DockerDatabase "yasargold" -DockerUser "yasargold" -DockerPassword "YOUR_PASSWORD" -RcloneRemote "gdrive-crypt:yasargold/postgres"

Notes:
- Prefer .pgpass / secret manager instead of embedding password.
- Remote encryption is handled by rclone crypt remote (recommended).
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$false)]
  [string]$DatabaseUrl,

  [switch]$UseDockerPgDump,

  [Alias('DbContainer','PostgresContainer','ContainerName')]
  [string]$DockerContainerName = "yasargold-db",

  [Alias('DbName','DatabaseName')]
  [string]$DockerDatabase = "yasargold",

  [Alias('DbUser','DatabaseUser','Username')]
  [string]$DockerUser = "yasargold",

  [Alias('DbPassword','DatabasePassword','Password')]
  [string]$DockerPassword = "",

  [string]$BackupDir = $(Join-Path (Split-Path -Parent $PSCommandPath) "..\backups\postgres"),

  [int]$RetentionDays = 14,

  [string]$RcloneRemote = "gdrive-crypt:yasargold/postgres",

  [string]$RcloneFlags = "",

  [int]$RemoteRetentionDays = 90
)

if (-not $UseDockerPgDump) {
  if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
    throw "DatabaseUrl is required unless -UseDockerPgDump is set"
  }
  if ($DatabaseUrl -notmatch '^postgres(ql)?://') {
    throw "DatabaseUrl does not look like PostgreSQL: $DatabaseUrl"
  }
}

$pgDump = $null
if (-not $UseDockerPgDump) {
  $pgDump = (Get-Command pg_dump -ErrorAction SilentlyContinue)
  if (-not $pgDump) {
    throw "pg_dump not found in PATH. Install PostgreSQL client tools OR use -UseDockerPgDump."
  }
} else {
  $docker = (Get-Command docker -ErrorAction SilentlyContinue)
  if (-not $docker) {
    throw "docker not found in PATH. Install Docker Desktop (or docker CLI) OR disable -UseDockerPgDump."
  }
}

$rclone = (Get-Command rclone -ErrorAction SilentlyContinue)
if (-not $rclone) {
  throw "rclone not found in PATH. Install rclone."
}

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

$ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$outFile = Join-Path $BackupDir "yasargold_pg_${ts}.dump"

if (-not $UseDockerPgDump) {
  & $pgDump.Source --format=custom --no-owner --no-acl --dbname $DatabaseUrl --file $outFile
  if ($LASTEXITCODE -ne 0) {
    throw "pg_dump failed with exit code $LASTEXITCODE"
  }
} else {
  # Run pg_dump inside the container, then docker cp the dump to the host.
  # This avoids installing PostgreSQL client tools on Windows.
  $containerTmp = "/tmp/yasargold_pg_${ts}.dump"

  $execArgs = @("exec")
  if (-not [string]::IsNullOrWhiteSpace($DockerPassword)) {
    $execArgs += @("-e", "PGPASSWORD=$DockerPassword")
  }
  $execArgs += @(
    $DockerContainerName,
    "pg_dump",
    "--format=custom",
    "--no-owner",
    "--no-acl",
    "-U", $DockerUser,
    "-d", $DockerDatabase,
    "--file", $containerTmp
  )

  & docker @execArgs
  if ($LASTEXITCODE -ne 0) {
    throw "docker exec pg_dump failed with exit code $LASTEXITCODE"
  }

  & docker cp "${DockerContainerName}:${containerTmp}" "$outFile"
  if ($LASTEXITCODE -ne 0) {
    throw "docker cp failed with exit code $LASTEXITCODE"
  }

  # Best-effort cleanup inside container
  & docker exec $DockerContainerName rm -f $containerTmp 2>$null
}

Write-Host "OK: created backup: $outFile"

# Upload to remote (encrypted if using crypt remote)
# rclone copy <file> <remote:folder>
if ([string]::IsNullOrWhiteSpace($RcloneFlags)) {
  & $rclone.Source copy $outFile $RcloneRemote
} else {
  # Split flags safely by whitespace (simple approach)
  $flagParts = $RcloneFlags -split '\s+'
  & $rclone.Source copy $outFile $RcloneRemote @flagParts
}

if ($LASTEXITCODE -ne 0) {
  throw "rclone copy failed with exit code $LASTEXITCODE"
}

Write-Host "OK: uploaded to remote: $RcloneRemote"

# Local retention cleanup
if ($RetentionDays -gt 0) {
  $cutoff = (Get-Date).ToUniversalTime().AddDays(-$RetentionDays)
  Get-ChildItem -Path $BackupDir -Filter 'yasargold_pg_*.dump' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTimeUtc -lt $cutoff } |
    Remove-Item -Force -ErrorAction SilentlyContinue
}

# Remote retention cleanup (best-effort)
if ($RemoteRetentionDays -gt 0) {
  try {
    if ([string]::IsNullOrWhiteSpace($RcloneFlags)) {
      & $rclone.Source delete $RcloneRemote --min-age "${RemoteRetentionDays}d"
    } else {
      $flagParts = $RcloneFlags -split '\s+'
      & $rclone.Source delete $RcloneRemote --min-age "${RemoteRetentionDays}d" @flagParts
    }
  } catch {
    # Best-effort: do not fail backups if remote cleanup fails
  }
}
