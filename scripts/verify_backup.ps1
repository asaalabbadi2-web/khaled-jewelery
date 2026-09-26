#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Proves a Yasar Gold backup archive can actually be restored, and that the
    books inside it are intact — before anyone stakes a recovery on it.

.DESCRIPTION
    An untested backup is not a backup.  This script restores the archive into a
    throwaway PostgreSQL container on an isolated Docker network (no published
    ports, torn down afterwards), then runs scripts/verify_ledger.sql against it.
    It never touches production and never writes to the archive.

    Two version facts drive the design, both measured, both documented in
    docs/runbooks/disaster-recovery.md §1:

      1. Backups are produced by `pg_dump -Fc` INSIDE the backend container,
         whose client is 17.x, while the server is postgres:16.  A v16 client
         cannot read the archive at all ("unsupported version (1.15) in file
         header").  Hence -ClientImage defaults to postgres:17 and the server
         to postgres:16 — client 17 → server 16 is the combination that works.

      2. Restoring a 17-produced archive into a 16 server always emits exactly
         one benign error (`SET transaction_timeout = 0;` is unknown to 16) and
         pg_restore exits non-zero even though every row arrived.  So exit code
         alone cannot be trusted here: this script classifies stderr instead,
         and fails on any error that is NOT that one.  Blind `|| true` would
         hide a real corruption; blind `check=True` calls a good restore a
         failure (which is the live defect in backend/routes/system.py).

.PARAMETER BackupPath
    The .zip produced by the in-app backup (database.dump + metadata.json), or
    a bare pg_dump custom-format .dump file.

.PARAMETER SelfTest
    Runs the stderr classifier against known-good and known-bad input and exits.
    Needs no Docker.  This is the script's own red/green witness — run it after
    touching Test-RestoreStderr.

.EXAMPLE
    pwsh -File scripts/verify_backup.ps1 -BackupPath D:\backups\yasargold-backup-2026-09-24T23-13-53.zip

.EXAMPLE
    pwsh -File scripts/verify_backup.ps1 -SelfTest

.OUTPUTS
    Exit 0 = the archive restored and every ledger invariant held.
    Exit 1 = anything else.  Nothing is "probably fine".
#>
[CmdletBinding(DefaultParameterSetName = 'Verify')]
param(
    [Parameter(ParameterSetName = 'Verify', Mandatory = $true, Position = 0)]
    [string]$BackupPath,

    [Parameter(ParameterSetName = 'SelfTest', Mandatory = $true)]
    [switch]$SelfTest,

    [string]$ServerImage   = 'postgres:16',
    [string]$ClientImage   = 'postgres:17',
    [string]$DatabaseName  = 'yasargold_db',
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
# Native stderr must not become a terminating error: pg_restore's benign line is
# expected output here, and classifying it is the whole point.
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Write-Section { param([string]$Text) Write-Host "`n── $Text " -ForegroundColor Cyan }
function Write-Ok      { param([string]$Text) Write-Host "  OK    $Text" -ForegroundColor Green }
function Write-Fail    { param([string]$Text) Write-Host "  FAIL  $Text" -ForegroundColor Red }
function Write-Info    { param([string]$Text) Write-Host "        $Text" -ForegroundColor DarkGray }

# ── the classifier ──────────────────────────────────────────────────────────
# Returns @{ Ok = bool; Unexpected = string[] }.  Kept small and pure so
# -SelfTest can witness it without Docker.
function Test-RestoreStderr {
    param([string[]]$Lines)

    $benignMarkers = @(
        'unrecognized configuration parameter "transaction_timeout"',
        'SET transaction_timeout = 0;',
        'errors ignored on restore:'
    )

    $unexpected  = @()
    $benignCount = 0
    $claimed     = 0

    foreach ($raw in $Lines) {
        $line = "$raw".Trim()
        if ($line -eq '') { continue }

        $matched = $false
        foreach ($marker in $benignMarkers) {
            if ($line.Contains($marker)) { $matched = $true; break }
        }

        if (-not $matched) { $unexpected += $line; continue }

        if ($line.Contains('unrecognized configuration parameter "transaction_timeout"')) {
            $benignCount++
        }
        if ($line -match 'errors ignored on restore:\s*(\d+)') {
            $claimed = [int]$Matches[1]
        }
    }

    # pg_restore counts its own ignored errors.  If it claims more than the
    # benign ones we recognised, something else failed quietly — do not pass it.
    if ($claimed -gt $benignCount) {
        $unexpected += "pg_restore ignored $claimed error(s) but only $benignCount were the known-benign transaction_timeout error"
    }

    return @{ Ok = ($unexpected.Count -eq 0); Unexpected = $unexpected }
}

function Invoke-SelfTest {
    $cases = @(
        @{ Name = 'real stderr from a 17-archive into a 16 server'
           Lines = @(
               'pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout"',
               'Command was: SET transaction_timeout = 0;',
               'pg_restore: warning: errors ignored on restore: 1')
           Expect = $true }
        @{ Name = 'clean restore, no stderr'
           Lines = @()
           Expect = $true }
        @{ Name = 'a real error alongside the benign one'
           Lines = @(
               'pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout"',
               'Command was: SET transaction_timeout = 0;',
               'pg_restore: error: could not execute query: ERROR:  relation "invoice" already exists',
               'pg_restore: warning: errors ignored on restore: 2')
           Expect = $false }
        @{ Name = 'pg_restore claims more ignored errors than we recognise'
           Lines = @(
               'pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout"',
               'pg_restore: warning: errors ignored on restore: 7')
           Expect = $false }
        @{ Name = 'archive unreadable by this client'
           Lines = @('pg_restore: error: unsupported version (1.15) in file header')
           Expect = $false }
    )

    Write-Section 'Self-test — stderr classifier'
    $failed = 0
    foreach ($case in $cases) {
        $got = (Test-RestoreStderr -Lines $case.Lines).Ok
        if ($got -eq $case.Expect) {
            Write-Ok "$($case.Name) → $got"
        } else {
            Write-Fail "$($case.Name) → expected $($case.Expect), got $got"
            $failed++
        }
    }

    if ($failed -gt 0) { Write-Host "`n$failed case(s) failed.`n" -ForegroundColor Red; return 1 }
    Write-Host "`nAll $($cases.Count) cases passed.`n" -ForegroundColor Green
    return 0
}

if ($SelfTest) { exit (Invoke-SelfTest) }

# ── docker helper ───────────────────────────────────────────────────────────
$script:DockerExit = 0
function Invoke-Docker {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$DockerArgs)
    $output = & docker @DockerArgs 2>&1 | ForEach-Object { "$_" }
    $script:DockerExit = $LASTEXITCODE
    return $output
}

# ── run ─────────────────────────────────────────────────────────────────────
$sqlDir      = $PSScriptRoot
$sqlFile     = Join-Path $sqlDir 'verify_ledger.sql'
$stamp       = Get-Date -Format 'yyyyMMdd-HHmmss'
$id          = "drverify-$stamp"
$network     = "$id-net"
$server      = "$id-db"
$workRoot    = Join-Path ([System.IO.Path]::GetTempPath()) $id
$serverUp    = $false
$networkUp   = $false
$verdict     = 1

if (-not (Test-Path $sqlFile)) { throw "verify_ledger.sql not found next to this script ($sqlFile)" }
if (-not (Test-Path $BackupPath)) { throw "backup not found: $BackupPath" }

try {
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

    # 1 ── the archive itself
    Write-Section 'Archive'
    $resolved = (Resolve-Path $BackupPath).Path
    $hash     = (Get-FileHash -Path $resolved -Algorithm SHA256).Hash.ToLower()
    $size     = [math]::Round((Get-Item $resolved).Length / 1MB, 2)
    Write-Info "file    $resolved"
    Write-Info "size    $size MB"
    Write-Info "sha256  $hash"

    if ($resolved.ToLower().EndsWith('.zip')) {
        $extract = Join-Path $workRoot 'extract'
        Expand-Archive -Path $resolved -DestinationPath $extract -Force
        $dumpFile = Join-Path $extract 'database.dump'
        if (-not (Test-Path $dumpFile)) { throw "the archive has no database.dump — is this a Yasar Gold backup?" }
        $metaFile = Join-Path $extract 'metadata.json'
        if (Test-Path $metaFile) {
            # Read created_at_utc out of the raw text: ConvertFrom-Json turns the
            # ISO string into a local DateTime, which reprints in the host's
            # locale and drops the UTC marker — and this is the exact timestamp
            # the runbook tells the operator to compare.  Keep it verbatim.
            $rawMeta = Get-Content $metaFile -Raw
            $meta    = $rawMeta | ConvertFrom-Json
            $created = [regex]::Match($rawMeta, '"created_at_utc"\s*:\s*"([^"]+)"').Groups[1].Value
            if ($created -eq '') { $created = '(absent)' }
            Write-Info "created $created  backend=$($meta.db_backend)  format=$($meta.format)"
            if ($meta.format -ne 'pg_dump_custom') { throw "unexpected backup format '$($meta.format)' — this script only verifies pg_dump_custom" }
        } else {
            Write-Info 'no metadata.json in the archive (older backup) — continuing'
        }
        Write-Ok 'archive expanded, database.dump present'
    } else {
        $dumpFile = $resolved
        Write-Ok 'treating the file as a bare pg_dump custom archive'
    }

    $dumpDir  = (Resolve-Path (Split-Path -Parent $dumpFile)).Path
    $dumpName = Split-Path -Leaf $dumpFile

    # 2 ── an isolated server, nothing published
    Write-Section "Throwaway server ($ServerImage)"
    Invoke-Docker network create $network | Out-Null
    if ($script:DockerExit -ne 0) { throw "could not create the docker network — is Docker running?" }
    $networkUp = $true

    Invoke-Docker run -d --name $server --network $network `
        -e POSTGRES_PASSWORD=verify -e POSTGRES_DB=$DatabaseName `
        $ServerImage | Out-Null
    if ($script:DockerExit -ne 0) { throw "could not start $ServerImage" }
    $serverUp = $true

    $ready = $false
    foreach ($attempt in 1..30) {
        Invoke-Docker exec $server pg_isready -U postgres -d $DatabaseName | Out-Null
        if ($script:DockerExit -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw 'the throwaway server never became ready (60s)' }
    Write-Ok "server ready, database '$DatabaseName' created empty"

    # 3 ── restore, then judge stderr rather than the exit code (see .DESCRIPTION)
    Write-Section "Restore ($ClientImage client → $ServerImage server)"
    $restoreOut = Invoke-Docker run --rm --network $network `
        -v "${dumpDir}:/b:ro" -e PGPASSWORD=verify $ClientImage `
        pg_restore --no-owner --no-privileges -h $server -U postgres -d $DatabaseName "/b/$dumpName"
    $restoreExit = $script:DockerExit

    $verdictStderr = Test-RestoreStderr -Lines $restoreOut
    if (-not $verdictStderr.Ok) {
        Write-Fail "pg_restore reported errors this script will not accept (exit $restoreExit):"
        foreach ($line in $verdictStderr.Unexpected) { Write-Host "        $line" -ForegroundColor Red }
        throw 'restore rejected'
    }
    if ($restoreExit -ne 0) {
        Write-Ok "restore complete — exit $restoreExit, only the known-benign transaction_timeout error (client $ClientImage vs server $ServerImage)"
    } else {
        Write-Ok 'restore complete with no errors at all'
    }

    # 4 ── the books
    Write-Section 'Ledger verification (scripts/verify_ledger.sql)'
    $sqlOut = Invoke-Docker run --rm --network $network `
        -v "${sqlDir}:/sql:ro" -e PGPASSWORD=verify $ClientImage `
        psql -h $server -U postgres -d $DatabaseName -v ON_ERROR_STOP=1 -f /sql/verify_ledger.sql
    $sqlExit = $script:DockerExit
    $sqlOut | ForEach-Object { Write-Host "        $_" }

    if ($sqlExit -ne 0) { Write-Fail "verify_ledger.sql failed (exit $sqlExit) — this backup must not be trusted"; throw 'ledger rejected' }
    Write-Ok 'every ledger invariant held'

    Write-Host "`n════ VERIFIED ════ this archive is restorable and its books are intact.`n" -ForegroundColor Green
    $verdict = 0
}
catch {
    Write-Host "`n════ NOT VERIFIED ════ $($_.Exception.Message)`n" -ForegroundColor Red
    $verdict = 1
}
finally {
    if ($Keep -and $serverUp) {
        Write-Info "-Keep: leaving container '$server' and network '$network' up. Remove with:"
        Write-Info "  docker rm -f $server; docker network rm $network"
    } else {
        if ($serverUp)  { Invoke-Docker rm -f $server | Out-Null }
        if ($networkUp) { Invoke-Docker network rm $network | Out-Null }
        if (Test-Path $workRoot) { Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue }
    }
}

exit $verdict
