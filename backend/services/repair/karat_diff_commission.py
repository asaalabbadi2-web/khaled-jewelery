"""A karat-difference commission posting never wrote (stage-4 item 9, POST-001;
the owner, 12 Oct 2026: «اعتمد الإصلاح»).

From 13 Jul to 29 Sep 2026 posting caught an ImportError and posted invoices
without their karat-difference entries (fixed in 2d0b1e37). One invoice was
hit: 3020, purchase #178 from supplier 7 (بن شيهون ـ نواعم), whose own fields
say the company earns 307.37 (karat_diff_earn_total). The entry is the one
routes/invoices.py _create_karat_diff_settlement_entries writes -- dated as
the invoice, keyed to it, debit the supplier / credit the commission revenue
4110 -- so a later unposting of the invoice takes it with the rest.

Only as measured: the invoice posted, its earn total the measured amount, no
pay total, no such entry yet. dry_run (the default) writes nothing.
"""
import json

from models import Account, AuditLog, Invoice, JournalEntry, JournalEntryLine, Supplier, db
from services.repair.entries import write_entry

# {invoice id: the commission measured on the 11 Oct backup}
MEASURED = {3020: 307.37}
REVENUE = '4110'
CENT = 0.005


class NotAsMeasured(ValueError):
    pass


def _written(invoice_id: int, revenue_id: int, amount: float) -> bool:
    return (db.session.query(JournalEntry.id)
            .join(JournalEntryLine, JournalEntryLine.journal_entry_id == JournalEntry.id)
            .filter(JournalEntry.reference_type == 'invoice', JournalEntry.reference_id == invoice_id,
                    JournalEntry.is_deleted.is_(False), JournalEntryLine.is_deleted.is_(False),
                    JournalEntryLine.account_id == revenue_id,
                    JournalEntryLine.cash_credit.between(amount - CENT, amount + CENT))
            .first() is not None)


def post_missing_commissions(*, by: str, now, dry_run: bool = True, measured=None) -> list:
    revenue = Account.query.filter_by(account_number=REVENUE).first()
    if revenue is None:
        raise NotAsMeasured(f'account {REVENUE} not found')
    out = []
    for invoice_id, amount in (measured or MEASURED).items():
        invoice = db.session.get(Invoice, int(invoice_id))
        if invoice is None or invoice.invoice_type != 'شراء' or not invoice.is_posted \
                or invoice.status in ('rejected', 'cancelled'):
            raise NotAsMeasured(f'invoice {invoice_id} is not a posted purchase')
        earn = float(invoice.karat_diff_earn_total or 0.0)
        if abs(earn - amount) > CENT or float(invoice.karat_diff_pay_total or 0.0) > CENT:
            raise NotAsMeasured(f'invoice {invoice_id}: earns {earn}, measured {amount}')
        supplier = db.session.get(Supplier, invoice.supplier_id) if invoice.supplier_id else None
        if supplier is None or not supplier.account_id:
            raise NotAsMeasured(f'invoice {invoice_id}: no supplier account')
        number = getattr(invoice, 'invoice_number', None) or invoice.id
        if _written(invoice.id, revenue.id, amount):
            out.append({'invoice_id': invoice.id, 'done': True})
            continue
        step = {'invoice_id': invoice.id, 'invoice': number, 'date': invoice.date, 'amount': amount,
                'debit': supplier.account_id, 'credit': REVENUE, 'written': False}
        out.append(step)
        if dry_run:
            continue
        description = f'عمولة فرق العيار — فاتورة #{number}'
        entry = write_entry(
            date=invoice.date, description=description, reference_type='invoice', reference_id=invoice.id,
            lines=[{'account_id': supplier.account_id, 'description': description, 'cash_debit': amount},
                   {'account_id': revenue.id, 'description': description, 'cash_credit': amount}],
            by=by, now=now, prefix='COR', safe_rows=False)
        step['written'] = entry.entry_number
        db.session.add(AuditLog(user_name=by, action='stage4_karat_diff_commission', entity_type='invoice',
                                entity_id=invoice.id, success=True,
                                details=json.dumps(step, ensure_ascii=False, default=str)))
        db.session.flush()
    return out
