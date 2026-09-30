"""E2 — Contract tests for internal_routes.py (ADR-023 seam, ADR-016 ERP sync).

Coverage matrix:
    C1  Happy path: POST creates Invoice + decrements stock in one transaction.
    C2  Atomicity: forced commit failure → nothing written (Invoice absent, stock unchanged).
    C3a Auth missing: no X-Internal-Secret → 503, nothing written.
    C3b Auth wrong: wrong X-Internal-Secret → 403, nothing written.
    C4  Idempotency: same commerce_order_id twice → one Invoice, stock decremented once.
    C5  Unknown item → 404, no Invoice.
    C6  Item out of stock → 409, no Invoice.
    C7a Reconcile found: GET /order-reconcile/{id} returns invoice fields.
    C7b Reconcile missing: GET /order-reconcile/{id} for unknown order → 404.

Law 0: the atomicity test (C2) induces a mid-transaction failure — the only proof that
Invoice and stock-- are a unit. A happy-path-only test cannot prove atomicity.
"""
from __future__ import annotations

import uuid

import os
from unittest.mock import patch

import pytest

from app import app as flask_app
from models import db, Invoice, InvoiceItem, Item


# ── Fixtures ──────────────────────────────────────────────────────────────────

_SECRET = "erp-test-secret-e2e"
_SECRET_HEADER = {"X-Internal-Secret": _SECRET}
_POST_URL = "/api/internal/online-orders"


@pytest.fixture(scope="module")
def client():
    flask_app.config["TESTING"] = True
    with flask_app.test_client() as c:
        yield c


@pytest.fixture()
def with_secret(monkeypatch):
    """Set ERP_INTERNAL_SECRET for the duration of one test."""
    monkeypatch.setenv("ERP_INTERNAL_SECRET", _SECRET)


@pytest.fixture()
def without_secret(monkeypatch):
    """Ensure ERP_INTERNAL_SECRET is absent."""
    monkeypatch.delenv("ERP_INTERNAL_SECRET", raising=False)


@pytest.fixture()
def item(request):
    """Seed a fresh Item with a unique code and configurable stock, then delete after."""
    stock = getattr(request, "param", 3)
    with flask_app.app_context():
        it = Item(
            # item_code is String(20); id(request) is 15 digits on the Linux CI runner
            # and made the code 23 characters (30 Sep 2026).
            item_code=f"TEST-E2-{uuid.uuid4().hex[:10]}",
            name="خاتم اختبار E2",
            stock=stock,
            karat="21",
            weight=5.0,
            wage=50.0,
            price=1215.0,
        )
        db.session.add(it)
        db.session.commit()
        item_id = it.id

    yield item_id, stock

    # Cleanup: remove item and any invoices created for it.
    with flask_app.app_context():
        for inv in Invoice.query.join(InvoiceItem, Invoice.id == InvoiceItem.invoice_id).filter(
            InvoiceItem.item_id == item_id
        ).all():
            InvoiceItem.query.filter_by(invoice_id=inv.id).delete()
            db.session.delete(inv)
        InvoiceItem.query.filter_by(item_id=item_id).delete()
        it = Item.query.get(item_id)
        if it:
            db.session.delete(it)
        db.session.commit()


# ── C1: Happy path ────────────────────────────────────────────────────────────

def test_c1_happy_path_creates_invoice_and_decrements_stock(client, with_secret, item):
    item_id, initial_stock = item
    order_id = f"ORD-C1-{item_id}"

    resp = client.post(
        _POST_URL,
        json={"order_id": order_id, "item_id": item_id, "amount": 1215.00},
        headers=_SECRET_HEADER,
    )

    assert resp.status_code == 201
    body = resp.get_json()
    assert body["status"] == "created"
    assert "invoice_id" in body

    with flask_app.app_context():
        inv = Invoice.query.filter_by(commerce_order_id=order_id).first()
        assert inv is not None, "Invoice must be committed"
        assert inv.status == "paid"
        assert float(inv.total) == pytest.approx(1215.00)

        ii = InvoiceItem.query.filter_by(invoice_id=inv.id).first()
        assert ii is not None, "InvoiceItem must exist"
        assert ii.item_id == item_id

        it = Item.query.get(item_id)
        assert it.stock == initial_stock - 1, "stock must be decremented"


# ── C2: Atomicity — forced commit failure ────────────────────────────────────

def test_c2_atomicity_commit_failure_leaves_nothing(client, with_secret, item):
    """Invoice and stock-- must be a unit: if commit fails, both are absent."""
    item_id, initial_stock = item
    order_id = f"ORD-C2-{item_id}"

    with patch("models.db.session.commit", side_effect=RuntimeError("forced-test-failure")):
        resp = client.post(
            _POST_URL,
            json={"order_id": order_id, "item_id": item_id, "amount": 999.00},
            headers=_SECRET_HEADER,
        )

    assert resp.status_code == 500

    with flask_app.app_context():
        assert Invoice.query.filter_by(commerce_order_id=order_id).first() is None, (
            "No Invoice must exist after a commit failure"
        )
        it = Item.query.get(item_id)
        assert it.stock == initial_stock, (
            "stock must be unchanged after a commit failure"
        )


# ── C3a: Auth — missing secret ────────────────────────────────────────────────

def test_c3a_missing_secret_returns_503_nothing_written(client, without_secret, item):
    item_id, _ = item
    order_id = f"ORD-C3A-{item_id}"

    resp = client.post(
        _POST_URL,
        json={"order_id": order_id, "item_id": item_id, "amount": 500.00},
        # no X-Internal-Secret header
    )

    assert resp.status_code == 503
    with flask_app.app_context():
        assert Invoice.query.filter_by(commerce_order_id=order_id).first() is None, (
            "503 must not write any Invoice"
        )


# ── C3b: Auth — wrong secret ──────────────────────────────────────────────────

def test_c3b_wrong_secret_returns_403_nothing_written(client, with_secret, item):
    item_id, _ = item
    order_id = f"ORD-C3B-{item_id}"

    resp = client.post(
        _POST_URL,
        json={"order_id": order_id, "item_id": item_id, "amount": 500.00},
        headers={"X-Internal-Secret": "wrong-secret-value"},
    )

    assert resp.status_code == 403
    with flask_app.app_context():
        assert Invoice.query.filter_by(commerce_order_id=order_id).first() is None, (
            "403 must not write any Invoice"
        )


# ── C4: Idempotency ───────────────────────────────────────────────────────────

def test_c4_idempotency_duplicate_order_is_ignored(client, with_secret, item):
    item_id, initial_stock = item
    order_id = f"ORD-C4-{item_id}"
    payload = {"order_id": order_id, "item_id": item_id, "amount": 1215.00}

    r1 = client.post(_POST_URL, json=payload, headers=_SECRET_HEADER)
    assert r1.status_code == 201
    invoice_id_first = r1.get_json()["invoice_id"]

    r2 = client.post(_POST_URL, json=payload, headers=_SECRET_HEADER)
    assert r2.status_code == 200
    b2 = r2.get_json()
    assert b2["status"] == "already_processed"
    assert b2["invoice_id"] == invoice_id_first, "must return same invoice_id"

    with flask_app.app_context():
        count = Invoice.query.filter_by(commerce_order_id=order_id).count()
        assert count == 1, "exactly one Invoice must exist"

        it = Item.query.get(item_id)
        assert it.stock == initial_stock - 1, "stock decremented exactly once"


# ── C5: Unknown item → 404 ───────────────────────────────────────────────────

def test_c5_unknown_item_returns_404_nothing_written(client, with_secret):
    order_id = "ORD-C5-NOITEM"
    resp = client.post(
        _POST_URL,
        json={"order_id": order_id, "item_id": 99999999, "amount": 100.00},
        headers=_SECRET_HEADER,
    )

    assert resp.status_code == 404
    with flask_app.app_context():
        assert Invoice.query.filter_by(commerce_order_id=order_id).first() is None


# ── C6: Item out of stock → 409 ──────────────────────────────────────────────

@pytest.mark.parametrize("item", [0], indirect=True)
def test_c6_out_of_stock_returns_409_nothing_written(client, with_secret, item):
    item_id, _ = item
    order_id = f"ORD-C6-{item_id}"

    resp = client.post(
        _POST_URL,
        json={"order_id": order_id, "item_id": item_id, "amount": 500.00},
        headers=_SECRET_HEADER,
    )

    assert resp.status_code == 409
    with flask_app.app_context():
        assert Invoice.query.filter_by(commerce_order_id=order_id).first() is None, (
            "409 must not write any Invoice"
        )


# ── C7a: Reconcile — found ────────────────────────────────────────────────────

def test_c7a_reconcile_found(client, with_secret, item):
    item_id, _ = item
    order_id = f"ORD-C7A-{item_id}"

    # Create the invoice first.
    r = client.post(
        _POST_URL,
        json={"order_id": order_id, "item_id": item_id, "amount": 1000.00},
        headers=_SECRET_HEADER,
    )
    assert r.status_code == 201
    expected_inv_id = r.get_json()["invoice_id"]

    resp = client.get(
        f"/api/internal/order-reconcile/{order_id}",
        headers=_SECRET_HEADER,
    )

    assert resp.status_code == 200
    body = resp.get_json()
    assert body["invoice_id"] == expected_inv_id
    assert float(body["total"]) == pytest.approx(1000.00)
    assert body["status"] == "paid"


# ── C7b: Reconcile — not found ───────────────────────────────────────────────

def test_c7b_reconcile_not_found(client, with_secret):
    resp = client.get(
        "/api/internal/order-reconcile/NONEXISTENT-ORDER-XYZ",
        headers=_SECRET_HEADER,
    )
    assert resp.status_code == 404
    assert "not found" in resp.get_json().get("error", "").lower()
