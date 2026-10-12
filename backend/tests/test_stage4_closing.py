"""Stage 4's last decisions (the owner, 12 Oct 2026).

1. Purchases 64 and 149 are paid in full: the rest was paid by vouchers that
   named no invoice (PV-2026-00149, 20,349; PV-2026-00846, 15,954) -- their
   suppliers' balances are zero. The payment row links them; no entry.
2. The cash customer owes nothing: what is left on it, invoice by invoice, is
   cleared against the temporary cash box (the main cash box matches reality;
   the owner's rule) -- invoice 61's payment was written twice, by its own
   entry and by PV-2026-00035.
3. The 20 other «عميل نقدي» records, all at zero, are stopped with their
   accounts; #8 stays the one.
4. The weight-equivalent column of 16 old entries (12 Feb - 14 Apr) is left
   and accepted -- and a nightly check names any entry it unbalances again.
5. The temporary bank's statement follows its ledger (AV-2026-00210, 3,700).
6. Item 1 is closed; voucher PV-2026-01293's 0.01 g is accepted as rounding.

Run:
    python -m pytest tests/test_stage4_closing.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import (
    Account, Customer, Invoice, InvoicePayment, JournalEntry, JournalEntryLine, PaymentMethod, SafeBox, Voucher, db,
)
from services.repair import stage4_closing as sc

NOW = datetime(2026, 10, 12, 12, 0)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _uid():
    return uuid.uuid4().hex[:6]


def _account(number=None, name='حساب', type_='Asset'):
    number = number or f'98{_uid()}'
    found = Account.query.filter_by(account_number=number).first()
    if found:
        return found
    a = Account(account_number=number, name=name, type=type_)
    db.session.add(a)
    db.session.flush()
    return a


def _entry(lines, *, ref_type, ref_id, date=datetime(2026, 2, 17)):
    je = JournalEntry(entry_number=f'JE-T-{_uid()}', date=date, description='t', entry_type='عادي',
                      reference_type=ref_type, reference_id=ref_id, is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    for spec in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, **spec))
    db.session.flush()
    return je


# ── 1. purchases paid by a voucher that named no invoice ──

def _voucher(amount, *, invoice=None, credit_account, debit_account, date=datetime(2026, 4, 1)):
    from models import VoucherAccountLine
    v = Voucher(voucher_number=f'PV-T-{_uid()}', voucher_type='payment', date=date, status='approved',
                amount_cash=amount, created_by='t',
                reference_type='invoice' if invoice else None, reference_id=invoice.id if invoice else None)
    db.session.add(v)
    db.session.flush()
    db.session.add_all([
        VoucherAccountLine(voucher_id=v.id, account_id=credit_account.id, line_type='credit', amount_type='cash',
                           amount=amount),
        VoucherAccountLine(voucher_id=v.id, account_id=debit_account.id, line_type='debit', amount_type='cash',
                           amount=amount)])
    db.session.flush()
    return v


def test_a_purchase_paid_by_two_vouchers_without_rows_is_paid_by_its_records(app):
    """As on production: no payment row at all -- the first voucher (naming the
    invoice) set amount_paid once, the second named nothing. A recompute would
    have said «unpaid»; after the step it says «paid» from the rows."""
    from services.invoice_payment_state_service import InvoicePaymentStateService
    bank = _account(name='بنك')
    supplier_acc = _account(type_='Liability')
    method = PaymentMethod(name=f'تحويل {_uid()}', payment_type='bank_transfer')
    db.session.add(method)
    db.session.flush()
    box = SafeBox(name=f'بنك {_uid()}', safe_type='bank', account_id=bank.id, is_active=True)
    db.session.add(box)
    db.session.flush()
    method.default_safe_box_id = box.id
    inv = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء', date=datetime(2026, 3, 19),
                  total=170349.0, status='partially_paid', amount_paid=150000.0, is_posted=True)
    db.session.add(inv)
    db.session.flush()
    named = _voucher(150000.0, invoice=inv, credit_account=bank, debit_account=supplier_acc, date=datetime(2026, 3, 19))
    unnamed = _voucher(20349.0, credit_account=bank, debit_account=supplier_acc)
    assert InvoicePaymentStateService()._recompute(inv).status == 'unpaid', 'what a recompute said before'
    db.session.refresh(inv)
    inv.amount_paid, inv.status = 150000.0, 'partially_paid'
    measured = {inv.id: unnamed.voucher_number}

    plan = sc.purchases_paid_by_unnamed_vouchers(by='t', now=NOW, dry_run=True, measured=measured)
    assert plan[0]['vouchers'] == {named.voucher_number: 150000.0, unnamed.voucher_number: 20349.0}
    assert not plan[0]['written']
    sc.purchases_paid_by_unnamed_vouchers(by='t', now=NOW, dry_run=False, measured=measured)
    rows = {r.source_voucher_id: r for r in InvoicePayment.query.filter_by(invoice_id=inv.id)}
    assert set(rows) == {named.id, unnamed.id}
    assert rows[unnamed.id].payment_method_id == method.id, 'the method of the safe it was paid from'
    db.session.refresh(inv)
    assert inv.status == 'paid' and inv.amount_paid == pytest.approx(170349.0)
    assert InvoicePaymentStateService()._recompute(inv).status == 'paid', 'a later recompute keeps it'
    assert sc.purchases_paid_by_unnamed_vouchers(by='t', now=NOW, dry_run=True, measured=measured)[0]['done']


# ── 2. the cash customer owes nothing ──

def test_what_is_left_on_the_cash_customer_is_cleared_against_the_temporary_cash(app):
    customer_acc = _account('1200000', 'عميل نقدي')
    temp_cash = _account('1100002', 'صندوق نقدية مؤقت')
    _account('1200', 'العملاء')
    cash = _account()
    cust = Customer(customer_code=f'C-{_uid()}', name=f'عميل {_uid()}')
    db.session.add(cust)
    db.session.flush()
    inv = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء من عميل',
                  date=datetime(2026, 2, 17), total=500.0, status='paid', is_posted=True)
    db.session.add(inv)
    db.session.flush()
    # Paid twice: by the invoice's entry, and again by a voucher on the customer.
    _entry([{'account_id': customer_acc.id, 'cash_debit': 500.0}, {'account_id': cash.id, 'cash_credit': 500.0}],
           ref_type='invoice_payments', ref_id=inv.id)
    measured = {inv.id: 500.0}
    assert sc.cash_customer_remainders(customer_acc.id)[inv.id] == pytest.approx(500.0)

    plan = sc.cash_customer_cleared(by='t', now=NOW, dry_run=True, measured=measured, split={})
    assert plan['cleared_total'] == 500.0 and not plan['written']
    sc.cash_customer_cleared(by='t', now=NOW, dry_run=False, measured=measured, split={}, customer_id=cust.id)
    entry = JournalEntry.query.filter_by(reference_type=sc.CASH_CUSTOMER_CLEARED, reference_id=inv.id).one()
    lines = {l.account_id: l for l in entry.lines}
    assert lines[customer_acc.id].cash_credit == pytest.approx(500.0)
    assert lines[temp_cash.id].cash_debit == pytest.approx(500.0)
    assert entry.date == inv.date
    assert sc.cash_customer_cleared(by='t', now=NOW, dry_run=True, measured=measured, split={})['done']


def test_a_remainder_not_as_measured_is_refused(app):
    customer_acc = _account('1200000', 'عميل نقدي')
    _account('1100002', 'صندوق نقدية مؤقت')
    _account('1200', 'العملاء')
    inv = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='بيع', date=datetime(2026, 3, 19),
                  total=100.0, status='paid', is_posted=True)
    db.session.add(inv)
    db.session.flush()
    _entry([{'account_id': customer_acc.id, 'cash_debit': 90.0}, {'account_id': _account().id, 'cash_credit': 90.0}],
           ref_type='invoice', ref_id=inv.id)
    with pytest.raises(sc.NotAsMeasured):
        sc.cash_customer_cleared(by='t', now=NOW, dry_run=True, measured={inv.id: 100.0}, split={})


def test_a_return_split_over_the_parent_moves_to_the_customer_without_cash(app):
    customer_acc = _account('1200000', 'عميل نقدي')
    temp_cash = _account('1100002', 'صندوق نقدية مؤقت')
    parent = _account('1200', 'العملاء')
    cash = _account()
    cust = Customer(customer_code=f'C-{_uid()}', name=f'عميل {_uid()}')
    db.session.add(cust)
    db.session.flush()
    ret = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='مرتجع شراء', date=datetime(2026, 4, 8),
                  total=630.0, status='paid', is_posted=True)
    db.session.add(ret)
    db.session.flush()
    # The return's customer side on the parent (tagged), its cash on the customer's own account.
    _entry([{'account_id': parent.id, 'customer_id': cust.id, 'cash_debit': 630.0},
            {'account_id': _account().id, 'cash_credit': 630.0}], ref_type='invoice', ref_id=ret.id,
           date=datetime(2026, 4, 8))
    _entry([{'account_id': cash.id, 'cash_debit': 630.0}, {'account_id': customer_acc.id, 'cash_credit': 630.0}],
           ref_type='invoice_payments', ref_id=ret.id, date=datetime(2026, 4, 8))
    temp_before = sum(float(l.cash_debit or 0) - float(l.cash_credit or 0)
                      for l in JournalEntryLine.query.filter_by(account_id=temp_cash.id))
    sc.cash_customer_cleared(by='t', now=NOW, dry_run=False, measured={}, split={ret.id: -630.0}, customer_id=cust.id)
    entry = JournalEntry.query.filter_by(reference_type=sc.CASH_CUSTOMER_CLEARED, reference_id=ret.id).one()
    lines = {l.account_id: l for l in entry.lines}
    assert lines[customer_acc.id].cash_debit == pytest.approx(630.0)
    assert lines[parent.id].cash_credit == pytest.approx(630.0) and lines[parent.id].customer_id == cust.id
    assert temp_cash.id not in lines
    assert sum(float(l.cash_debit or 0) - float(l.cash_credit or 0)
               for l in JournalEntryLine.query.filter_by(account_id=temp_cash.id)) == temp_before, 'no cash moved'


# ── 3. the other «عميل نقدي» records stop ──

def test_the_other_cash_customers_stop_with_their_accounts(app):
    from services.account_status import deactivate_account
    acc = _account(name='عميل نقدي مكرر')
    dup = Customer(customer_code=f'C-{_uid()}', name='عميل نقدي', account_id=acc.id, active=True)
    db.session.add(dup)
    db.session.flush()
    with pytest.raises(Exception):
        deactivate_account(acc.id, by='t', now=NOW)   # a live customer's account: refused, as before
    sc.cash_customer_duplicates(by='t', now=NOW, dry_run=False, ids=[dup.id])
    db.session.refresh(dup)
    db.session.refresh(acc)
    assert dup.active is False and acc.is_active is False


# ── 4. the weight-equivalent column: a nightly check ──

def test_an_entry_whose_weight_column_is_unbalanced_is_named(app):
    from services.books_invariants import CHECKS, ENTRY_WEIGHT_UNBALANCED
    from services.finding_kinds import KIND_INFO
    assert ENTRY_WEIGHT_UNBALANCED in KIND_INFO
    a, b = _account(), _account()
    bad = _entry([{'account_id': a.id, 'debit_21k': 10.0, 'debit_weight': 10.0},
                  {'account_id': b.id, 'credit_21k': 10.0}], ref_type='invoice', ref_id=None)
    good = _entry([{'account_id': a.id, 'debit_21k': 5.0, 'debit_weight': 5.0},
                   {'account_id': b.id, 'credit_21k': 5.0, 'credit_weight': 5.0}], ref_type='invoice', ref_id=None)
    keys = {f.subject_key: f.metric for f in CHECKS[ENTRY_WEIGHT_UNBALANCED]()}
    assert keys[f'journal_entry:{bad.id}'] == pytest.approx(10.0)
    assert f'journal_entry:{good.id}' not in keys
