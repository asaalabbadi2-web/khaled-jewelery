"""Contract tests for the SAD preview endpoint — ADR-025.

Preview exists so the accountant can see what post() would decide before
approving anything. Two properties make it trustworthy, and both are proven
here: it agrees with post() because it calls the same service logic, and it
writes nothing at all while doing so.

The read-only proofs are deliberately blunt — voucher count, journal entry
count, journal line count, document status, stored snapshot — because "this
GET is harmless" is exactly the kind of claim that decays silently.
"""

import uuid
from datetime import datetime, timedelta

import pytest

from app import app, db
from models import (
    JournalEntry,
    JournalEntryLine,
    Supplier,
    SupplierSettlementAdjustment,
    Voucher,
)
from pricing.karat_service import convert_to_main_karat
from party_account_service import ensure_supplier_accounts

from tests.test_supplier_settlement_adjustment_api import (
    ALL_SAD_PERMISSIONS,
    _create_draft,
    _ensure_policy,
    _headers_for,
    _supplier_with_residual,
)


# ── Helpers ──────────────────────────────────────────────────────────────────

def _preview(client, headers, sad_id):
    return client.get(
        f'/api/supplier-settlement-adjustments/{sad_id}/preview', headers=headers)


def _add_ledger_line(supplier_id, **line_kwargs):
    """Push another posted line onto the supplier's account.

    Used to move the balance after a draft exists — which is precisely the
    situation preview is meant to expose.
    """
    supplier = Supplier.query.get(supplier_id)
    accounts = ensure_supplier_accounts(supplier)
    db.session.flush()

    je = JournalEntry(
        entry_number=f'JE-PRV-{uuid.uuid4().hex[:8]}',
        date=datetime.now() - timedelta(hours=1),
        description='رصيد اختباري للمعاينة',
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
        supplier_id=supplier_id,
        is_deleted=False,
        **line_kwargs,
    ))
    db.session.commit()


def _ledger_counts():
    return (
        Voucher.query.count(),
        JournalEntry.query.count(),
        JournalEntryLine.query.count(),
    )


# ── 1. The eligible case ─────────────────────────────────────────────────────

def test_preview_for_an_eligible_supplier_reports_no_blocker():
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual(cash=3.00)
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        sad = _create_draft(client, headers, supplier_id).get_json()['adjustment']

        resp = _preview(client, headers, sad['id'])
        assert resp.status_code == 200

        preview = resp.get_json()['preview']
        assert preview['eligibility']['eligible'] is True
        assert preview['eligibility']['blocking_reason'] is None
        assert preview['stored_snapshot_matches'] is True

        # The live balance the post would act on, debit-positive.
        assert round(preview['balance_before_financial'], 2) == 3.00
        assert set(preview['balance_before_weight']) == {'18k', '21k', '22k', '24k'}
        assert preview['main_karat_equivalent'] == 0.0

        # Every gate is reported, not only the failing one.
        names = [c['name'] for c in preview['eligibility']['checks']]
        assert 'no_pending_vouchers' in names
        assert 'below_review_threshold' in names
        assert all(c['passed'] for c in preview['eligibility']['checks'])


# ── 2. A blocker that appeared after the draft ───────────────────────────────

def test_preview_reports_pending_vouchers_as_a_structured_blocker():
    """The draft was legal when created; a pending voucher landed afterwards."""
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual(cash=3.00)
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        sad = _create_draft(client, headers, supplier_id).get_json()['adjustment']

        with app.app_context():
            db.session.add(Voucher(
                voucher_number=f'V-PRV-{uuid.uuid4().hex[:8]}',
                voucher_type='صرف',
                date=datetime.now(),
                supplier_id=supplier_id,
                amount_cash=10.0,
                status='pending',
            ))
            db.session.commit()

        preview = _preview(client, headers, sad['id']).get_json()['preview']

        assert preview['eligibility']['eligible'] is False
        blocker = preview['eligibility']['blocking_reason']
        assert blocker['code'] == 'no_pending_vouchers'
        # The message is the service's own wording, not a rewrite.
        assert 'سند معلّق' in blocker['message']


# ── 3. The review threshold outranks every other refusal ─────────────────────

def test_preview_reports_review_threshold_breach_ahead_of_other_blockers():
    """post() raises on the review gate before anything else; preview agrees.

    The residual here also drifts away from the stored snapshot, so two
    refusals are live at once. Preview must name the same one post() would.
    """
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual(cash=3.00)
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        sad = _create_draft(client, headers, supplier_id).get_json()['adjustment']

        with app.app_context():
            # Review threshold in the test policy is 500.
            _add_ledger_line(supplier_id, cash_debit=600.00)

        preview = _preview(client, headers, sad['id']).get_json()['preview']

        assert preview['eligibility']['eligible'] is False
        assert preview['eligibility']['blocking_reason']['code'] == 'below_review_threshold'
        # Drift is real and reported, but it does not outrank the review gate.
        assert preview['stored_snapshot_matches'] is False

        # And post() refuses with the same verdict.
        resp = client.post(
            f"/api/supplier-settlement-adjustments/{sad['id']}/approve", json={}, headers=headers)
        assert resp.status_code == 200
        resp = client.post(
            f"/api/supplier-settlement-adjustments/{sad['id']}/post", json={}, headers=headers)
        assert resp.status_code == 409
        assert resp.get_json()['error'] == 'supplier_account_review_required'


# ── 4. Main karat equivalent across several karats ───────────────────────────

def test_preview_normalises_every_karat_and_never_sums_raw_grams():
    raw = {'18k': 0.010, '21k': 0.012, '24k': 0.008}

    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual(cash=1.00)
        for key, grams in raw.items():
            _add_ledger_line(supplier_id, **{f'debit_{key}': grams})
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

        expected = round(sum(
            abs(convert_to_main_karat(grams, float(key[:2])))
            for key, grams in raw.items()
        ), 6)

    with app.test_client() as client:
        sad = _create_draft(client, headers, supplier_id).get_json()['adjustment']
        preview = _preview(client, headers, sad['id']).get_json()['preview']

        # Each karat is reported on its own, unconverted.
        for key, grams in raw.items():
            assert preview['balance_before_weight'][key] == pytest.approx(grams, abs=1e-6)

        assert preview['main_karat_equivalent'] == pytest.approx(expected, abs=1e-6)
        # 0.010 + 0.012 + 0.008 = 0.030 is not the answer to anything.
        assert preview['main_karat_equivalent'] != pytest.approx(0.030, abs=1e-9)


# ── 5. Policy limits and the month's remaining allowance ─────────────────────

def test_preview_reports_policy_limits_consumption_and_remaining_caps():
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual(cash=3.00)
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        sad = _create_draft(client, headers, supplier_id).get_json()['adjustment']
        preview = _preview(client, headers, sad['id']).get_json()['preview']

        policy = preview['policy']
        assert policy['policy_id'] is not None
        assert policy['tolerance_cash'] == pytest.approx(5.00)
        assert policy['tolerance_weight'] == pytest.approx(0.050)
        assert policy['period_cap_cash'] == pytest.approx(50.00)
        assert policy['period_cap_weight'] == pytest.approx(0.500)
        assert policy['review_threshold_cash'] == pytest.approx(500.00)

        # Nothing posted this month yet, so the whole cap is still available.
        assert policy['cash_consumed'] == pytest.approx(0.0)
        assert policy['weight_consumed'] == pytest.approx(0.0)
        assert policy['remaining_cash_cap'] == pytest.approx(50.00)
        assert policy['remaining_weight_cap'] == pytest.approx(0.500)

        assert preview['period_key'] == datetime.now().strftime('%Y-%m')


# ── 6. No voucher, no journal entry ──────────────────────────────────────────

def test_preview_writes_no_voucher_and_no_journal_entry():
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual(cash=3.00)
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        sad = _create_draft(client, headers, supplier_id).get_json()['adjustment']

        with app.app_context():
            before = _ledger_counts()

        # Several times over: an accidental write would compound.
        for _ in range(3):
            assert _preview(client, headers, sad['id']).status_code == 200

        with app.app_context():
            assert _ledger_counts() == before


# ── 7. No state change, no snapshot change ───────────────────────────────────

def test_preview_leaves_the_document_and_its_snapshot_untouched():
    """Even when the balance has moved — post() would kick back here, preview must not."""
    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual(cash=3.00)
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        sad = _create_draft(client, headers, supplier_id).get_json()['adjustment']

        with app.app_context():
            _add_ledger_line(supplier_id, cash_debit=1.50)
            stored = SupplierSettlementAdjustment.query.get(sad['id'])
            before = (
                stored.status,
                float(stored.balance_before_financial),
                dict(stored.balance_before_weight_by_karat),
                stored.snapshot_captured_at,
                stored.approved_by,
                stored.policy_id,
                stored.voucher_id,
                stored.journal_entry_id,
            )

        preview = _preview(client, headers, sad['id']).get_json()['preview']
        # The drift is visible...
        assert preview['stored_snapshot_matches'] is False
        assert round(preview['balance_before_financial'], 2) == 4.50

        with app.app_context():
            stored = SupplierSettlementAdjustment.query.get(sad['id'])
            after = (
                stored.status,
                float(stored.balance_before_financial),
                dict(stored.balance_before_weight_by_karat),
                stored.snapshot_captured_at,
                stored.approved_by,
                stored.policy_id,
                stored.voucher_id,
                stored.journal_entry_id,
            )

        # ...and nothing was done about it. The snapshot still reads 3.00.
        assert after == before
        assert after[0] == SupplierSettlementAdjustment.STATUS_DRAFT
        assert after[1] == pytest.approx(3.00)


# ── 8. Authorization ─────────────────────────────────────────────────────────

def test_preview_requires_the_view_permission(monkeypatch):
    monkeypatch.setenv('BYPASS_AUTH_FOR_DEVELOPMENT', '0')

    with app.app_context():
        _ensure_policy()
        supplier_id = _supplier_with_residual(cash=3.00)
        _, full = _headers_for(ALL_SAD_PERMISSIONS)
        # Every SAD permission except the one that gates reading.
        _, partial = _headers_for(
            [c for c in ALL_SAD_PERMISSIONS if not c.endswith('.view')])

    with app.test_client() as client:
        sad = _create_draft(client, full, supplier_id).get_json()['adjustment']

        resp = _preview(client, partial, sad['id'])
        assert resp.status_code == 403
        assert resp.get_json()['error'] == 'permission_denied'

        resp = client.get(
            f"/api/supplier-settlement-adjustments/{sad['id']}/preview")
        assert resp.status_code == 401


def test_preview_of_a_missing_document_is_404():
    with app.app_context():
        _, headers = _headers_for(ALL_SAD_PERMISSIONS)

    with app.test_client() as client:
        resp = _preview(client, headers, 99999999)
        assert resp.status_code == 404
        assert resp.get_json()['error'] == 'not_found'
