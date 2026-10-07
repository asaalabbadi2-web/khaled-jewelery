# Architecture v1.0 — Platform Constitution

**Status:** Frozen  
**Date:** 2026-07-13 · Last updated: 2026-07-14  
**Scope:** yasargold Commerce Platform — Backend Core  
**Tests at freeze:** 358 (247 domain · 111 commerce-api) — 0 failures  
**Tests at v1.1.0:** 414 (275 domain · 139 commerce-api) — 0 failures  
**Tests at v1.2.0:** 484 (311 domain · 173 commerce-api) — 0 failures  
**Tests at v1.3.0:** 517 (321 domain · 196 commerce-api) — 0 failures  
**Tests at v1.3.1:** 529 (321 domain · 208 commerce-api) — 0 failures  
**Tests at v1.4.0-dev:** 559 (327 domain · 232 commerce-api) — 0 failures
**Tests at v1.4.0:** 589 (334 domain · 255 commerce-api) — 0 failures  
**Tests at v1.4.1-dev:** 659 (334 domain · 325 commerce-api) — 0 failures
**Tests at v1.4.2-dev:** 703 (334 domain · 369 commerce-api) — 0 failures
**Tests at v1.4.3-dev:** 707 (334 domain · 373 commerce-api) — 0 failures
**Tests at v1.4.4-dev:** 738 (334 domain · 404 commerce-api) — 0 failures
**Tests at v1.4.5-dev:** 749 (334 domain · 415 commerce-api) — 0 failures
**Tests at v1.4.6-dev:** 765 (334 domain · 431 commerce-api) — 0 failures

> **How to use this document**  
> This is the canonical reference for every design decision on this platform.  
> Any implementation that contradicts a Law here requires a new ADR — not a workaround.  
> Any new Capability must satisfy all Quality Gates before merging to `main`.

---

## 1. Executive Summary

### Vision

A commerce platform for fine jewellery built on an architectural foundation that outlasts any single sprint, team, or provider dependency.

### Scope

The platform governs the full transactional lifecycle of a gold item: from the moment a customer sees a price, to the moment an order closes and ERP records the entry.

### Why This Platform Was Built This Way

Three hard lessons from the ERP monolith that preceded this platform:

1. **Business logic lived in routes.** When a route changed, behaviour changed silently.
2. **State lived in the database only.** No model enforced transitions — anything could be written anywhere.
3. **Providers were wired directly.** Switching a payment provider required rewriting business logic.

This platform was built to make all three impossible by design.

### Core Principles

| Principle | Statement |
|-----------|-----------|
| Domain First | Business rules live in `packages/domain`, not in HTTP handlers |
| Single Source of Truth | One service owns each piece of state |
| Single Writer | Only the owning service writes to its aggregate |
| Atomic Transaction | One Unit of Work per business operation — commit or rollback |
| Events Over Direct Calls | Cross-capability communication goes through the Outbox, not function calls |
| **Policy is Data, Law is Code** | Things that change with the world live as data (env vars, DB rows, config registries). Things that must never change — business invariants and security guarantees — live as tested code. A rule that is not tested is a recommendation. |

### What "Policy is Data, Law is Code" Means in Practice

This distinction — more than any chosen technology — determines whether the platform survives 10 years of operation.

**Policies** (stored as data, changeable without a merge):

| Policy | Where it lives | Who changes it |
|--------|---------------|----------------|
| `void_window` | `CarrierConfig` table row | Ops |
| `reservation_ttl` | `ReservationPolicy` DB row | Product |
| Rate limits per class | `RATE_LIMITS` registry (env-overridable) | Ops |
| Trusted proxy depth | `TRUSTED_PROXY_HOPS` env var | Deployment |
| Tax rate + effective date | Tax policy table | Finance |
| Allowed CORS origins | `ALLOWED_ORIGINS` env var | Deployment |

**Laws** (written as tested invariants, changeable only through an ADR):

| Law | Where it lives | Proof test |
|-----|---------------|------------|
| No item sold twice | `ReservationService` aggregate lock | `test_bola.py` |
| No price without snapshot | `locked_rate` frozen at claim | `test_pricing.py` |
| No domain translation before signature | Webhook handler ordering | `test_webhook_signature.py` |
| Secrets never pass through domain | `import-linter` contract | `test_route_security_scan.py` |
| Every route has a declared scope | `ROUTE_SECURITY` + CI scan | `test_route_security_scan.py` |

The test in the rightmost column is not a quality check — it is the mechanism that makes the invariant binding. Without it, the "law" is a comment.

**The enforcement mechanism for this principle** is `ADR-000` (the template itself): the mandatory "Policy or Law?" field forces the classification decision at the point where it is made, not as a post-hoc annotation.

---

## 2. Platform Topology

```
┌─────────────────────────────────────┐
│           Next.js Web               │  (v1.2+)
└──────────────────┬──────────────────┘
                   │ HTTPS
                   ▼
┌─────────────────────────────────────┐
│        Commerce API (FastAPI)       │
│  /api/v1/catalog                    │
│  /api/v1/reservations               │
│  /api/v1/payments                   │
│  /api/v1/orders                     │
│  /api/v1/webhooks/payment           │
│  /metrics  (Prometheus)             │
└───────────┬──────────────┬──────────┘
            │              │
     ┌──────▼──────┐  ┌───▼──────────┐
     │   Domain    │  │   Workers    │
     │  Packages   │  │  (Expiry /   │
     │             │  │   Outbox)    │
     └──────┬──────┘  └──────────────┘
            │
     ┌──────▼──────────────────────────┐
     │         PostgreSQL              │
     │  reservations · payments        │
     │  orders · outbox_events         │
     │  gold_price · items (read-only) │
     └──────────────┬──────────────────┘
                    │  Outbox consumer [Sprint 8]
                    ▼
     ┌──────────────────────────────────┐
     │      ERP (Flask — legacy)        │
     │  invoices · accounts · GL        │
     └──────────────────────────────────┘
```

**Data flow direction:** Commerce API → Domain → PostgreSQL → (Outbox) → ERP  
ERP is a **planned downstream consumer** of Commerce events (Sprint 8).  
See §4.6 (Known Gaps) for the current dual-source-of-truth period and its reconciliation contract.

---

## 3. Layering Rules

### Layer Definitions

```
apps/commerce-api          ← HTTP handlers, Workers, Infrastructure wiring
       │
       ▼
packages/domain            ← Aggregates, Services, Events, Protocols
       │
       ▼
packages/platform          ← Shared value types, identifiers (no domain concepts)
       │
       ▼
PostgreSQL                 ← Persistence (accessed only through UoW + Repository)
```

### Dependency Table

| Layer | May depend on | May NOT depend on |
|-------|--------------|-------------------|
| `packages/domain` | `packages/platform`, stdlib | Flask, FastAPI, SQLAlchemy, Requests, any SDK |
| `packages/platform` | stdlib | anything above |
| `apps/commerce-api` routers | `packages/domain`, `packages/platform`, FastAPI | other routers, infra directly |
| `apps/commerce-api` infra | `packages/domain`, SQLAlchemy | FastAPI routers |
| Workers | `packages/domain`, infra | — |

### Enforcement

`import-linter` is configured in `pyproject.toml` and runs in CI.  
A PR that breaks these rules **cannot merge**.

---

## 4. Business Capabilities

Each capability owns its Aggregate, Service, Events, Repository, and UoW.  
No two capabilities share a write path.

### 4.1 Pricing

| Element | Detail |
|---------|--------|
| Core type | `Quote` (value object — immutable after issue, never persisted) |
| Service | `pricing/engine.py` — `karat_rate()`, `PRICING_ENGINE_VERSION` |
| Events | none (read-only capability) |
| Source of truth | `gold_price` table (written by ERP scheduler, read by Commerce) |

**Price freshness contract (INV-8):**

| Age of `gold_price.date` | Quote status | Reservation allowed? |
|--------------------------|--------------|----------------------|
| < 90 seconds | `FRESH` | ✅ Yes |
| 90s – 5 min | `STALE` | ❌ No (`QUOTE_STATUS_INVALID`) |
| > 5 min | `HALTED` | ❌ No (`QUOTE_STATUS_INVALID`) |

`gold_price.date` is stored as **naive UTC** by the ERP (`gold_price.save_gold_price`, since 28 Jul 2026 — rows before that are Riyadh wall clock and stay as stored, the owner's decision).  
Commerce normalises it with `tzinfo=UTC`. The ERP's readers compute ages in UTC, cut days at Riyadh's midnight and send every time marked `Z` (`backend/pricing/price_clock.py`, `tests/test_gold_price_clock.py`).

**Quote snapshot (INV-2):**  
Although `Quote` is never persisted, the fields that matter for invoice reconstruction are  
written onto `ReservationRecord` at lock time:
- `locked_rate_per_gram_24k` (Decimal)
- `karat_rate_per_gram` (Decimal)
- `pricing_engine_version` (e.g. `"v1"`)
- `gold_price_id` (foreign key to the row used)

This makes invoice reconstruction deterministic at any future point without re-querying the market.

---

### 4.2 Reservation

| Element | Detail |
|---------|--------|
| Aggregate | `Reservation` |
| Service | `ReservationService.reserve()`, `ReservationExpiryService.expire_elapsed()` |
| Events | `ReservationCreated` |
| Repository | `InventoryReservationRepository` (Protocol) |
| UoW | `ReservationUnitOfWork` |
| State machine | `ACTIVE → EXPIRED \| CANCELLED \| COMPLETED` |

**Invariant INV-6:** Partial unique index on `(item_id) WHERE status = 'ACTIVE'` +  
`SELECT FOR UPDATE NOWAIT` guarantees exactly one active reservation per item  
across concurrent online requests.

> **Known gap (INV-4):** INV-6 prevents two concurrent *online* reservations.  
> It does **not** prevent a physical POS sale via ERP while an online reservation is active.  
> ERP invoice creation currently has no check against the `reservations` table.  
> **ADR-013** accepts this gap for the transition period under three mandatory conditions:  
> (1) double availability check at reservation creation + checkout confirmation,  
> (2) `GET /api/v1/items/{id}/availability` endpoint for POS screens,  
> (3) compensation path (`PAID → REFUND_PENDING → REFUNDED`) must exist before real monetary volumes.  
> Terminal resolution: Sprint 8 (ERP Sync) will implement a shared `InventoryService`.  
> ADR-013 expires at Sprint 8; extension requires a new ADR.

---

### 4.3 Payment

| Element | Detail |
|---------|--------|
| Aggregate | `PaymentIntent` |
| Service | `PaymentService.issue()`, `PaymentService.confirm()` |
| Events | `PaymentIntentCreated`, `PaymentReceived`, `PaymentFailed` |
| Repository | `PaymentIntentRepository` (Protocol) |
| UoW | `PaymentUnitOfWork` |
| Gateway | `PaymentGateway` (Protocol) — implemented by `MoyasarGateway` |
| State machine | `PENDING → PAID \| FAILED \| EXPIRED` · `PAID → REFUND_PENDING → REFUNDED` |

**Idempotency:** A duplicate webhook for an already-terminal intent raises  
`PaymentIntentStatusError` → HTTP 204 (not 4xx). No double-processing.

**Late webhook (PENDING → EXPIRED then webhook arrives):**  
`can_pay()` returns `False` when `expires_at` has elapsed.  
`PaymentService.confirm()` raises `PaymentIntentExpiredError`.  
The HTTP layer returns 204. The charge was already collected.

**Payment Succeeded with Business Failure (INV-10) — resolved v1.0.1:**  
When a webhook arrives successfully but checkout fails (e.g. reservation expired  
or INV-4 race), the money is captured but the order is not created.  
This is not FAILED (provider rejected) nor EXPIRED (no payment). It is its own state:

```
PAID ──[reservation expired / INV-4 race]──► REFUND_PENDING
                                                    │
                                          [provider confirms refund]
                                                    ▼
                                                REFUNDED   ← terminal
```

Guard methods: `can_mark_refund_pending()` (PAID only) · `can_mark_refunded()` (REFUND_PENDING only).  
`RefundWorker` polls for `REFUND_PENDING` intents and calls `gateway.refund()`.  
`REFUNDED` is a terminal state — `is_terminal` returns `True`.

---

### 4.4 Checkout — Application Orchestrator

Checkout is not a Domain Service in the traditional sense.  
It is an **Application-layer Orchestrator**: the HTTP webhook handler that holds  
two UoWs and calls two domain services in sequence.

```
POST /api/v1/webhooks/payment
  │
  ├── Phase 1: payment_uow
  │     payment_service.confirm(webhook_result, payment_uow)
  │     payment_uow.commit()          ← intent is now PAID
  │
  └── Phase 2: checkout_uow  (only if intent.can_confirm())
        checkout_service.confirm(reservation_id, order_service, checkout_uow)
        checkout_uow.commit()         ← reservation COMPLETED + order CREATED atomically
```

**Why two phases instead of one?**  
The payment record must survive even if checkout fails (audit requirement).  
If they were in the same UoW, a checkout bug would roll back the payment record.

**`CheckoutUnitOfWork`** holds `reservation_repository` + `order_repository`  
in a single SQLAlchemy session, so the state change is atomic across both aggregates.

---

### 4.5 Orders

| Element | Detail |
|---------|--------|
| Aggregate | `Order` |
| Service | `CheckoutService` (creates), `OrderService` (transitions) |
| Events | `OrderCreated` |
| Repository | `OrderRepository` (Protocol) |
| State machine | `PENDING → CONFIRMED → READY_FOR_SHIPMENT → SHIPPED → DELIVERED` ↘ `CANCELLED` |

`Order` is the canonical business record for a completed sale (ADR-011).  
ERP journals are derived from `OrderCreated` — not the other way around.

---

### 4.6 Known Gaps and Planned Resolutions

| Gap | Severity | ADR | Status | Resolution |
|-----|----------|-----|--------|------------|
| FC-2: `syncServerClock` never called in `gold-price-context.tsx` — age computed from `Date.now()`, defeating skew correction | 🟡 Medium | — | 🟡 Open | Call `syncServerClock(data.updatedAt)` inside `GoldPriceProvider`'s fetch callback before computing `initialAge`. The `updatedAt` field returned by `/catalog/gold-price` is a reliable server-now proxy. Until wired, skewed device clocks show incorrect staleness. Components fixed (checkout, product) — only the context remains. |
| INV-4: POS can sell a reserved item | 🔴 High | ADR-013, ADR-016 | 🟡 Managed — NOT closed | ADR-016 (Option B) bridges Commerce→ERP via async event sync. INV-4 window = `payment_confirmation` → `ERPSyncWorker consumes OrderCreated` (SLO: P95 ≤ 30s, `erp_sync_lag` metric). If the worker is down the window is unbounded. Compensation path: `REFUND_PENDING` → RefundWorker. **Gate B (POS UI) is now the sole preventive mechanism on the showroom side — not optional.** |
| INV-10: No REFUNDED state in PaymentIntent | 🔴 High | ADR-013 | ✅ Resolved v1.3.0 | `REFUND_PENDING` + `REFUNDED` + `RefundWorker` + `RefundGateway` Protocol built. Gate A still requires staging E2E with real Moyasar sandbox. |
| INV-11: POS UI has no visibility into online reservations | 🟡 Medium | ADR-013 | 🟡 Partial | `GET /api/v1/items/{id}/availability` endpoint deployed. **POS UI integration pending** — this is Gate B, which is now the sole preventive mechanism for INV-4 on the showroom side under the Event Sync architecture (ADR-016). |
| ERP dual source of truth | 🟡 Medium | ADR-012 | ✅ Resolved v1.3.0 | `ERPSyncWorker` + `POST /api/internal/online-orders` + `ReconciliationWorker` built. ADR-013 Sunset Clause closed and renegotiated by ADR-016 (Option B substituted for Option A — see ADR-016 for explicit declaration). |
| SEC-001: No authentication on Commerce API write endpoints | 🔴 High | ADR-017 | ✅ Closed v1.4.6 | JWT enforced on all non-public endpoints via `get_customer_ref` (customer scope) and `require_admin` (admin scope). `require_admin_secret` (X-Admin-Secret) fully retired. Proof: `test_admin_scope_enforcement.py` (admin-side, 13 tests) + `test_law4_customer_scope.py` (customer-side, 16 tests). Bug caught in closing: `GET /orders/{id}/shipments` was classified `scope=customer` but missing `Depends(get_customer_ref)` — found and fixed by the proof test. |
| SEC-002: Carrier adapter contract unvalidated against real sandbox | 🟡 Medium | ADR-015 | 🟡 Open | `LogShippingGateway` stub does not verify that `declared_value` and `idempotency_key` arrive at the carrier with correct field semantics. A single end-to-end sandbox test proving correct field delivery MUST be a merge requirement for any real carrier adapter — not a post-deployment observation. Failure here means: wrong `declared_value` → insurance gap; missing `idempotency_key` → duplicate labels billed to account. |
| SEC-003: `/api/internal/*` trust boundary | 🟡 Medium | ADR-016 | 🟡 Mitigated | `_check_internal_secret()` applies `secrets.compare_digest` on every endpoint in `internal_bp`. If `ERP_INTERNAL_SECRET` is unset → 503 (not silently open). **Trust boundary declared:** caller assumed to be on the same private network; `X-Internal-Secret` is the auth layer within that boundary; any path from outside the private subnet to port 5000 must be blocked at infrastructure level. Terminal fix: mTLS or service-mesh token when infrastructure is hardened. |
| SEC-004: ERP → Commerce pos-claim endpoints trust a shared `X-POS-Secret` | 🟡 Medium | — | 🟡 Mitigated | If the ERP host is compromised, an attacker can claim items on behalf of POS. **Interim:** `secrets.compare_digest` (constant-time); fail-closed (`POS_API_SECRET` unset → 503); `X-POS-Secret` in `RedactingFilter`. **Terminal fix:** mTLS or service-mesh mutual authentication between ERP and Commerce; sunset trigger: the first multi-host ERP deployment or a SOC-2 readiness review. (Recorded in `docs/security/security-overview.md` §8; added here on 2026-09-29 so both registers agree.) |
| TIME-001: ERP backend services (`backend/services/inventory_*.py`, `journals.py`) call `datetime.now()` directly in business logic instead of the injected Clock Provider | 🟡 Medium | ADR-015 | 🟡 Managed | 15 violations suppressed with `# clock-guard: TIME-001` (counted in `docs/architecture/.clock-debt-baseline`). `scripts/clock_guard.py --update` lowers the baseline only after genuine removal. Trigger: first modification of the affected module. Note: `pricing/engine.py:quoted_at` is **not** TIME-001 debt — it is `# clock-guard: record-only`, an audit timestamp with no decision effect (decision gate is `Quote.valid_until` in `quotes.py`). |
| SCHED-001: `start_all_schedulers()` returns a raw list; no SchedulerManager abstraction | 🟢 Low | — | 🟡 Open | A `SchedulerManager` (uniform `start/stop/join` contract across all scheduler types) was deliberately deferred until all 5 scheduler interfaces are understood. Current callers (`run_schedulers.main()`, tests) duck-type the list via `hasattr`. Trigger: when a second scheduler type needs the same stop/join pattern, extract a shared base class or `SchedulerManager`; never add a third duck-type caller before that extraction. |
| SCHED-002: DB connection held for the entire `process_due_settlements()` batch | 🟡 Medium | — | 🟡 Managed | `process_due_settlements()` runs inside a single `app.app_context()` that holds one connection from the pool for its full duration. With `SQLALCHEMY_POOL_SIZE=5` and `gunicorn -w 2`, a slow settlement run (large PM batch, heavy lock contention) can exhaust the pool and stall ERP HTTP handlers. Safe today at current PM volume. Exposure: pool exhaustion under peak batch × gunicorn worker count. Trigger: first observed pool-pressure alert, or before increasing gunicorn workers beyond 4. Fix: chunked batch + explicit session close between chunks, or a dedicated pool with `pool_size=1` for the scheduler process. |
| SEC-005: `BYPASS_AUTH_FOR_DEVELOPMENT` disables ERP authentication and authorization wholesale | 🔴 High | ADR-025 | 🟡 Mitigated — **must never be enabled in production** | When `BYPASS_AUTH_FOR_DEVELOPMENT=1`, `app.py`'s `bypass_auth_for_development()` before_request serves **any `/api/` request without an `Authorization` header as `admin`**, defeating `require_auth`, `require_permission`, `require_admin`, and every permission-derived rule built on them (including SAD's manager-approval bar for `reason_code=OTHER`). The flag is currently set in `backend/.env` for local development. **Consequence for verification: authorization tests executed in an environment with the bypass enabled prove nothing about production security** — any such test must disable the flag explicitly, as `tests/test_auth_bypass_production_guard.py` and the SAD API 401 test do. Mitigation (v-current): `_assert_auth_bypass_not_in_production()` raises at boot when the flag is set and `YASAR_ENV`/`FLASK_ENV` is `prod`/`production`, and the before_request hook independently refuses to apply the bypass in production (defence in depth). Proof: `tests/test_auth_bypass_production_guard.py` (22 tests). Terminal fix: remove the bypass entirely once a seeded local login exists for development. |
| SCHED-003: No DB-level uniqueness on `(payment_month_id, settlement_date)` | 🟡 Medium | — | 🟡 Open | `ensure_unique_reference=True` prevents a second auto-settlement run from writing a duplicate *reference string*, but a manual settlement voucher with the same PM on the same date can still coexist. There is no DB `UNIQUE` constraint on `(voucher_type='clearing_settlement', reference_payment_month_id, created_date)`. Exposure: if manual settlements are ever enabled alongside the scheduler, or if the unique-reference guard is bypassed, duplicate rows appear without any DB-level rejection. Trigger: before enabling manual clearing-settlement creation via the POS/ERP UI, add a partial unique index or DB-level check constraint. |
| STATUS-001: `Invoice.status` carries workflow state and payment state in one column | 🟡 Medium | ADR-028 | 🟡 Managed — guarded by a ratchet | `reject_invoice()` writes `'rejected'` into the same column that otherwise carries `unpaid`/`partially_paid`/`paid`. Full separation into distinct workflow and payment columns is deliberately deferred: it touches ~150 `Invoice.query` sites plus the Flutter UI. **Exposure, measured:** before the guard, an invoice with `is_posted=False, status='rejected'` still reported `invoice_open_gold_obligation() = 200.0`, was counted in `reconcile_supplier().gross_obligation`, appeared in the employee's attribution picker at its full weight, and **accepted 50 g of attributed gold with no objection** — gold evidenced against a document that no longer stood. **Mitigation (v-current):** `live_obligations_for_invoice()` / `live_obligations_for_supplier()` in `services/gold_allocation_service.py` are the single operational channel that decides whether a gold obligation stands; `recorded_obligations_for_invoice()` is the separate, explicitly named reader for the historical record. `reject_invoice()`, `unpost_invoice()` and `delete_unposted_invoice()` now release the attribution evidence and the operational allocations, while `InvoiceGoldObligation` rows are kept as the frozen historical record (ADR-028) so a re-post restores them rather than inventing them again. **Do not treat `InvoiceGoldObligation` existence as proof that an invoice is currently live.** **Proof:** `tests/test_invoice_lifecycle_gold_cleanup.py` (31 tests), of which `TestObligationReadsAreFunnelled` is the ratchet — it fails on any new direct `InvoiceGoldObligation.query` outside the three documented exemptions (`gold_allocation_service.py`, which defines the funnel and the retraction helpers; `invoice_payment_state_service.py`, which reads the invoice's own record for its own status and must NOT be filtered or an unposted invoice reports `gold_required = 0` and can flip to `paid`; `routes/invoices.py`, which deletes the rows). A filter that must be remembered at each reader was the first attempt and was forgotten at the fourth. **Trigger:** before adding any further consumer of invoice gold state, or when the Flutter invoice screens are next reworked — whichever comes first. **Terminal fix:** split the column into `workflow_state` and `payment_status`, at which point the standing test becomes a property of the invoice rather than a convention the funnel enforces. |
| REPAIR-001: `POST /safe-boxes/repair-transactions` (admin, `dry_run=false`) posts unposted voucher entries on posted invoices without reading the voucher's status | 🟢 Low | ADR-030 | ✅ Fixed in code (2 Oct 2026), **not yet deployed** — the tool posts only an approved voucher's entry and names the others with their status; the strict xfail is now the law | The nightly `SafeboxReconciliationScheduler` phase A ran the same code; ADR-030 changed it to REPORT such entries (finding `VOUCHER_ENTRY_UNPOSTED_ON_POSTED_INVOICE`) and post nothing. Its manual twin, `routes/safe_boxes.py::repair_safe_box_transactions`, was deliberately left unchanged in that unit. The dry run lists `would_post_voucher_je` without the voucher status, so the admin who confirms it cannot see a pending or cancelled payment among the rows. **Exposure, measured on the reference bench:** zero candidates on the 24 Sep baseline and on both 28 Sep snapshots (04:51, 09:48) — no unposted voucher entry sits on a posted invoice, so a run today posts nothing. On the 28 Sep 09:48 snapshot, all 28 posted entries of cancelled vouchers (136,681.35 cash debit) are offset by a posted `voucher_reversal`: no damage from this path is visible. It becomes live the moment such an entry exists, and the nightly job now opens a finding for exactly that condition, so the entry is visible before anyone reaches for this tool. **Proof:** `tests/test_books_invariants.py::TestManualRepairStillPostsStatusBlind`, `xfail(strict=True, raises=AssertionError)`; witnessed red without the marker (`assert True is False`: a pending voucher's entry reached the ledger). **Trigger:** before the endpoint is next run with `dry_run=false`, or when the safe-box screens are next reworked. **Terminal fix:** the endpoint reports instead of posting, as phase A does, or is removed (its other duty, the phase B backfill, is done nightly by the job); the witness then XPASSes, turns red, and its marker is deleted. |
| SEC-006: ERP `/api` had no deny-by-default authentication — anonymous requests reached write routes, including deletes | 🔴 Critical | ADR-031 | ✅ Closed — deployed 2026-09-29 (`99e86008`) | Authentication was opt-in per route (decorator), or per blueprint for the legacy `api` blueprint, whose `before_request` required a session. The July 2026 routes migration (`c1195c4` … `0232533`) moved the routes into per-domain blueprints and the protection did not travel with them: **111 route-methods reached their view with no authentication** (49 writes, 62 reads — invoices, account and party statements, employee payroll, `PUT /settings`, `debug/db-info`). **Witnessed on a throwaway database with no token: `DELETE` of a journal entry, a voucher, a supplier and a customer returned 200 and the rows were gone.** Production `ops/nginx/default.conf` publishes `:80` and proxies `/api/` to the backend with no filtering. **Fix:** `api_auth_guard.py` — an app-level `before_request` requires a session for every `/api/` request (reusing `require_auth`), except `PUBLIC_API_ROUTES` (15 entries, each with its reason); OPTIONS passes; an unknown `/api` path is 401. The Flutter app sent no token on 13 `ApiService` methods and the direct-print upload — fixed in the same unit, or those screens would fail after the guard. **Proof:** `tests/test_api_authentication_by_default.py` asks every `/api` rule in the url map (hooks only, no view runs) — witnessed red with the guard unwired: 417 open routes, the four deletes 200; `tests/test_frontend_sends_session.py` checks every raw Flutter HTTP call against the server's public list — witnessed red on the pre-fix sources (14 calls). **Deployed 2026-09-29** as `99e86008` (clients are browsers only). Verified on production: anonymous `GET /api/invoices` → 401; `GET /api/auth/check-setup` → 200. What a signed-in user may do is SEC-007 / SEC-008. |
| SEC-007: 45 ERP write routes declare no permission — any signed-in user can perform them | 🔴 High | ADR-031, ADR-036 | 🟡 Paid in code (R2, 2 Oct 2026), **not yet deployed** — ratchet | After SEC-006 a caller must be signed in, but WHAT they may do is each route's `@require_permission`. 45 write routes declare none and check none in their body — among them `DELETE /journal_entries/<id>` (hard delete, cascades into invoices and vouchers), `PUT /settings` (including `allow_unposting`), voucher approve/cancel/delete, supplier/customer/payment-method delete, gold price update and gold-costing reset. Which role may do each is a business decision, so none was guessed. **Proof:** `tests/test_write_routes_declare_permission.py` lists them by name as debt and fails on any NEW write route that declares no permission (witnessed red with a probe route) and on any entry whose debt has been paid. **Trigger:** before the next role is given to a non-owner employee. **Terminal fix:** a permission per route, decided with the owner, until the debt list is empty. **1 Oct 2026 (UNPOST-001 U3):** three paid — the hard delete of an entry now needs `journal.delete`; cancelling a voucher `vouchers.cancel` (the system admin and the manager — not the accountant, the owner's decision, until the voucher lifecycle is characterised); deleting a voucher `vouchers.delete`. Off the ratchet's allowlist. After V0 the owner kept cancelling off the accountant: not for the books' sake (cancelling is sound) but to separate duties until SEC-007 is complete. **R2 (2 Oct 2026, ADR-036):** the owner decided the roles for all of them; the 38 debts are paid -- each route asks for its matrix code (settings, the costing reset and the gold costing set: `system.settings`; payment methods, branches, offices and the account mappings: the new `business.setup`, the accountant's; recompute: the new `costing.recompute`; customers, suppliers, vouchers, the gold price, bonuses and goals: their catalog codes); a supplier invoice or its return needs the new `invoices.supplier` (manager, accountant -- not the seller); a payment added to an invoice is the seller's on their own invoices only. Four routes stay listed with their reason -- they act on the caller's own goals and achievements (`refuse_unless_self`). **Witness:** `tests/test_write_routes_follow_the_matrix.py` (each role on 12 routes, and the supplier invoice). Measured on the 2 Oct copy: one seller wrote one supplier purchase in 120 days (July); after R2 they cannot. |
| BACKUP-001: automatic database backups were off, and no copy left the machine | 🔴 Critical | — | 🟡 Open — backups on (daily 02:00) and copied nightly to the external drive, both in place 29 Sep 2026; awaiting their first night; nothing leaves the building | On the 28 Sep 2026 production copy `settings.backup_auto_enabled = false`: a backup exists only when someone takes one from the app. **Enabling it would change nothing:** the scheduled path fails at once — `backup_scheduler.py` imports `_create_sqlite_backup_to_file` from `routes`, which the July routes migration moved into `routes/system.py` (`0232533`, 13 Jul 2026), so every scheduled run since has raised `ImportError`, been caught, and printed one log line; witnessed on a production copy on 29 Sep. Had it run, it would write zips to the `backup_data` Docker volume **on the same machine** and upload nothing. The machine was wiped on 25 Sep 2026 (hardware failure) and was rebuilt only because a manually downloaded 24 Sep zip sat on another machine. The manual backup in the app works — it produced that zip. **Terminal fix** (transport decided in the 26 Sep rebuild plan, not built): a daily automatic backup; an automatic off-machine copy through `backend/google_drive_service_account.py`; every copy restored and checked automatically (the restore step of `backend/tools/rehearse_release.py`); a freshness gate that alarms on a *missing* backup; `postgresql-client` pinned to the server's major (16). **2026-09-29:** the import points at `routes.system`, proven by `tests/test_scheduled_backup.py` (witnessed red: the `ImportError`) and by `tests/test_local_imports_resolve.py`, which fails on any import whose name no longer exists. On the 28 Sep copy the fixed scheduled path, with the image's pg_dump 17, wrote a 5.8 MB archive in 2 s; restored, all 77 tables matched the source (row counts and content digests); the only restore error was the benign `transaction_timeout` of a 17 client against a 16 server — the reason for the version pin. Remaining: switch it on, the off-machine copy, automatic verification, the pin. **Trigger:** now — stage 0 of `docs/plans/recovery-roadmap-2026-09.md`. **Witness:** `tests/test_scheduled_backup.py`; the freshness gate is part of the fix. **2026-09-29:** `backup_auto_enabled` was switched on through the settings screen at 10:08 (Riyadh) — `PUT /settings` writes no audit row and declares no permission (SEC-007), so who did it is not on record. The owner chose the external drive `D:\yasargold-recovery` for copies: `copy-backups.ps1`, a Windows scheduled task (daily 03:15, the signed-in user), copies each automatic backup out of the Docker volume into `auto\`, checks it (a zip whose `database.dump` starts with `PGDMP`) before naming it, keeps 30 days there — never fewer than the newest 7 — and fails, logged in `logs\backup-copy.log`, if the drive is missing, Docker is unreachable, an archive is broken, or the newest backup is over 26 hours old (the app stopped backing up). A task, not a bind mount: an unplugged drive fails the copy, never the app's start. `tests/test_copy_backups_script.py` (7; the check and the staleness rule witnessed red by breaking them). **Remaining:** the first night's evidence; a copy that leaves the building (the drive shares the machine's fate — theft, fire, ransomware); an automatic restore test of a copy. |
| SCHED-004: `STALE_SETTLEMENT` — the clearing scheduler's only liveness alarm — opened on an ordinary quiet day and could never close | 🟡 Medium | — | 🟡 Closing deployed (`2d0b1e37`); the alarm by each method's schedule deployed (`c2dd704b`, 29 Sep 2026); the heartbeat in the live bell deployed (`cf34ea91`) and **witnessed on production** | `_emit_stale_finding_if_needed()` opened a finding when no auto-settlement voucher had been created for 3 h and nothing ever resolved it: on the 28 Sep copy one was open since 2026-07-29 with `check_count` 68,093 while 61 auto-settlements followed. The closing was fixed and deployed on 29 Sep 2026. **The threshold could not be fixed by a number:** the 200 auto-settlements since April are about a day apart (median gap 23.7 h, longest quiet spell 96.6 h — weekly methods, days without card sales); 3 h fired on 142 of 199 gaps, 24 h on 90, 72 h still on 5 while letting a real stoppage run three days. **Owner's decision, 29 Sep 2026:** alarm by each payment method's own schedule, not by elapsed time. `OVERDUE_SETTLEMENT`, one finding per method (ADR-030 lifecycle): a payment the method's last settlement day included — read through `settlement_day()`, the scheduler's own and only reading of the schedule — still unsettled `SETTLEMENT_OVERDUE_GRACE_HOURS` (policy, default 6) after that day began. A day without card sales, a weekly method before its day and an amount below the method's minimum raise nothing; open `STALE_SETTLEMENT` rows are resolved and the kind retired. **Measured on the 29 Sep copy:** nothing overdue now; replayed over September it fires on 9,300 of Mada on 26 Sep, the day production was rebuilt. (It also showed a Visa/Master payment of 1,500 late from 11 to 21 Sep — a replay artefact: it was entered as cash and corrected to Visa later, per the owner, and the replay read today's method.) **Proof:** `tests/test_settlement_overdue_alarm.py` (14; witnessed red). **Heartbeat (ADR-033):** the scheduler writes `scheduler_heartbeats` — the process each minute, the settlement loop on start and each wake — and the backend, a different process, reads it in `GET /api/pending-actions`, which the home screen's bell polls: a heartbeat silent over `SCHEDULER_HEARTBEAT_STALE_SECONDS` (policy, 300) is a 'المجدول متوقف' entry at the top of «المعلّقات بانتظار الإجراء» and counts in the bell; computed on each read, gone when the scheduler beats. (Deployed first in `77ca191a` writing SystemAlert rows for the alerts dialog — removed from the app on 2 Jun 2026, `448e475`; nobody could have seen it. Corrected before it was ever tested.) `tests/test_scheduler_heartbeat.py` (13). **Witnessed on production, 30 Sep 2026 (`cf34ea91`):** `docker stop yasargold-scheduler` — the bell showed «المجدول متوقف» after 6 minutes; `docker start` — it cleared itself within 2 minutes. On the owner's remark the fault has its own chip on the home screen, apart from «بانتظار الإجراء» (invoices and reservations). **First real alarm (29 Sep 2026, 22:07–22:18):** the owner corrected sale #1509's payment of 4,000 (24 Sep) from cash to Mada; being already past its day, it opened `OVERDUE_SETTLEMENT` a minute later, and the scheduler's next run settled it (AV-2026-00441) and closed it — the alarm saw money due and not moving, then saw it move. **Remaining:** nothing for SCHED-004 — alarm by each method's schedule, closing, heartbeat and restart policy are all live. **Trigger:** stage 1 of `docs/plans/recovery-roadmap-2026-09.md`. |
| UNPOST-001: seven code paths retract posted documents, and they disagree | 🔴 High | — | 🟡 U1 (`5a006a4f`), U2 (`f7980c20`) and U3 (`73bff07c`) deployed — a document's entry is never touched alone, a posted entry never deleted (ADR-035) · V1 (`21bd2a97`) deployed · U4 deployed (`7cbc67ce`); the freeze stays | **Paths:** `posting_routes.py` `unpost_invoice`, `unpost_invoices_batch`, `unpost_journal_entry`, `unpost_journal_entries_batch`; `routes/invoices.py` `unpost_invoice`; `routes/journals.py` `soft_delete_journal_entry` (permission `journal.delete`, **not gated by `allow_unposting`**) and `delete_journal_entry` (hard delete, no permission — SEC-007). **Disagreements:** the invoice unpost the UI uses appends reversal gold statement rows, leaves the entries `is_posted=False, is_draft=False` — the state party balances count and the ledger readers do not — keeps gold attribution, does not recompute cached balances, and writes an audit row; its `routes/invoices.py` twin deletes the invoice's own statement rows, releases gold evidence, deletes category-weight movements, recomputes balances and writes no audit row. Entry-level unpost will unpost an invoice's or voucher's entry alone while the document stays posted/approved (posting such an entry alone is refused). Soft delete unposts the invoice but leaves its other entries posted and resets an approved voucher to pending; restore re-posts neither. **Terminal fix** (owner's decision, 2026-09-28: unposting and deletion stay): one operation each to post, unpost and delete, every path calling it; a document's entry is never unposted or deleted alone; unposted = draft (the three disagreeing readers already ignore drafts); laws with tests — round trip, no half-state, no residue, complete-or-refused, an `audit_logs` row — and a ratchet that fails on any `is_posted` write outside the service. **Trigger:** stage 3 of `docs/plans/recovery-roadmap-2026-09.md`; the freeze stays until then — and does not cover the two entry-delete paths. **U0 (1 Oct 2026):** every invoice retraction path measured on real invoices (`docs/plans/unpost-001-u0-retraction-map.md`, `tests/u0_retraction_effects.json`). **U1 (in code):** `posting_routes.unpost_invoice_document`, the counterpart of `post_invoice_document`, called by the posting screen, its batch and the invoices route — entries become drafts, the invoice's own safe-box rows go, the inventory ledger is reversed, category weights go, gold evidence is released, balances recomputed; an audit row on success only; an invoice left unposted at creation keeps drafts and writes no safe-box row (the four creation-time safe writers were gated on approval only, not on auto-post off). ADR-034 proved (9 tests); `tests/test_unpost_001_u1_laws.py`. The inventory ledger gained posting cycles (ADR-002 addendum, migration `20261001_inventory_ledger_cycle`). Measured on the 30 Sep copy (360 real invoices, rolled back): after the unpost nothing of any invoice counts anywhere. The round trip in the SAFES does not hold for sales, supplier purchases and returns — posting at creation and posting later are two writers (SAFEBOX-001, POSTGOLD-001) — witnessed xfail. **U2 (in code):** reject withdraws the unposted invoice's draft payments (no voucher, no safe-box row — `invoice_retraction_guard.draft_payments_of`), keeps its entries drafts, answers its approval alert and writes an audit row naming what it withdrew; the edit asks `financial_history_of` (less the draft payments) before deleting anything and refuses as delete does. `tests/test_unpost_001_u2_reject.py`; U0's record changes for reject. **U3 (in code, ADR-035):** a session guard on every SQLAlchemy session (`journal_entry_guard`) refuses at commit an invoice entry out of step with its invoice, an invoice entry deleted while its invoice remains, a voucher entry deleted while its voucher remains, and any bulk delete of entries/invoices/vouchers or bulk update of their posted state; a PostgreSQL trigger refuses deleting, soft-deleting or truncating posted entries, even by raw SQL (migration `20261001_posted_entry_immutable`). The only exception, `system_purge()`, is confined to the two system resets by a test. The entry routes refuse a document's entry and a posted entry early (409). Voucher status ↔ entry posting stays for a voucher discovery (the owner's scope). **V0/V1 (1 Oct 2026, ADR-035 addendum):** every voucher path measured (`docs/plans/v0-voucher-lifecycle-map.md`, `tests/v0_voucher_effects.json`); the guard now holds a voucher's status against its entry — approved: posted; cancelled: posted with a posted reversal; pending and rejected: none — so an approved voucher is cancelled, never rejected (409); the bonus approval, payment and reversal post their voucher's entry in the same operation, whatever the auto-post settings. **U4 (in code):** `unapprove` removed (it refused every approved voucher — each has an entry); the batch approval writes each voucher's audit row; the writers of `is_posted` are frozen (`tests/test_posting_writers_ratchet.py`: 24 functions, witnessed red with an injected writer) — a new one fails until added in review, and the list only shrinks. |
| TEST-001: the tests ran on SQLite, and their fence isolated nothing | 🟡 Medium | — | ✅ Closed in code (30 Sep 2026) — not yet in CI | Two faults, found together. **The fence:** the `rollback_after_each` fixture copied into 17 modules set `db.session.bind = connection`, but Flask-SQLAlchemy 3.1's `get_bind()` never reads `session.bind`: every commit in the code under test stayed in the run's database (a settings row one test left broke another on 29 Sep). **The database:** `backend/conftest.py` forced SQLite while development and production run PostgreSQL — the owner asked why SQLite problems were still being handled. Run once on PostgreSQL, the gate had **35 failures SQLite had passed**: fixed-id seeding that never advanced the id sequences (account_pkey collisions); foreign keys SQLite does not enforce (office ids 1/4/7 naming no office, accounts and bonus rules deleted before the rows naming them); a receipt voucher whose id only coincided with its payment's on SQLite; a pg_dump older than the server; the scheduled-backup test driving the SQLite branch production never takes — and **one real code fault**: `account_number_generator` cast `account_number` to BIGINT in SQL beside text filters it trusted to run first, so an account number like '2100-T1' failed the query on PostgreSQL and no office, supplier or customer account could be created under that parent (production has none today; the numeric test now happens in Python — `tests/test_account_number_generator_text_numbers.py`, witnessed red). **Now:** the tests create a throwaway PostgreSQL database per run and drop it (no SQLite mode); ids sequences advanced after seeding; one shared `db_fence` (`tests/conftest.py`: the session built on one connection whose `get_bind()` honours it, `join_transaction_mode='create_savepoint'`), used by all 17 modules; `tests/test_db_fence.py` commits — directly and through a route — and finds nothing afterwards, and fails on any module keeping its own fence. Gate on PostgreSQL: 968 passed; the one failure is TEST-002's bonus test (since fixed). **CI:** the `backend-test` job (TEST-002) runs the gate on PostgreSQL. |
| TEST-002: 13 backend tests fail in a clean checkout — 12 of them pass only because `backend/.env` turns the development bypass on | 🟡 Medium | — | ✅ Closed in code (30 Sep 2026) — the CI job's first run is its witness | Measured on PostgreSQL with the bypass off: exactly 13 — `test_account_pair_lifecycle.py` (7) and `test_dual_distribution_parity.py` (5) called protected routes with no token, and `test_bonus_points_parity.py::test_race_and_bonus_read_same_config`. **Fixes:** `backend/conftest.py` forces `BYPASS_AUTH_FOR_DEVELOPMENT=0` before the app is imported, whatever `.env` says (`tests/test_the_suite_runs_with_the_bypass_off.py`, witnessed red); the 12 sign in as the seeded admin. **The bonus test was a stale expectation, not a bug:** it patched `models.Settings` and expected `Settings.query.first()`, but since `7ebc4f5` (3 Aug 2026) `get_race_points_config()` reads the canonical row through `core.settings._get_settings_singleton` — the one the settings API uses — so the patch reached nothing and it read the defaults; red for two months because CI ran no backend test. It now checks the behaviour on a real settings row. **CI:** `.gitlab-ci.yml` job `backend-test` runs the gate on PostgreSQL 16 (matching `pg_dump`), bypass off, on the backend image's Python; a red gate stops the build stage. Locally, run exactly that way: **971 passed, 0 failed** — the first fully green gate. **Its first run in GitLab failed** — it caught what no Mac could: `item_code` (String(20)) built from `id(...)` in two test modules, 10–11 digits on macOS and 15 on the Linux runner (17 errors; now a short uuid); and `auth_decorators._now()` in LOCAL time measuring durations — a test switching the zone to Asia/Riyadh on the UTC runner saw every session three hours idle, and the blacklist TTL (token exp is UTC) was three hours too long all along. The auth clock is UTC now (`tests/test_auth_clock_is_utc.py`, witnessed red); rows written in local time before read three hours ahead, so the idle check treats them as fresh until real time catches up — no forced logout. The job was then run locally in its own image (`python:3.11-slim` + `postgres:16`): 952 passed, 0 failed. Local tests still run Python 3.9 against production's 3.11 — the container run is the check that matches. |
| OBS-001: production cannot see which device sent a request | 🟡 Medium | — | 🟡 Open | Docker Desktop (WSL2) replaces the source address of published ports: all 539 access-log lines of `yasargold-nginx` on 28 Sep 2026 read `172.18.0.1`. `docker logs` also keeps only what followed the last container recreate — every deploy. No investigation by address is possible, including of the period SEC-006's routes were open while a router port forward existed. **Interim:** identity from authentication (SEC-006) and `audit_logs`. **Terminal fix:** the planned Linux host, or `tailscale serve`, which adds the tailnet identity to each request; access logs kept outside the container. |
| SEC-008: 83 ERP read routes declare no permission — at least 16 expose data beyond any one role | 🟡 Medium | ADR-031, ADR-036 | 🟡 Paid in code (R3, 2 Oct 2026), **not yet deployed** | Since SEC-006 a reader must be signed in, but any signed-in employee can read, among others: account statements and balances (`/accounts/<id>/statement`, `…/statement_merged`, `/accounts/balances`), supplier ledger and statement, customer statement, employee payroll and attendance, the permission catalogue and a user's permissions, and `GET /debug/db-info`. Some of the 83 are fine for anyone signed in (prices, lookups). Which role may read what is a business decision. **Terminal fix:** a permission per sensitive read, decided with the owner; then the SEC-007 ratchet extended to reads. **Trigger:** with SEC-007. **R3 (2 Oct 2026, ADR-036):** 83 GET routes declared no permission -- the July route move took them off the blueprint that inferred one. 61 now ask for the matrix code (statements and balances `reports.financial`, ledgers `reports.purchases`, the cost `costing.view` (new), the vouchers, payroll, bonuses, permissions, diagnostics...); 23 stay open by nature, each with its reason (the point of sale, the caller's own, the gold price, the settings). The owner's recommendations: a seller lists their own invoices (`invoices.view_others`, new); reads any invoice for a return but never its cost or profit (`services/read_scope.without_cost`, also on the creation response -- the server still holds a sale under cost); the scrap purchase screen gets a suggested price (`/gold-costing/suggested-purchase-price`), not the cost snapshot; a seller reads their own invoice's vouchers and the employees' names only; the approvals bell counts for approvers. `/routes` (outside `/api`, unauthenticated) now needs `system.settings`. **Witness:** `tests/test_read_routes_declare_permission.py` (the read ratchet), `tests/test_read_scope.py` (11 of 14 red on HEAD). **Closed after (2 Oct 2026):** the item list carries no cost (measured); the safe-box list carries no balance for a seller, and the balance, movements, reconciliation and stones reads ask for `safe_boxes.transfer` or `reports.financial`, the shift closing summaries for who closes it. **Test leak, recorded:** run before `test_supplier_settlement_adjustment.py`, the API file's commits make six of its tests fail (as on HEAD) -- the gate's order hides it (TEST-001). |
| SEC-009: routes ask for 33 permission codes no catalog holds, and the app read only the overrides | 🟡 Medium | ADR-036 | 🟡 Fixed in code, **not yet deployed** (R1) | Measured 2 Oct 2026: 33 codes asked by route decorators were in no catalog (`voucher.approve`, `invoice.post`, `invoice.edit`, `invoice.unpost`, `journal.unpost`, `gold_advances.view/allocate`, `audit.view`, `admin`, `manager`, `role.*`, `user.*`, `bonus.*`, `bonus_rule.*`, ...), so no role held them and only the system admin passed -- the manager could not approve a voucher, post, edit or unpost an invoice, or attribute a voucher: closed by accident, not by decision. And `AppUser.to_dict` sent the overrides alone, so the app hid from a role what the server allowed it. **Fix (ADR-036 R1):** the catalog gained the missing codes and the storekeeper role; every phantom code maps to a catalog one; the role templates are the owner's matrix; the server sends `effective_permissions` (role grants, overrides on top) and the app reads it; a seller edits, rejects or deletes only their own invoices (`services/record_ownership.py`). **Witness:** `tests/test_permission_catalog.py` (6, red before), `frontend/test/effective_permissions_test.dart`. |
| PERF-001: `GET /api/journal-entries/posted` takes 40–46 s on production data | 🟡 Medium | — | 🟡 Open | Measured in four rehearsals on the 28 Sep copy (`docs/runbooks/release-rehearsal.md`); the next slowest route, `/api/invoices/returnable`, takes ~5 s. The screen that lists posted entries waits that long. **Terminal fix:** paginate, and fix the query plan. **Trigger:** when the posting screen is next touched, or on the first complaint. **Witness:** every rehearsal report lists the slowest routes. |
| POST-001: invoice posting skipped the karat-difference and 24k-settlement entries from 13 Jul to 29 Sep 2026 | 🔴 High | — | 🟡 Fixed and deployed (`2d0b1e37`, 29 Sep 2026) — one invoice to repair | `posting_routes.post_invoice` builds these entries through helpers imported lazily from `routes`; the July routes migration (`0232533`) moved them into `routes/invoices.py`, and every posting since caught the `ImportError`, printed one line and posted the invoice **without** the entry. The helpers (added 18–19 Jun) had not run for a real invoice before July, so none ever has. **Exposure, measured on the 28 Sep copy:** one invoice — 3020, purchase #178, supplier 7, posted 15 Sep — whose karat-difference commission of **307.37** was never recorded (Dr supplier / Cr commission revenue 4110); no 24k-settlement invoice exists. **Fix:** the imports point at `routes.invoices`. **Proof:** `tests/test_invoice_posting_commission_entries.py` posts through the real route and checks amount, accounts and sides for earn, pay and 24k — witnessed red (`[] == [...]`) before the fix; `tests/test_local_imports_resolve.py` fails on any import whose name no longer exists, the class that hid this and BACKUP-001. **Remaining:** invoice 3020's entry is data repair — stage 4 of `docs/plans/recovery-roadmap-2026-09.md`, the owner's accounting decision. |
| APPROVE-001: «اعتماد وترحيل» posts an approval-gated invoice but leaves its own journal entry unposted | 🔴 High | — | 🟡 Fixed in code, **not yet deployed** — the broken button was not reachable in the app (see below) | Two buttons approve an invoice saved behind an approval gate (`below_cost`, `large_discount`, `above_live_price`). «✓ ترحيل» in «المعلّقات بانتظار الإجراء» calls `POST /api/invoices/post/<id>` (`posting_routes.post_invoice`): it posts the invoice's entries, then creates the deferred payment entry and safe-box rows — complete. «اعتماد وترحيل» in the alerts dialog and in «تفاصيل اعتماد الفاتورة» calls `POST /api/invoices/approve/<id>` → `approve_large_discount_invoice`: it marks the invoice posted and creates the payment entry and safe-box rows, but **never posts the invoice's own entry** (sale, VAT, weight). **Rehearsed on the 29 Sep copy with invoice 3158:** afterwards the cash customer is credited 4,150 with no sale against it, revenue, VAT and the gold weight stay out of the posted books, while the safe-box rows say the cash and gold moved. **History consistent with it:** 184 invoices dated 1 Jan – 13 Apr 2026 (22 with approval alerts) had their entries posted in one batch by `admin` on 13 Jun 16:50; none is left unposted today. The posting-management switch `require_approval_before_post` (on in production) is stored and never read. **Witness today:** the books check's `UNPOSTED_ENTRY_IN_LIMBO` (ADR-030) reports any new occurrence. **Terminal fix:** one approval operation — the alias runs `post_invoice`'s path — proven through the real route (invoice entry posted, payment entry, safe-box rows, cash customer nets to zero); the dead switch wired or removed. **Fix (29 Sep 2026):** one posting, `posting_routes.post_invoice_document()`, called by all four routes that post an unposted invoice — «✓ ترحيل», «اعتماد وترحيل», the batch («إدارة الترحيل») and the API approve in `routes/invoices.py`. They had diverged four ways: the bell's never posted the invoice's own entry; the API approve never created the payment entry (the cash never reached the safe box); «✓ ترحيل» never closed the approval alert (35 alerts of posted invoices were still open on the 28 Sep copy); the batch skipped the karat-difference and 24k-settlement entries (POST-001 alive there alone). It also writes the category-weight movements and inventory ledger an approval-gated invoice never got (written at creation only for one posted at once) and recomputes the cached balances its entries touch. **Proof:** `tests/test_invoice_approval_is_one_posting.py` replays 3158's state through each route and requires the same complete result (witnessed red, each for its own reason), plus a ratchet that no route restates the posting; on the 29 Sep copy «اعتماد وترحيل» on 3158 now posts the sale, puts 4,150 in the cash box, nets the cash customer and closes its alert. **Correction (30 Sep 2026):** the alerts dialog and «تفاصيل اعتماد الفاتورة» — the only places «اعتماد وترحيل» appeared — were removed from the app on 2 Jun 2026 (`448e475`, «remove alerts/notifications system completely»); the files stayed, unused. So since June the bell's path was reachable only through the API, and the owner's approvals went through «✓ ترحيل». The unified posting still matters: it fixed the batch (karat-difference and 24k entries), the API approve (no payment entry) and «✓ ترحيل» (approval alert left open). |
| EDIT-001: editing an unposted invoice gives it a new number and date, and a failed edit says the original is gone | 🔴 High | — | 🟡 Deployed (`50fbc3bd`, 30 Sep 2026) — hung on production, see EDIT-002; the safe-box follow-up **not yet deployed** | `PUT /api/invoices/<id>` (`update_unposted_invoice`) deletes the invoice and re-creates it through `add_invoice`. It passes the original `invoice_type_id` "to preserve the display number" (docstring and Flutter comment, since `2d897d5`, 2 Mar 2026), but `add_invoice` always allocates the next number: **rehearsed on the 29 Sep copy, sale #1540 came back as #1543**, leaving a hole in the sale sequence and a printed receipt that matches nothing. The sale screen sends `date = now` in edit mode, so the sale also moves to the moment of the edit — across a month end, into another period. On failure the route answers «فشل إعادة إنشاء الفاتورة بعد الحذف. يرجى إنشاء فاتورة جديدة.», yet the whole transaction rolls back and the original survives unchanged (rehearsed twice — an early 404 and a late database error — byte-identical before and after): a user who obeys the message sells the same thing twice. Editing a scrap sale also opens the regular sale screen, which turns it into a regular sale. **Terminal fix:** an edit corrects a document without changing its identity — number and date kept (the date rule is the owner's decision) — with the failure message stating that nothing changed; tests through the route. **Fix (30 Sep 2026), the owner's rule — an edit corrects the invoice, it stays the same invoice:** `add_invoice(preserve_invoice_type_id=)` keeps the number; the original date always wins over the one the app sends; the scrap-custody holder stays who took the gold in (the screen sent the signed-in user's employee, which would have moved the custody to whoever edited); a failed edit answers `edit_failed` «تعذّر حفظ التعديل، والفاتورة الأصلية لم تتغيّر ... لا تُنشئ فاتورة جديدة». **And «شراء من عميل» can be edited from the app** (the list said «التعديل غير متاح لهذا النوع»): the scrap-purchase screen has an edit mode. `tests/test_invoice_edit_keeps_identity.py` (3, witnessed red). On the 30 Sep copy, invoice 3170 (0.5 g of 18k bought at 700/g, held above the live price) edited as the app does, by the admin, with today's date: number 768, 29 Sep 19:35, employee and custody 19 all kept; posted at once (the new price under the live one). Editing a scrap SALE still opens the regular sale screen and turns it into a regular sale. **Follow-up (30 Sep 2026):** edited by the owner — an account with no employee — the screen sent the main scrap safe (31) and the header moved there while the gold went to the holder's custody (46): an edit of «شراء من عميل» now keeps the original `safe_box_id`, as it keeps the holder. The screen warned «حساب غير مرتبط بموظف … سيتم إسناد الذهب للخزينة الرئيسية للكسر» on that edit, which was untrue: the invoice now carries `scrap_holder_gold_safe_box_id`, and the warning is not shown on an edit whose holder has a custody safe (the owner's rule). `tests/test_invoice_edit_keeps_identity.py` (+2) and `frontend/test/scrap_purchase_unlinked_warning_test.dart` (4), witnessed red. Replayed on the 11:49 copy under gunicorn: 3170 edited, header 46, 0.5 g of 18k into 46. |
| HANG-001: editing invoice 3170 hangs on production, and a killed request left no trace | 🔴 High | — | 🟢 Trace deployed (`b8be4772`, 30 Sep 2026); its first capture found the cause — EDIT-002 | 30 Sep 2026, after `50fbc3bd`: the admin edited «شراء من عميل» 3170 twice from the app; both `PUT /api/invoices/3170` hung until gunicorn killed the worker at its 120 s timeout (nginx 499 for the client). The second hung ~60 s more after the first was killed, so it was not only waiting on the first. The transaction rolled back: 3170 stands untouched (350, unposted, paid). The same edit on the restored copy, same code, network open, saves in 0.4 s. The log held «WORKER TIMEOUT» then «was sent SIGKILL» — nothing else. Gunicorn sends SIGABRT first, and its handler is Python, which never runs while the worker is blocked inside C; that the SIGKILL was needed says the request was stuck in a C call — most likely libpq waiting on a PostgreSQL lock. (The «السعر المحفوظ قديم» lines around it were the app's price reads in the other worker: the invoice path reads the price from the database only.) **Trace (30 Sep 2026):** `backend/gunicorn.conf.py`, run by the Dockerfile with `-c` (same 2 workers, :8001, 120 s), enables `faulthandler` in each worker after gunicorn's own signal handlers: a worker killed for hanging first writes every thread's stack — file and line — to the log. `tests/test_hung_request_names_its_line.py` (witnessed red: exactly production's two lines; green: the stack names the function waiting on a lock another connection holds). **Terminal fix:** found from the first trace production writes. **Found (30 Sep 2026, 12:05):** the owner's third edit of 3170 hung, and the trace named `routes/invoices.py:1196 → 4295`, an INSERT flush in `add_invoice` — see EDIT-002. |
| EDIT-002: the invoice edit loaded a second copy of the app and ran in two transactions | 🔴 High | — | 🟡 Fixed in code, **not yet deployed** | gunicorn loads `backend.wsgi:app`, so the running module is `backend.app`. Since the routes migration (`0232533`, 13 Jul 2026) `update_unposted_invoice` said `from app import app`: under that name app.py ran a **second** time (a second Flask app, own engine, own sessions — the unexplained «Startup bootstrap» line in the log) and `add_invoice` ran inside it. The old invoice was deleted on one connection, the new one written and committed on another: **the edit was two transactions, not one**. Until EDIT-001 the new invoice took a new number, so nothing collided and edits "worked" — but a failed commit of the delete after the new invoice committed would leave both. EDIT-001 kept the number: the new INSERT waited on the uncommitted DELETE of the same `(invoice_type, invoice_type_id)` (`_invoice_type_uc`), and the request waited on itself until gunicorn killed it — invoice 3170, three times, rolled back each time. Tests and copy replays loaded the app as `app`, where the second load cannot happen; reproduced on the 30 Sep 11:49 copy under gunicorn as production runs it (`pg_stat_activity`: `DELETE FROM invoice WHERE id = 3170` idle in transaction, the INSERT waiting on `transactionid`; same stack). The wipe routes in `routes/system.py` did the same, under a comment saying they must not. **Fix:** the edit runs `add_invoice` in the running app (`current_app`); the wipe calls the running module (`sys.modules[current_app.import_name]`). `tests/test_the_app_is_loaded_once.py` loads the app as gunicorn does (witnessed red: `add_invoice` in a second app; `routes/invoices.py` 1179, 9207 and `routes/system.py` 1221, 1228) and fails for any module the running app loads that imports `app` by its bare name. Replayed on the copy under gunicorn: 3170 edited in 0.44 s, number 768, 29 Sep, holder 19, one invoice. **Stage-4 inventory:** edits made 13 Jul – 30 Sep ran in two transactions — look for an edited invoice whose original was not deleted. |
| EDIT-003: the invoice edit keeps its own cleanup list and asks nothing about evidence | 🟡 Medium | — | ✅ Fixed (UNPOST-001 U2), deployed `f7980c20` | `PUT /api/invoices/<id>` deletes the invoice and re-creates it through `add_invoice` — the same creation path, so entries, safe-box movements, approval gates and posting behave as on creation (the number, date, employee, scrap holder and scrap-purchase safe box are kept; the live-price gate and the permissions are those of the moment of the edit). Its cleanup, though, is a hand-written list, not `services/invoice_retraction_guard.REFERENCES` — the registry delete relies on, whose test fails on an unclassified reference; the guard's own docstring names such a list as the cause of the 3123/3132 incidents. And it asks nothing about EVIDENCE — rows another document wrote about the invoice. Verified 30 Sep 2026 with a return: `Invoice.returns` is a plain backref, so deleting the original makes SQLAlchemy null the return's `original_invoice_id` instead of refusing — the edit would succeed and the return would no longer name its original; delete refuses the same invoice with `has_financial_history`. (What the invoice OWNS is cleared: its gold obligations go by ORM cascade — a first reading of the list said otherwise; checked.) **Exposure:** the 30 Sep copy has 2 unposted invoices, neither with evidence rows — latent. **Terminal fix:** the edit derives what it clears from REFERENCES and refuses on evidence as delete does — except the invoice's own payments, which an edit corrects (3170 was edited paid) and `financial_history_of` counts, so the rule needs that distinction. **Witness:** `tests/test_invoice_edit_uses_the_reference_registry.py` (xfail strict). **Fix (1 Oct 2026):** the edit asks `financial_history_of` before deleting anything, setting aside only the invoice's own draft payments, and refuses with `has_financial_history`; the witness is a law. The hand-written cleanup list stays for what the invoice owns. |
| EDIT-004: editing a scrap sale made it a sale of new gold | 🔴 High | — | 🟡 Fixed in code, **not yet deployed** — the data (one sale) waits for stage 4 | A scrap sale is saved as «بيع» with `gold_type` 'scrap' (its gold leaves the main scrap safe). The invoices list chose the edit screen by `invoice_type` alone, so a scrap sale opened in the ordinary sale screen, which sends no `gold_type`; `update_unposted_invoice` passed the payload to `add_invoice`, whose default is 'new'. **Exposure** (2 Oct copy): sale #1540 (3158, 29 Sep 2026) came back as 3162 (#1543, before EDIT-001 kept the number) -- its 8 g of 22k left the display safe (30) and the display inventory (71300, entry #7480) instead of the scrap safe (31); the owner saw it when the scrap safe's 22k did not move. The roadmap had recorded 3158 as edited into an ordinary sale on purpose; the owner corrected it: it was a scrap sale. **Fix:** an edit keeps what kind of invoice it is -- type and gold: sent nothing, the original's stands; sent another, 409 `edit_changes_invoice_kind` before anything is deleted (`routes/invoices.py`); the list opens a scrap sale in the scrap sale screen, which gained an edit mode (`isScrapSale`, `ScrapSalesInvoiceScreen.editInvoiceId`). **Witness:** `tests/test_scrap_sale_edit_stays_scrap.py` (red 3 of 4 before), `frontend/test/scrap_sale_edit_screen_test.dart`. **Data:** 3162 back to a scrap sale (8 g of 22k from display to scrap) -- stage 4 (the owner). |
| LINK-001: «this voucher pays this invoice» had two writers and older rows with no link | 🟡 Medium | ADR-034 | 🟡 Writer fixed in code, **not yet deployed** -- the data waits for stage 4 | Measured on the 2 Oct copy. Two meanings: an invoice's own payment at creation (a payment row and a voucher naming the invoice -- linked by `source_voucher_id` only since the payment-voucher change; 2,481 older vouchers are linked by the invoice alone, or the notes' `invoice_payment_id`), and a later voucher paying the invoice (133 payment rows pointing to their voucher, 2 gold attributions). On posted invoices: 2,055 agree; **178 have payments and no voucher** -- 120 sales of March-April (history), and 55 scrap purchases from March to October that were held for approval and posted later: `_create_deferred_payment_entries` wrote the entry lines and the safe rows and no voucher, while posting at creation writes one (two writers; 4 since August, the last 3202 on 1 Oct; the books are the same, the document is missing); **19 have a voucher and no payment row**, and with them 39 supplier purchases named by a payment voucher with no linked payment row (manual vouchers to 14 Sep 2026). **Corrected (3 Oct):** 22 of the 39 invoices hold a payment row of the voucher's own amount, unlinked -- the cash IS counted, only the link is missing (attributing again would count it twice); 17 are gold bought for cash with no wages and no payment row. What stays unpaid (#17 30,414.83 wages, #18 500, #81 1, #141 99.12) is real debt, not a lost voucher. **Fix:** one builder of an invoice payment's voucher (`accounting/invoice_payment_voucher.py`) for both postings: the later posting writes each cash payment's voucher, approved with the entry carrying the payment, once. **Witness:** `tests/test_late_posting_writes_the_payment_voucher.py` (2, red before). **Data (stage 4):** the 55 scrap purchases' and the 120 sales' missing vouchers (or kept, the owner's call); linking the 22 vouchers to their payment rows; the payment state of the 17 cash-bought purchases (the owner). |
| BALANCE-001: one balance, three sources, and readers of all three | 🟡 Medium | — | 🟡 B1-B3 in code, **not yet deployed** (2 Oct 2026) -- the columns' drop waits for the owner | The posted ledger is the official balance (the safes screen, the reports, the supplier statements read it). But 18 functions read the cached columns (`Account.balance_*`, `Customer.balance_*`, written by `update_balance()` in nine places, not by posting) and 11 read the safe-box ledger's sums for a decision. **Exposure** (2 Oct copy): the customers screen shows the cached customer balance -- 7 of 22 differ, «عميل نقدي» #8 −2,790,158.17 against the ledger's 70,261.82; at least 24 accounts' cached cash differs from the ledger (clearing accounts most: مدى −270,577 against 2,200); the gold safe transfer and the melting renewal decide sufficiency from the safe-box ledger while the screen shows the ledger's balance (8 open gold drift findings), the cash transfer from the ledger. **Map:** `docs/plans/balance-001-b0-readers-map.md`. **Terminal fix:** every balance a user sees or a decision uses is read from the ledger by one reader; the safe-box ledger for the statement and shift closing only; the cached columns read by no one (a ratchet), then dropped. **B1 (the owner's rule, 2 Oct 2026):** a customer's balance is every posted line on its own financial account, tagged or not, plus those tagged to it on shared customer accounts (12…) -- the suppliers' own rule; cash only (the weight memo twin 712… holds the dual system's weights -- 19,173.5 g of 21k on the cash customer's -- not gold a customer owes). One reader (`services/party_live_balances.compute_live_customer_balances`, `customer_line_clause`) for the customers list, the statement (which read the tagged lines alone: «عميل نقدي» 1,476,486.31, missing the untagged collections) and the dashboard's liquidity. **Witness:** `tests/test_customer_balance_is_the_ledger.py` (3, red before). On the copy every customer then reads 0 but #8 (89,581.82 -- the residue of a few invoices left open: returns, 2821, the year's first entries) and #16 (2,150 -- 3123, SETTINGS-001): stage 4, with the 21 duplicate «عميل نقدي» records. **B2:** the gold transfer, the karat correction and the melting renewal ask the ledger whether a gold safe holds enough (`services/live_balances.safe_gold_available`), as the cash transfer did -- they summed the safe-box rows; stones stay on the rows (no ledger weight). **Witness:** `tests/test_gold_sufficiency_is_the_ledger.py` (5, red before). Measured on the copy: the display safe's rows said 18k −2,229.26 and 21k −1,551.49 where the ledger (and the screen) says 11,674.47 and 6,934.04 -- a transfer from it was always refused; 24k rows 2,434.84 where the ledger says −176.00 -- accepted, now refused. The ledger's −176 g of 24k in the display safe: stage 4. **And (2 Oct 2026, on production):** 5.7 g of 21k from the display safe was refused `insufficient_balance_24k` -- the transfer's check ran over all four karats, requested or not, so any karat below zero blocked every transfer (before B2 the rows' −2,229 of 18k did; after it the ledger's −176 of 24k). Only a karat that moves is checked now (`test_a_karat_not_moved_does_not_block_the_transfer`, red before; the same transfer on a scratch copy of production: 201). **B3:** the last readers moved to the ledger -- the bridge account check after an invoice and its monitor, the sales-by-customer report, the bonus payment's office balance, the office balance's last fallback (no ledger: none, not the cache); `Account.to_dict`, `Customer.to_dict` and `Office.to_dict` no longer send the cached columns (the routes set the live balance), `SafeBox.to_dict(include_balance)` reads the ledger. **Ratchet:** `tests/test_cached_balances_are_not_read.py` freezes who reads them -- writers, the resets, tools and two dead helpers, each with its reason (witnessed red with a probe reader). **Still open (the owner):** dropping the columns by a migration once their writers go too. |
| BARTER-001: a barter sale and its scrap purchase are saved in two requests | 🟢 Low | — | ✅ Fixed in code (2 Oct 2026), **not yet deployed** -- `POST /api/invoices/barter-sale` writes both in one transaction or neither; the sale screen sends one request for a new barter sale (editing one keeps the old path) | The owner's rule (2 Oct 2026): a barter in a sale is a purchase and a sale, not gold for gold -- the customer's scrap is a «شراء من عميل» invoice linked to the sale (`barter_sale_invoice_id`), and the sale is settled by its cash value (`barter_total`). The sale screen does so (`sales_invoice_screen_v2.dart`): it saves the sale, then the purchase in a second request; if the second fails it says «تم حفظ فاتورة البيع، لكن فشل إنشاء فاتورة شراء الكسر» and the sale stands settled by a barter whose gold the books never received. **Exposure** (2 Oct copy): none -- 4 barter sales, all linked. **Terminal fix:** one request that writes both in one transaction (the server creates the purchase from the sale's barter lines), or refuses both. **Witness:** `tests/test_barter_sale_is_one_transaction.py` (red before: no such route) -- the purchase linked to the sale; a purchase that fails saves no sale. **And (the owner):** the purchase's value pays the sale as cash does, and is what settles the purchase -- a «شراء من عميل» linked to a barter sale carries its value as `barter_total`, so the payment state reads it «paid» (it read «unpaid» since the payment-state service: no barter since June, so none on the copy); only the cash part moves a safe and the customer's account nets to zero over the pair (the test, red before). |
| APPROVED-ENTRY-001: nine writers create an approved voucher whose entry is posted only if auto-post is on | 🟡 Medium | ADR-035 | 🟡 Fixed in code, **not yet deployed** (2 Oct 2026) | The rule since V1 (ADR-035, V0 addendum): an approved voucher's entry stands posted, held by `journal_entry_guard`; a voucher born approved is born with its entry posted (`post_entry_of_approved_voucher`). The bonus paths and the office-reservation deposit follow it. Nine others still build the entry with `create_journal_entry_from_voucher`, which posts only when `voucher_auto_post` or `auto_post_entries` is on, and mark the voucher approved: `routes/system.py` create_melting_renewal · `routes/clearing.py` (two) · `routes/safe_boxes.py` the safe transfer and correct_safe_box_karat · `routes/employees.py` mark_payroll_paid · `routes/invoices.py` correct_invoice_payment_method (two) and the gold-settlement voucher of add_invoice. **Exposure:** none while both settings stay on (production, 1 Oct 2026); turned off, each of these operations is refused by the guard (500) instead of leaving an approved voucher with a draft entry, as it did before V1 — found by the reservation tests, which ran with auto-post off. **Terminal fix:** each calls `post_entry_of_approved_voucher`. **Trigger:** before anyone turns auto-post off. **Fix (2 Oct 2026):** the nine call `post_entry_of_approved_voucher` -- the entry is posted with the voucher whatever the settings, and an entry that cannot be made fails the operation (the clearing and payment-method corrections used to carry on without one). **Witness:** `tests/test_approved_voucher_writers_post_their_entry.py` -- a frozen list of who may call `create_journal_entry_from_voucher` (the helper, the approval paths that post what they build, two repair tools; red with exactly these nine before), and the gold safe transfer with auto-post off (500 from the guard before). |
| WPROFIT-001: weight profit has two reports on two bases | 🟡 Medium | — | 🟡 Open — recorded as debt (the owner, 1 Oct 2026) | The owner's rule: the gram profit report and the weight income statement must rest on the same basis. They do not. `/reports/gram_profit` takes the trading margin from INVOICES — average sale price minus the average purchase price of customer and settlement (office) purchases, times the weight sold — plus weight accounts outside 741/751. `/reports/income-statement/gold` sums the weight accounts 74xx/75xx, where every gram bought from a customer is a weight gain (credit 7512). **Exposure** (30 Sep copy, Jan–Sep 2026): 2,077.47 g against 12,347.13 g. The office-reservation weight fix (SAFEBOX-001: credit the purchases' weight twin 7512, not scrap inventory 71310) moves only the income statement — about +5,811.83 g (21k) if the 27 reservation entries are corrected — and leaves the gram profit's average purchase price untouched (it reads invoices). **Terminal fix:** one definition of weight profit, one computation, both reports read it, with a parity law. **Witness:** none yet — the test world posts a customer scrap purchase's weight to the customer's weight account (712xxxxx), not 7512 as production does, so the two reports agree there by accident; the law is built with the fix, on a world configured as production. |
| SAFEBOX-001: the safe-box ledger has many writers, and one fact under more than one name | 🟡 Medium | — | 🟡 S0 measured · S1 (`7cbc67ce`), S2 (`13ca69dd`) and the nightly gold check (`1c357637`) deployed — the data waits for stage 4 | ADR-006 names `SafeBoxPostingService` as the future single writer of the safe-box ledger; no such service exists in the code. `SafeBoxTransaction` rows are created in 32 places across 9 production files (posting_routes.py 11, routes/invoices.py 6, models.py 4, accounting/safe_boxes.py 3, routes/system.py, routes/safe_boxes.py and accounting/voucher_engine.py 2 each, routes/vouchers.py and historical_clearing_adjustment_service.py 1 each — counted 30 Sep 2026, tests and tools excluded). One fact carries more than one name: a scrap purchase's gold received is `invoice_scrap_receipt` when the invoice posts as it saves (`add_invoice`) and `invoice_gold` when it is approved later (`posting_routes`) — seen on invoice 3170's two replays. `OWN_MOVEMENT_TYPES` lists seven names for what an invoice writes about itself, and `repair_safebox_transactions` / `purge_duplicate_gold_movement_sbts` exist to mend the ledger. **Exposure:** partly measured (1 Oct 2026, 30 Sep copy): of 756 posted scrap purchases, 701 carry `invoice_scrap_receipt` and 56 `invoice_gold` — and one carries both: invoice 992 (#81, 18 Apr 2026) brought its 59.6 g of 21k into safe 31 twice. Nothing saw it: the reconciliation screen and the nightly `SAFEBOX_SUBLEDGER_DRIFT` compare riyals only (`services/safebox_subledger.py`: `amount_cash` against `cash_debit/cash_credit`); the gold weight of a gold safe is compared by nothing. Whether any report reads one name and misses the other is still open. **Next:** discovery only — each writer → what it writes → which report reads it, measured on a restored copy; then the owner decides (one writer, or one name per fact). Precedes the safe-box statement repair of stage 4 (roadmap rule 4: no data repair before the writer is closed). **Witness:** none yet; the discovery produces it. **S0 (1 Oct 2026, `docs/plans/safebox-001-s0-ledger-writers-map.md`):** 27 live writers, 21 names; every balance the user sees reads the GL, the ledger is read by shift closing, stones, reconciliation and the cash guards. Gold by document (`backend/tools/diagnostics/safebox_gold_by_document.sql`) found two live writers wrong: a supplier purchase of new gold posted at creation wrote no row at all (−9,528.5 g on the display safe, 78 invoices since May — the earlier rows were one-off backfills), and a scrap purchase a closing-office reservation settled got, when posted later, a row into the display safe (+3,388.8 g, 17) though its gold is the reservation's (the owner: it stays at the office, on our account's safe there, until a voucher moves it). Invoice 992's double row is matched by a manual GL correction (#2818). **S1 (in code):** a supplier purchase's or return's gold rows are read from its posted entry, in both posting paths (`_gold_rows_from_posted_entry`; `post_invoice_document` now writes them after posting the entries); a reservation-settled invoice gets none. `tests/test_supplier_purchase_gold_follows_its_entry.py` (red 3 of 4 before). Measured on the copy without saving: 84 real purchases and returns — rows equal the entry in every safe; 12 reservation invoices — none. Data (78 + 17): stage 4. **S2 (in code):** every office reservation is a purchase (the owner): the weight entry moves from creation to settlement and credits the purchases account's weight twin (512 → 7512), not scrap inventory 71310 — which had left the scrap group near −4.8 kg; reversing a settlement reverses the weight and the office safe's rows; no weight twin, no settlement. `tests/test_office_reservation_is_a_purchase.py` (red 4 of 4 before); the phase 8E/9C reservation tests moved under the fence and into the gate. Data (27 entries, ≈5,811.83 g at 21k): stage 4; the weight income statement moves with it (WPROFIT-001). **Nightly gold check (in code):** `SAFEBOX_GOLD_DRIFT` — per gold safe and karat, the statement against the posted entries on its account, manual entries on neither side (as for cash); `services/safebox_subledger.gold_subledger_by_box`, tests in `tests/test_books_invariants.py` (red 5 before). On the 2 Oct copy it reports 8 safe×karat findings — the stage-4 inventory: the display safe (30) in all four karats, scrap 992 (31), a ledger adjustment with no entry (41), an opening balance (47), 65.4 g (48). Still open: one name per fact, the cash drift's breakdown.  **One writer for a sale's gold (the owner, 2 Oct 2026):** posting at creation wrote it as `invoice_sale_gold_movement`, to the configured sale safe only; posting later as `invoice_gold` by the plan's safe rule -- so unposting and posting a sale again did not bring the safes back (UNPOST-001's last xfail). Creation now writes the plan (`_append_safe_transactions_for_invoice_gold`), `invoice_gold`; older rows keep their names and every reader knows both. On the 2 Oct copy the sale safe is 30 and all 156 September sale rows were there -- same safe, new name. The U0 record changed only there (`tests/u0_retraction_effects.json`). |
| POSTGOLD-001: the posting that comes later moves a sale's gold times the line's quantity | 🔴 High | — | 🟢 Fixed and deployed (`5a006a4f`, 1 Oct 2026) — the data (five sales, 684.15 g) waits for stage 4 | A sale line's weight is the whole line's: `total_weight` is the sum of the lines' weights (336 of 404 posted sales with a quantity above one; the other 68, all 7 Mar – 5 Apr 2026, stored one piece). Posting at creation moves that weight (since 14 Apr 2026). Posting later — approval and re-post, `posting_routes._append_safe_transactions_for_invoice_gold` — moves `weight × quantity`. On the 30 Sep copy: sale 1057 (one line, 18.7 g × 3) took 56.1 g out of the display box; 2478 (66.9 g) took 518.8 g; 1641, 1779 and 2204 (the invoices of the 92,385.00 receipts, unposted and re-posted in May–July) kept their creation movement and gained a multiplied `invoice_gold` on top. Five sales stand **684.15 g** over, uncorrected. The creation writer did the same from 1 Jan to 13 Apr 2026 (59 sales, 2,257.90 g over) and 55 more (1 Jan – 4 Mar) differ otherwise (2,575.24 g); the June historical reconciliation corrected part — after it, 68 multi-quantity sales stand 6,243.25 g UNDER their weight, unexplained yet. None of it was seen: nothing compares a gold safe's weight (SAFEBOX-001). **Terminal fix:** one posting writer that moves what the lines record (SAFEBOX-001); the immediate fix — the later posting stops multiplying — is a small release of its own. **Fix (1 Oct 2026):** the later posting moves a line's recorded weight once; only a line with no weight of its own falls back to the item's (one piece) times the quantity. `tests/test_approval_moves_the_recorded_gold_once.py` (witnessed red: −56.1 moved for −18.7). Re-measured on the copy: 60 of 60 real sales now come back from post, unpost, post with their safes unchanged (47 before). **Data:** stage 4. |
| RETRACT-001: a pending invoice whose payment has no voucher can be neither rejected nor deleted | 🟡 Medium | — | ✅ Fixed (UNPOST-001 U2), deployed `f7980c20` | Rejecting refuses with `has_live_payments` («ألغِ السداد أولًا...»), deleting refuses with `has_financial_history` («ارفضها بدلًا من حذفها...») — and no operation cancels an `InvoicePayment` that has no source voucher. The refusals are right (incidents 3123/3132); the loop is the gap: such an invoice can only be edited or posted. Met on 29 Sep with invoice 3158 (rehearsed on the copy: both 409). **Terminal fix:** part of UNPOST-001's single retraction operation — one way to withdraw a payment that has no voucher, with its own law and test. **Fix (1 Oct 2026, the owner's decision):** such a payment on an unposted invoice is part of its draft (ADR-034) — no voucher, no safe-box row, no effect anywhere — and rejecting withdraws it, named in the audit row. One with a safe-box row is an event and still refuses. The old test that it «still counts» became the two tests of the new rule in `tests/test_invoice_retraction_guard.py`. |
| SCRAP-001: a scrap sale can take a karat the scrap safe does not hold | 🟡 Medium | — | ✅ Closed — policy (the owner, 2 Oct 2026): negative scrap stock is allowed | Invoice 3158 (sale #1540, 28 Sep 2026) sells 8 g of 22k from «خزينة ذهب الكسر الرئيسية», which holds 0 g of 22k in both the ledger and the safe-box rows; posting it would leave that safe at −8 g (rehearsed on the copy). Nothing on the scrap-sale path checks the safe's balance for the karat sold. **Terminal fix:** the scrap sale refuses a weight the safe does not hold — a law with a test — or the owner decides that negative scrap stock is allowed and says so here. **Decision (2 Oct 2026):** the owner allows a scrap sale to take the safe below zero for the karat sold; nothing refuses it, and nothing will. |
| CLEAR-001: three clearing settlement vouchers carry 9,050 SAR that no payment can be traced to | 🟡 Medium | — | 🔴 Open — data repair | Every run of `ClearingSettlementScheduler` starts with a repair phase (`AllocationRepairService.repair_safe_box`) that tries to write the missing SettlementLine rows of each settlement voucher; `AllocationService.validate` refuses a plan whose payments cannot absorb the voucher's amount (`settlement_line_coverage_mismatch`), so nothing is written and the scheduler prints ❌ and moves on — on every run. **On production at the 29 Sep 2026 deploy:** Tamara (SB#35) AV-2026-00098 — 2,105.00 of 3,000.00 untraceable — and AV-2026-00124 — 895.00 of 895.00; Mada (SB#32) AV-2026-00133 — 6,050.00 of 19,710.00 (the gap `allocation_service.py` names as the reason the check exists). **Not a regression:** the previous release `99e86008` refuses the same three with the same figures on the same day's copy. The refusal is correct — it is the evidence, not the fault. **Terminal fix:** stage 4 data repair — find which payments these amounts settled, or reverse the untraceable part — the owner's accounting decision; the ❌ lines stop when the data is right. |
| RESTART-001: no production service had a restart policy | 🔴 High | — | 🟡 Fixed in the compose file; applied to the running containers with `docker update` | Found 29 Sep 2026: `docker-compose.prod.gitlab.yml` set no `restart:` for `db`, `backend`, `scheduler` or `nginx`. The scheduler exits on purpose when a critical scheduler fails (fail-closed, S1/S2 in `run_schedulers.py`) — a design that assumes something restarts it; with no policy it stayed dead, and nothing noticed (the settlement alarm runs inside it). After the machine restarted, production stayed down until someone ran `docker compose up`. **Fix:** `restart: unless-stopped` on every service — a container that dies, or a machine that reboots, comes back; one stopped on purpose stays stopped. `tests/test_production_compose.py::test_every_service_comes_back_on_its_own` (witnessed red). Applied without downtime by `docker update --restart unless-stopped` on the four containers; the compose file carries it into every later recreate. **Depends on:** Docker Desktop starting at sign-in, and the machine signing in after a reboot. **Next:** the heartbeat (SCHED-004), so a scheduler that dies — or keeps restarting — is seen in the app's alert bell. |
| SETTINGS-001: saving the settings screen posts every unposted invoice and voucher entry — rejected and awaiting-approval ones included | 🔴 Critical | — | ✅ Fixed and deployed (`cf34ea91`, per the recovery roadmap; this row said «not deployed» until 6 Oct 2026) | `routes/system.py` `PUT /settings`: whenever `voucher_auto_post` or `auto_post_entries` is on (both are, in production), each save posts EVERY journal entry with `reference_type` in ('voucher', 'invoice') that is unposted, as `system`, with no look at its document. **What it did, measured on production snapshots:** on 28 Sep 2026 06:40:53 a settings save posted the entries of two REJECTED sales. Invoice 2821 (24 Aug, 5,700 SAR, a 21k bangle whose weight was typed as 5,700 g — the approval gate stopped it at a cost of 2,904,278 and it was rightly rejected) now has in the posted books: 5,700 SAR of sales, **5,700 g of 21k out of display inventory** (71300), and **102,600 SAR of manufacturing wages** (18 × 5,700). Invoice 3123 (rejected and re-entered as 3124) adds 2,150 of sales a second time. The year's net weight profit on the dashboard fell from 2,248 g to 2,029 g that morning; returning the two entries to unposted on a copy gives 2,260.6 g. The save of 29 Sep 10:08 (auto-backup on) posted nothing only because nothing was unposted then. The next save will post the entry of any invoice awaiting approval — the half state of APPROVE-001. `PUT /settings` also writes no audit row and declares no permission (SEC-007). **The books check did not see it:** it flags an unposted entry of a settled document (LIMBO) and a posted entry with no document (ORPHAN), not a posted entry whose document is rejected or unposted. **Fix (29 Sep 2026):** a settings save posts nothing — the block is gone (`tests/test_settings_save_posts_nothing.py`, witnessed red on the old route: rejected, awaiting-approval and pending-voucher entries all posted); the books check gains the mirror invariant `POSTED_ENTRY_OF_UNPOSTED_INVOICE` (`tests/test_books_invariants.py`), which on the 29 Sep copy reports exactly entries 6641 and 7391. The two entries stay as they are until the stage-4 inventory (the owner's decision); the nightly check now shows them every night. |
| PURCHASE-CASH-1: `add_invoice` measured a supplier purchase's cash payments against `total`, which carries the gold's value | 🟡 Medium | — | 🟡 Fixed in code, not yet deployed | For `invoice_type='شراء'` the supplier is owed the gold, and in cash only the wages (none when he takes them in gold) and the VAT — `Invoice.cash_obligation` (Phase 13). `add_invoice` compared `payments` with `total`: with partial payments **off**, paying exactly the cash owed was refused («مجموع المبالغ (551.25) لا يساوي إجمالي الفاتورة (4226.25)»); with them **on**, paying more than the cash owed went through so long as it stayed under a total swollen by the gold's value. **Fix:** the one formula is now `models.purchase_cash_obligation` (the property delegates to it; a closing-office purchase keeps its total); `add_invoice` holds a purchase's payments to it, and says «النقد المستحق للمورد». **Decision (the owner, 7 Oct 2026):** an invoice is paid up to its cash owed only; an advance or a rounding is a separate payment voucher. On the 6 Oct production copy 2 of 29 paid purchases went over (3066: 1,340.00 for 1,336.40; 3210: 1,400.00 for 699.30) — history, untouched. **Witness:** `backend/tests/test_purchase_cash_paid_against_its_obligation.py` (the strict xfail turned into the test; overpaying refused — both red before). |
| WAGE-MODE-1: a supplier purchase's wages are always capitalized, whatever `manufacturing_wage_mode` says — and the invoice records the setting, not what was posted | 🟡 Medium | ADR-039 | 🟡 Fixed in code, **not yet deployed** — the release corrects production's setting itself | `add_invoice` (`routes/invoices.py`, the `'شراء'` branch) reads `manufacturing_wage_mode` and resolves an expense account from it, then never uses either: the entry always debits `manufacturing_wage_inventory` (1320/1350). The purchase screen offered its own «مصروفات / رسملة» choice, kept per device and never sent anywhere the server reads. **Measured on the 6 Oct production copy:** the setting is `expense`; 158 purchases carry `manufacturing_wage_mode_snapshot='expense'` (wages 601,146.75); their entries put 541,514.97 on 1320 «مخزون أجور المصنعية» across 156 entries — capitalized. **Decided (the owner, 6 Oct 2026):** a purchase's wages follow the setting — capitalized into wage inventory or charged to expense, as the settings say. **Terminal fix:** the purchase posting debits the account the invoice's own frozen `manufacturing_wage_mode_snapshot` names (§13: frozen at creation, so a later post or approval does not read the live setting), the setting is shown and edited on the settings screen, and the purchase screen shows it read-only. **Transition, in the release:** `alembic 20261006_wage_mode_matches_books` sets the treatment to `inventory` when it says otherwise over posted purchases that capitalized wages (production: `expense`, 156 such lines → `inventory`, rehearsed); a database with none keeps its choice. History is made to say what was posted (the owner: all production purchases were capitalized): the same migration sets the snapshot of every purchase whose posted entry capitalized wages to `inventory` (156 on the 6 Oct copy); invoices 32 and 36 carry wages with no wage line and keep `expense` for the data repair. **Fix (ADR-039, 6 Oct 2026):** one reading in `accounting/wages.py`; the purchase debits 1320 under `inventory` and the wage expense under `expense`, from the invoice's frozen mode; a sale and a sale return touch 1320 only under `inventory`; a melting writes off damaged wage only under `inventory`; `PUT /settings` refuses any other value; `GET /settings/wage-treatment` gives the settings screen the account and its balance, and a change asks first, naming the entry that zeroes the balance. The purchase screen shows the treatment and no longer chooses it. **Witness:** `backend/tests/test_wage_treatment_follows_the_setting.py` (the purchase and the sale under `expense` red before the fix). **Rehearsed** on a copy of the 6 Oct snapshot: reading shows 1320 at −72,960.02; saving the setting posts nothing; under each treatment the purchase and the sale post as above. |
| WAGE-INV-1: the wage inventory (1320) is negative — more wages left it than ever entered | 🟢 Low | ADR-039 | ✅ Not a gap — intended (the owner, 7 Oct 2026) | **Measured on the 6 Oct production copy:** debits 644,376.77, credits 717,336.79, balance −72,960.02. **Why, per the owner:** sale invoices carry wages raised above what the purchases capitalized (a sale releases its line's wage rate × weight), so more leaves 1320 than entered; the negative balance is to be transferred to revenue by an entry — the same rule the settings screen states for a change of treatment (ADR-039: negative → revenue). Kept here so the figure is not mistaken for a defect. |
| RETURN-WAGE-1: a supplier return did not reverse its purchase — it moved the gold's cash value between 2100 and 1300 and left wages and VAT on 1320 / 1400 | 🟡 Medium | ADR-039 | 🟡 Fixed in code, not yet deployed · old returns: data repair | A purchase posts in cash only its wages (1320, or the wage expense under «expense») and their VAT and the gold VAT (1400) against the supplier; the gold by weight. The return debited the supplier for wages and VAT, debited 2100 («عكس جسر التقييم») with the gold's cash value, and credited 1300 with the whole total. **Measured on the 6 Oct production copy (5 returns: 876, 1432, 1508, 1732, 1769):** 1300 lost 128,111.41 in cash that never entered it (120,394.24 gold value + 7,717.17 wages and VAT); 2100 gained 120,394.24 never charged; 1320 kept 5,964.31 of returned wages and 1400 their 752.86 of VAT. **Fix (the owner, 7 Oct 2026: a return reverses its purchase exactly):** the supplier is debited for wages, their VAT and the gold VAT; the wage account of the original's frozen treatment and 1400 are credited; no cash for the gold's value; the weight lines as before. **Witness:** `backend/tests/test_supplier_return_reverses_purchase.py` (3 red before). **Rehearsed** on a copy of the 6 Oct snapshot: a return of purchase 3233 posts supplier Dr 115, 1320 Cr 100, 1400 Cr 15. **Left:** the five old returns' balances on 1300, 2100, 1320 and 1400 — a reviewed correcting entry in the recovery roadmap's data repair. |
| PURCHASE-VAT-1: a purchase's VAT is decided by a hidden switch kept on the device, and the invoice does not record the decision | 🟡 Medium | — | 🟡 Fixed in code, not yet deployed | Purchases with and without VAT are intentional (the owner, 6 Oct 2026). **Measured on the 6 Oct production copy:** 26 purchases with VAT (exactly 15 % of wages), 132 without, 32 without wages; individuals never charge VAT, companies usually do with exceptions (e.g. 5 with / 1 without). Today «فاتورة بدون ضريبة» sits behind the gear, says «this invoice only», but is saved per device (`invoice_ui_settings_v1.purchase.disable_vat`) and never reset: switched on for one individual, the next company's invoice also goes out without VAT, unseen. The invoice keeps only a zero tax, not the decision; on manual weight lines a sent zero VAT was read as absent (`0 == False` in Python) and the line was **silently taxed to policy** — a no-VAT manual purchase was saved with VAT. The gold-VAT switch is also kept per device. **Decision (the owner, 6 Oct 2026):** the supplier's existing «الرقم الضريبي» is the default — with a tax number an invoice starts with VAT, without one it starts without; the choice is on the invoice's face, changed for that invoice only, shown in the review, recorded on the invoice, and accepted by the server on manual lines. No supplier has a tax number today; the owner enters them for the VAT-registered companies. **Fix (6 Oct 2026):** `invoice.vat_applied` (nullable; alembic `20261006_invoice_vat_applied`, no backfill); `add_invoice` records a supplier purchase's or supplier return's decision, refuses a non-boolean (`invalid_vat_applied`) and a «no VAT» invoice that carries VAT (`vat_decision_mismatch`), expects zero VAT on its manual lines, and reads a sent 0 as a figure. The purchase screen decides on its face from the supplier's tax number, resets it per invoice and per supplier, shows it and any exception in the review, and no longer reads the device switch; the gold-VAT choice is per invoice too. **Witnesses:** `backend/tests/test_purchase_vat_decision.py` (red before), `frontend/test/purchase_invoice_screen_test.dart` VAT group (4 red on the previous screen). The same per-device switch exists in the sales and scrap-sales screens (separate task). |
| SALES-VAT-1: «no VAT on sales» rested on a switch kept on each device, while the company's setting said VAT is on | 🔴 High | — | 🟡 Fixed in code, not yet deployed | **Measured on the 6 Oct production copy:** from the evening of 1 May 2026 every sale carries no VAT — 204 sales in May with 4 taxed, none from June to October (≈ 5.98 M of sales) — across every employee at once; before, 15 % inside the price. **Intended** (the owner, 7 Oct 2026). But it was «فاتورة بدون ضريبة» behind the gear, saved per device (`invoice_ui_settings_v1.<ctx>.disable_vat`): a new device, cleared storage or a reset switch would have charged 15 % again, unseen; and the server took each sale line's VAT as sent, with no check. **Fix:** `Settings.sales_vat_enabled` (alembic `20261007_sales_vat_setting`, which sets it off where the 50 most recent taxable sales carry none — production: off, rehearsed); `add_invoice` refuses a sale carrying VAT when it is off (`sales_vat_disabled`; returns are not held to it — a return of a sale taxed before May reverses that VAT); the sales and scrap-sales screens read the setting and no longer offer or read the device switch; the settings screen sets it, apart from purchase VAT. **Witnesses:** `backend/tests/test_sales_vat_setting.py` (4 of 6 red before), `frontend/test/sales_vat_setting_test.dart` (the screens' source gate and the provider). |
| SALES-UX-1: the sales screen recorded what was not typed — an unread amount as the whole remainder, a second save, a duplicate or weightless piece, a karat of 25 | 🔴 High | — | 🟡 Fixed in code, not yet deployed | **Read in the code (7 Oct 2026):** the payment «المبلغ» had no number reading: «٥٠٠» or «1,000» did not parse and the **whole remainder** was recorded on that method (500 cash and the rest by card → all cash); nothing stopped a second save while the first was in flight; a scanned piece could be added twice, one without a recorded weight was sold at an invented 10 g, part of a name added the first match; the line edits ignored Arabic digits and took any karat; the manual line said «وزن القطعة الواحدة… سيُضرب في العدد» and nothing multiplies — **measured on the 6 Oct copy:** 489 manual lines with a count above 1 sell at the single lines' price per gram (2 stand out), so the count was used as the note it is (the owner: «العدد توضيحي فقط»); the save button stayed off while anything was due even with partial payments on. **Fix:** one reading of typed amounts (Arabic digits, «٫», a thousands comma), an unread one refused; one save at a time; a piece once, never without its weight; several matches ask which; line edits read digits and hold the karat to 18/21/22/24; the weight is «الوزن الكلي للسطر» and the count «للبيان فقط»; a sale on credit saves when the settings allow it (the owner); the cash customer is the server's one (CASH-CUST-1). **Witness:** `frontend/test/sales_invoice_screen_test.dart` (12 of 13 red on the old screen; the 13th is today's rule with partial payments off). |
| SALES-UX-2: a sale could be left owed on «عميل نقدي», and the screen said what stood in the way only as a message that passed | 🔴 High | — | 🟡 Fixed in code, not yet deployed | **Measured on the 6 Oct production copy:** 17 sales left part or all of their total unpaid, every one on «عميل نقدي» #8 — the walk-in customer, who is nobody (the residue BALANCE-001 found). **Law (the owner, 7 Oct 2026: a credit sale needs a real customer):** `add_invoice` refuses a sale with something owed to the walk-in customer or to none (`credit_needs_customer`); a sale paid in full, in cash or with barter, is not held to it. The names are `models.CASH_CUSTOMER_NAMES`, the one list POST /customers also uses. **Screen:** `utils/sales_readiness.dart` mirrors the server's refusals — branch, weight and karat of each line, a price, barter and payments no more than the total, what remains only with partial payments on and then only on a named customer; the footer says «جاهز للحفظ» or the first reason (and taps to it), Ctrl+S saves a ready sale, leaving with work asks first, the review lists each line, whom it is owed by, and flags a price under the metal's value at market (a sale under cost, said without the cost — ADR-036) or far above it. **Witnesses:** `backend/tests/test_credit_sale_needs_a_real_customer.py` (2 of 4 red before); `frontend/test/sales_readiness_test.dart`; `frontend/test/sales_invoice_screen_test.dart` stage 2 (9 red on the old screen). **Left:** a seller without costing.view learns of a below-cost hold by the market comparison only, not by the server's own cost test — an endpoint that answers «under cost?» without the cost needs ADR-036's owner. Historic: the 17 open sales stay. |
| SALES-UX-7: the scrap sale screen was a 5,359-line copy of the sales screen, so every fix reached one and not the other | 🟡 Medium | — | 🟡 Fixed in code, not yet deployed | **Measured on the 6 Oct production copy:** 25 scrap sales of 1,564 (1.6 %), all manual lines, all on «عميل نقدي», all paid in full. The copy still read an amount typed in Arabic digits as «the whole remainder», could be saved twice, had no readiness bar and showed every seller the cost column. What set it apart was small: `gold_type: 'scrap'`, the invoice's own `safe_box_id` (the settings' main scrap safe, else the default gold safe), no barter (barter takes scrap in), its title and color, its settings context, and an edit that keeps its kind (sale #1540 came back a sale of new gold). **Fix (the owner, 8 Oct 2026):** one screen — `SalesInvoiceScreenV2(scrap: true)` carries those differences and nothing else; `scrap_sales_invoice_screen.dart` is deleted and the four places that opened it open the sales screen in that mode. An edited scrap sale keeps its safe and each line's saved total. **Witness:** `frontend/test/sales_invoice_screen_test.dart` «a scrap sale is this screen, in its mode» (4 of 6 red before). **Left:** an edited ordinary sale still restores its lines by profit, which drifts if the gold price loads after it — as the scrap edit did before. |
| SALES-UX-9: the scrap purchase from a customer (776 invoices, 3.9 a day) had none of the sales screen's fixes, and took any name holding «نقد» for the walk-in customer | 🔴 High | — | 🟡 Fixed in code (stages 1, 2, 4, 5), entry row pending | **Measured on the 6 Oct production copy:** 776 scrap purchases, 610 of one line, almost all manual lines, 515 of the 516 since June on the walk-in customer, paid in cash (505) or by transfer (18), 3 left unpaid. The payment amount read «٥٠٠» as the whole remainder; a second press saved a second invoice; no readiness bar, no warning on leaving. **The walk-in customer was found by any name or code holding «نقد» / «كاش» / «cash»** — and the identity check (id number, its version, birth date) is skipped for the walk-in customer, so «مؤسسة النقد للمجوهرات» or any such name bought scrap with no identity on file. **Fix:** the walk-in customer is the server's names exactly (`CASH_CUSTOMER_NAMES`), the oldest; `utils/scrap_purchase_readiness.dart` says «جاهز للحفظ» or the first reason (branch, weight / standing weight / stones / amount of each line, karat, identity of a named customer, paid in full) in a footer always in view; one save at a time; Ctrl+S; leaving asks; one way to pay (the shared `PayBox`, Alt+1…9); one summary with a target amount; the review says «مراجعة فاتورة شراء كسر» and flags a price over the live price (held for the manager, above_live_price) or far under it; the table fits its screen (no net column: no VAT on a scrap purchase). **Witnesses:** `frontend/test/scrap_purchase_readiness_test.dart`, `frontend/test/scrap_purchase_invoice_screen_test.dart` (14 of 16 red before). **Left:** a fixed entry row (the screen still adds a line by dialog) and the scrap sale-return screen. |
| CASH-CUST-1: 21 «عميل نقدي» customers where there is to be one | 🟡 Medium | — | 🟡 Creation fixed (9 Mar 2026, now gated) · data repair pending | **Measured on the 6 Oct production copy:** #8 (2,271 invoices) and twenty more made 4–8 March (#10–#28, #61; 77 invoices between them), each with its own accounts — a sale without a customer created one whenever the screen's list did not hold it. Since 9 March `POST /customers` returns the existing cash customer (`routes/customers.py`); its witness `backend/test_cash_customer_dedupe.py` sat outside the gate and had broken unseen (404 since the routes moved) — replaced by `backend/tests/test_cash_customer_is_one.py` (red with the rule switched off). The sales screen now picks the server's row (the name exactly, the active first, the oldest) instead of the first name containing «نقد». **Left:** merging the twenty into #8 — their invoices and their accounts' lines — a reviewed data repair in the recovery roadmap. |

---

### 4.7 Notifications ✅ Sprint 6

Provider-agnostic customer notification dispatch, triggered by `OrderCreated` events from the Outbox.

| Component | Location |
|-----------|----------|
| Domain — channels, aggregate, gateway Protocol, service | `packages/domain/yasargold_domain/notifications/` |
| Repository + UoW Protocols | `packages/domain/yasargold_domain/notifications/repository.py` |
| SQLAlchemy ORM, store, UoW | `apps/commerce-api/infra/notification_{orm,store,uow}.py` |
| `LogNotificationGateway` (dev / staging stub) | `apps/commerce-api/infra/log_notification_gateway.py` |
| `NotificationWorker` | `apps/commerce-api/workers/notification_worker.py` |

**Dispatch contract:** `NotificationService.dispatch()` never raises — gateway failures are recorded as `FAILED` Notification facts (ADR-008). Idempotency: `find_by_order_id()` check before every dispatch.

**Worker cursor:** `outbox_events.notification_dispatched_at` — independent of `published_at` (OutboxWorker). Each worker drains its own view of the Outbox (ADR-007).

**`customer_phone` on `ReservationRecord`:** captured at reservation creation and loaded by the NotificationWorker. PII stays out of event payloads.

**ADR-014** governs this capability.

---

### 4.8 Shipping ✅ Sprint 7

Physical shipment lifecycle for Orders, from carrier registration through delivery.

| Component | Location |
|-----------|----------|
| Domain — `Shipment` aggregate, `CarrierConfig`, `ShippingGateway` Protocol, service, events | `packages/domain/yasargold_domain/shipping/` |
| Repository + UoW Protocols | `packages/domain/yasargold_domain/shipping/repository.py` |
| SQLAlchemy ORM (`shipments`, `carrier_configs`), store, UoW | `apps/commerce-api/infra/shipment_{orm,store,uow}.py` |
| `LogShippingGateway` (dev / staging stub) | `apps/commerce-api/infra/log_shipping_gateway.py` |
| Router — create, void, deliver, get | `apps/commerce-api/routers/shipments.py` |

**State machine:** `PENDING → CREATED → IN_TRANSIT → DELIVERED` (terminal) · `CREATED → VOIDED` (terminal within void_window) · `PENDING → FAILED` (terminal).

**claim-then-send (mandatory from day one):**
1. `claim()` saves `PENDING` — caller commits before any network call
2. `gateway.create_shipment(…, idempotency_key)` — carrier registers the label
3. `mark_created()` saves `CREATED` with `tracking_number` + emits `ShipmentCreated` — caller commits

If the process crashes between steps 2 and 3, the next retry finds the existing `PENDING` row, calls the carrier with the same `idempotency_key`, and receives the same `tracking_number`. No duplicate labels.

**`declared_value` — Frozen (§13):** set at `claim()` time from `locked_rate × weight` at the sale snapshot. Never recomputed from the current gold price.

**`void_window` — Live (§13):** read from `CarrierConfig` at the moment of the void decision, not cached on the `Shipment`. Each carrier (Aramex, SMSA) has its own value. `can_void(now, void_window)` is a pure function — both arguments are injected (ADR-015).

**Delivery as event-of-record (§13):** `ShipmentDelivered` is emitted by `mark_delivered()` and enters the Outbox. A downstream worker reads this event and calls `OrderService.deliver()` to transition `Order → DELIVERED`. The tracking display cache (Live) and the delivery event path are separate — the cache is never promoted to a business decision source.

**`carrier_id` frozen on `Shipment`:** the carrier used at registration time is stored. If a second carrier is onboarded, historical shipments retain their original carrier for void and audit.

**ADR-015** governs the Clock Protocol introduced by this capability.

### 4.9 ERP Sync ✅ Sprint 8

Bridges the Commerce Order record and the ERP Invoice record via the Outbox pattern. Closes ADR-012 dual source-of-truth and ADR-013 Sunset Clause (see ADR-016).

| Component | Location |
|-----------|----------|
| `ERPSyncWorker` — polls `outbox_events`, POSTs to ERP | `apps/commerce-api/workers/erp_sync_worker.py` |
| `RefundWorker` — polls `REFUND_PENDING` intents, calls `RefundGateway` | `apps/commerce-api/workers/refund_worker.py` |
| `ReconciliationWorker` — daily Commerce vs ERP audit | `apps/commerce-api/workers/reconciliation_worker.py` |
| `RefundGateway` Protocol + `LogRefundGateway` stub | `packages/domain/payment/refund_gateway.py` · `apps/commerce-api/infra/log_refund_gateway.py` |
| `RefundConfirmed` domain event | `packages/domain/payment/events.py` |
| `PaymentService.mark_refunded()` | `packages/domain/payment/service.py` |
| ERP internal API Blueprint | `backend/internal_routes.py` — `POST /api/internal/online-orders` + `GET /api/internal/order-reconcile/{id}` |
| `Invoice.commerce_order_id` (unique, nullable) | `backend/models.py` |
| `OutboxEventRow.erp_synced_at` cursor | `apps/commerce-api/infra/reservation_orm.py` |
| `PaymentIntentRow.refunded_at` | `apps/commerce-api/infra/payment_orm.py` |

**ERPSyncWorker cursor:** `erp_synced_at` on `outbox_events` — independent of `published_at` and `notification_dispatched_at`. Three workers, same table, three independent at-least-once cursors.

**ERP idempotency:** `Invoice.commerce_order_id` unique constraint. `POST /api/internal/online-orders` returns 200 `{"status": "already_processed"}` on duplicate calls.

**Refund loop:** `REFUND_PENDING → REFUNDED` via `RefundWorker`. Emits `RefundConfirmed` to Outbox for accounting journal reversal downstream. `LogRefundGateway` is the current stub — Gate A blocked until real Moyasar sandbox adapter merged.

**Gate A blockers remaining:** (1) `MoyasarRefundGateway` + staging E2E; (2) real SMS adapter; (3) real carrier adapter (SEC-002).
**Gate B blocker remaining:** POS Flutter UI consumes `GET /api/v1/items/{id}/availability`.

### Planned Capabilities

| Capability | Sprint | Central Event |
|------------|--------|---------------|
| Notifications | 6 ✅ | `OrderCreated` → `NotificationWorker` |
| Shipping | 7 ✅ | `ShipmentCreated`, `ShipmentDelivered` |
| ERP Sync | 8 ✅ | `OrderCreated` → ERP journal + `RefundWorker` + Reconciliation |

---

## 5. Architecture Laws

These laws are extracted from ADR-001 through ADR-019. They do not change without a new ADR.

### Law 1 — Domain Owns State (ADR-006)
Any business concept with a lifecycle — states, transitions, expiry — must live in `packages/domain`.  
It may not live in an HTTP schema, a database model, or a worker.

### Law 2 — Domain Events Are Typed (ADR-007)
Any event written to the Outbox must be a typed `DomainEvent` instance defined in `packages/domain`.  
Untyped dicts in the Outbox are forbidden.

### Law 3 — Services Return Facts, Not Counts (ADR-008)
A domain service method that processes a collection must return the affected entities (`list[Record]`), not a count (`int`).  
Callers decide what to measure.

### Law 4 — Providers Are Adapters (ADR-009)
The domain never imports a provider SDK, URL, or credential.  
Provider implementations live in `apps/*/infra/` and are injected via Protocol.

### Law 5 — Webhooks Are Translators (ADR-010)
The HTTP webhook handler translates an external payload into a `WebhookResult` value object,  
then calls a domain service. No business logic inside the handler.

### Law 6 — Orders Are Business Records (ADR-011)
`Order` is the canonical source of truth for a completed sale.  
ERP journals are derived from it — not the other way around.

### Law 7 — One UoW Per Operation
Every write operation opens exactly one `UnitOfWork`.  
Cross-capability operations that require atomicity use a composite UoW  
(e.g. `CheckoutUnitOfWork` owns both `reservation_repository` and `order_repository`  
inside a single database session).

### Law 8 — Outbox for Async; Orchestrator for Atomic
**Cross-capability communication has two valid patterns — not one:**

| Pattern | When to use | Example |
|---------|-------------|---------|
| **Outbox** (async) | When the consumer can succeed or fail independently | `OrderCreated` → Notifications |
| **Application Orchestrator** (sync, same request) | When atomicity across capabilities is required | Checkout: Payment + Reservation + Order in one flow |

A direct synchronous call between domain services is allowed **only** when:  
(a) it happens inside the HTTP request that owns the operation, and  
(b) both operations share a single commit boundary (same UoW or two sequential UoWs where phase-2 failure is recoverable).  

Calling a domain service from another domain service directly (without an HTTP layer or Worker in between) is forbidden.

### Law 9 — State Machines Live in Aggregates
`can_pay()`, `can_expire()`, `can_confirm()` live on the Aggregate class.  
HTTP handlers call the service; services call the aggregate.  
HTTP handlers never call aggregate methods directly.

### Law 10 — Single Source of Truth Per Capability
Each capability has exactly one service that owns writes to its aggregate.  
Two services may not both write to the same aggregate.

---

### 5.0 Enforcement Terminology

Two terms recur throughout the security laws and known-gaps tables. They are defined here once so that every row in every table means the same thing.

**CI Enforcement**
A guarantee that is verified at build / test time — before any code reaches production. Examples: `import-linter` blocking secret imports in domain packages, a route-scan test that fails CI if a route is missing from `ROUTE_SECURITY`, a structural unit test. CI enforcement catches structural violations at merge time. It does **not** affect individual HTTP requests at runtime.

**Runtime Enforcement**
A guarantee that is applied to every individual request (or operation) while the system is running. Examples: JWT middleware validating a `scope` claim on every request, `secrets.compare_digest` checking `X-Admin-Secret`, `RedactingFilter` rewriting log records before they reach any handler, `MoyasarGateway.parse_webhook()` verifying the HMAC signature before any domain object is constructed.

> **Reading the security table:** A law with ✅ under "CI-enforced" and ⏳ under "Runtime-enforced" provides structural guarantee only — the classification is correct and complete, but no per-request check enforces it yet. Both columns must be ✅ for the law to provide end-to-end protection.

**Principal Identifier (`customer_ref`)** — the string the domain uses to identify the owner of a resource. The domain is deliberately blind to its format: it may be a phone number today, a UUID tomorrow, or an OIDC `sub` claim after that. Migrating auth providers (OAuth, Keycloak, Auth0) is a change in the auth layer only — domain services, aggregates, and repositories are unchanged. The one hard constraint: `customer_ref` must be stable for the lifetime of a customer's records. See ADR-018.

---

### 5.1 Security Laws (ADR-017)

> **Security Law 0 — The Meta-Law:**  
> *Every security law has a test that proves it. Otherwise it is a recommendation.*

> **Two dimensions of enforcement** — every row below shows both:
> - **CI-enforced** — checked at merge time; CI fails if the law is violated structurally.
> - **Runtime-enforced** — checked per HTTP request; this is where the actual security boundary lives.
>
> A law that is CI-enforced but not yet runtime-enforced provides structural guarantee (you cannot forget to classify a route) but **not** per-request protection. These two dimensions must be read together — a "✅ CI" alone does not mean the endpoint is protected.

| Law | Statement | Proof test | CI-enforced | Runtime-enforced |
|-----|-----------|------------|-------------|-----------------|
| **Law 1** Deny-by-default scope | Every route must declare its scope in `security.ROUTE_SECURITY` before merging. Missing entry fails CI. | `test_route_security_scan.py` (Law 1) | ✅ Route classification verified at CI | ✅ v1.4 — JWT middleware (`auth.py`) validates `scope` per request |
| **Law 2** Secrets never in logs | Sensitive field values (`Authorization`, `X-Admin-Secret`, `token`, `api_key`, …) are redacted by `RedactingFilter` before reaching any handler. `packages/domain` cannot import secrets (import-linter). | `test_log_redaction.py` (msg + args + tracebacks) | ✅ import-linter blocks domain secret access | ✅ RedactingFilter live — install on every handler |
| **Law 3** Deny-by-default rate class | Every route must declare its `rate_class`. Missing entry fails CI. `RateLimitMiddleware` (fixed-window Redis) enforces it per request. XFF forge-resistant (`TRUSTED_PROXY_HOPS` env). Webhook counter independent of payment counter. | `test_route_security_scan.py` (Law 3) · `test_rate_limiting.py` (30 tests) | ✅ Rate class declared for every route | ✅ v1.4.5 — `RateLimitMiddleware` live; production requires `REDIS_URL` (fail-safe) |
| **Law 4** RBAC on capability | Permissions granted on capabilities, not routes. `scope=admin` vs `scope=customer` enforced at JWT level. admin ⊇ customer capabilities. | `test_admin_scope_enforcement.py` (13) · `test_law4_customer_scope.py` (16) | ✅ CI scan ensures all routes are classified; structural scan catches missing `Depends` | ✅ v1.4.6 — both directions proven; SEC-001 fully withdrawn |
| **Law 5** BOLA — ownership in domain | `service.find_X_for_customer(id, customer_ref)` returns `None` (→ 404) on ownership failure. Never 403. `customer_ref = None` always returns `None`. | `test_bola.py` · `test_payment_bola.py` | ✅ Pattern + domain methods proven | ✅ v1.4 — JWT `sub` injected as `customer_ref`; open surfaces documented below |
| **Law 6** Signature before translation | Webhook handler verifies provider signature before constructing any domain object. Forged payload → 400, domain never called. | `test_webhook_signature.py` | ✅ | ✅ Live — `MoyasarSignatureError` raised inside `gateway.parse_webhook()` |

**Open BOLA surfaces (deferred to Gate B):**
- `GET /api/v1/orders/{order_id}/shipments` — auth enforced (v1.4.6); ownership check (shipment.order.customer_ref == caller) deferred to Gate B.

**Confirmed closed:**
- `GET /api/v1/orders/{order_id}` — `find_order_for_customer()` in `OrderService` checks ownership at domain layer; router maps `None → 404`. Live since v1.4.

**SEC-001** ✅ **CLOSED (v1.4.6)** — `require_admin_secret` retired; JWT enforced on all non-public endpoints. Both withdrawal conditions met (admin-side: 13 tests; customer-side: 16 tests).

---

## 6. Event Flow

The complete platform event chain — including planned capabilities:

```
Customer browses Catalog
         │
         ▼
   Quote issued (in-memory value object — not persisted)
   Snapshot written to ReservationRecord on lock
         │
         ▼ POST /api/v1/reservations
   ReservationCreated ──────────────────────► Outbox
         │
         ▼ POST /api/v1/payments
   PaymentIntentCreated ────────────────────► Outbox
         │
         ▼ POST /api/v1/webhooks/payment
   PaymentReceived ─────────────────────────► Outbox
         │ [Phase 2: Application Orchestrator]
         ▼
   OrderCreated ───────────────────────────► Outbox
         │
         ├──────────────────────────────────► OrderCreated consumed  [Sprint 6 ✅]
         │                                   by NotificationWorker
         │                                   (cursor: notification_dispatched_at)
         │                                   SMS · Email · Push · WhatsApp
         │
         ├──────────────────────────────────► ShipmentCreated        [Sprint 7]
         │                                         │
         │                                         ▼
         │                                   ShipmentDelivered
         │
         └──────────────────────────────────► ERP Journal Posted     [Sprint 8]
                                                   │
                                                   ▼
                                              GL Entry · (+ INV-4 guard)

   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
   Business failure path (INV-4 race or late webhook):
   PaymentService.confirm() → PAID
   CheckoutService raises ItemNoLongerAvailableError
   HTTP layer → intent.mark_refund_pending() → REFUND_PENDING
   RefundWorker → gateway.refund() → intent.mark_refunded() → REFUNDED
   Customer receives: automatic refund + apology [Sprint 6 notification]
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
```

**Rule:** Every arrow that crosses a capability boundary asynchronously goes through the Outbox.  
Synchronous cross-capability calls (Orchestrator pattern) are confined to a single HTTP request.

---

## 7. Dependency Rules

### `packages/domain` — Zero external dependencies

| Dependency | Allowed |
|------------|---------|
| Flask | ❌ |
| FastAPI | ❌ |
| SQLAlchemy | ❌ |
| Requests / HTTPX | ❌ |
| Any payment SDK | ❌ |
| Any SMS SDK | ❌ |
| `datetime`, `decimal`, `uuid` (stdlib) | ✅ |
| `packages/platform` | ✅ |

### `apps/commerce-api/routers/` — HTTP layer constraints

| Rule |
|------|
| May call domain services and infra via `Depends` |
| May NOT contain business logic (conditions, calculations, state decisions) |
| May NOT call `aggregate.can_*()` directly |
| May NOT access the database directly — only through UoW injected via `Depends` |
| May act as Application Orchestrator (Law 8) for atomic multi-capability flows |

---

## 8. ADR Index

| ADR | Title | Core decision |
|-----|-------|---------------|
| ADR-004 | uv Workspaces | `uv` for monorepo dependency management |
| ADR-005 | FastAPI for Commerce API | FastAPI: Pydantic at public boundaries + framework boundary prevents ERP blueprint leakage |
| ADR-006 | Domain Owns Business State | Lifecycle concepts (`QuoteStatus`, `PaymentStatus`, …) live in `packages/domain` only |
| ADR-007 | Domain Events Are First-Class | All Outbox events are typed `DomainEvent` instances |
| ADR-008 | Services Return Facts Not Counts | Batch mutations return `list[Record]`, not `int` |
| ADR-009 | External Providers Are Adapters | Domain defines Protocol; infra implements it |
| ADR-010 | Webhooks Are Translators | Handler → `WebhookResult` → domain service — no logic in handler |
| ADR-011 | Orders Are Business Records | `Order` is canonical; ERP journals are derived |
| ADR-012 | ERP Is a Downstream Consumer | ERP transitions from source-of-truth to event consumer (strangler fig) |
| ADR-013 | Inventory — Strangler Fig (Option B) | POS remains authoritative during transition; 3 mandatory conditions + Sunset Clause at Sprint 8 |
| ADR-014 | Notifications — Provider-Agnostic Domain | `NotificationGateway` Protocol injected; `dispatch()` never raises; worker cursor independent of OutboxWorker |
| ADR-015 | Clock Protocol — Inject `now` | All time-dependent domain methods receive `now: datetime` as a parameter; no `datetime.now()` inside domain logic |
| ADR-016 | ERP Sync + ADR-013 Sunset Closed | `ERPSyncWorker` + `RefundWorker` + `ReconciliationWorker` + ERP internal API. ADR-013 Sunset Clause formally closed. |

Full text: [`docs/adr/`](../adr/)

> **ADR-012 note:** The original platform vision (v0) assumed ERP and Commerce would share the same domain services. ADR-012 documents the deliberate reversal: Commerce is now the system of record for transactional state; ERP consumes `OrderCreated` events to produce GL entries. During the transition (until Sprint 8), there is a dual-source-of-truth period: Order lives in Commerce, Invoice lives in ERP, with event-lag between them. The reconciliation contract is defined in the Sprint 8 runbook.

> **ADR-013 note:** Confirms INV-4 as a production gap. Accepts POS as the authoritative inventory writer during the transition period under three mandatory conditions (double check, POS visibility endpoint, compensation path). The Strangler Fig expires at Sprint 8 — any extension requires a new ADR. This is a deliberate, documented risk acceptance, not an omission.

---

## 9. Quality Gates

Every new capability must pass all gates before merging to `main`:

| Gate | Requirement |
|------|-------------|
| **Domain Tests** | All aggregate, service, and policy behaviour covered without DB or HTTP |
| **Contract Tests** | HTTP layer tests using stubs — no real DB, no real providers |
| **ADR** | At least one ADR documenting the key architectural decision |
| **Runbook** | Staging validation steps, observable signals, rollback procedure |
| **Observability** | At minimum: success counter, error counter, latency histogram |
| **Migration** | Alembic migration for any schema change — forward only |
| **Protocols** | Repository + UoW defined as Protocol in `packages/domain` |
| **Cardinality** | No dynamic label values in Prometheus metrics — bounded enums only |
| **Audit trail** | Every write operation that changes financial state enqueues an audit event in the same UoW transaction (INV-9) |

**Current totals at v1.0.1:** 358 tests · 13 ADRs · 5 runbooks · 20 metrics  
**Current totals at v1.1.0:** 414 tests · 14 ADRs · 5 runbooks · 20 metrics  
**Current totals at v1.3.0:** 517 tests · 16 ADRs · 5 runbooks · 20 metrics

---

## 10. Roadmap

### v1.0 — Commerce Core ✅
- Pricing (gold rate engine, freshness contract)
- Reservation (INV-6, expiry worker, quote snapshot)
- Payment (MoyasarGateway, webhook idempotency)
- Checkout (Application Orchestrator — atomic reservation + order)
- Orders (state machine, `OrderCreated` event)

### v1.0.1 — Safety ✅ (before real monetary volumes)
- `REFUND_PENDING` + `REFUNDED` states in `PaymentIntent` (INV-10 resolved)
- `PaymentService.mark_refund_pending()` — domain service method for compensation path
- Double ERP availability check: at reservation creation + at checkout confirmation (ADR-013 Condition 1)
- `GET /api/v1/items/{id}/availability` — POS visibility endpoint deployed (ADR-013 Condition 2)
- ADR-012: ERP downstream consumer documented
- ADR-013: Inventory Strangler Fig with Sunset Clause documented
- Architecture v1.0 freeze: Platform Constitution published

> **Gate A — Money gate (Moyasar production keys):**  
> Must be satisfied before real SAR flows through the system:  
> 1. `REFUNDED` path tested end-to-end in staging (automated refund confirmed, not manual)  
> 2. Daily reconciliation job running and alerting (Commerce orders vs ERP invoices — ADR-012)  
>
> **Gate B — Inventory exposure gate (raise item ceiling):**  
> Must be satisfied before listing showroom-displayed items online:  
> 3. POS UI consumes `GET /api/v1/items/{id}/availability` (INV-11 resolved)  
>
> Before Gate B: only publish items *not physically present in the showroom*. INV-4 exposure = zero by definition — a POS sale cannot race an online reservation that was never created.  
> After Gate B: all items may be listed online. The POS visibility check becomes the human backstop.  
>
> **⚠️ Under the Event Sync architecture (ADR-016 Option B), Gate B is the sole preventive mechanism on the showroom side.** The original ADR-013 Option A (synchronous POS check into `InventoryService`) was not built. There is no real-time hard block at the POS before a sale. Gate B (staff visibility via the UI) is the only friction point that prevents a POS operator from selling an item with an active online reservation. Gate B was previously optional UX; it is now architecturally mandatory before showroom items go online.  
>
> Gate A and Gate B are independent. Gate A unblocks revenue. Gate B unblocks full catalogue. Neither waits for the other.

### v1.1 — Operational Layer ✅
- Notifications Capability (Sprint 6) ✅ — `NotificationGateway` Protocol, `NotificationWorker`, `customer_phone` on Reservation, ADR-014

### v1.2 — Shipping ✅
- Shipping Capability (Sprint 7) ✅ — `Shipment` aggregate, claim-then-send, `CarrierConfig.void_window` (Live), `declared_value` (Frozen), `ShipmentDelivered` event-of-record, ADR-015 Clock Protocol

### v1.3 — ERP Sync ✅
- ERP Sync Capability (Sprint 8) ✅ — `ERPSyncWorker`, `RefundWorker`, `ReconciliationWorker`, `RefundGateway` Protocol, `RefundConfirmed` event, `PaymentService.mark_refunded()`, ERP internal API, ADR-016 closes ADR-013 Sunset Clause

### v1.3 — ERP Sync ✅ Sprint 8

> ADR-013 Sunset Clause formally closed by ADR-016.

| Deliverable | Gap closed | Gate | Status |
|-------------|------------|------|--------|
| `OrderCreated` → ERP consumer (`ERPSyncWorker` + `POST /api/internal/online-orders`) | ERP dual source-of-truth | ADR-012 | ✅ Done |
| `Item.stock` decremented on online sale | INV-4 partial mitigation | ADR-012 | ✅ Done |
| `erp_sync_lag` Prometheus metric (SLO P95 ≤ 30s) | INV-4 managed window | ADR-016 | ✅ Done |
| `ReconciliationWorker` with `reconciliation_gaps_total` counter + `reconciliation_findings` DB table | ADR-012 | Gate A | ✅ Done |
| `RefundWorker` built (`LogRefundGateway` stub) | INV-10 completion | Gate A | ✅ Built — staging E2E pending |
| ADR-013 Sunset Clause closed (renegotiated: Option A → Option B) | ADR-013 | Constitutional | ✅ ADR-016 |
| SEC-003 trust boundary declared + `compare_digest` guard on every endpoint | SEC-003 | Known Gap | ✅ Mitigated |
| POS UI consumes `GET /api/v1/items/{id}/availability` | INV-11 / **INV-4 sole POS guard** | **Gate B (mandatory)** | 🟡 POS Flutter changes pending |

**Remaining Gate A blockers:** `MoyasarRefundGateway` + staging E2E · real SMS adapter · real carrier adapter (SEC-002) · `reconciliation_gaps_total` alert wired in monitoring stack.  
**Remaining Gate B blocker:** POS Flutter UI consumes availability endpoint — **mandatory before showroom items go online** (ADR-016).

### v1.3 — Customer Experience
- Next.js storefront
- Customer portal (account, order history)
- Product search + SEO
- Returns capability
- Loyalty programme

---

## 11. What We Deliberately Do Not Do

These are conscious architectural rejections. Each has been tested and found wanting.

| We do not | Reason |
|-----------|--------|
| Put business logic in routers | Routers are HTTP translation layers — they call services, not decide |
| Import ORM models into domain | Domain uses Protocols + value objects; SQLAlchemy stays in `infra/` |
| Import provider SDKs into domain | Provider changes must not touch domain — ADR-009 |
| Use dynamic Prometheus label values | Unbounded cardinality degrades Prometheus performance |
| Write to the database outside a Unit of Work | Bypasses atomicity guarantee |
| Put state machines outside aggregates | `can_pay()` belongs on `PaymentIntent`, not in a router condition |
| Call ERP directly from Commerce API | ERP is a downstream consumer of events — ADR-012 |
| Share a write path between two capabilities | Single Writer law — one service owns one aggregate |
| Raise HTTP exceptions in domain services | Domain raises domain exceptions; routers map them to HTTP status codes |
| Return `int` from batch domain mutations | Return Facts, not Statistics — ADR-008 |
| Justify FastAPI by "async-native" | The reservation path is blocked by a synchronous PostgreSQL transaction; the real reason is Pydantic at public boundaries + framework separation |

---

## 12. Document Authority

This file is the **Single Source of Truth** for the yasargold Commerce Platform architecture.

| Document type | Role | Authority |
|---------------|------|-----------|
| `docs/architecture/architecture-v1.md` (this file) | Platform Constitution | **Canonical** — overrides all others |
| `docs/adr/*.md` | Decision records | Binding — each Law here cites one |
| Executive summaries / Arabic translations | Management communication | Informational only — must cite this document as source and carry a "last reconciled" date |
| Conversation planning artifacts | Design drafts | Historical — not binding after a Law or ADR is issued |

**Any document that contradicts a Law in §5 is wrong, not this document.**  
Executive translations must be updated within one sprint of any change to §§4–10 and must carry:
```
This is an executive translation of architecture-v1.md (last reconciled: YYYY-MM-DD).
In case of discrepancy, architecture-v1.md governs.
```

---

## 13. Value Temporality Reference — Frozen vs Live

Every value that crosses a capability boundary has a temporal authority: it is either **frozen** (captured once at a business event and never updated) or **live** (read at the moment of decision from the current authoritative source).

Confusing the two is the most common class of business-logic bug on this platform. This table is the canonical reference. Any new cross-boundary value must be classified here before its ADR is merged.

**The single derivation question for any new row:**

> **Who owns the truth at the moment of use?**
> - If **we own it** (we declared it, the customer accepted it, it is settled) → **Frozen** — capture once, never re-read.
> - If **an external system owns it** (carrier policy, market price, physical stock) → **Live** — read at the moment of decision.

This question produces opposite classifications from the same logic: `declared_value` is frozen because *we* declared it at sale; `void_window` is live because *the carrier's system* decides if it accepts the void. Both answers follow from the same rule.

| Value | Frozen or Live | Frozen at / Read from | Owner of truth | Why |
|-------|---------------|----------------------|----------------|-----|
| `locked_rate_per_gram_24k` | **Frozen** | Reservation creation | Us (customer accepted) | Rate changes after lock do not affect this transaction |
| `amount` on `PaymentIntent` | **Frozen** | Payment intent creation | Us (charge settled) | Re-reading gold price after settlement would constitute fraud |
| `declared_value` on shipment | **Frozen** | Order creation (locked rate × weight) | Us (insured value we declared) | Insurance policy is issued at sale value; post-sale price changes are a carrier dispute |
| Tax rate | **Frozen** | Order creation | Us (assessed at time of supply) | Retrospective rate changes do not alter settled transactions |
| Shipping address | **Frozen** | Shipment creation (waybill issuance) | Us (policy we issued) | Customer editing their profile later does not change an issued waybill; a new shipment would need a new address |
| `void_window` on carrier | **Live** | Read at void decision time from `CarrierConfig` by `shipment.carrier_id` | Carrier's system | The carrier decides if it accepts the void; their current policy governs, not our snapshot |
| Gold price (current) | **Live** | Read at quote time from `GoldPrice` (ERP) | Market / ERP | Customers price against current market; staleness rules enforce freshness |
| Item availability | **Live** | Read at reservation + checkout from ERP stock | ERP / physical reality | Physical stock changes in real time; two checks + compensation path (ADR-013) |
| Tracking status (display) | **Live** | Read from carrier at display time; local copy is cache only | Carrier's system | The carrier owns shipment state; our local copy exists for display performance, never for business decisions. **Exception: delivery confirmation** is an event-of-record (signed webhook or confirmed poll) that enters the Outbox as `ShipmentDelivered` and drives `Order → DELIVERED`. Two paths for the same information: Live-display cache and event-of-record are never substituted for each other. |
| Supplier settlement limits (`tolerance_*`, `period_cap_*`, `review_threshold_cash`) | **Live** | Read at `post()` from the effective-dated `supplier_settlement_policy` row in force at that moment | Us (finance policy) | The limit that governs is the one in force at the moment of the accounting decision, not when the draft was typed — same rule as `void_window`. The resolved `policy_id` is then frozen onto the adjustment so the audit trail shows which limits actually applied. If the policy changes mid-month, the limit in force at posting applies to the whole period's accumulation. (ADR-025) |
| `balance_before_financial` / `balance_before_weight` on a settlement adjustment | **Frozen** | Draft creation (or explicit `refresh_snapshot()`) from `compute_live_supplier_balances()` | Us (the reading we approved) | The snapshot exists precisely to be compared against a fresh reading at posting time. If it were re-read automatically it could not detect that the balance moved, which is the entire point of the check. A drift — in cash or in any karat — kicks the document back to `draft`, voids its approval, and writes nothing. (ADR-025) |
| Supplier weight (memo) account used by a settlement | **Live** | Read at posting from the account pair (`Account.memo_account_id`) via `_resolve_account_id_for_amount_type` | Us (the chart of accounts) | The pairing is the current truth about where this supplier's grams live; it is read fresh at posting rather than cached on the document, so a re-paired account routes correctly next time. Never derived from the account number by prefix. **Weight residuals are settled with the same settlement semantics as cash residuals, but through these parallel memo accounts — no monetary valuation, no gold-price read, no inventory movement.** (ADR-025) |
| Main Karat used to measure settlement weight limits | **Live** | Read at each eligibility check from `Settings.main_karat`, via `pricing.karat_service.convert_to_main_karat` | Us (system configuration) | SAD retains weight residuals by original karat for accounting and audit; tolerance and the monthly cumulative cap are measured using the equivalent weight in the configured Main Karat. The unit is read live so a change to the configured main karat takes effect immediately for limits, and the cumulative figure stays additive across documents. **This is a measurement normalization for eligibility and policy limits — not a monetary valuation, and not a replacement of the original-karat memo posting**, which always carries each karat in its own column. (ADR-025) |

**Rules:**
1. **Frozen values are never re-read from their source after the freezing event.** A service that re-queries the gold price after a reservation is locked is wrong, regardless of whether the result is the same.
2. **Live values are never cached between the read and the decision that depends on them.** A `void_window` read 10 minutes before the void call is not the live value. A cached tracking status must not gate a business action.
3. **The freezing event, source column, and owner must all be documented.** "We freeze at order creation" is incomplete without "from `ReservationRecord.locked_rate_per_gram_24k`."
4. **When a new cross-boundary value is introduced, classify it in this table before writing code.** The classification determines the data model: frozen values need a snapshot column; live values need a live lookup at the decision point.
5. **Law 0 for this table (every row has a test):**
   - Every **Frozen** row → one test: change the source value after the freezing event and assert the stored value does not change.
   - Every **Live** row → one test: change the source value and assert the read reflects the new value immediately.

---

*This document is the canonical reference for the yasargold Commerce Platform architecture.*  
*Any decision that contradicts it requires a new ADR and an update to this document.*  
*Last updated: 2026-07-14 — v1.3.0 (Sprint 8 ERP Sync: ERPSyncWorker + RefundWorker + ReconciliationWorker + ERP internal API + RefundGateway Protocol + RefundConfirmed event + PaymentService.mark_refunded(); ADR-016 closes ADR-013 Sunset Clause; 16 ADRs)*
