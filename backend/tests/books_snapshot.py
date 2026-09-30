"""Everything the books hold about one invoice, as plain numbers (UNPOST-001, U0).

A retraction path is characterised by what it changes here: take a snapshot,
run the path, take another, compare. Only counts and sums -- never ids -- so a
round trip (post, retract, post again) can be compared with where it started.

The invoice is followed by what points at it, not by its id alone: an edit
re-creates it under a new id, so callers may pass the (invoice_type,
invoice_type_id) pair instead.
"""
from collections import defaultdict

import sqlalchemy as sa

from models import (
    Account, AuditLog, CategoryWeightMovement, InventoryLedger, Invoice, InvoiceGoldObligation,
    InvoicePayment, JournalEntry, JournalEntryLine, SafeBoxTransaction, SystemAlert, Voucher,
    VoucherInvoiceGoldAttribution, db,
)

KARATS = ('18k', '21k', '22k', '24k')


def _r(x):
    return round(float(x or 0.0), 4)


def _entry_lines(je_ids):
    """Net of each posted and unposted line total, per column."""
    out = {}
    if not je_ids:
        return out
    cols = ['cash_debit', 'cash_credit'] + [f'{s}_{k}' for k in KARATS for s in ('debit', 'credit')]
    for posted in (True, False):
        q = (db.session.query(*[sa.func.coalesce(sa.func.sum(getattr(JournalEntryLine, c)), 0) for c in cols])
             .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
             .filter(JournalEntry.id.in_(je_ids), JournalEntry.is_posted.is_(posted)))
        row = q.one()
        for c, v in zip(cols, row):
            if _r(v):
                out[f"{'posted' if posted else 'unposted'}.{c}"] = _r(v)
    return out


def snapshot(invoice_type, invoice_type_id, known_ids=()):
    """The books' view of the invoice numbered (invoice_type, invoice_type_id).

    known_ids: ids the invoice had before (a deleted invoice, the original of
    an edit) -- what still points at them is residue, and is counted too."""
    db.session.expire_all()
    invoices = Invoice.query.filter_by(invoice_type=invoice_type, invoice_type_id=invoice_type_id).all()
    ids = sorted({i.id for i in invoices} | set(known_ids))
    snap = {
        'invoices': len(invoices),
        'invoice.is_posted': sorted(bool(i.is_posted) for i in invoices),
        'invoice.status': sorted(str(i.status) for i in invoices),
    }
    if not ids:
        return snap

    vouchers = Voucher.query.filter(Voucher.reference_type == 'invoice', Voucher.reference_id.in_(ids)).all()
    v_ids = [v.id for v in vouchers]
    snap['vouchers.status'] = sorted(str(v.status) for v in vouchers)

    inv_jes = JournalEntry.query.filter(JournalEntry.reference_type == 'invoice',
                                        JournalEntry.reference_id.in_(ids)).all()
    v_jes = []
    if v_ids:
        v_jes = JournalEntry.query.filter(sa.or_(
            sa.and_(JournalEntry.reference_type == 'voucher', JournalEntry.reference_id.in_(v_ids)),
            JournalEntry.id.in_([v.journal_entry_id for v in vouchers if v.journal_entry_id]))).all()
    for name, jes in (('invoice_entries', inv_jes), ('voucher_entries', v_jes)):
        snap[f'{name}'] = sorted(
            f"posted={bool(j.is_posted)},draft={bool(getattr(j, 'is_draft', False))},"
            f"deleted={bool(getattr(j, 'is_deleted', False))}" for j in jes)
        for k, v in _entry_lines([j.id for j in jes]).items():
            snap[f'{name}.{k}'] = v

    payments = InvoicePayment.query.filter(InvoicePayment.invoice_id.in_(ids)).all()
    snap['payments'] = sorted(f"{_r(p.amount)}:voucher={'yes' if getattr(p, 'source_voucher_id', None) else 'no'}"
                              for p in payments)

    sbt = defaultdict(float)
    for t in SafeBoxTransaction.query.filter(SafeBoxTransaction.invoice_id.in_(ids)).all():
        sign = 1 if t.direction == 'in' else -1
        sbt[f'{t.ref_type}.rows'] += 1
        sbt[f'{t.ref_type}.cash'] += sign * float(t.amount_cash or 0)
        for k in KARATS:
            sbt[f'{t.ref_type}.w{k}'] += sign * float(getattr(t, f'weight_{k}', 0) or 0)
    snap.update({f'sbt.{k}': _r(v) for k, v in sorted(sbt.items()) if _r(v)})

    cwm = CategoryWeightMovement.query.filter(CategoryWeightMovement.invoice_id.in_(ids)).all()
    snap['category_weight.rows'] = len(cwm)
    snap['category_weight.net'] = _r(sum(m.weight_delta_grams or 0 for m in cwm))

    led = InventoryLedger.query.filter(InventoryLedger.source_type == 'invoice',
                                       InventoryLedger.source_id.in_(ids)).all()
    snap['inventory_ledger.rows'] = len(led)
    snap['inventory_ledger.net'] = _r(sum(r.weight_delta or 0 for r in led))

    snap['gold_obligations'] = InvoiceGoldObligation.query.filter(InvoiceGoldObligation.invoice_id.in_(ids)).count()
    snap['gold_attributions'] = VoucherInvoiceGoldAttribution.query.filter(
        VoucherInvoiceGoldAttribution.invoice_id.in_(ids)).count()
    snap['system_alerts'] = sorted(
        f"{a.alert_type}:{'reviewed' if a.is_reviewed else 'open'}"
        for a in SystemAlert.query.filter(SystemAlert.entity_type == 'Invoice', SystemAlert.entity_id.in_(ids)).all())
    snap['audit_log'] = sorted(a.action for a in AuditLog.query.filter(
        AuditLog.entity_type.in_(('Invoice', 'invoice')), AuditLog.entity_id.in_(ids)).all())
    return snap


def cached_vs_ledger(account_ids):
    """Accounts whose cached balance_cash differs from the sum of their posted lines."""
    drift = {}
    for acc in Account.query.filter(Account.id.in_(account_ids)).all():
        row = (db.session.query(sa.func.coalesce(sa.func.sum(JournalEntryLine.cash_debit), 0)
                                - sa.func.coalesce(sa.func.sum(JournalEntryLine.cash_credit), 0))
               .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
               .filter(JournalEntryLine.account_id == acc.id, JournalEntry.is_posted.is_(True)).scalar())
        cached = getattr(acc, 'balance_cash', None)
        if cached is not None and abs(abs(float(cached)) - abs(float(row or 0))) > 0.01:
            drift[acc.account_number] = (_r(cached), _r(row))
    return drift


def diff(before, after):
    keys = sorted(set(before) | set(after))
    return {k: (before.get(k), after.get(k)) for k in keys if before.get(k) != after.get(k)}
