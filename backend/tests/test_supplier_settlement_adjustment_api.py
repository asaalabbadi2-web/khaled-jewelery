"""HTTP contract tests for the Supplier Settlement Adjustment API — ADR-025.

These prove the boundary, not the accounting: that authentication and
authorization are enforced, that the client cannot supply accounting inputs or
authority, that attribution comes from the authenticated identity, and that a
refusal writes nothing.

Real posting is deliberately NOT exercised here — it requires the four
AccountingMapping rows, which are a finance decision. What is proven instead is
that posting without them fails cleanly and leaves the ledger untouched.
"""

import uuid
from datetime import datetime, timedelta

import pytest

from app import app, db
from auth_decorators import generate_token
from models import (
    JournalEntry,
    JournalEntryLine,
    Permission,
    Role,
    Supplier,
    SupplierSettlementAdjustment,
    SupplierSettlementPolicy,
    User,
    Voucher,
)
from party_account_service import ensure_supplier_accounts


ALL_SAD_PERMISSIONS = [
    'supplier_settlement_adjustments.view',
    'supplier_settlement_adjustments.create',
    'supplier_settlement_adjustments.approve',
    'supplier_settlement_adjustments.post',
    'supplier_settlement_adjustments.reverse',
    'supplier_settlement_adjustments.cancel',
]


# ── Helpers ──────────────────────────────────────────────────────────────────

def _headers_for(permission_codes=(), is_admin=False):
    """Create a user carrying exactly these permissions; return its auth headers."""
    suffix = uuid.uuid4().hex[:8]
    user = User(
        username=f'sad_{suffix}',
        full_name='SAD test user',
        is_active=True,
        is_admin=is_admin,
    )
    user.set_password('x')
    db.session.add(user)
    db.session.flush()

    if permission_codes:
        role = Role(name=f'sad_role_{suffix}', name_ar='دور اختبار', is_active=True)
        db.session.add(role)
        db.session.flush()
        for code in permission_codes:
            perm = Permission.query.filter_by(code=code).first()
            if perm is None:
                perm = Permission(
                    code=code, name=code, name_ar=code,
                    category='supplier_settlement_adjustments', is_active=True,
                )
                db.session.add(perm)
                db.session.flush()
            role.permissions.append(perm)
        user.roles.append(role)

    db.session.commit()
    return user.username, {'Authorization': f'Bearer {generate_token(user)}'}


def _ensure_policy():
    if SupplierSettlementPolicy.query.first() is None:
        db.session.add(SupplierSettlementPolicy(
            tolerance_cash=5.00,
            tolerance_weight=0.050,
            period_cap_cash=50.00,
            period_cap_weight=0.500,
            review_threshold_cash=500.00,
            effective_from=datetime.now() - timedelta(days=30),
            created_by='test',
        ))
        db.session.commit()


def _supplier_with_residual(cash=3.00):
    """A supplier carrying a small settleable cash residual."""
    supplier = Supplier(
        supplier_code=f'S-API-{uuid.uuid4().hex[:6]}',
        name='مورد اختبار API',
    )
    db.session.add(supplier)
    db.session.flush()
    accounts = ensure_supplier_accounts(supplier)
    db.session.flush()

    je = JournalEntry(
        entry_number=f'JE-API-{uuid.uuid4().hex[:8]}',
        date=datetime.now() - timedelta(days=1),
        description='رصيد اختباري',
        entry_type='عادي',
        is_posted=True,
        is_draft=False,
        is_deleted=False,
    )
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(
        journal_entry_id=je.id,
        account_id=accounts.financial.id,
        supplier_id=supplier.id,
        cash_debit=cash,
        is_deleted=False,
    ))
    db.session.commit()
    return supplier.id


def _create_draft(client, headers, supplier_id, reason='ROUNDING_DIFFERENCE', note=None):
    body = {'reason_code': reason}
    if note is not None:
        body['note'] = note
    return client.post(
        f'/api/suppliers/{supplier_id}/settlement-adjustments',
        json=body, headers=headers,
    )


# ── Authentication ───────────────────────────────────────────────────────────

def test_unauthenticated_requests_are_rejected(monkeypatch):
    """Every endpoint refuses an anonymous caller.

    BYPASS_AUTH_FOR_DEVELOPMENT is disabled explicitly here. That flag is set in
    this repo's backend/.env, and while it is on, any /api/ request without an
    Authorization header is served as `admin` — so leaving it enabled would make
    this test assert the developer's environment rather than the route's own
    behaviour.
    """
    monkeypatch.setenv('BYPASS_AUTH_FOR_DEVELOPMENT', '0')

    with app.app_context():
        supplier_id = _supplier_with_residual()

    with app.test_client() as client:
        calls = [
            ('post', f'/api/suppliers/{supplier_id}/settlement-adjustments'),
            ('get', f'/api/suppliers/{supplier_id}/settlement-adjustments'),
            ('get', '/api/supplier-settlement-adjustments/1'),
            ('post', '/api/supplier-settlement-adjustments/1/recalculate'),
            ('post', '/api/supplier-settlement-adjustments/1/approve'),
            ('post', '/api/supplier-settlement-adjustments/1/post'),
            ('post', '/api/supplier-settlement-adjustments/1/reverse'),
            ('post', '/api/supplier-settlement-adjustments/1/cancel'),
        ]
        for method, url in calls:
            resp = getattr(client, method)(url, json={})
            assert resp.status_code == 401, f'{method.upper()} {url} → {resp.status_code}'


def test_authenticated_user_without_permission_is_rejected():
    with app.app_context():
        supplier_id = _supplier_with_residual()
        _, headers = _headers_for(permission_codes=[])  # no permissions at all

    with app.test_client() as client:
        resp = _create_draft(client, headers, supplier_id)
        assert resp.status_code == 403
        assert resp.get_json()['error'] == 'permission_denied'

        resp = client.get(
            f'/api/suppliers/{supplier_id}/settlement-adjustments', headers=headers)
        assert resp.status_code == 403


# ── Create + attribution ─────────────────────────────────────────────────────

def test_create_draft_attributes_to_the_authenticated_user():
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual()
        username, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        resp = _create_draft(client, headers, supplier_id)

    assert resp.status_code == 201
    body = resp.get_json()
    assert body['success'] is True
    # Attribution came from the token, not from anything the client sent.
    assert body['adjustment']['created_by'] == username
    assert body['adjustment']['status'] == 'draft'


def test_client_cannot_supply_is_manager():
    """The elevated-approval flag is derived server-side and never read here."""
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual()
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        resp = client.post(
            f'/api/suppliers/{supplier_id}/settlement-adjustments',
            json={'reason_code': 'OTHER', 'note': 'x', 'is_manager': True},
            headers=headers,
        )

    assert resp.status_code == 400
    body = resp.get_json()
    assert body['error'] == 'client_controlled_field_rejected'
    assert 'is_manager' in body['fields']


@pytest.mark.parametrize('field,value', [
    ('amount', 999.0),
    ('account_id', 15),
    ('policy_id', 1),
    ('voucher_id', 1),
    ('journal_entry_id', 1),
    ('created_by', 'someone_else'),
    ('status', 'posted'),
])
def test_client_cannot_supply_accounting_inputs(field, value):
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual()
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        resp = client.post(
            f'/api/suppliers/{supplier_id}/settlement-adjustments',
            json={'reason_code': 'ROUNDING_DIFFERENCE', field: value},
            headers=headers,
        )

    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'client_controlled_field_rejected'


def test_unknown_field_is_rejected():
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual()
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        resp = client.post(
            f'/api/suppliers/{supplier_id}/settlement-adjustments',
            json={'reason_code': 'ROUNDING_DIFFERENCE', 'surprise': 1},
            headers=headers,
        )

    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'unsupported_field'


def test_unknown_supplier_returns_404():
    with app.app_context():
        _ensure_policy()
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        resp = _create_draft(client, headers, 99999999)

    assert resp.status_code == 404
    assert resp.get_json()['error'] == 'not_found'


# ── Read ─────────────────────────────────────────────────────────────────────

def test_get_and_list_adjustments():
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual()
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        created = _create_draft(client, headers, supplier_id).get_json()['adjustment']

        one = client.get(
            f"/api/supplier-settlement-adjustments/{created['id']}", headers=headers)
        assert one.status_code == 200
        assert one.get_json()['adjustment']['adjustment_number'] == created['adjustment_number']

        listed = client.get(
            f'/api/suppliers/{supplier_id}/settlement-adjustments', headers=headers)
        assert listed.status_code == 200
        body = listed.get_json()
        assert body['count'] == 1
        assert body['adjustments'][0]['id'] == created['id']

        filtered = client.get(
            f'/api/suppliers/{supplier_id}/settlement-adjustments?status=posted',
            headers=headers)
        assert filtered.get_json()['count'] == 0

        missing = client.get(
            '/api/supplier-settlement-adjustments/99999999', headers=headers)
        assert missing.status_code == 404


# ── Approve + manager authority ──────────────────────────────────────────────

def test_approve_attributes_to_authenticated_user():
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual()
        username, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        sad = _create_draft(client, headers, supplier_id).get_json()['adjustment']
        resp = client.post(
            f"/api/supplier-settlement-adjustments/{sad['id']}/approve",
            json={}, headers=headers)

    assert resp.status_code == 200
    body = resp.get_json()['adjustment']
    assert body['status'] == 'approved'
    assert body['approved_by'] == username
    # No approve_other permission → not a manager approval.
    assert body['approved_by_manager'] is False


def test_other_reason_requires_the_manager_permission():
    """reason_code=OTHER needs approve_other, which the accountant role lacks."""
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual()
        _, plain_headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        sad = _create_draft(
            client, plain_headers, supplier_id,
            reason='OTHER', note='تنازل موثق',
        ).get_json()['adjustment']

        denied = client.post(
            f"/api/supplier-settlement-adjustments/{sad['id']}/approve",
            json={}, headers=plain_headers)

    assert denied.status_code == 403
    body = denied.get_json()
    assert body['error'] == 'manager_approval_required'
    assert body['required_permission'] == 'supplier_settlement_adjustments.approve_other'


def test_manager_permission_unlocks_other_reason():
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual()
        _, creator_headers = _headers_for(ALL_SAD_PERMISSIONS)
        manager_name, manager_headers = _headers_for(
            ALL_SAD_PERMISSIONS + ['supplier_settlement_adjustments.approve_other'])

    with app.test_client() as client:
        sad = _create_draft(
            client, creator_headers, supplier_id,
            reason='OTHER', note='تنازل موثق',
        ).get_json()['adjustment']

        resp = client.post(
            f"/api/supplier-settlement-adjustments/{sad['id']}/approve",
            json={}, headers=manager_headers)

    assert resp.status_code == 200
    body = resp.get_json()['adjustment']
    assert body['approved_by'] == manager_name
    assert body['approved_by_manager'] is True


def test_approve_rejects_client_supplied_approved_by():
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual()
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        sad = _create_draft(client, headers, supplier_id).get_json()['adjustment']
        resp = client.post(
            f"/api/supplier-settlement-adjustments/{sad['id']}/approve",
            json={'approved_by': 'someone_else'}, headers=headers)

    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'client_controlled_field_rejected'


# ── Post: gated by the finance decision ──────────────────────────────────────

def test_post_without_accounting_mappings_fails_and_writes_nothing():
    """The only posting path provable today: refuse, and leave the ledger alone."""
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual()
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)
        je_before = JournalEntry.query.count()
        voucher_before = Voucher.query.count()

    with app.test_client() as client:
        sad = _create_draft(client, headers, supplier_id).get_json()['adjustment']
        client.post(f"/api/supplier-settlement-adjustments/{sad['id']}/approve",
                    json={}, headers=headers)
        resp = client.post(f"/api/supplier-settlement-adjustments/{sad['id']}/post",
                           json={}, headers=headers)

    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'missing_accounting_mapping'

    with app.app_context():
        assert JournalEntry.query.count() == je_before
        assert Voucher.query.count() == voucher_before
        stored = SupplierSettlementAdjustment.query.get(sad['id'])
        assert stored.voucher_id is None
        assert stored.journal_entry_id is None
        assert stored.status == 'approved'  # unchanged by the refusal


# ── Recalculate / cancel / reverse ───────────────────────────────────────────

def test_recalculate_updates_the_snapshot():
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual(cash=3.00)
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        sad = _create_draft(client, headers, supplier_id).get_json()['adjustment']
        assert sad['balance_before_financial'] == pytest.approx(3.00)

    with app.app_context():
        supplier = Supplier.query.get(supplier_id)
        accounts = ensure_supplier_accounts(supplier)
        je = JournalEntry(
            entry_number=f'JE-API-{uuid.uuid4().hex[:8]}',
            date=datetime.now(), entry_type='عادي',
            is_posted=True, is_draft=False, is_deleted=False,
        )
        db.session.add(je)
        db.session.flush()
        db.session.add(JournalEntryLine(
            journal_entry_id=je.id, account_id=accounts.financial.id,
            supplier_id=supplier_id, cash_debit=1.00, is_deleted=False,
        ))
        db.session.commit()

    with app.test_client() as client:
        resp = client.post(
            f"/api/supplier-settlement-adjustments/{sad['id']}/recalculate",
            json={}, headers=headers)

    assert resp.status_code == 200
    assert resp.get_json()['adjustment']['balance_before_financial'] == pytest.approx(4.00)


def test_cancel_requires_a_reason_and_records_the_actor():
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual()
        username, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        sad = _create_draft(client, headers, supplier_id).get_json()['adjustment']

        missing_reason = client.post(
            f"/api/supplier-settlement-adjustments/{sad['id']}/cancel",
            json={}, headers=headers)
        assert missing_reason.status_code == 400
        assert missing_reason.get_json()['error'] == 'reason_required'

        resp = client.post(
            f"/api/supplier-settlement-adjustments/{sad['id']}/cancel",
            json={'reason': 'لم تعد لازمة'}, headers=headers)

    assert resp.status_code == 200
    body = resp.get_json()['adjustment']
    assert body['status'] == 'cancelled'
    assert body['cancelled_by'] == username
    assert body['cancellation_reason'] == 'لم تعد لازمة'


def test_reverse_requires_a_posted_adjustment():
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual()
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        sad = _create_draft(client, headers, supplier_id).get_json()['adjustment']

        missing_reason = client.post(
            f"/api/supplier-settlement-adjustments/{sad['id']}/reverse",
            json={}, headers=headers)
        assert missing_reason.status_code == 400
        assert missing_reason.get_json()['error'] == 'reason_required'

        resp = client.post(
            f"/api/supplier-settlement-adjustments/{sad['id']}/reverse",
            json={'reason': 'خطأ'}, headers=headers)

    # A draft was never posted, so there is nothing to reverse.
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'invalid_request'
