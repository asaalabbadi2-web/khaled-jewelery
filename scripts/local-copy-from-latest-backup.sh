#!/usr/bin/env bash
# A local copy of production from its latest backup -- the books as they are
# today, on this machine, never production itself.
#
#   1. the newest yasargold-backup-*.zip in ~/Downloads (or the one given)
#   2. restored into its own database, named by the backup's time
#      (local_YYYYMMDD_HHMM); already there, it is used as it is -- --fresh
#      restores it again
#   3. brought to the code's migrations (alembic upgrade head)
#   4. backend/.env's DATABASE_URL pointed at it
#   5. the ERP on :8002 and its web screens on :8090, built to call :8002,
#      and the browser opened. ":8001" (Backend: Start, SQLite) is left alone.
#
# The code is the last commit's (HEAD), checked out on its own: what other
# sessions are halfway through editing does not break the copy.
# --working-tree runs the tree as it stands instead, edits and all.
#
# Usage: ./scripts/local-copy-from-latest-backup.sh [--fresh] [--working-tree] [path/to/backup.zip]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API_PORT=8002
WEB_PORT=8090
WORK="${TMPDIR:-/tmp}/yasargold-local-copy"
PG_BIN="${PG_BIN:-/opt/homebrew/opt/postgresql@17/bin}"   # the dumps are pg_dump 17's
FLUTTER="${FLUTTER:-$(command -v flutter || echo "$HOME/flutter/bin/flutter")}"

FRESH=false
WORKING_TREE=false
ZIP=""
for arg in "$@"; do
  case "$arg" in
    --fresh) FRESH=true ;;
    --working-tree) WORKING_TREE=true ;;
    *) ZIP="$arg" ;;
  esac
done

mkdir -p "$WORK"
if $WORKING_TREE; then
  CODE="$ROOT"
  echo "🧩 الكود: الشجرة كما هي، بتعديلاتها"
else
  CODE="$WORK/tree"
  git -C "$ROOT" worktree prune
  if [ -d "$CODE/.git" ] || [ -f "$CODE/.git" ]; then
    git -C "$CODE" checkout -q --detach "$(git -C "$ROOT" rev-parse HEAD)"
  else
    git -C "$ROOT" worktree add -q --detach "$CODE" HEAD
  fi
  # .env is not in git: the copy's code reads the repository's own.
  ln -sf "$ROOT/backend/.env" "$CODE/backend/.env"
  echo "🧩 الكود: آخر إيداع $(git -C "$CODE" log -1 --format='%h %s' | cut -c1-70)"
fi
BACKEND="$CODE/backend"
FRONTEND="$CODE/frontend"
VENV="$ROOT/backend/venv"
WEB_OUT="$WORK/web"

if [ -z "$ZIP" ]; then
  ZIP="$(ls -t "$HOME"/Downloads/yasargold-backup-*.zip 2>/dev/null | head -1 || true)"
fi
[ -n "$ZIP" ] && [ -f "$ZIP" ] || { echo "❌ لا توجد نسخة احتياطية (yasargold-backup-*.zip) في Downloads" >&2; exit 1; }

# yasargold-backup-2026-10-27T23-13-25.zip -> local_20261027_2313
STAMP="$(basename "$ZIP" .zip | sed -E 's/^yasargold-backup-//; s/[^0-9]//g' | cut -c1-12)"
[ ${#STAMP} -eq 12 ] || { echo "❌ لا أقرأ وقت النسخة من اسمها: $ZIP" >&2; exit 1; }
DB="local_${STAMP:0:8}_${STAMP:8:4}"
echo "📦 النسخة: $(basename "$ZIP")  →  القاعدة: $DB"

if psql -d postgres -Atc "select 1 from pg_database where datname='$DB'" | grep -q 1; then
  if $FRESH; then
    echo "♻️  --fresh: تُحذف $DB وتُستعاد من جديد"
    dropdb "$DB"
  else
    echo "✔︎ $DB موجودة -- تُستعمل كما هي (--fresh لاستعادتها من جديد)"
  fi
fi

if ! psql -d postgres -Atc "select 1 from pg_database where datname='$DB'" | grep -q 1; then
  UNZIP_DIR="$(mktemp -d "$WORK/unzip.XXXXXX")"
  unzip -q -o "$ZIP" -d "$UNZIP_DIR"
  [ -f "$UNZIP_DIR/database.dump" ] || { echo "❌ لا يوجد database.dump في النسخة" >&2; exit 1; }
  createdb "$DB"
  echo "⏳ استعادة القاعدة..."
  # pg_restore 17 into an older server reports one harmless error
  # (SET transaction_timeout); the restore is judged by what it restored.
  "$PG_BIN/pg_restore" --no-owner --no-privileges -d "$DB" "$UNZIP_DIR/database.dump" 2>"$WORK/restore.err" || true
  grep -v -e transaction_timeout -e 'Command was: SET' -e 'errors ignored on restore' "$WORK/restore.err" || true
  rm -rf "$UNZIP_DIR"
  psql -d "$DB" -Atc "select 1 from alembic_version" >/dev/null || { echo "❌ لم تكتمل الاستعادة" >&2; exit 1; }
fi

# backend/.env: only the database's name changes -- user, password and host stay.
ENV_FILE="$ROOT/backend/.env"
[ -f "$ENV_FILE" ] || { echo "❌ لا يوجد backend/.env" >&2; exit 1; }
sed -i '' -E "s#^(DATABASE_URL=postgresql[^ ]*/)[A-Za-z0-9_]+\$#\\1$DB#" "$ENV_FILE"
DATABASE_URL="$(grep '^DATABASE_URL=' "$ENV_FILE" | cut -d= -f2-)"
case "$DATABASE_URL" in */"$DB") ;; *) echo "❌ DATABASE_URL في backend/.env ليس postgresql -- لم أغيّره" >&2; exit 1 ;; esac
export DATABASE_URL

echo "⏳ الترحيلات..."
(cd "$BACKEND" && "$VENV/bin/alembic" upgrade head 2>&1 | grep -E 'Running upgrade|ERROR' || true)
echo "✔︎ $DB على $(psql -d "$DB" -Atc 'select version_num from alembic_version'): $(psql -d "$DB" -Atc 'select count(*) from journal_entry') قيدًا، آخرها $(psql -d "$DB" -Atc 'select max(date)::date from journal_entry')"

stop_port() {
  local pids
  pids="$(lsof -ti tcp:"$1" -sTCP:LISTEN 2>/dev/null || true)"
  if [ -n "$pids" ]; then echo "$pids" | xargs kill -TERM 2>/dev/null || true; sleep 1; fi
}

stop_port "$API_PORT"
# Detached from this shell: the task's terminal ends, the servers stay.
nohup "$VENV/bin/gunicorn" --chdir "$BACKEND" -b 127.0.0.1:"$API_PORT" --workers 1 --threads 4 --timeout 120 app:app \
  >"$WORK/backend.log" 2>&1 </dev/null &
disown
for _ in $(seq 1 60); do curl -s -o /dev/null -m 2 "http://127.0.0.1:$API_PORT/api/settings" && break; sleep 1; done
curl -s -o /dev/null -m 2 "http://127.0.0.1:$API_PORT/api/settings" \
  || { echo "❌ الخادم لم يبدأ -- انظر $WORK/backend.log" >&2; exit 1; }
echo "✔︎ الخادم على :$API_PORT ($WORK/backend.log)"

echo "⏳ بناء الواجهة..."
(cd "$FRONTEND" && "$FLUTTER" build web --release --dart-define=API_BASE_URL="http://127.0.0.1:$API_PORT/api" -o "$WEB_OUT" >"$WORK/web-build.log" 2>&1) \
  || { echo "❌ فشل بناء الواجهة -- انظر $WORK/web-build.log" >&2; exit 1; }

stop_port "$WEB_PORT"
nohup python3 -m http.server "$WEB_PORT" --bind 127.0.0.1 --directory "$WEB_OUT" >"$WORK/web.log" 2>&1 </dev/null &
disown
for _ in $(seq 1 20); do curl -s -o /dev/null -m 2 "http://localhost:$WEB_PORT/" && break; sleep 0.5; done
echo "✔︎ الواجهة على http://localhost:$WEB_PORT"
open "http://localhost:$WEB_PORT/"
