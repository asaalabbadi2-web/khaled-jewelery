#requires -Version 5.1
<#
PostgreSQL backup -> verified -> encrypted upload to Google Drive via rclone (Windows).

Flow (every step must pass before the next one runs):
  1. preflight : tools exist, remote is a crypt remote, free disk space, single instance
  2. dump      : pg_dump (custom format) into <name>.dump.partial
  3. verify    : non-empty, `pg_restore --list` reads it, size survives docker cp
  4. publish   : rename .partial -> .dump (only verified files ever carry the final name)
  5. upload    : rclone copy of every local *.dump (so an earlier failed upload is retried)
  6. check     : rclone cryptcheck (local file vs. decrypted remote content)
  7. retention : local N days, remote N days -- only after 1-6 succeeded, never below
                 a minimum number of recent files, only files named yasargold_pg_*.dump

Exit code 0 = a verified backup exists locally AND on the remote. Anything else = 1.
Schedule: daily 03:00 -- one hour after the app's own 02:00 (Asia/Riyadh) nightly backup.

Prereqs: rclone in PATH; either pg_dump + pg_restore in PATH, or docker (-UseDockerPgDump).

Docker (production):
  pwsh -NoProfile -File .\backend\backup_postgres_to_gdrive.ps1 -UseDockerPgDump
  # container yasargold-db, database yasargold_db, user yasargold, remote gdrive-crypt: (its root)

Safe rehearsal (no dump, no upload, no delete -- prints what it would do):
  pwsh -NoProfile -File .\backend\backup_postgres_to_gdrive.ps1 -UseDockerPgDump -DryRun

Secrets:
- Nothing secret is printed or logged. The DB password travels in the PGPASSWORD
  environment variable (docker: `-e PGPASSWORD` with no value on the command line).
- Prefer no password at all inside the container (local socket auth), or .pgpass.
- rclone.conf is never read or printed by this script.

RcloneRemote: the crypt remote already points at gdrive:yasargold/postgres, so the
default is the crypt root ("gdrive-crypt:"). Appending yasargold/postgres again would
nest the folders. Pass a sub-folder only if you want one (e.g. "gdrive-crypt:daily").
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$false)]
  [string]$DatabaseUrl,

  [switch]$UseDockerPgDump,

  [Alias('DbContainer','PostgresContainer','ContainerName')]
  [string]$DockerContainerName = "yasargold-db",

  [Alias('DbName','DatabaseName')]
  [string]$DockerDatabase = "yasargold_db",

  [Alias('DbUser','DatabaseUser','Username')]
  [string]$DockerUser = "yasargold",

  [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword',
    '',
    Justification = 'Passed to pg_dump only through the PGPASSWORD environment variable. Prefer .pgpass / socket auth; kept for compatibility.',
    Target = 'DockerPassword'
  )]
  [Alias('DbPassword','DatabasePassword','Password')]
  [string]$DockerPassword = "",

  [string]$BackupDir = "",

  [int]$RetentionDays = 14,

  [string]$RcloneRemote = "gdrive-crypt:",

  [string]$RcloneFlags = "",

  [int]$RemoteRetentionDays = 90,

  [int]$KeepLocalMin = 3,

  [int]$KeepRemoteMin = 7,

  [int]$MinFreeSpaceMB = 2048,

  [int]$LogRetentionDays = 30,

  [string]$LogDir = "",

  [switch]$AllowUnencryptedRemote,

  [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:FilePattern = 'yasargold_pg_*.dump'
$script:LogFile = $null
$script:Secrets = @()
# Arabic Windows defaults to the Hijri calendar: Get-Date would yield year 1447/1448 in file names.
$script:Inv = [Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------- helpers ---

function Protect-Text([string]$Text) {
  foreach ($s in $script:Secrets) {
    if (-not [string]::IsNullOrEmpty($s)) { $Text = $Text.Replace($s, '***') }
  }
  # postgresql://user:password@host -> postgresql://user:***@host
  return [regex]::Replace($Text, '(postgres(?:ql)?://[^:@/\s]+):[^@\s]*@', '$1:***@')
}

function Write-Log([string]$Level, [string]$Message) {
  $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $script:Inv), $Level, (Protect-Text $Message)
  Write-Host $line
  if ($script:LogFile) {
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
  }
}

# Runs a native command, never throws on a non-zero exit, returns exit code + output lines.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
  }
  $lines = @()
  if ($null -ne $out) { $lines = @($out) }
  return [pscustomobject]@{ ExitCode = $code; Output = $lines }
}

function Split-Flags([string]$Flags) {
  if ([string]::IsNullOrWhiteSpace($Flags)) { return @() }
  return @($Flags.Trim() -split '\s+')
}

function Get-FreeBytes([string]$Path) {
  try {
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
    if ($root.StartsWith('\\')) { return $null }  # UNC: cannot tell
    return ([IO.DriveInfo]::new($root)).AvailableFreeSpace
  } catch { return $null }
}

# --------------------------------------------------------------- preflight ---

if ([string]::IsNullOrWhiteSpace($BackupDir)) {
  $BackupDir = [IO.Path]::GetFullPath((Join-Path (Join-Path (Split-Path -Parent $PSCommandPath) '..') (Join-Path 'backups' 'postgres')))
}
if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $BackupDir 'logs' }

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$script:LogFile = Join-Path $LogDir ("backup_{0}.log" -f (Get-Date).ToString('yyyyMMdd', $script:Inv))

if (-not [string]::IsNullOrEmpty($DockerPassword)) { $script:Secrets += $DockerPassword }

$lockStream = $null
$docker = $null
$exitCode = 1
$partial = $null
$containerTmp = $null
$envPasswordSet = $false

try {
  Write-Log 'INFO' ("start: docker={0} dryrun={1} remote={2} backupdir={3}" -f [bool]$UseDockerPgDump, [bool]$DryRun, $RcloneRemote, $BackupDir)

  # single instance
  try {
    $lockStream = [IO.File]::Open((Join-Path $BackupDir '.backup.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  } catch {
    throw "another backup run is already in progress (lock held)"
  }

  if ($RetentionDays -lt 1 -or $RemoteRetentionDays -lt 1) { throw "retention days must be >= 1" }
  if ($KeepLocalMin -lt 1 -or $KeepRemoteMin -lt 1) { throw "KeepLocalMin / KeepRemoteMin must be >= 1" }

  $rclone = Get-Command rclone -ErrorAction SilentlyContinue
  if (-not $rclone) { throw "rclone not found in PATH" }

  $pgDump = $null; $pgRestore = $null; $docker = $null
  if ($UseDockerPgDump) {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) { throw "docker not found in PATH" }
  } else {
    if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) { throw "DatabaseUrl is required unless -UseDockerPgDump is set" }
    if ($DatabaseUrl -notmatch '^postgres(ql)?://') { throw "DatabaseUrl does not look like a PostgreSQL URL" }
    $m = [regex]::Match($DatabaseUrl, '^(postgres(?:ql)?://[^:@/]+):([^@]*)@')
    if ($m.Success) {
      # keep the password off the pg_dump command line
      $script:Secrets += $m.Groups[2].Value
      $DockerPassword = [Uri]::UnescapeDataString($m.Groups[2].Value)
      $DatabaseUrl = $DatabaseUrl.Remove($m.Groups[1].Length, 1 + $m.Groups[2].Length)
    }
    $pgDump = Get-Command pg_dump -ErrorAction SilentlyContinue
    $pgRestore = Get-Command pg_restore -ErrorAction SilentlyContinue
    if (-not $pgDump -or -not $pgRestore) { throw "pg_dump / pg_restore not found in PATH (or use -UseDockerPgDump)" }
  }

  # The remote must be a crypt remote, otherwise the dump would leave this machine in clear text.
  $remoteName = ($RcloneRemote -split ':', 2)[0]
  if ([string]::IsNullOrWhiteSpace($remoteName) -or $RcloneRemote -notmatch ':') {
    throw "RcloneRemote must look like 'remote:path' (got '$RcloneRemote')"
  }
  $lr = Invoke-Native $rclone.Source @('listremotes', '--long')
  if ($lr.ExitCode -ne 0) { throw "rclone listremotes failed (exit $($lr.ExitCode))" }
  $remoteType = $null
  foreach ($line in $lr.Output) {
    if ($line -match '^(?<n>[^:\s]+):\s+(?<t>\S+)\s*$' -and $Matches['n'] -eq $remoteName) { $remoteType = $Matches['t'] }
  }
  if (-not $remoteType) { throw "rclone remote '$remoteName' is not configured" }
  $isCrypt = ($remoteType -eq 'crypt')
  if (-not $isCrypt -and -not $AllowUnencryptedRemote) {
    throw "remote '$remoteName' is type '$remoteType', not 'crypt' -- refusing to upload an unencrypted database dump (override: -AllowUnencryptedRemote)"
  }
  Write-Log 'INFO' "remote '$remoteName' type=$remoteType"

  # disk space: at least MinFreeSpaceMB, and at least twice the newest dump
  $free = Get-FreeBytes $BackupDir
  $newest = Get-ChildItem -LiteralPath $BackupDir -Filter $script:FilePattern -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  $need = [Math]::Max([int64]$MinFreeSpaceMB * 1MB, $(if ($newest) { 2 * $newest.Length } else { 0 }))
  if ($null -ne $free -and $free -lt $need) {
    throw ("not enough free disk space on the backup drive: {0} MB free, {1} MB required" -f ([int64]($free / 1MB)), ([int64]($need / 1MB)))
  }

  $filter = @('--include', $script:FilePattern)
  $extra = Split-Flags $RcloneFlags
  $netFlags = @('--retries', '5', '--low-level-retries', '20', '--timeout', '5m', '--contimeout', '1m')

  if ($DryRun) {
    Write-Log 'INFO' 'DRY RUN: no dump, no upload, no deletion'
    $ls = Invoke-Native $rclone.Source (@('lsf', $RcloneRemote) + $filter + $extra)
    if ($ls.ExitCode -ne 0) { throw "cannot list the remote (exit $($ls.ExitCode)): $($ls.Output -join ' | ')" }
    Write-Log 'INFO' ("remote currently holds {0} matching file(s)" -f (@($ls.Output | Where-Object { $_ }).Count))
    $del = Invoke-Native $rclone.Source (@('delete', $RcloneRemote, '--dry-run', '--min-age', "${RemoteRetentionDays}d") + $filter + $extra)
    foreach ($l in $del.Output) { Write-Log 'INFO' "would-delete(remote): $l" }
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$RetentionDays)
    $localFiles = @(Get-ChildItem -LiteralPath $BackupDir -Filter $script:FilePattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    $localFiles | Select-Object -Skip $KeepLocalMin | Where-Object { $_.LastWriteTimeUtc -lt $cutoff } |
      ForEach-Object { Write-Log 'INFO' "would-delete(local): $($_.Name)" }
    Write-Log 'INFO' 'DRY RUN complete'
    $exitCode = 0
    return
  }

  # -------------------------------------------------------------- dump ----
  $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ', $script:Inv)
  $finalName = "yasargold_pg_${ts}.dump"
  $outFile = Join-Path $BackupDir $finalName
  $partial = "$outFile.partial"

  if (-not [string]::IsNullOrEmpty($DockerPassword)) {
    $env:PGPASSWORD = $DockerPassword
    $envPasswordSet = $true
  }

  if (-not $UseDockerPgDump) {
    $r = Invoke-Native $pgDump.Source @('--format=custom', '--no-owner', '--no-acl', '--dbname', $DatabaseUrl, '--file', $partial)
    if ($r.ExitCode -ne 0) { throw "pg_dump failed (exit $($r.ExitCode)): $($r.Output -join ' | ')" }
    $v = Invoke-Native $pgRestore.Source @('--list', $partial)
    if ($v.ExitCode -ne 0) { throw "dump failed verification, pg_restore --list exit $($v.ExitCode): $($v.Output -join ' | ')" }
    $tocLines = @($v.Output | Where-Object { $_ -and -not $_.StartsWith(';') }).Count
  } else {
    $containerTmp = "/tmp/yasargold_pg_${ts}.dump"
    $execArgs = @('exec')
    if ($envPasswordSet) { $execArgs += @('-e', 'PGPASSWORD') }   # name only; value comes from this process env
    $r = Invoke-Native $docker.Source ($execArgs + @($DockerContainerName, 'pg_dump', '--format=custom', '--no-owner', '--no-acl',
          '-U', $DockerUser, '-d', $DockerDatabase, '--file', $containerTmp))
    if ($r.ExitCode -ne 0) { throw "docker exec pg_dump failed (exit $($r.ExitCode)): $($r.Output -join ' | ')" }

    $v = Invoke-Native $docker.Source @('exec', $DockerContainerName, 'pg_restore', '--list', $containerTmp)
    if ($v.ExitCode -ne 0) { throw "dump failed verification inside the container, pg_restore --list exit $($v.ExitCode)" }
    $tocLines = @($v.Output | Where-Object { $_ -and -not $_.StartsWith(';') }).Count

    $sz = Invoke-Native $docker.Source @('exec', $DockerContainerName, 'sh', '-c', "wc -c < $containerTmp")
    $containerSize = 0L
    if ($sz.ExitCode -ne 0 -or -not [int64]::TryParse((($sz.Output -join '').Trim()), [ref]$containerSize)) {
      throw "could not read the dump size inside the container"
    }

    $cp = Invoke-Native $docker.Source @('cp', "${DockerContainerName}:${containerTmp}", $partial)
    if ($cp.ExitCode -ne 0) { throw "docker cp failed (exit $($cp.ExitCode)): $($cp.Output -join ' | ')" }
    if ((Get-Item -LiteralPath $partial).Length -ne $containerSize) {
      throw "size mismatch after docker cp: container=$containerSize host=$((Get-Item -LiteralPath $partial).Length)"
    }
  }

  $len = (Get-Item -LiteralPath $partial).Length
  if ($len -le 0) { throw "dump file is empty" }
  if ($tocLines -lt 1) { throw "dump contains no objects" }

  Move-Item -LiteralPath $partial -Destination $outFile
  $partial = $null
  $sha = (Get-FileHash -LiteralPath $outFile -Algorithm SHA256).Hash
  Write-Log 'INFO' ("verified backup: {0} size={1} objects={2} sha256={3}" -f $finalName, $len, $tocLines, $sha)

  # ------------------------------------------------------------ upload ----
  # Whole folder, not just the new file: a dump whose upload failed yesterday goes up today.
  $up = Invoke-Native $rclone.Source (@('copy', $BackupDir, $RcloneRemote) + $filter + $netFlags + $extra)
  foreach ($l in $up.Output) { Write-Log 'INFO' "rclone: $l" }
  if ($up.ExitCode -ne 0) { throw "rclone copy failed (exit $($up.ExitCode)) -- backup is safe locally and will be retried next run" }

  $chk = if ($isCrypt) {
    Invoke-Native $rclone.Source (@('cryptcheck', $BackupDir, $RcloneRemote, '--one-way') + $filter + $extra)
  } else {
    Invoke-Native $rclone.Source (@('check', $BackupDir, $RcloneRemote, '--one-way') + $filter + $extra)
  }
  foreach ($l in $chk.Output) { Write-Log 'INFO' "rclone check: $l" }
  if ($chk.ExitCode -ne 0) { throw "post-upload verification failed (exit $($chk.ExitCode))" }
  Write-Log 'INFO' "uploaded and verified on remote: $RcloneRemote"

  # From here on a verified copy exists locally and remotely; cleanup problems are warnings.
  $exitCode = 0

  # --------------------------------------------------- local retention ----
  try {
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$RetentionDays)
    $all = @(Get-ChildItem -LiteralPath $BackupDir -Filter $script:FilePattern -File | Sort-Object LastWriteTimeUtc -Descending)
    $all | Select-Object -Skip $KeepLocalMin | Where-Object { $_.LastWriteTimeUtc -lt $cutoff } | ForEach-Object {
      Remove-Item -LiteralPath $_.FullName -Force
      Write-Log 'INFO' "deleted old local backup: $($_.Name)"
    }
    Get-ChildItem -LiteralPath $BackupDir -Filter 'yasargold_pg_*.dump.partial' -File |
      Where-Object { $_.LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddDays(-1) } |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force; Write-Log 'INFO' "deleted stale partial: $($_.Name)" }
    Get-ChildItem -LiteralPath $LogDir -Filter 'backup_*.log' -File |
      Where-Object { $_.LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddDays(-$LogRetentionDays) } |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
  } catch { Write-Log 'WARN' "local retention failed: $($_.Exception.Message)" }

  # -------------------------------------------------- remote retention ----
  # Only delete when enough RECENT backups exist remotely, so a silent outage can never
  # age the whole history away.
  try {
    $recent = Invoke-Native $rclone.Source (@('lsf', $RcloneRemote, '--max-age', "${RemoteRetentionDays}d") + $filter + $extra)
    $recentCount = @($recent.Output | Where-Object { $_ }).Count
    if ($recent.ExitCode -ne 0) {
      Write-Log 'WARN' "remote retention skipped: cannot list remote (exit $($recent.ExitCode))"
    } elseif ($recentCount -lt $KeepRemoteMin) {
      Write-Log 'WARN' "remote retention skipped: only $recentCount recent file(s) on remote, need >= $KeepRemoteMin"
    } else {
      $del = Invoke-Native $rclone.Source (@('delete', $RcloneRemote, '--min-age', "${RemoteRetentionDays}d", '-v') + $filter + $extra)
      foreach ($l in $del.Output) { Write-Log 'INFO' "rclone delete: $l" }
      if ($del.ExitCode -ne 0) { Write-Log 'WARN' "remote retention failed (exit $($del.ExitCode))" }
    }
  } catch { Write-Log 'WARN' "remote retention failed: $($_.Exception.Message)" }
}
catch {
  Write-Log 'ERROR' $_.Exception.Message
  $exitCode = 1
}
finally {
  if ($envPasswordSet) { Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue }
  if ($partial -and (Test-Path -LiteralPath $partial)) {
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
  }
  if ($containerTmp -and $docker) {
    $null = Invoke-Native $docker.Source @('exec', $DockerContainerName, 'rm', '-f', $containerTmp)
  }
  if ($lockStream) { $lockStream.Dispose() }
  Write-Log 'INFO' "finished exit=$exitCode"
}

exit $exitCode
