#!/usr/bin/env bash
set -euo pipefail

# PostgreSQL backup for YasarGold.
# Usage:
#   export DATABASE_URL='postgresql://user:pass@host:5432/dbname'
#   ./backup_postgres.sh
#
# Notes:
# - Prefer using .pgpass or secret manager instead of embedding password in DATABASE_URL.
# - Produces pg_dump custom-format file (.dump) which is compressed and supports parallel restore.

# ── DATABASE_URL resolution ─────────────────────────────────────────────────
# The environment wins.  When it is empty -- which is the case under launchd,
# whose jobs inherit almost nothing -- fall back to the application's own
# config file, and read ONLY DATABASE_URL out of it.
#
# Deliberately NOT `source`/`set -a`: this script must not become a second
# configuration surface for the application.  It needs one value; it takes one
# value.  BackupService will own configuration properly later.
ENV_FILE="$(cd "$(dirname "$0")" && pwd)/.env"

if [[ -z "${DATABASE_URL:-}" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: DATABASE_URL is not set and no config file at $ENV_FILE" >&2
    exit 1
  fi

  DATABASE_URL="$(sed -n 's/^[[:space:]]*DATABASE_URL=//p' "$ENV_FILE" | tail -1)"
  DATABASE_URL="${DATABASE_URL%$'\r'}"          # tolerate CRLF files
  DATABASE_URL="${DATABASE_URL%\"}"; DATABASE_URL="${DATABASE_URL#\"}"
  DATABASE_URL="${DATABASE_URL%\'}"; DATABASE_URL="${DATABASE_URL#\'}"

  if [[ -z "$DATABASE_URL" ]]; then
    echo "ERROR: DATABASE_URL is not set and $ENV_FILE defines no DATABASE_URL" >&2
    exit 1
  fi
  echo "OK: DATABASE_URL taken from $ENV_FILE (not from the environment)"
fi

if ! [[ "${DATABASE_URL}" =~ ^postgres(ql)?:// ]]; then
  echo "ERROR: DATABASE_URL does not look like PostgreSQL (got: ${DATABASE_URL})" >&2
  exit 1
fi

# ── PostgreSQL tools + version contract ─────────────────────────────────────
# TRANSITIONAL: this resolution and check belong in BackupService, which will own
# one canonical engine and one contract.  It lives here only until that exists.
# Do not grow this block into half a backup engine.
#
# The contract, measured 2026-09-27 against server 16.14 with clients 14/16/17:
#   client major <  server major   pg_dump refuses outright (exit 1)
#   client major >  server major   dump succeeds, but the archive carries
#                                  `SET transaction_timeout`, and restoring it
#                                  into the older server exits non-zero -- the
#                                  live defect documented in
#                                  docs/runbooks/disaster-recovery.md §1
#   client major == server major   canonical
# So a canonical backup requires EQUAL majors, and this check runs BEFORE any
# directory or artifact is created: discovering the mismatch after writing a
# plausible-looking dump is how an unusable backup gets trusted.
#
# PG_BIN names the bin DIRECTORY of the PostgreSQL client tools, so the same
# script serves every host without machine paths in its logic:
#   macOS      PG_BIN=/opt/homebrew/opt/postgresql@16/bin
#   Debian     PG_BIN=/usr/lib/postgresql/16/bin
# Unset, the tools are taken from PATH -- which on a developer machine may well
# be a different major than the server (it was 14 here, against a 16 server).
PG_BIN="${PG_BIN:-}"
if [[ -n "$PG_BIN" ]]; then
  PG_DUMP="$PG_BIN/pg_dump"
  PSQL="$PG_BIN/psql"
else
  PG_DUMP="$(command -v pg_dump || true)"
  PSQL="$(command -v psql || true)"
fi

for tool_path in "$PG_DUMP" "$PSQL"; do
  if [[ -z "$tool_path" || ! -x "$tool_path" ]]; then
    echo "ERROR: PostgreSQL client tools not found${PG_BIN:+ under PG_BIN=$PG_BIN}." >&2
    echo "       Set PG_BIN to the bin directory of the client tools matching the server." >&2
    exit 1
  fi
done

CLIENT_VERSION="$("$PG_DUMP" --version | awk '{print $3}')"
CLIENT_MAJOR="${CLIENT_VERSION%%.*}"
SERVER_VERSION_NUM="$("$PSQL" -tAc 'SHOW server_version_num;' "$DATABASE_URL" | tr -d '[:space:]')"
SERVER_MAJOR="$(( SERVER_VERSION_NUM / 10000 ))"

if [[ "$CLIENT_MAJOR" != "$SERVER_MAJOR" ]]; then
  echo "ERROR: pg_dump major version does not match the server. NO backup was created." >&2
  echo "       pg_dump : $CLIENT_VERSION  (major $CLIENT_MAJOR)  at $PG_DUMP" >&2
  echo "       server  : $SERVER_VERSION_NUM  (major $SERVER_MAJOR)" >&2
  echo "       Fix: PG_BIN=<bin dir of PostgreSQL $SERVER_MAJOR client tools> $0" >&2
  exit 1
fi

echo "OK: pg_dump $CLIENT_VERSION matches server major $SERVER_MAJOR"

BACKUP_DIR="${BACKUP_DIR:-"$(cd "$(dirname "$0")" && pwd)/../backups/postgres"}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

umask 077
mkdir -p "$BACKUP_DIR"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_FILE="$BACKUP_DIR/yasargold_pg_${TS}.dump"
# Dump to a hidden temporary name and rename only on success, so an interrupted
# dump (disk full, dropped connection) cannot leave a truncated file that looks
# like a backup.  The temp name deliberately does NOT match the
# `yasargold_pg_*.dump` glob used by retention below.
TMP_FILE="$BACKUP_DIR/.yasargold_pg_${TS}.dump.partial"

# Clean the temporary file on every exit path, including interruption -- launchd
# sends SIGTERM to the whole job at logout/shutdown, and a partial dump left
# behind is invisible: it is hidden and excluded from the retention glob, so it
# would accumulate unnoticed.  Two traps on purpose: a signal trap without an
# explicit exit would run the handler and then RESUME the interrupted script.
# (SIGKILL cannot be trapped by any process -- that case is unreachable here.)
trap 'rm -f "${TMP_FILE:-}"' EXIT
trap 'rm -f "${TMP_FILE:-}"; exit 130' INT TERM

# -Fc: custom format (compressed)
# --no-owner/--no-acl: avoids ownership/permission issues across environments
if ! "$PG_DUMP" \
  --format=custom \
  --no-owner \
  --no-acl \
  --dbname "$DATABASE_URL" \
  --file "$TMP_FILE"
then
  rm -f "$TMP_FILE"
  echo "ERROR: pg_dump failed. Partial file removed; NO backup was created." >&2
  exit 1
fi

mv "$TMP_FILE" "$OUT_FILE"

echo "OK: created backup: $OUT_FILE"

# Retention cleanup
if [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && [[ "$RETENTION_DAYS" -gt 0 ]]; then
  find "$BACKUP_DIR" -type f -name 'yasargold_pg_*.dump' -mtime "+$RETENTION_DAYS" -print -delete || true
fi
