"""A stopped safe takes no new row (ADR-052; the nightly check, 9 Nov 2026).

ADR-052 stopped each office's old gold safe -- a safe on its supplier's
weight account -- when the office's gold became a deposit. The account stays
the supplier's, live; the safe-row writers matched safes by account, active
or not: each gold payment to the office as a supplier wrote an «in» row on
its stopped safe (the Dewan's: 290.5 g on 26 Oct, 175 g on 7 Nov -- 465.5 g
of SAFEBOX_GOLD_DRIFT). The invoice's gold rows already skipped a stopped
safe (posting_routes); the voucher's writers now do too
(accounting/safe_boxes.row_safes_by_account). And a stopped safe's ledger is
no longer its own: the drift checks read the active safes.

Run:
    python -m pytest tests/test_a_stopped_safe_takes_no_row.py -v
"""
import pytest

from accounting.voucher_engine import _append_safe_transactions_for_voucher, post_entry_of_approved_voucher
from models import SafeBox, SafeBoxTransaction, Supplier, Voucher, VoucherAccountLine, db
from services.books_invariants import check_safebox_gold_drift, check_safebox_subledger_drift
from services.repair.office_gold_deposits import make_deposits
from tests.test_office_gold_deposits import NOW, office, parent  # noqa: F401


@pytest.fixture(autouse=True)
def _fenced(db_fence):
    yield


def _pay_the_office_from_its_deposit(office, grams):
    make_deposits(by='owner', now=NOW)
    db.session.expire_all()
    supplier = db.session.get(Supplier, office['supplier'].id)
    deposit = supplier.default_safe_box
    v = Voucher(voucher_number=f'PV-T-{office["office"].id}', voucher_type='payment', date=NOW, party_type='supplier',
                supplier_id=supplier.id, description='سداد ذهب للمكتب', amount_gold=grams, amount_cash=0.0,
                status='approved', created_by='t')
    db.session.add(v)
    db.session.flush()
    db.session.add_all([
        VoucherAccountLine(voucher_id=v.id, account_id=deposit.account_id, line_type='credit', amount_type='gold',
                           amount=grams, karat=21),
        VoucherAccountLine(voucher_id=v.id, account_id=office['gold'].id, line_type='debit', amount_type='gold',
                           amount=grams, karat=21),
    ])
    db.session.flush()
    je = post_entry_of_approved_voucher(v, posted_by='t')
    v.journal_entry_id = je.id
    _append_safe_transactions_for_voucher(v, created_by='t')
    return v, deposit


def test_a_payment_to_the_office_writes_no_row_on_its_stopped_safe(office):
    v, deposit = _pay_the_office_from_its_deposit(office, 100.0)
    rows = SafeBoxTransaction.query.filter_by(ref_type='voucher', ref_id=v.id).all()
    assert [(r.safe_box_id, r.direction) for r in rows] == [(deposit.id, 'out')], \
        'the deposit\'s row only: none on the stopped safe'
    assert db.session.get(SafeBox, office['old'].id).is_active is False


def test_the_drift_checks_read_the_active_safes(office):
    old = office['old']
    db.session.add(SafeBoxTransaction(safe_box_id=old.id, ref_type='voucher', ref_id=0, direction='in',
                                      amount_cash=500.0, weight_21k=465.5, created_by='t'))
    old.is_active = False
    db.session.flush()
    keys = {f.subject_key for f in check_safebox_gold_drift()} | {f.subject_key for f in check_safebox_subledger_drift()}
    assert not any(k.startswith(f'safe_box:{old.id}') for k in keys), 'a stopped safe\'s ledger is not its own'
    old.is_active = True
    db.session.flush()
    keys = {f.subject_key for f in check_safebox_gold_drift()}
    assert f'safe_box:{old.id}:21k' in keys, 'active, it is read as it was'
