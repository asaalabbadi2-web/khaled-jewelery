# Recovery Snapshot — 2026-09-26

**Purpose:** freeze the exact state production was brought back to, so any later divergence is
measurable against something real instead of remembered. This is a record, not a procedure — the
procedure is `docs/runbooks/disaster-recovery.md`.

**Incident:** the shop's production machine was wiped by a hardware failure on 2026-09-25. The
development machine was untouched. Production was rebuilt on a clean Windows install from the newest
off-machine backup.

---

## 1. What production is now

| | |
|---|---|
| Production checkout | `C:\Projects\khaledjewels` |
| Compose file | `docker-compose.prod.gitlab.yml` (+ `--env-file .env.production`, always explicit) |
| PostgreSQL | 16 (container) |
| Database / role | `yasargold_db` / `yasargold` |
| Alembic revision | `20260925_settlement_reason_limits` (head) |
| Image tag in use | `9d6fdad8` (commit `9d6fdad`) — pinned at this baseline, was `latest` |
| backend image digest | `sha256:1b9e2668651033e49aeab73c0602ecc2f40c143d7afea9fa5652864fa69b0ad1` |
| web image digest | `sha256:1b361ec660a5f7bf0b493732f7ef776de3881a8cbbd282683531b585f87f8da2` |
| Services | db · backend · scheduler · nginx — all up |

**How the image pin was established:** the manifest digest of tag `9d6fdad8` was compared against the
digest of the image actually running, for both services, and they matched. The pin therefore names the
exact bits in production rather than an assumption about which build was deployed. (Note for whoever
repeats this: Docker Desktop's containerd image store reports an image's *manifest* digest as its ID,
which is why `docker inspect` and `docker manifest inspect --verbose` agree here. The tag `9d6fdad`
does not exist — GitLab's `CI_COMMIT_SHORT_SHA` is **eight** characters, not the seven `git log` prints.)

`C:\khaled-jewelery` is a **stale path from before the incident. It is not production.** Both deploy
paths — `update-prod.bat` and `.gitlab-ci.yml` — were corrected to `C:\Projects\khaledjewels` in the
same commit as this document; see §5 for what remains.

---

## 2. Timeline

| When (Asia/Riyadh) | Event |
|---|---|
| 2026-09-24 23:13 UTC (= 09-25 02:13 +03) | Last backup taken on the old machine — the one recovery was built from |
| 2026-09-25 | Production machine wiped |
| 2026-09-26 10:27 +03 | **Production services restored** — first successful backend start in the logs |
| 2026-09-26 ~10:36 +03 | **Login verification completed** |

Two timestamps deliberately, not one averaged guess: services being up and a human proving they can
sign in are different facts, and a recovery record that blurs them is less useful than one that does not.

**RPO achieved: ~26 hours.** The business day of 2026-09-25 is the accepted loss.

---

## 3. Provenance of the data

**Source archive** (verified on the dev machine before the restore, 2026-09-26):

| | |
|---|---|
| File | `yasargold-backup-2026-09-24T23-13-53.zip` |
| SHA-256 | `12b28f77a366bd17d8590ed9c420d95672ed1859f677ef093bb5c296b241255a` |
| Created | `2026-09-24T23:13:48.221733Z` · format `pg_dump_custom` |
| Origin | server 16.15 (Debian) / `pg_dump` 17.11 (Debian) — i.e. the production container itself |
| Alembic revision inside | `20260924_invoice_gold_tracked` |

**Post-recovery backup** (taken from the restored, migrated production):

| | |
|---|---|
| File | `yasargold-post-recovery.dump` |
| SHA-256 | `71011F2FC374367D52B56A9093E605BC8E4EBE6660F4EF4143AD9BA6FF92CF3F` |
| Size | 6,012,441 bytes |
| Off-machine copy | `D:\yasargold-recovery\yasargold-post-recovery.dump` (USB) |

---

## 4. Verified state of the books

Measured on production after `alembic upgrade head`:

| Check | Value |
|---|---|
| Invoices | 2,421 |
| Invoice payments | 2,751 |
| Journal entries | 6,258 |
| Journal entry lines | 25,713 |
| Suppliers | 26 |
| Cash ledger difference | **0.00** |

**These are identical to the source archive's own counts**, independently verified on the dev machine
before the restore. Since no business was transacted between the restore and the count, equality is
what a faithful restore must produce — and it did. (Corroborating detail: the post-recovery dump is
983 bytes larger than the source's `database.dump`, consistent with the one additive migration
applied in between.)

**How the ledger was checked, precisely:** by direct SQL over `journal_entry_line.cash_debit` /
`cash_credit` on production. **Not** via `scripts/verify_ledger.sql` — that file did not exist on the
production machine at the time, because it had been written but never committed. This commit fixes
that. The first run of `verify_ledger.sql` on production is therefore still pending, and it is the
stronger check: it also asserts a single `alembic_version` row, a non-empty invoice table, and at
least one active `system_admin`, and it excludes soft-deleted lines — without which the same healthy
data reads as 116,378.00 out of balance.

---

## 5. Known exposures at this baseline

Recorded so they are not rediscovered under pressure. None of them blocks operation today.

| Exposure | Consequence | Where it is fixed |
|---|---|---|
| No automated off-site backup. The USB copy is manual and sits beside the machine | A theft or fire takes both | Post-recovery plan, phase 2 — the top priority |
| `IMAGE_TAG` is a tag, not a digest | Tags are mutable in principle. The pin is safe because `9d6fdad8` is a commit tag CI never rewrites — unlike `latest`, which every push to `main` re-tags (the build jobs have no `changes:` filter, so even a docs-only commit rebuilds production's images) | Digest pinning would need two explicit image references in compose; not worth it while commit tags hold. Post-recovery plan, phase 9 |
| The stale `C:\khaled-jewelery` folder may still exist on the machine | Compose derives its project name from the folder, so that path resolves to a **different volume namespace** (`khaled-jewelery_postgres_data`, not `khaledjewels_postgres_data`) — anything run from there would not be operating on this database. Both deploy files now point at the correct path, but an ambiguous folder invites the mistake back | If it still exists, rename it (e.g. `C:\khaled-jewelery.old`) so only one production folder can be found |
| The GitLab runner is not registered | No automatic deploy can run — which is deliberate protection, not an omission | Post-recovery plan, phase 8, and only **after** image pinning holds: an automated deploy over a mutable tag automates the uncertainty |
| In-app restore reports failure on a successful restore (`postgresql-client` unpinned → client 17 vs server 16) | An operator may conclude a good restore failed and try something worse | Post-recovery plan, phase 6. `disaster-recovery.md` §1 is the workaround until then |
| Secrets rotated at recovery: `POSTGRES_PASSWORD`, `JWT_SECRET_KEY`, `FLASK_SECRET_KEY` | Old JWTs and refresh tokens invalid — one re-login per user. 2FA unaffected (`totp_secret` is independent of both keys) | Done, no action |

---

## 6. What invalidates this snapshot

Write a new one — do not edit this file — when any of these changes: the Alembic head, the database
name or host, the production checkout path, the compose file, or the off-site backup arrangement.
This document's value is that it was true at one specific moment.
