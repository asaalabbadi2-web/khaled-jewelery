<#
.SYNOPSIS
  Copy the app's automatic backups to the external drive, checked.

.DESCRIPTION
  The app writes a backup every night at 02:00 (Asia/Riyadh) into the Docker
  volume behind /data/backups -- on the production disk -- and keeps the last 7.
  This script copies each one to D:\yasargold-recovery\auto (the owner's choice,
  29 Sep 2026) and keeps 30 days there, never fewer than the newest 7.

  A scheduled task, not a bind mount: an unplugged drive fails this copy, never
  the app's start.

  Each copy lands as <name>.partial, is checked -- a zip holding database.dump
  that starts with PGDMP -- and only then takes its name. The run fails (exit 1,
  logged) when the drive is missing, Docker cannot be reached, an archive is
  broken, no backup exists, or the newest one is more than 26 hours old: the
  app has stopped backing up.

  Once, on the production machine:
    powershell -NoProfile -ExecutionPolicy Bypass -File C:\Projects\khaledjewels\copy-backups.ps1 -Install
  registers the task for the signed-in user (Docker Desktop runs only while
  that user is signed in), daily at 03:15. Log: C:\Projects\khaledjewels\logs\backup-copy.log

  Written for Windows PowerShell 5.1: no syntax newer than that.
#>
param(
    [string]$Destination = 'D:\yasargold-recovery\auto',
    [string]$Container = 'yasargold-backend',
    [string]$Source = '/data/backups',
    [int]$KeepDays = 30,
    [int]$MinKeep = 7,
    [int]$StaleHours = 26,
    [string]$Root = 'C:\Projects\khaledjewels',
    [switch]$Install,
    [string]$At = '03:15'
)

$ErrorActionPreference = 'Stop'
$Pattern = '^yasargold-backup-(\d{8}-\d{6})\.zip$'
$script:Failed = $false

function Log([string]$text) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $text
    Write-Host $text
    try {
        $dir = Join-Path $Root 'logs'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath (Join-Path $dir 'backup-copy.log') -Value $line -Encoding UTF8
    } catch { Write-Host "  (could not write the log: $($_.Exception.Message))" }
}
function Problem([string]$text) { Log "PROBLEM: $text"; $script:Failed = $true }
function Stop-Run([string]$text) { Problem $text; Log 'result: FAILED'; exit 1 }

function Stamp-Of([string]$name) {
    $m = [regex]::Match($name, $Pattern)
    if (-not $m.Success) { return $null }
    return [datetime]::ParseExact($m.Groups[1].Value, 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
}

function Is-Sound-Backup([string]$path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try { $zip = [System.IO.Compression.ZipFile]::OpenRead($path) } catch { return 'not a readable zip' }
    try {
        $entry = $zip.GetEntry('database.dump')
        if ($null -eq $entry) { return 'no database.dump inside' }
        $stream = $entry.Open()
        try {
            $head = New-Object byte[] 5
            $read = $stream.Read($head, 0, 5)
        } finally { $stream.Close() }
        if ($read -lt 5 -or [System.Text.Encoding]::ASCII.GetString($head) -ne 'PGDMP') { return 'database.dump is not a PostgreSQL dump' }
        return $null
    } finally { $zip.Dispose() }
}

# ---------------------------------------------------------------- install
if ($Install) {
    $self = $MyInvocation.MyCommand.Path
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$self`""
    $trigger = New-ScheduledTaskTrigger -Daily -At $At
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
    Register-ScheduledTask -TaskName 'yasargold-backup-copy' -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "registered: task 'yasargold-backup-copy', daily at $At, as $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Host "run it now:  Start-ScheduledTask -TaskName yasargold-backup-copy"
    Write-Host "last result: Get-ScheduledTaskInfo -TaskName yasargold-backup-copy   (LastTaskResult 0 = success)"
    exit 0
}

# ---------------------------------------------------------------- copy
Log "copy of automatic backups -> $Destination"
if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
    Stop-Run "$Destination not found -- is the external drive connected? Nothing was copied."
}

# A missing folder (no backup written yet) lists nothing; only Docker itself failing is an error.
$listing = & docker exec $Container sh -c "ls -1 $Source 2>/dev/null || true" 2>&1
if ($LASTEXITCODE -ne 0) { Stop-Run "docker could not list $Container`:$Source -- is Docker running? $listing" }
$names = @($listing | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match $Pattern } | Sort-Object)
if ($names.Count -eq 0) { Stop-Run "no automatic backup in $Container`:$Source -- is auto-backup enabled?" }

$copied = 0
foreach ($name in $names) {
    $final = Join-Path $Destination $name
    if (Test-Path -LiteralPath $final) { continue }
    $partial = "$final.partial"
    & docker cp "${Container}:$Source/$name" $partial 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $partial)) {
        Problem "REFUSED $name -- docker cp failed"
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        continue
    }
    $why = Is-Sound-Backup $partial
    if ($why) {
        Problem "REFUSED $name -- $why"
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        continue
    }
    Move-Item -LiteralPath $partial -Destination $final
    $copied += 1
    Log ("  copied {0} ({1:N1} MB)" -f $name, ((Get-Item -LiteralPath $final).Length / 1MB))
}

$newest = Stamp-Of $names[-1]
$age = ([datetime]::UtcNow - $newest).TotalHours
if ($age -gt $StaleHours) {
    Problem ("the newest automatic backup, {0}, is {1:N0} hours old -- the app has stopped backing up" -f $names[-1], $age)
}

# 30 days on the drive, never fewer than the newest 7.
$onDrive = @(Get-ChildItem -LiteralPath $Destination -File | Where-Object { $_.Name -match $Pattern } |
    Sort-Object { Stamp-Of $_.Name } -Descending)
$limit = [datetime]::UtcNow.AddDays(-$KeepDays)
$removed = 0
for ($i = $MinKeep; $i -lt $onDrive.Count; $i++) {
    if ((Stamp-Of $onDrive[$i].Name) -lt $limit) {
        Remove-Item -LiteralPath $onDrive[$i].FullName -Force
        $removed += 1
    }
}

Log ("copied {0}, removed {1} older than {2} days, {3} on the drive" -f $copied, $removed, $KeepDays, ($onDrive.Count - $removed))
if ($script:Failed) { Log 'result: FAILED'; exit 1 }
Log 'result: OK'
exit 0
