"""A payment method's commission is taken at its settlement, never at the invoice (COMMISSION-1, the owner 15 Oct 2026).

A method had a «commission timing»: 'settlement' (the bank deducts it from the
deposit, and the settlement posts it) or 'invoice' (the invoice posts an
estimate from the rate). The owner: «احتساب العمولة عند الفاتورة غير منطقي»
-- the bank, Tamara and Tabby deduct what they deduct when they deposit; and
no method ever took a commission at the invoice (15 Oct 2026 copy: every
commission of 2026 is on a 'settlement' method; نقداً and تحويل were
'invoice' at rate 0). The 'invoice' path was also broken: a sale posted its
revenue net of the commission, 23 short, and was refused (Known Gap
SALE-COMMISSION-AT-INVOICE, found by the scenario matrix). Deleted, with the
setting: there is one timing, so nothing to set.
"""
import uuid
from datetime import datetime

import pytest
from flask import g

from accounting.mappings import get_account_id_for_mapping
from app import app as flask_app
from models import Account, AccountingMapping, JournalEntry, JournalEntryLine, PaymentMethod, db
from tests.retraction_world import world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _map_commission():
    """The commission and its VAT mapped for a sale, as production has them (5320, 1410)."""
    ids = {}
    for role in ('commission', 'commission_vat'):
        ids[role] = get_account_id_for_mapping('بيع', role)
        if ids[role]:
            continue
        account = Account(account_number=f'97{uuid.uuid4().int % 10**6:06d}', name=f'اختبار {role}',
                          type='Expense', transaction_type='cash', tracks_weight=False, is_active=True)
        db.session.add(account)
        db.session.flush()
        db.session.add(AccountingMapping(operation_type='بيع', account_type=role, account_id=account.id,
                                         is_active=True, created_by='t'))
        ids[role] = account.id
    db.session.flush()
    return ids


def test_a_sale_posts_its_gross_revenue_and_no_commission(auth_headers, world):
    # The screens send the commission they estimate; the invoice does not post it.
    ids = _map_commission()
    sale = {'customer_id': world['customer'].id, 'invoice_type': 'بيع', 'gold_type': 'new',
            'employee_id': world['holder'].id, 'date': datetime.now().isoformat(),
            'total': 1000.0, 'total_weight': 2.0, 'total_tax': 0.0, 'amount_paid': 1000.0,
            'payments': [{'payment_method_id': world['pm'].id, 'amount': 1000.0,
                          'commission_amount': 20.0, 'commission_vat': 3.0}],
            'items': [{'name': 'سلسال', 'karat': 21, 'weight': 2.0, 'price': 1000.0, 'net': 1000.0,
                       'quantity': 1, 'wage': 0, 'selling_price': 1000.0}]}
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json=sale)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]

    entries = [je.id for je in JournalEntry.query.filter_by(reference_type='invoice',
                                                           reference_id=resp.get_json()['id'])]
    assert entries, 'the sale posted no entry'
    lines = JournalEntryLine.query.filter(JournalEntryLine.journal_entry_id.in_(entries)).all()
    revenue = get_account_id_for_mapping('بيع', 'sales_gold_new')
    assert sum(float(ln.cash_credit or 0) for ln in lines if ln.account_id == revenue) == pytest.approx(1000.0)
    assert not [ln for ln in lines if ln.account_id in ids.values()], 'a commission posted at the invoice'


def test_a_method_with_a_rate_is_charged_at_its_settlement():
    from clearing_settlement_scheduler import settlement_fee
    pm = PaymentMethod(payment_type='card', name=f'بطاقة {uuid.uuid4().hex[:6]}', commission_rate=2.0,
                       is_active=True)
    assert settlement_fee(pm, 1000.0, 1) == pytest.approx(20.0)


def test_there_is_no_commission_timing_to_set():
    assert not hasattr(PaymentMethod, 'commission_timing')
    pm = PaymentMethod(payment_type='card', name='بطاقة', commission_rate=1.0, is_active=True)
    assert 'commission_timing' not in pm.to_dict()
