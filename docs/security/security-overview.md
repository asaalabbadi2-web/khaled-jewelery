# YasarGold Commerce Platform — Security Architecture

**Status:** Accepted  
**Version:** v1.4.6-dev (2026-07-15)  
**Audience:** Technical security auditor — canonical edition  
**Authority:** This document consolidates ADR-017 and architecture-v1.md §5.0–§5.1 as the
single security reference for external review. On any conflict with the constitution
(`architecture-v1.md`), the constitution wins.  
**Derived from:** ADR-017 · architecture-v1.md §5.0–§5.1 · threat table §4.6  
**Derivatives:** Payment-gateway compliance brief · CTO brief (exported on demand; each carries
`last reconciled: YYYY-MM-DD` and cites this document as the source)  
**Test suite at reconciliation:** 778 tests · 0 failures

> Every security claim below names its proof test and enforcement status.
> A claim with no test reference does not appear in this document.

---

## 1. Security Model in One Paragraph

Security on this platform is not a checklist appended after implementation — it is a set
of seven Laws, each backed by at least one proof test that runs in CI on every merge.
A Law without a test is, by our own definition (§1 principle: *"Policy is Data, Law is
Code — without the test, the law is a comment"*), not a law. This document lists each Law,
its enforcement mechanism at both layers (structural/CI and runtime), the exact proof tests,
and — with equal precision — the surfaces that remain open.

---

## 2. Trust Boundaries

```
Internet (untrusted)
   │
   ▼  HTTPS — TLS termination at load balancer
API Gateway / LB         trusted XFF hop (TRUSTED_PROXY_HOPS=1, env-configurable)
   │
   ▼
Commerce API (FastAPI)   every route classified in ROUTE_SECURITY (Law 1)
   ├── public routes     no auth (catalog read, availability, health)
   ├── customer routes   JWT Bearer — scope="customer"
   ├── admin routes      JWT Bearer — scope="admin"
   ├── webhook routes    HMAC-SHA256 provider signature (Moyasar)
   └── ops routes        no HTTP auth — must not be externally routable
   │
   ▼
Domain Services          pure Python — no HTTP, no SQL, no SDK (import-linter enforced)
   │
   ▼
PostgreSQL               single source of truth · invariants as DB constraints
   │
   ▼  events, at-least-once via Outbox
ERP (Flask, internal)    /api/internal/* — X-Internal-Secret verified (SEC-003); private subnet only
```

**Boundary rules:**

| Boundary | Rule | Enforced by |
|----------|------|-------------|
| Internet → Commerce API | No unclassified route exists | `security.py` registry + CI scan (Laws 1/3) |
| Commerce API → Domain | No business logic in routers; domain raises typed domain exceptions | Law 9 + contract tests |
| Domain → Infrastructure | Domain imports no framework, SDK, or secret source | `import-linter` — 0 broken contracts |
| Worker → ERP | `X-Internal-Secret` via `secrets.compare_digest` | SEC-003 mitigation; terminal fix: mTLS |

---

## 3. Enforcement Terminology

Two distinct claims, never conflated:

- **Structural enforcement (CI):** the property is verified against the codebase on every
  merge. Violation cannot reach `main`.
- **Runtime enforcement (per-request):** the property is verified on every live HTTP request.

A row marked ✅ CI / ⏳ Runtime provides structural protection only — it does not protect
individual requests.

---

## 4. The Seven Security Laws

### Law 0 — The Meta-Law

> **Every security law has a proof test. Without it, it is a recommendation.**

Written first because it changes how all other laws are read. The proof is the table below —
each row names a test file and collected test count. Law 0 is itself proven by the existence
of that table.

---

### Law 1 — Deny-by-Default Scope

Every FastAPI route must declare its security scope in `security.ROUTE_SECURITY` before
merging. A route without an entry fails CI.

**Scope classification:**

| Scope | Auth required | v1.4 runtime enforcement |
|-------|--------------|--------------------------|
| `public` | None | Unrestricted |
| `customer` | JWT Bearer, `scope="customer"` | `Depends(get_customer_ref)` on every handler |
| `admin` | JWT Bearer, `scope="admin"` | `Depends(require_admin)` on every handler |
| `webhook` | HMAC-SHA256 provider signature | `gateway.parse_webhook()` raises on invalid sig |
| `ops` | None (internal network only) | No HTTP auth; must not be externally routable |

**CI enforcement:** `TestLaw1DenyByDefaultScope` in `test_route_security_scan.py` walks
`app.router.routes` (including `_IncludedRouter` entries) and fails if any `APIRoute` is
absent from `ROUTE_SECURITY`. A new endpoint without a registry entry blocks merge.

**Proof test:** `apps/commerce-api/tests/security/test_route_security_scan.py` — 4 Law 1 tests

---

### Law 2 — Secrets Never Pass Through Domain

**Face 1 — Domain cannot read secrets:**  
`import-linter` (contract in `pyproject.toml`) blocks `os.environ` and `settings` imports
inside `packages/domain`. Domain code receives secrets only through injected Protocols.
0 broken contracts at every CI run.

**Face 2 — Secrets cannot reach log handlers:**  
`RedactingFilter` rewrites log records before any handler emits them. Field names
`Authorization`, `X-Admin-Secret`, `X-Internal-Secret`, `api_key`, `token`, `secret`,
`password` have their values replaced with `<redacted>`. Applies to message text,
positional `args`, and traceback bodies.

**Installation requirement:** `handler.addFilter(RedactingFilter())` on every log handler
that receives request context.

**Proof test:** `apps/commerce-api/tests/security/test_log_redaction.py` — 16 tests
(message body · positional args · traceback text · explicit non-sensitive fields pass-through)

---

### Law 3 — Deny-by-Default Rate Class

Every route must declare a `rate_class` in `ROUTE_SECURITY`. A route without a rate class
is unthrottled by construction — that is a security constraint, not a UX choice.

**Rate classes (v1.4.5):**

| Class | Limit | Window | Intent |
|-------|-------|--------|--------|
| `catalog-read` | 200 req | 60 s | Public browse |
| `reservation-write` | 5 req | 60 s | Inventory lock |
| `payment-write` | 3 req | 300 s | Single-shot per session |
| `order-read` | 60 req | 60 s | Customer self-service |
| `webhook` | 100 req | 60 s | Provider retries (Moyasar) — independent counter |
| `admin-write` | 20 req | 60 s | Internal ops |
| `ops` | unlimited | — | Health/metrics |

**Implementation:** `RateLimitMiddleware` (`yasargold_commerce.rate_limiter`).
Fixed-window: `INCR key` then `EXPIRE key window` (only on first hit to avoid reset-on-write).

**XFF forge resistance:**  
`TRUSTED_PROXY_HOPS` env var (default 1) selects `X-Forwarded-For[−N]` (LB-appended,
trustworthy) not `[0]` (client-controlled, forgeable). A forged prefix accumulates on the
real IP — bypass requires controlling an upstream hop.

**Webhook counter isolation:**  
`POST /webhooks/payment` uses class `webhook` (100/min), independent of `payment-write`
(3/5min). Moyasar retries on confirmation failures cannot exhaust the payment counter.

**Production fail-safe:**  
`COMMERCE_ENV=production` without `REDIS_URL` → `RuntimeError` in FastAPI lifespan.
App refuses to start rather than using per-process in-memory rate limiting (which provides
no cross-worker protection). FakeRedis permitted in dev/test only, with log warning.

**CGNAT note:**  
`reservation-write` at 5/min is per client IP. Saudi mobile networks aggregate many
subscribers under one IP. Monitor 429 rates at launch; v1.5 path: key = IP + JWT `sub`.

**Proof tests:**  
`test_route_security_scan.py` (Law 3 scan, 4 tests) ·
`test_rate_limiting.py` (enforcement, 30 tests: unit · path resolution · middleware ·
XFF forge resistance · webhook isolation · production config · Retry-After header)

---

### Law 4 — RBAC on Capability

Permissions are granted on **capabilities**, not on routes. The RBAC check answers
"Does this role have permission to exercise this capability?" — not "does this role have
permission to call this URL?"

**Roles (v1.4):**

| Role | Capabilities |
|------|-------------|
| `customer` | Create reservation · create payment · view own orders · view own shipment |
| `admin` | All customer capabilities + shipment create/void/deliver |
| `webhook_provider` | Process payment webhooks (signature-gated, no JWT) |

**admin ⊇ customer:** A valid admin JWT passes all customer-scoped endpoints.
Proven by `test_law4_customer_scope.py::test_admin_jwt_passes_auth_on_customer_endpoint`.

**Enforcement — both directions proven:**

| Direction | Test | Count | What it proves |
|-----------|------|-------|----------------|
| Admin-side | `test_admin_scope_enforcement.py` | 7 | Customer JWT → 403 on all 3 admin endpoints |
| Customer-side | `test_law4_customer_scope.py` | 16 | No JWT → 401 on all 5 customer endpoints |

**Structural scan:** `test_law4_customer_scope.py` contains a count-check test that fails if a
new `scope="customer"` entry is added to `ROUTE_SECURITY` without adding the route to
`_CUSTOMER_ENDPOINTS` in the test file. Unclassified auth enforcement cannot silently exist.

**JWT implementation:** `pyjwt` HS256. Claims: `sub` (phone number), `scope`, `exp`.
`test_jwt_auth.py` — 10 unit tests (valid · expired · wrong secret · missing `sub` ·
missing `scope` · admin vs customer scope distinction).

**Bug found and fixed by this test (v1.4.6):**  
`GET /api/v1/orders/{order_id}/shipments` was classified `scope="customer"` in `ROUTE_SECURITY`
but had no `Depends(get_customer_ref)` — classified but not enforced. The Law 4 proof test
caught it. Fix: `routers/shipments.py:224`. This is cited as empirical evidence that the
Laws detect vulnerabilities, not merely document them.

**SEC-001 withdrawn (v1.4.6):** `require_admin_secret` (X-Admin-Secret interim header) is
retired. All three withdrawal conditions met: runtime scope enforcement live + admin-side
proof (7 tests) + customer-side proof (16 tests).

---

### Law 5 — BOLA: Ownership Check Lives in Domain Service

BOLA (Broken Object Level Authorization, OWASP API Security #1) — a customer changes an ID
in the URL and reads or modifies another customer's resource.

**Four rules that constitute Law 5:**

1. Ownership check lives in the domain service method, not in the router.
2. The service returns `None` when ownership fails — never raises.
3. The router maps `None → 404` (not 403 — 403 confirms the resource exists; oracle attack).
4. `customer_ref = None` (unauthenticated) always returns `None` — deny at domain level.

**`customer_ref` source in v1.4:** the verified JWT `sub` claim, injected by
`get_customer_ref()` Depends before the domain call. Not a client-supplied parameter.

**Closed surfaces (ownership enforced at domain layer):**
- `POST /reservations` → `ReservationService.find_reservation_for_customer()`
- `POST /payments` → ownership check before PaymentIntent creation
- `GET /orders/{order_id}` → `OrderService.find_order_for_customer(order_id, customer_ref, uow)`;
  `customer_ref=None` returns `None`; pre-v1.4 records with `customer_ref=NULL` return `None`

**Open surface (auth enforced, ownership deferred — Gate B):**
- `GET /orders/{order_id}/shipments` — caller must be authenticated (Law 4 fix, v1.4.6);
  ownership check (shipment's order owner == caller) not yet applied.

**Proof tests:**  
`packages/domain/tests/reservation/test_bola.py` — 6 domain-layer tests ·
`apps/commerce-api/tests/security/test_payment_bola.py` — 4 API-layer tests

---

### Law 6 — No Domain Translation Before Signature Verification

The webhook handler must verify the provider signature **before** creating any domain object
or calling any domain service.

**Why order matters:** A domain call with a forged payload can corrupt order state (e.g.,
mark an unpaid order PAID) even if the call ultimately fails. The signature check must be
the first operation.

**Invariant:** `MoyasarSignatureError` is raised inside `gateway.parse_webhook()` before
`WebhookResult` is constructed. The router catches it and returns 400.
`PaymentService.confirm()` is never called.

**Proof test:** `apps/commerce-api/tests/security/test_webhook_signature.py` — 4 tests.  
Key: `test_forged_payload_does_not_reach_domain_service` — spy proves `transition_called == False`
after a forged payload hits the handler.

---

### Law 7 — No Financial Adapter may silently downgrade in Production

Any adapter that handles a financial operation (refund, payment, settlement) must fail at boot
if it is not production-ready. A stub that logs and returns is more dangerous than a boot
failure: a boot failure is immediately visible; a silently dropped refund is invisible until a
customer reports it or a reconciliation run finds the gap.

**Rule:** If `COMMERCE_ENV=production` and the wired gateway is `LogRefundGateway` (or any
log-only stub), the app must refuse to start with a `RuntimeError` that names the fix.

**Two failure modes — both caught:**
1. `MOYASAR_SECRET_KEY` absent → `_build_refund_gateway()` returns `LogRefundGateway` → type check catches it.
2. `LogRefundGateway` wired explicitly in code → same type check catches it.

**No silent fallback:** `_build_refund_gateway()` has no `try/except`. If `MoyasarRefundGateway()`
raises (malformed key, bad config), the error propagates — the app refuses to start. Falling back
to `LogRefundGateway` on a construction error would be a silent downgrade.

**Permitted environments for `LogRefundGateway`:** `development`, `test`, and any env where
`COMMERCE_ENV != "production"`. The absence of production enforcement is by design — dev and test
need to operate without live credentials. A loud `WARNING` is emitted at build time so the state
is explicit in logs.

**Proof test:** `apps/commerce-api/tests/security/test_refund_gateway_boot.py` — 13 tests (GW1–GW6):

| Case | Env | Key | Expected |
|------|-----|-----|----------|
| GW1 | production | set | `MoyasarRefundGateway` built; check passes |
| GW2 | production | absent | `RuntimeError` naming `LogRefundGateway` and `MOYASAR_SECRET_KEY` |
| GW3 | production | any | `RuntimeError` if `LogRefundGateway` wired explicitly; cites Law 7 |
| GW4 | development | absent | `LogRefundGateway` allowed; `WARNING` logged |
| GW5 | test / unset | absent | `LogRefundGateway` allowed; no error |
| GW6 | development | set | `MoyasarRefundGateway` built; check passes |

**Scope:** this law currently covers `RefundGateway`. Gate B (E4 — POS availability) extends
the fail-closed principle to the ERP→Commerce availability check. Every new financial adapter
added in future must register a GW-series test or the Law 0 requirement is not met.

---

## 5. Authentication and Authorization

**Token model:** JWT (HS256, `pyjwt`). Claims: `sub` (E.164 phone), `scope`, `exp`.
Short-lived; refresh token flow planned for v1.5.

**Deny-by-default:** a new endpoint cannot merge without a declared scope (Law 1).
No JWT → 401 on every customer endpoint (16 proof tests). No JWT or wrong scope → 401/403
on every admin endpoint (7 proof tests).

**Object-level authorization (Law 5):** ownership resolved in the domain service;
`None` → 404 from router. 403 is never returned on resource ownership failure.

---

## 6. Payment Data Handling

**No card data transits this platform.**  
Checkout uses Moyasar's hosted page: `initiate()` returns `transaction_url` (Moyasar's
domain); the customer enters card details there. The platform stores payment-intent
identifiers, statuses, amounts, and `provider_payment_id` only.

**Webhooks:** signature verified before translation (Law 6); idempotent by `provider_event_id`;
processed by async worker; duplicate → 204.

**Refunds:** `REFUND_PENDING → REFUNDED` state machine; permanent vs transient error
classification; `Idempotency-Key` header on provider calls; total refunds bounded by
`amount_paid` (DB CHECK constraint — INV-10).

**Reconciliation:** daily worker compares provider records vs platform vs ERP;
gaps write `reconciliation_findings` rows (`resolved_at = NULL`) and increment
`reconciliation_gaps_total{kind}` (Prometheus). Detection capability proven by
gap-injection tests (12 tests against real SQLite, not stubs).

---

## 7. Rate Limiting — Operational Detail

| Class | Limit | Notes |
|-------|-------|-------|
| `reservation-write` | 5/min | per client IP (see CGNAT note, §8) |
| `payment-write` | 3/5min | webhook path explicitly excluded |
| `webhook` | 100/min | independent counter — retries cannot throttle `payment-write` (4 proof tests) |
| `catalog-read` | 200/min | — |
| `ops` | unlimited | — |

**Hardening properties proven by test:**

| Property | Proof |
|----------|-------|
| Fail-closed: `COMMERCE_ENV=production` without `REDIS_URL` → boot failure | `TestProductionRedisConfig` (4 tests) |
| Fail-closed: `COMMERCE_ENV=production` with `LogRefundGateway` → boot failure | `test_refund_gateway_boot.py` (13 tests, GW1–GW6) |
| XFF forge: forged prefix accumulates on real IP, not bypassed | `TestXFFForgeResistance` (3 tests) |
| Zero-hops mode: `TRUSTED_PROXY_HOPS=0` ignores XFF entirely | `TestXFFForgeResistance` |
| 429 responses carry `Retry-After` header | `test_rate_limiting.py` |

---

## 8. Open Surfaces — Stated Plainly

| ID | Surface | Exposure | Interim control | Terminal fix |
|----|---------|----------|----------------|-------------|
| SEC-002 | Real-provider field semantics unverified — 98 adapter tests use MockTransport | field-mapping error vs Aramex/Moyasar/Twilio possible | merge gate: sandbox assertions defined per provider (`declared_value` in insurance field; duplicate idempotency key = one AWB / one refund / one SMS) | sandbox E2E test; blocked on account provisioning (OPEN-1) |
| SEC-003 | ERP internal endpoints trust shared secret + network co-location | compromise of private subnet affects ERP trust | `secrets.compare_digest` live from day one; fail-closed (`ERP_INTERNAL_SECRET` unset → 503) | mTLS or service-mesh token |
| SEC-004 | ERP → Commerce pos-claim endpoints trust shared `X-POS-Secret` | shared secret: if ERP host is compromised, attacker can claim items on behalf of POS | `secrets.compare_digest` (constant-time); fail-closed (`POS_API_SECRET` unset → 503); `X-POS-Secret` in `RedactingFilter` | mTLS or service-mesh mutual authentication between ERP and Commerce; sunset trigger: first multi-host ERP deployment or SOC-2 readiness review |
| SEC-005 | `BYPASS_AUTH_FOR_DEVELOPMENT` serves every tokenless ERP `/api` request as `admin` | a process started with it on has no authentication or authorization at all; `backend/.env` turns it on locally, so any local auth test that does not turn it off proves nothing (TEST-002) | the ERP refuses to boot with it on in production (`_assert_auth_bypass_not_in_production`) | remove the bypass, or confine it to a local-only entry point |
| SEC-006 | ERP `/api` had no deny-by-default authentication — anonymous deletes of journal entries, vouchers, suppliers and customers witnessed | open in production until release `e5853c02` is deployed; reachable from the shop network and the tailnet | external access only through Tailscale (the router port forward is closed) | `backend/api_auth_guard.py` (ADR-031) — in code, deploy pending |
| SEC-007 | 45 ERP write routes declare no permission | any signed-in employee can hard-delete journal entries, change settings (including `allow_unposting`), approve/cancel/delete vouchers, delete suppliers, customers and payment methods | `tests/test_write_routes_declare_permission.py`: no new write route without a permission | a permission per route, decided with the owner |
| SEC-008 | 83 ERP read routes declare no permission; at least 16 sensitive | any signed-in employee reads account/party statements, payroll and attendance, the permission catalogue, `debug/db-info` | — | a permission per sensitive read; the SEC-007 ratchet extended to reads |
| CGNAT | Per-IP rate limits may throttle legitimate users behind carrier NAT | false-positive 429s under load | monitor 429 rate before tightening limits | v1.5: key = IP + JWT `sub` |
| INV-4 | Showroom / online same-piece race — managed, not closed | window = ERP sync lag, SLO P95 ≤ 30 s | `reservation_gaps_total` + `erp_sync_lag` metrics; auto-refund compensation path; only non-showroom items online until Gate B | POS UI consuming availability endpoint (Gate B) |

**SEC-001** ✅ Closed (v1.4.6) — `require_admin_secret` retired; JWT enforced on all non-public endpoints. Both withdrawal conditions satisfied: admin-side (7 tests) and customer-side (16 tests).

**BOLA-orders** ✅ Previously listed as open — confirmed closed (v1.4):
`GET /orders/{order_id}` enforces ownership via `OrderService.find_order_for_customer()` at
the domain layer. Stale entry removed.

**BOLA-shipments** ✅ Closed (Sprint 10) — `GET /orders/{id}/shipments` now enforces
ownership via `OrderService.find_order_for_customer()` before any shipment query.
Non-owner, non-existent order, and no-shipment-yet all return identical 404 responses —
no resource enumeration. Proof: `tests/security/test_shipment_bola.py` (4 tests).
All BOLA surfaces are now closed. `test_open_surfaces.py` xfail witness removed.

---

## 9. What We Deliberately Do Not Do

| We do not | Reason |
|-----------|--------|
| Store or transit card data | Provider-hosted checkout; out of PCI card-data scope by architecture |
| Trust `X-Forwarded-For[0]` as client IP | Client-controlled; forgeable. Read `ips[−TRUSTED_PROXY_HOPS]`. |
| Return 403 on non-owned resources | 403 confirms existence (oracle attack). Always 404 (Law 5). |
| Let secrets reach the domain package or the logs | Law 2 — both faces, both tested |
| Fall back silently when Redis is absent in production | Fail-closed at boot (Law 3) |
| Use a log-only stub for refunds in production | `LogRefundGateway` caught by type check at lifespan (Law 7) |
| Merge an unclassified route | Laws 1/3 registry scan — CI-fatal |
| Call the ERP from request path | Events via Outbox; internal endpoints are worker-to-ERP only |
| Issue long-lived API keys to customers | Short-lived JWTs; refresh token in v1.5 |
| Store JWT in localStorage | `HttpOnly` cookie + `SameSite=Strict` |
| Allow CORS wildcard (`*`) in production | `ALLOWED_ORIGINS` env var required explicitly |
| Pass tokens through query parameters | Query params appear in access logs and browser history |
| Import `os.environ` inside `packages/domain` | Law 2 Face 1; import-linter — 0 broken |
| Log values of sensitive header fields | Law 2 Face 2; `RedactingFilter` — `<redacted>` |

---

## 10. Observability Relevant to Security

- Structured logging with correlation IDs; `RedactingFilter` applied before every handler.
- Prometheus metrics — bounded-enum labels only (no dynamic cardinality — constitution Quality Gate).
- Adapter metrics: `{capability}_{operation}_{success|failure}_total` + duration histograms,
  `kind={permanent|transient}`.
- Alert rules: `reconciliation_gaps_total > 0` · ERP sync lag SLO breach · gold-price
  staleness · Outbox age.

---

## 11. Test Inventory

| Law | Test file | Tests | What it proves |
|-----|-----------|-------|----------------|
| Laws 1+3 (scope + rate scan) | `tests/security/test_route_security_scan.py` | 10 | Every route has scope + rate class; missing entry fails CI |
| Law 2 (redaction) | `tests/security/test_log_redaction.py` | 16 | Message · args · tracebacks; non-sensitive fields pass |
| Law 3 (enforcement) | `tests/security/test_rate_limiting.py` | 30 | Fixed-window · XFF forge · webhook isolation · production config |
| Law 4 JWT unit | `tests/security/test_jwt_auth.py` | 10 | Valid/expired/wrong-secret/missing-claims/scope distinction |
| Law 4 admin-side | `tests/security/test_admin_scope_enforcement.py` | 7 | Customer JWT → 403 on all admin endpoints |
| Law 4 customer-side | `tests/security/test_law4_customer_scope.py` | 16 | No JWT → 401; customer JWT → passes; admin JWT → passes; count scan |
| Law 5 BOLA (domain) | `packages/domain/tests/reservation/test_bola.py` | 6 | Ownership in service layer; `None → 404`; `customer_ref=None` denied |
| Law 5 BOLA (API) | `tests/security/test_payment_bola.py` | 4 | Payment respects reservation ownership |
| Law 6 (sig before domain) | `tests/security/test_webhook_signature.py` | 4 | Forged payload does not reach domain service |
| Law 7 (financial adapter boot guard) | `tests/security/test_refund_gateway_boot.py` | 15 | GW1–GW7: production rejects any NonProductionFinancialAdapter; dev/test permits with WARNING |
| Law 5 BOLA (shipments) | `tests/security/test_shipment_bola.py` | 4 | Wrong customer → 404; unauthenticated → 404; ownership delegates to domain; owner proceeds past check |

**Total: 123 security tests across 12 files.**  
All run in the standard CI pipeline.
No mocking of auth or signature verification — only business-layer dependencies are stubbed.

> **Regenerate this table:** `python scripts/gen_security_test_counts.py` — reads live counts from `pytest --collect-only`. Run before any commit that adds or removes security tests.

---

## Appendix A — Source Index

| Topic | Canonical source |
|-------|-----------------|
| Laws + current status table | `architecture-v1.md §5.1` |
| Enforcement terminology | `architecture-v1.md §5.0` |
| Security decisions (rationale) | `docs/adr/ADR-017-security-architecture.md` |
| Threat table / gap history | `architecture-v1.md §4.6` (Known Gaps) |
| Business invariants INV-1…10 | `architecture-v1.md §2` |
| Value temporality (frozen vs live) | `architecture-v1.md §13` |

Derived documents (payment-gateway compliance brief; CTO brief) must cite this file
and carry their own `last reconciled:` date. Derivation direction: technical detail → summary.
Never the reverse.

---

*Last reconciled: 2026-07-15 · v1.4.6-dev · 765 platform tests (334 domain · 431 commerce-api) · 0 failures*
