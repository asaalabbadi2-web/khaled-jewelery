# Runbook — Release rehearsal: prove a release on a copy of production before it ships

**Applies to:** every ERP production release (`docker-compose.prod.gitlab.yml`, pinned `IMAGE_TAG`)
**Tool:** `backend/tools/rehearse_release.py` (+ `backend/tools/rehearse_probe.py`) · judgement pinned by `backend/tests/test_rehearse_release.py`
**Rule:** nothing is tried on production. A release ships only with a GREEN rehearsal made on the backup taken just before the deploy.
**See also:** `local-staging.md` (synthetic seeded scenarios for the commerce↔ERP seam — a different job), `disaster-recovery.md`

---

## When

After CI has built the images for the commit to ship, and right after the pre-deploy backup is taken — before `IMAGE_TAG` changes on the server.

## Run

```bash
python backend/tools/rehearse_release.py \
  --backup  ~/Downloads/yasargold-backup-<timestamp>.zip \
  --baseline <IMAGE_TAG production runs now> \
  --release  <commit to ship> \
  --report   rehearsal-<commit>.md
```

`--release WORKTREE` rehearses uncommitted work; a path rehearses any backend directory. About five minutes on the 28 Sep 2026 data. Exit status: 0 green, 1 red, 2 could not run.

## Deploy — `update-prod.ps1` on the server

Once: copy `update-prod.ps1` and `update-prod.bat` into `C:\Projects\khaledjewels`, and run `docker login registry.gitlab.com` (the credentials are then stored; the script holds no token).

```powershell
cd C:\Projects\khaledjewels
.\update-prod.bat -Tag <8-char tag> -Backup              # images exist? then a backup with the server's own pg_dump
# the dump lands on the external drive: D:\yasargold-recovery\pre-<tag>-<time>.dump
# copy it to the Mac and run the rehearsal the script prints
.\update-prod.bat -Tag <8-char tag> -Deploy -Rehearsed   # only on GREEN
.\update-prod.bat -Tag <previous tag> -Deploy -Rollback  # if ever needed; the script prints it
```

`-Deploy` refuses without `-Rehearsed`, refuses the tag already running, stops before any change if an image is missing, writes `IMAGE_TAG` and reads it back, migrates before anything restarts (a failed migration puts the old tag back and restarts nothing), then checks the running image tags, `401` for an anonymous `/api/invoices` and `200` for `/api/auth/check-setup`. `-DryRun` prints every step and changes nothing. Backups go to the external drive `D:\yasargold-recovery` (`-BackupDir`; the owner's choice, 29 Sep 2026), never the production disk: if the drive is not connected the script stops before dumping, and a copy that does not start with `PGDMP` is refused. Proven against a fake `docker` by `backend/tests/test_update_prod_script.py` (16 tests; the rehearsal gate, the tag restore and the boot wait witnessed red by breaking them). Every command it prints is the `.bat` form: a stock Windows client refuses to run a `.ps1` directly. It pulls and restarts `backend`, `scheduler` and `nginx` only — never the database: `postgres:16` is a moving tag. The database was still recreated by both deploys of 29 Sep 2026 — it read `.env.production` whole, so each new `IMAGE_TAG` changed its environment; `db` and `nginx` no longer read that file (`tests/test_production_compose.py`). Verification waits for the backend (up to `-SettleSeconds`, default 90) instead of a fixed pause.

The CI job `deploy-production` is manual only: a runner registered one day must not turn a push into a deploy.

## Restart policy — every container comes back on its own

`docker-compose.prod.gitlab.yml` gives every service `restart: unless-stopped` (RESTART-001). Containers created before that carry no policy; apply it once, without recreating anything:

```powershell
docker update --restart unless-stopped yasargold-db yasargold-backend yasargold-scheduler yasargold-nginx
docker inspect -f "{{.Name}} {{.HostConfig.RestartPolicy.Name}}" yasargold-db yasargold-backend yasargold-scheduler yasargold-nginx
```

It only helps if Docker Desktop itself starts: *Settings → General → Start Docker Desktop when you sign in*, and the machine signs in after a reboot.

## Automatic backups — `copy-backups.ps1` on the server

The app writes `yasargold-backup-<UTC stamp>.zip` every night at 02:00 (Asia/Riyadh) into the Docker volume behind `/data/backups` and keeps the last 7. A Windows scheduled task copies each one to the external drive:

```powershell
# once (as the user Docker Desktop runs under):
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Projects\khaledjewels\copy-backups.ps1 -Install
Start-ScheduledTask -TaskName yasargold-backup-copy          # run it now
Get-ScheduledTaskInfo -TaskName yasargold-backup-copy        # LastTaskResult 0 = success
Get-Content C:\Projects\khaledjewels\logs\backup-copy.log -Tail 20
```

Daily at 03:15 into `D:\yasargold-recovery\auto`: each copy is checked (a zip whose `database.dump` starts with `PGDMP`) before it takes its name; 30 days are kept, never fewer than the newest 7. The run fails — `LastTaskResult` 1 and a `PROBLEM:` line in the log — if the drive is missing, Docker is unreachable, an archive is broken, or the newest backup is more than 26 hours old. `backend/tests/test_copy_backups_script.py` (7).

## What it does — all on the Mac, hermetic

1. Restores the backup into scratch databases (the oldest `pg_restore` that can read it), then `ANALYZE` — production has planner statistics, a fresh restore does not.
2. Exports both versions with `git archive` (never checks out over the working tree) and runs them with no `.env`, `BYPASS_AUTH_FOR_DEVELOPMENT=0`, and outbound HTTP pointed at a closed port: no price fetched, nothing uploaded, nobody called.
3. **Control:** the baseline answers every `/api` GET, as the shop's manager, on two identical copies. Routes that answer differently there are noise (clock, database name) and are named and set aside.
4. **Release:** `alembic upgrade head` on the second copy exactly as the deploy does, boot, the same requests. Every status change is named.
5. **Security:** every `/api` route must refuse an anonymous request unless listed in `api_auth_guard.PUBLIC_API_ROUTES`.
6. **Rollback:** the baseline must boot on the migrated copy and answer as before — rolling back is then just the previous tag.
7. **Nights:** the nightly jobs (`safebox_reconciliation`, `books_invariants`) run twice; the financial tables are fingerprinted around each night. After the first night nothing may change.

## Reading the report

- **GREEN** → deploy the same tag, unchanged.
- **RED** → no deploy. Each reason is named: a route whose status changed, an open route, a failed migration or boot, a job that is not idempotent.
- A status change the release *intends* (a route that used to fail now answers) is accepted only by name: `--accept /api/route` — and the report says so.
- **Body changes on a stable route** are not red; they are the review list. Read them before deciding.
- **Slowest routes** are listed; on 28 Sep 2026 `/api/journal-entries/posted` took ~40 s.

## Limits

- It cannot click through the app; the Flutter tests and `tests/test_frontend_sends_session.py` cover the client.
- It cannot see what production writes after the backup was taken.
- It sweeps GET only: writes are exercised by the nightly jobs and by the test suite, not here.

## Known issues

- **Duration varies — from about 5 minutes to about an hour.** In the slow runs each probe process spent 7–15 minutes *outside* its requests (the routes themselves summed to about 60 s). No lock wait was seen and the machine was not busy; the cause is not found yet. The report now prints each sweep's split (import / sign-in / requests) so the next slow run shows where the time goes. The verdict is unaffected: it is made from the recorded answers, not from time.
- **Fixed:** the control and the rollback sweeps wrote to the same file (`label=` now keeps them apart). Comparisons were never affected — each sweep was read as soon as it was written.

## Traps it already handles (learned 2026-09-28)

| Trap | What went wrong | What the tool does |
|---|---|---|
| `backend/.env` sets `BYPASS_AUTH_FOR_DEVELOPMENT=1` | tokenless requests served as admin — every 401 check lies | runs every version without `.env`, bypass off |
| Copied data trips the idle-session timeout | every token rejected with `session_expired` | refreshes `session_activity` in the scratch copies only |
| A per-request `signal.alarm` | cannot cancel a query already on the server; it kept running and stalled the rest (33 min instead of 5) | `PGOPTIONS=-c statement_timeout` — Postgres cancels cleanly |
| Live gold-price fetches | answers differ between identical runs | hermetic proxy + the control sweep |
| A 17-written archive vs a 16 server | `transaction_timeout` errors | picks the reader, treats only that error as benign |

## First runs — 2026-09-28, backup `lastBUp.dump`

| Rehearsal | Result |
|---|---|
| production (`98ea522`) against itself | 🟢 GREEN — 0 status changes (noise check) |
| `98ea522` → working tree (books invariants + deny-by-default guard) | 🟢 GREEN — schema `20260925_settlement_reason_limits` → `20260928_rf_subject`, 0 open routes, 0 status changes, both nights left the financial tables unchanged |
| a planted fault (`GET /api/suppliers` raises) | 🔴 RED — `/api/suppliers: 200 → 500` |
