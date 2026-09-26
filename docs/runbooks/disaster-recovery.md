# Runbook — Disaster Recovery: rebuilding production from a backup

**Applies to:** production ERP — `docker-compose.prod.gitlab.yml` on the shop's own machine
**First executed:** 2026-09-26, after the production machine was wiped. Every number in §5 is
transcribed from a real verified restore of `yasargold-backup-2026-09-24T23-13-53.zip` performed
that day — not from expectation.
**Audience:** whoever has to bring production back on a machine that has nothing on it.
**Authority:** `docker-compose.prod.gitlab.yml` · `.env.production` · `scripts/verify_backup.ps1` ·
`scripts/verify_ledger.sql`
**See also:** `PRODUCTION_BACKUP_GUIDE.md` (how backups are produced), `BACKUP_RESTORE_GUIDE.md`,
`docs/runbooks/sad-deployment.md`,
`docs/runbooks/recovery-snapshot-2026-09-26.md` (the state the 2026-09-26 rebuild landed on)

---

## 1. The two version facts that decide everything

Backups are produced by `pg_dump -Fc` **inside the backend container** (`backend/routes/system.py`),
and that container's client tools are **17.11** (Debian 13, via an unpinned `postgresql-client` in
`backend/Dockerfile`) while the server is **postgres:16.15**. Two consequences, both measured:

| Fact | Consequence |
|---|---|
| The archive is written in pg_dump **17** format (header 1.15) | A 14 or 16 client **cannot open it at all**: `pg_restore: error: unsupported version (1.15) in file header`. Restore with a **17** client against the **16** server. |
| A 17-produced archive restored into a 16 server hits `SET transaction_timeout = 0;` | `pg_restore` prints exactly **one** error and exits **non-zero — while restoring every row correctly**. |

**Therefore: judge stderr, not the exit code.** Exactly one error is acceptable:

```
pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout"
Command was: SET transaction_timeout = 0;
pg_restore: warning: errors ignored on restore: 1
```

Anything else — stop. Do not wrap the restore in `|| true`: that would hide real corruption just as
surely as treating the exit code as truth would abort a good restore.

> **The in-app restore cannot be used for disaster recovery yet.** `_restore_postgres_from_backup_file`
> runs `pg_restore` with `check=True`, so the benign error above becomes
> `RuntimeError: فشل استعادة PostgreSQL` — the UI reports failure on a restore that actually
> succeeded. Owner: **Path B item 1** — pin `postgresql-client-16` in `backend/Dockerfile` and add a
> test proving a system-produced backup restores with exit 0. Until that lands, §4 below is the only
> sanctioned restore path.

---

## 2. RPO / RTO — measured, not aspirational

| | 2026-09-25 incident (actual) | Target after Path B |
|---|---|---|
| **RPO** | **~26 hours.** Newest off-machine copy: `2026-09-24T23:13:48Z`. Machine wiped 2026-09-25. One business day of invoicing lost. | ≤ 24 h, automatic, off-site |
| **RTO** | Restore + verify of a 5.5 MB archive (2,421 invoices) ≈ **2 minutes**. The machine rebuild — Docker, clone, registry pull — dominates: budget **60–90 minutes**. | ≤ 60 min |

A backup exists only where you copied it. On 2026-09-25 that was, by hand, the dev machine's
`Downloads` folder — and that hand-copy is the only reason this runbook has anything to restore.
Until Path B automates off-site copies, **copying every backup off the machine *is* the recovery plan.**

---

## 3. Before you touch the new machine

| # | Prerequisite | Proof it is really there |
|---|---|---|
| 1 | Docker Desktop running, Git installed | `docker info`, `git --version` |
| 2 | **A GitLab token with `read_registry`, and the images still in the registry** | `docker login registry.gitlab.com -u <user>` then `docker manifest inspect registry.gitlab.com/sasalabbadi/khaledjewels/backend:latest` |
| 3 | A **verified** backup archive | `powershell -File scripts/verify_backup.ps1 -BackupPath <archive.zip>` → exit 0 |
| 4 | `.env.production`, reconciled | §3.1 — do not skip |

A stock Windows install has **`powershell` (5.1), not `pwsh`** — `verify_backup.ps1` runs on both, so
use `powershell -File …` unless PowerShell 7 is installed. `-SelfTest` needs no Docker and proves the
script's error classifier still behaves after any edit:

```powershell
powershell -File scripts\verify_backup.ps1 -SelfTest        # → 5 cases pass, exit 0
```

**Do #2 first.** `update-prod.bat` ships `set GL_TOKEN=YOUR_TOKEN_HERE`: the real token was pasted in
by hand and does not survive the machine. And the token is not only needed for the app —
`alembic upgrade head` runs *through the backend image* (`run --rm backend`), so a missing token
blocks the **migration**, not just the startup. Discovering that halfway through a restore is how a
60-minute recovery becomes a 6-hour one.

### 3.1 The database name — the quietest way to lose a day

Production ran on **`yasargold_db`** (the name is recorded inside the dump itself). The copy of
`.env.production` on the dev machine says `POSTGRES_DB=yasargold`. Three places must agree:

- `POSTGRES_DB` in `.env.production`
- the database path in `DATABASE_URL`
- the `-d` argument of `pg_restore`

Get this wrong and you restore into one database while the app reads an empty other one — and
conclude the backup was lost. It was not.

While you are in that file: `DATABASE_URL` still reads `postgresql://…` with no driver named. Safe
today only because `backend/requirements.txt` pins `SQLAlchemy==2.0.36`; it becomes a live outage the
day that pin moves (SQLAlchemy 2.1 changed the default `postgresql://` driver from psycopg2 to
psycopg v3). Explicit `postgresql+psycopg2://` is Path B.

---

## 4. The procedure

Commands are PowerShell, run from the repo root on the production machine. They are written out in
full rather than behind a `$C` shorthand: a runbook executed under pressure must be copy-pasteable
without the reader holding state in their head.

```powershell
# 0 ── clone to THE production path: C:\Projects\khaledjewels as of the 2026-09-26
#     rebuild (see recovery-snapshot-2026-09-26.md).  C:\khaled-jewelery is the
#     pre-incident path and is NOT production; `update-prod.bat` and
#     .gitlab-ci.yml were corrected to this path in the same commit as this
#     runbook.  Compose derives its project name from the
#     folder, so the two paths resolve to DIFFERENT volume namespaces
#     (khaled-jewelery_postgres_data vs khaledjewels_postgres_data): a deploy from
#     the stale folder would not be operating on production's database at all.
#     If that folder still exists on the machine, rename it so only one
#     production folder can be found.
git clone https://gitlab.com/sasalabbadi/khaledjewels.git C:\Projects\khaledjewels
cd C:\Projects\khaledjewels

# 1 ── .env.production in place (§3.1 reconciled), and the archive's dump in .\restore\
mkdir restore
Expand-Archive -Path .\yasargold-backup-2026-09-24T23-13-53.zip -DestinationPath .\restore -Force   # → .\restore\database.dump

# 2 ── the database ALONE. Not the backend. See §7.
docker compose -f docker-compose.prod.gitlab.yml --env-file .env.production pull
docker compose -f docker-compose.prod.gitlab.yml --env-file .env.production up -d db
docker compose -f docker-compose.prod.gitlab.yml --env-file .env.production ps    # wait for db: healthy

# 3 ── restore with the client that produced the archive (17) into the 16 server.
#     `run --rm backend bash -c ...` overrides the container command, so app.py is never
#     imported and db.create_all() never runs.  The bash string is SINGLE-quoted on purpose:
#     $POSTGRES_* must reach the container's shell, not be expanded by PowerShell.
docker compose -f docker-compose.prod.gitlab.yml --env-file .env.production run --rm -v "${PWD}\restore:/b" backend bash -c 'PGPASSWORD=$POSTGRES_PASSWORD pg_restore --no-owner --no-privileges -h db -U $POSTGRES_USER -d $POSTGRES_DB /b/database.dump'
#     → expect exit 1 with the ONE benign error of §1.  Read it.  Anything else: stop.

# 4 ── verify before trusting anything (§5).  Exit 0, or stop.
docker compose -f docker-compose.prod.gitlab.yml --env-file .env.production run --rm -v "${PWD}\scripts:/sql:ro" backend bash -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -h db -U $POSTGRES_USER -d $POSTGRES_DB -v ON_ERROR_STOP=1 -f /sql/verify_ledger.sql'

# 5 ── a return point BEFORE the migration — then copy it off the machine immediately.
docker compose -f docker-compose.prod.gitlab.yml --env-file .env.production run --rm -v "${PWD}\restore:/b" backend bash -c 'PGPASSWORD=$POSTGRES_PASSWORD pg_dump -Fc -h db -U $POSTGRES_USER -f /b/pre-migration.dump $POSTGRES_DB'

# 6 ── migrate.  One migration is pending as of 2026-09-26, and it is purely additive
#     (add_column + create_table + create_index; no drop).
docker compose -f docker-compose.prod.gitlab.yml --env-file .env.production run --rm backend bash -c 'cd /app/backend && alembic current'
#     → 20260924_invoice_gold_tracked
docker compose -f docker-compose.prod.gitlab.yml --env-file .env.production run --rm backend bash -c 'cd /app/backend && alembic upgrade head'
docker compose -f docker-compose.prod.gitlab.yml --env-file .env.production run --rm backend bash -c 'cd /app/backend && alembic current'
#     → 20260925_settlement_reason_limits

# 7 ── verify again.  Same file, same invariants.
docker compose -f docker-compose.prod.gitlab.yml --env-file .env.production run --rm -v "${PWD}\scripts:/sql:ro" backend bash -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -h db -U $POSTGRES_USER -d $POSTGRES_DB -v ON_ERROR_STOP=1 -f /sql/verify_ledger.sql'

# 8 ── now, and only now, the application.
docker compose -f docker-compose.prod.gitlab.yml --env-file .env.production up -d --remove-orphans
docker logs yasargold-scheduler --tail=20

# 9 ── smoke test, READ ONLY (§7.3)
# 10 ── off-site backup (§8).  The GitLab runner is the LAST step, after §8.
```

---

## 5. Verification baselines

Transcribed from `yasargold-backup-2026-09-24T23-13-53.zip`, restored and verified 2026-09-26:

| Check | Value |
|---|---|
| `sha256` of the archive | `12b28f77a366bd17d8590ed9c420d95672ed1859f677ef093bb5c296b241255a` |
| `created_at_utc` | `2026-09-24T23:13:48.221733Z` |
| Source server / dump client | 16.15 (Debian) / 17.11 (Debian) — i.e. from the production container |
| `alembic_version` before migrating | `20260924_invoice_gold_tracked` |
| Public tables | 76 |
| Invoices / last invoice date | **2,421** / **2026-09-24** |
| Invoice payments | 2,751 |
| Journal entries / lines | 6,258 / 25,713 |
| Suppliers | 26 |
| **Cash ledger** | debit **77,297,159.27** = credit **77,297,159.27**, difference **0.00** |
| Active accounts | 1 `system_admin`, 1 `manager`, 6 `employee` |

These counts belong to *that* archive; a newer one only grows. What must hold for **any** restore are
the invariants in `scripts/verify_ledger.sql`, which raise rather than print:

1. `alembic_version` holds exactly one row.
2. Invoices exist at all (otherwise this is not a production database).
3. The cash ledger balances to within one halala **over live lines only** — `is_deleted = false` is
   load-bearing: across *all* lines the same backup is out of balance by 116,378.00, because
   soft-deleted lines are excluded from the books. A check without that filter is a false alarm.
4. At least one active `system_admin` — a restore nobody can log into is a failed restore.

Witnessed red before green on 2026-09-26: corrupting one cash line by 0.50 and deactivating the only
`system_admin` each made the script exit **3**; untouched data exits **0**.

---

## 6. Abort criteria

Stop, change nothing further, and re-plan if:

- `pg_restore` prints any error other than the single `transaction_timeout` line of §1.
- `verify_ledger.sql` exits non-zero at step 4 — **especially** do not migrate. Restoring again is
  cheap and repeatable; migrating over data you do not trust is neither.
- `alembic current` at step 6 reports something other than the version the archive carried.
- Counts at step 4 are *lower* than §5 while the archive is *newer* than 24 Sep.

---

## 7. What must never happen

1. **Starting `backend` before the restore and the migration.** `backend/app.py` calls
   `db.create_all()` at import time (gunicorn never runs `__main__`), so an app that boots first
   creates tables straight from the models. The schema then looks correct while `alembic_version`
   stays behind and anything only a migration can do — a backfill above all — silently never runs.
   That is exactly how the Phase 16C release reached production with its tables present and 0 of 153
   obligations backfilled. Step 2 starts `db` alone for this reason.
2. **Suppressing errors wholesale** to get past step 3. One known error is read and accepted; the
   rest are the signal.
3. **"Testing" the restored system by creating an invoice, voucher, or journal entry.** That writes
   into real books. The step 9 smoke test is read-only: log in, confirm the last invoice is the
   24 Sep one, open the supplier balance page (derived from the ledger — ADR-028), read the
   scheduler log. Real business traffic resumes on its own.

---

## 8. After production is up

| Order | Action | Why here |
|---|---|---|
| 1 | Automatic **off-site** backup | Production running for days with its backups on its own disk is a verbatim repeat of the 2026-09-25 loss. `backup_data` is a volume on the same machine; it does not count. |
| 2 | Monthly automatic restore drill: `scripts/verify_backup.ps1` against the newest archive | An untested backup is not a backup. It is also the rehearsal for moving to a Linux host later. |
| 3 | GitLab runner as a **Windows service** (not `gitlab-runner run` in a window), `GL_TOKEN` read from `.env.production` | Last deliberately: until a runner is registered, a push to `main` cannot deploy — which is exactly the protection you want *during* a recovery. A registered runner mid-restore would race `up -d` against you. |

---

## 9. Defects this runbook works around

| Defect | Severity | Fix owner |
|---|---|---|
| `backend/Dockerfile` installs `postgresql-client` unpinned → client 17 against server 16 → every system-produced backup restores with a non-zero exit, and the in-app restore path calls a successful restore a failure | 🔴 High | Path B item 1: pin `postgresql-client-16` + a test asserting exit 0 on a system-produced backup |
| `update-prod.bat` carries a placeholder `GL_TOKEN` in a tracked file | 🟡 Medium | Path B: read it from `.env.production` |
| `DATABASE_URL` names no driver | 🟡 Medium | Path B: explicit `postgresql+psycopg2://` + a gate |
| No automatic off-site backup | 🔴 High | §8 item 1 |

Root cause shared by the first three: **an unpinned toolchain**. The same omission that broke
`commerce-api` on a clean build (`sqlalchemy>=2.0` → 2.1.1 → a psycopg driver that was never
installed) also broke the disaster-recovery path itself. `backend/requirements.txt` pins with `==`
and was never affected. That is the whole lesson, and Path B is where it becomes a gate.
