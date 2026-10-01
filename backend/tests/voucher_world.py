"""Real vouchers for the voucher-lifecycle discovery (V0): made by POST /api/vouchers.

Shapes: a cash receipt from a customer, a cash payment to a supplier, a gold
payment to a supplier. Created with voucher_auto_post on -- production's
setting (1 Oct 2026), approved at creation -- or off, pending. The safe boxes
are real ones, so the safe-box rows a voucher writes have somewhere to go.
"""
import uuid
from datetime import datetime

import pytest
from sqlalchemy import func

from app import app as flask_app
from models import (
    Account, AuditLog, Customer, InvoicePayment, JournalEntry, JournalEntryLine, SafeBox,
    SafeBoxTransaction, Settings, Supplier, Voucher, VoucherInvoiceGoldAttribution, db,
)

SHAPES = ('cash_receipt', 'cash_payment', 'gold_payment')
KARATS = ('18k', '21k', '22k', '24k')


def _account(name, kind):
    acc = Account(account_number=f'8{uuid.uuid4().int % 10**7:07d}', name=f'{name} V0', type=kind)
    db.session.add(acc)
    db.session.flush()
    return acc


@pytest.fixture
def vworld():
    cash = _account('خزينة نقد', 'Asset')
    gold = _account('خزينة ذهب', 'Asset')
    db.session.add_all([
        SafeBox(name=f'نقد V0 {uuid.uuid4().hex[:6]}', safe_type='cash', account_id=cash.id, is_active=True),
        SafeBox(name=f'ذهب V0 {uuid.uuid4().hex[:6]}', safe_type='gold', account_id=gold.id, is_active=True),
    ])
    db.session.flush()
    return {'cash': cash.id, 'gold': gold.id,
            'customer_acc': _account('عميل', 'Asset').id, 'supplier_acc': _account('مورد', 'Liability').id,
            'customer': Customer.query.first().id, 'supplier': Supplier.query.get(1).id}


def auto_post(on: bool):
    row = Settings.query.first() or Settings()
    row.voucher_auto_post = on
    db.session.add(row)
    db.session.flush()


def payload(w, shape, amount=500.0):
    if shape == 'cash_receipt':
        return {'voucher_type': 'receipt', 'date': datetime(2026, 10, 1).isoformat(), 'party_type': 'customer',
                'customer_id': w['customer'], 'account_lines': [
                    {'account_id': w['cash'], 'line_type': 'debit', 'amount_type': 'cash', 'amount': amount},
                    {'account_id': w['customer_acc'], 'line_type': 'credit', 'amount_type': 'cash', 'amount': amount}]}
    if shape == 'cash_payment':
        return {'voucher_type': 'payment', 'date': datetime(2026, 10, 1).isoformat(), 'party_type': 'supplier',
                'supplier_id': w['supplier'], 'account_lines': [
                    {'account_id': w['supplier_acc'], 'line_type': 'debit', 'amount_type': 'cash', 'amount': amount},
                    {'account_id': w['cash'], 'line_type': 'credit', 'amount_type': 'cash', 'amount': amount}]}
    grams = amount / 100.0
    return {'voucher_type': 'payment', 'date': datetime(2026, 10, 1).isoformat(), 'party_type': 'supplier',
            'supplier_id': w['supplier'], 'account_lines': [
                {'account_id': w['supplier_acc'], 'line_type': 'debit', 'amount_type': 'gold', 'amount': grams, 'karat': 21},
                {'account_id': w['gold'], 'line_type': 'credit', 'amount_type': 'gold', 'amount': grams, 'karat': 21}]}


def create(headers, w, shape):
    resp = flask_app.test_client().post('/api/vouchers', headers=headers, json=payload(w, shape))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    return resp.get_json()['id']


def _r(x):
    return round(float(x or 0.0), 4)


def snapshot(voucher_id):
    """The books' view of one voucher, as counts and sums -- never ids."""
    db.session.expire_all()
    v = db.session.get(Voucher, voucher_id)
    snap = {'voucher': 'gone' if v is None else str(v.status)}
    je_ids = set()
    if v is not None and v.journal_entry_id:
        je_ids.add(v.journal_entry_id)
    je_ids |= {j for (j,) in db.session.query(JournalEntry.id).filter(
        JournalEntry.reference_type.in_(('voucher', 'voucher_reversal')), JournalEntry.reference_id == voucher_id)}
    entries = JournalEntry.query.filter(JournalEntry.id.in_(je_ids)).all() if je_ids else []
    snap['entries'] = sorted(f"{e.reference_type or '-'}:posted={bool(e.is_posted)},draft={bool(e.is_draft)},"
                             f"deleted={bool(e.is_deleted)}" for e in entries)
    if je_ids:
        cols = ['cash_debit', 'cash_credit'] + [f'{s}_{k}' for k in KARATS for s in ('debit', 'credit')]
        for posted in (True, False):
            row = (db.session.query(*[func.coalesce(func.sum(getattr(JournalEntryLine, c)), 0) for c in cols])
                   .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
                   .filter(JournalEntry.id.in_(je_ids), JournalEntry.is_posted.is_(posted)).one())
            for c, val in zip(cols, row):
                if _r(val):
                    snap[f"entries.{'posted' if posted else 'unposted'}.{c}"] = _r(val)
    sbt = {}
    for t in SafeBoxTransaction.query.filter(SafeBoxTransaction.ref_id == voucher_id,
                                             SafeBoxTransaction.ref_type.in_(('voucher', 'voucher_reversal'))).all():
        sign = 1 if t.direction == 'in' else -1
        sbt[f'{t.ref_type}.rows'] = sbt.get(f'{t.ref_type}.rows', 0) + 1
        sbt[f'{t.ref_type}.cash'] = sbt.get(f'{t.ref_type}.cash', 0.0) + sign * float(t.amount_cash or 0)
        for k in KARATS:
            sbt[f'{t.ref_type}.w{k}'] = sbt.get(f'{t.ref_type}.w{k}', 0.0) + sign * float(getattr(t, f'weight_{k}') or 0)
    snap.update({f'sbt.{k}': _r(val) for k, val in sorted(sbt.items()) if _r(val)})
    snap['invoice_payments'] = InvoicePayment.query.filter_by(source_voucher_id=voucher_id).count()
    snap['gold_attributions'] = VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=voucher_id).count()
    snap['audit_log'] = sorted(f"{a.action}:{'ok' if a.success else 'failed'}" for a in AuditLog.query.filter(
        AuditLog.entity_type.in_(('voucher', 'Voucher')), AuditLog.entity_id == voucher_id).all())
    return snap


def stand_posted(voucher):
    """Give a voucher written straight to the session the posted entry its
    'approved' status claims (V1, journal_entry_guard): a fixture may not
    write the state the rule forbids. No lines -- a fixture's voucher is
    evidence of a status, not of amounts."""
    je = JournalEntry(entry_number=f'TV-{uuid.uuid4().hex[:10]}', date=datetime.now(),
                      description=f'fixture entry of voucher {voucher.voucher_number}',
                      reference_type='voucher', reference_id=voucher.id, is_posted=True, created_by='test')
    db.session.add(je)
    db.session.flush()
    voucher.journal_entry_id = je.id
    return voucher
