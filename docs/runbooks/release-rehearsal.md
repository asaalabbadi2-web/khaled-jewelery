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
