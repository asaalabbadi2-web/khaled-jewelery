"""Stage 4: a rejected invoice whose entry was posted by mistake is undone by entries (the owner, 3 Oct 2026).

3123's shape: rejected, its entry posted by a settings save (SETTINGS-001),
its payment's entry unposted and not a draft, a pending voucher (RV-1825)
holding that entry, its safe rows still there. The laws:

- every account the invoice touched nets to zero on every column -- cash, the
  karat and the main-karat weight -- a posted reversal dated as the original,
  the original untouched;
- the nightly check no longer reports its entries;
- the voucher is rejected with no entry, the payment withdrawn, the safe rows gone;
- the session guard accepts it; a second run does nothing; a dry run writes nothing.

Run:
    python -m pytest tests/test_stage4_rejected_invoice_reversal.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import (
    Account, Invoice, InvoicePayment, JournalEntry, JournalEntryLine, SafeBox, SafeBoxTransaction, Voucher, db,
)
from services.books_invariants import (
    check_orphan_posted_entries, check_posted_entries_of_unposted_invoices, check_unposted_entries_in_limbo,
)
from services.repair.rejected_invoice_reversal import NotARejectedInvoice, reverse_rejected_invoice

ORIGINAL_DATE = datetime(2026, 9, 26, 11, 42)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _acc(prefix, name, weight=False):
    a = Account(account_number=f'{prefix}{uuid.uuid4().int % 10**6:06d}', name=name, type='Asset',
                tracks_weight=weight)
    db.session.add(a)
    db.session.flush()
    return a


def _entry(ref_type, ref_id, lines, *, posted):
    je = JournalEntry(entry_number=f'JE-T-{uuid.uuid4().hex[:8]}', date=ORIGINAL_DATE, description='t',
                      reference_type=ref_type, reference_id=ref_id, is_posted=posted, is_draft=False)
    db.session.add(je)
    db.session.flush()
    for account_id, dr, cr, w22 in lines:
        # The main-karat weight rides with the karat, as on 3123's entry (3.3 g 22k = 3.457143).
        w = round(w22 * 22 / 21, 6)
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account_id, cash_debit=dr,
                                        cash_credit=cr, debit_22k=max(w22, 0.0), credit_22k=max(-w22, 0.0),
                                        debit_weight=max(w, 0.0), credit_weight=max(-w, 0.0)))
    db.session.flush()
    return je


@pytest.fixture
def rejected_3123():
    cust, sales, display, display_w, mada = (_acc('12', 'عميل'), _acc('4', 'مبيعات'), _acc('13', 'معروض'),
                                             _acc('713', 'معروض وزني', True), _acc('15', 'مدى'))
    box = SafeBox(name=f'معروض {uuid.uuid4().hex[:5]}', safe_type='gold', account_id=display_w.id, is_active=True)
    mada_box = SafeBox(name=f'مدى {uuid.uuid4().hex[:5]}', safe_type='bank', account_id=mada.id, is_active=True)
    db.session.add_all([box, mada_box])
    db.session.flush()
    inv = Invoice(invoice_type='بيع', invoice_type_id=900000 + uuid.uuid4().int % 99999, date=ORIGINAL_DATE,
                  total=2150.0, status='rejected', is_posted=False)
    db.session.add(inv)
    db.session.flush()
    posted = _entry('invoice', inv.id, [(cust.id, 2150.0, 0.0, 0.0), (sales.id, 0.0, 2150.0, 0.0),
                                        (display_w.id, 0.0, 0.0, -3.3), (display.id, 0.0, 0.0, 3.3)], posted=True)
    pay_entry = _entry('invoice_payments', inv.id, [(mada.id, 2150.0, 0.0, 0.0), (cust.id, 0.0, 2150.0, 0.0)],
                       posted=False)
    voucher = Voucher(voucher_number=f'RV-T-{uuid.uuid4().hex[:6]}', voucher_type='receipt', date=ORIGINAL_DATE,
                      status='pending', amount_cash=2150.0, reference_type='invoice', reference_id=inv.id)
    db.session.add(voucher)
    db.session.flush()
    voucher.journal_entry_id = pay_entry.id
    from models import PaymentMethod
    pm = PaymentMethod(payment_type='card', name=f'مدى {uuid.uuid4().hex[:5]}', commission_rate=0.0, is_active=True,
                       default_safe_box_id=mada_box.id)
    db.session.add(pm)
    db.session.flush()
    payment = InvoicePayment(invoice_id=inv.id, payment_method_id=pm.id, amount=2150.0, net_amount=2150.0,
                             source_voucher_id=voucher.id)
    db.session.add(payment)
    db.session.flush()
    db.session.add_all([
        SafeBoxTransaction(safe_box_id=mada_box.id, ref_type='invoice_payment', ref_id=payment.id,
                           invoice_payment_id=payment.id, invoice_id=inv.id, direction='in', amount_cash=2150.0),
        SafeBoxTransaction(safe_box_id=box.id, ref_type='invoice_sale_gold_movement', ref_id=inv.id,
                           invoice_id=inv.id, direction='out', weight_22k=3.3),
    ])
    db.session.flush()
    return {'invoice': inv, 'posted': posted, 'pay_entry': pay_entry, 'voucher': voucher,
            'accounts': [cust.id, sales.id, display.id, display_w.id, mada.id]}


def _net(account_ids):
    out = {}
    for a in account_ids:
        rows = (db.session.query(JournalEntryLine).join(JournalEntry)
                .filter(JournalEntryLine.account_id == a, JournalEntry.is_posted.is_(True),
                        JournalEntry.is_deleted.is_(False)).all())
        out[a] = (round(sum((l.cash_debit or 0) - (l.cash_credit or 0) for l in rows), 2),
                  round(sum((l.debit_22k or 0) - (l.credit_22k or 0) for l in rows), 3),
                  round(sum((l.debit_weight or 0) - (l.credit_weight or 0) for l in rows), 3))
    return out


def _keys(facts):
    return {f.subject_key for f in facts}


def test_the_invoice_counts_nowhere_after(rejected_3123):
    w = rejected_3123
    assert f"journal_entry:{w['posted'].id}" in _keys(check_posted_entries_of_unposted_invoices())
    assert f"journal_entry:{w['pay_entry'].id}" in _keys(check_unposted_entries_in_limbo())

    plan = reverse_rejected_invoice(w['invoice'].id, by='t', now=ORIGINAL_DATE, reason='اختبار', dry_run=False)
    db.session.flush()
    assert plan['written'] and len(plan['reversal_entries']) == 1

    assert all(v == (0.0, 0.0, 0.0) for v in _net(w['accounts']).values()), _net(w['accounts'])
    rev = JournalEntry.query.filter_by(reference_type='journal_entry_reversal', reference_id=w['posted'].id).one()
    assert rev.date == ORIGINAL_DATE and rev.is_posted
    assert db.session.get(JournalEntry, w['posted'].id).is_posted, 'the original stays as it was'
    assert f"journal_entry:{w['posted'].id}" not in _keys(check_posted_entries_of_unposted_invoices())
    assert f"journal_entry:{w['pay_entry'].id}" not in _keys(check_unposted_entries_in_limbo())
    assert f"journal_entry:{rev.id}" not in _keys(check_orphan_posted_entries())

    v = db.session.get(Voucher, w['voucher'].id)
    assert (v.status, v.journal_entry_id) == ('rejected', None)
    assert db.session.get(JournalEntry, w['pay_entry'].id).is_draft
    assert InvoicePayment.query.filter_by(invoice_id=w['invoice'].id).count() == 0
    assert SafeBoxTransaction.query.filter_by(invoice_id=w['invoice'].id).count() == 0
    assert db.session.get(Invoice, w['invoice'].id).status == 'rejected'


def test_a_second_run_does_nothing_and_a_dry_run_writes_nothing(rejected_3123):
    w = rejected_3123
    dry = reverse_rejected_invoice(w['invoice'].id, by='t', now=ORIGINAL_DATE, reason='x', dry_run=True)
    assert dry['written'] is False and dry['reverse_entries']
    assert JournalEntry.query.filter_by(reference_type='journal_entry_reversal').filter(
        JournalEntry.reference_id == w['posted'].id).count() == 0
    reverse_rejected_invoice(w['invoice'].id, by='t', now=ORIGINAL_DATE, reason='x', dry_run=False)
    again = reverse_rejected_invoice(w['invoice'].id, by='t', now=ORIGINAL_DATE, reason='x', dry_run=False)
    assert again['written'] is False and not again['reverse_entries']


def test_only_a_rejected_unposted_invoice(rejected_3123):
    w = rejected_3123
    w['invoice'].status = 'paid'
    db.session.flush()
    with pytest.raises(NotARejectedInvoice):
        reverse_rejected_invoice(w['invoice'].id, by='t', now=ORIGINAL_DATE, reason='x', dry_run=True)
