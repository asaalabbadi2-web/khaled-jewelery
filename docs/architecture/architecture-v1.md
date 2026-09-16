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

`gold_price.date` is stored as naive Riyadh local time (UTC+3) by the ERP scheduler.  
Commerce treats naive datetimes from this column as `tzinfo=UTC+3`.

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
| TIME-001: ERP backend services (`backend/services/inventory_*.py`, `journals.py`) call `datetime.now()` directly in business logic instead of the injected Clock Provider | 🟡 Medium | ADR-015 | 🟡 Managed | 15 violations suppressed with `# clock-guard: TIME-001` (counted in `docs/architecture/.clock-debt-baseline`). `scripts/clock_guard.py --update` lowers the baseline only after genuine removal. Trigger: first modification of the affected module. Note: `pricing/engine.py:quoted_at` is **not** TIME-001 debt — it is `# clock-guard: record-only`, an audit timestamp with no decision effect (decision gate is `Quote.valid_until` in `quotes.py`). |
| SCHED-001: `start_all_schedulers()` returns a raw list; no SchedulerManager abstraction | 🟢 Low | — | 🟡 Open | A `SchedulerManager` (uniform `start/stop/join` contract across all scheduler types) was deliberately deferred until all 5 scheduler interfaces are understood. Current callers (`run_schedulers.main()`, tests) duck-type the list via `hasattr`. Trigger: when a second scheduler type needs the same stop/join pattern, extract a shared base class or `SchedulerManager`; never add a third duck-type caller before that extraction. |
| SCHED-002: DB connection held for the entire `process_due_settlements()` batch | 🟡 Medium | — | 🟡 Managed | `process_due_settlements()` runs inside a single `app.app_context()` that holds one connection from the pool for its full duration. With `SQLALCHEMY_POOL_SIZE=5` and `gunicorn -w 2`, a slow settlement run (large PM batch, heavy lock contention) can exhaust the pool and stall ERP HTTP handlers. Safe today at current PM volume. Exposure: pool exhaustion under peak batch × gunicorn worker count. Trigger: first observed pool-pressure alert, or before increasing gunicorn workers beyond 4. Fix: chunked batch + explicit session close between chunks, or a dedicated pool with `pool_size=1` for the scheduler process. |
| SEC-005: `BYPASS_AUTH_FOR_DEVELOPMENT` disables ERP authentication and authorization wholesale | 🔴 High | ADR-025 | 🟡 Mitigated — **must never be enabled in production** | When `BYPASS_AUTH_FOR_DEVELOPMENT=1`, `app.py`'s `bypass_auth_for_development()` before_request serves **any `/api/` request without an `Authorization` header as `admin`**, defeating `require_auth`, `require_permission`, `require_admin`, and every permission-derived rule built on them (including SAD's manager-approval bar for `reason_code=OTHER`). The flag is currently set in `backend/.env` for local development. **Consequence for verification: authorization tests executed in an environment with the bypass enabled prove nothing about production security** — any such test must disable the flag explicitly, as `tests/test_auth_bypass_production_guard.py` and the SAD API 401 test do. Mitigation (v-current): `_assert_auth_bypass_not_in_production()` raises at boot when the flag is set and `YASAR_ENV`/`FLASK_ENV` is `prod`/`production`, and the before_request hook independently refuses to apply the bypass in production (defence in depth). Proof: `tests/test_auth_bypass_production_guard.py` (22 tests). Terminal fix: remove the bypass entirely once a seeded local login exists for development. |
| SCHED-003: No DB-level uniqueness on `(payment_month_id, settlement_date)` | 🟡 Medium | — | 🟡 Open | `ensure_unique_reference=True` prevents a second auto-settlement run from writing a duplicate *reference string*, but a manual settlement voucher with the same PM on the same date can still coexist. There is no DB `UNIQUE` constraint on `(voucher_type='clearing_settlement', reference_payment_month_id, created_date)`. Exposure: if manual settlements are ever enabled alongside the scheduler, or if the unique-reference guard is bypassed, duplicate rows appear without any DB-level rejection. Trigger: before enabling manual clearing-settlement creation via the POS/ERP UI, add a partial unique index or DB-level check constraint. |

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
