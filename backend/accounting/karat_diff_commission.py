"""The karat-difference commission: one writer (stage-4 item 9's cause; the owner, 12 Oct 2026).

When a supplier is paid, or a purchase's lines settled, in a karat other than
the one owed, the difference is a commission: what the company earns (debit
the supplier / credit 4110 «خصم السداد بعيار أعلى») or pays (debit 5240
«رسوم السداد بعيار أقل» / credit the supplier).

It had two writers -- the invoice's in routes/invoices.py and the voucher's
in posting_routes.py -- the same accounts and rule in two copies, each
skipping the entry silently when the supplier had no account. And the invoice
posted at creation (as production posts: auto_post_invoices) called neither:
invoice 3020, the year's only purchase with a commission, lost its 307.37.

Here, once: every posting of an invoice and every approval of a voucher calls
write_karat_diff_commission. It is idempotent -- an entry already on the
document's commission account is not written again -- and it refuses rather
than skips: a commission with no supplier account raises, and the posting is
refused with it.
"""
from models import Account, JournalEntry, JournalEntryLine, Supplier, db

REVENUE_NUMBER = '4110'   # خصم السداد بعيار أعلى
EXPENSE_NUMBER = '5240'   # رسوم السداد بعيار أقل
CENT = 0.005


class CommissionRefused(ValueError):
    pass


def _ensure_karat_diff_expense_account() -> int:
    """Find or create رسوم السداد بعيار أقل. Production number: 5240."""
    by_number = Account.query.filter_by(account_number=EXPENSE_NUMBER).first()
    if by_number:
        return by_number.id
    name = 'رسوم السداد بعيار أقل'
    by_name = Account.query.filter_by(name=name).first()
    if by_name:
        return by_name.id
    parent = Account.query.filter_by(account_number='52').first() or Account.query.filter_by(account_number='5').first()
    number = next((c for c in ('5240', '5241', '5242', '5250')
                   if not Account.query.filter_by(account_number=c).first()), '5240')
    account = Account(account_number=number, name=name, type='expense', transaction_type='cash',
                      tracks_weight=False, parent_id=parent.id if parent else None)
    db.session.add(account)
    db.session.flush()
    return account.id


def _written(reference_type: str, reference_id: int, account_id: int) -> bool:
    return (db.session.query(JournalEntry.id)
            .join(JournalEntryLine, JournalEntryLine.journal_entry_id == JournalEntry.id)
            .filter(JournalEntry.reference_type == reference_type, JournalEntry.reference_id == reference_id,
                    JournalEntry.is_deleted.is_(False), JournalEntryLine.is_deleted.is_(False),
                    JournalEntryLine.account_id == account_id)
            .first() is not None)


def write_karat_diff_commission(document, *, reference_type: str, label: str, by: str, now) -> list:
    """The commission entries of *document* (an Invoice or a Voucher carrying
    karat_diff_earn_total / karat_diff_pay_total and supplier_id), posted, dated
    as it, keyed to it. Returns the entries written."""
    from accounting.voucher_engine import _generate_journal_entry_number
    from accounting.wages import _ensure_gold24k_commission_revenue_account
    from dimensions_service import compute_line_analytics

    earn = round(float(getattr(document, 'karat_diff_earn_total', 0) or 0), 2)
    pay = round(float(getattr(document, 'karat_diff_pay_total', 0) or 0), 2)
    if earn < CENT and pay < CENT:
        return []
    supplier = db.session.get(Supplier, document.supplier_id) if getattr(document, 'supplier_id', None) else None
    if supplier is None or not supplier.account_id:
        raise CommissionRefused(f'{label}: عليها عمولة فرق عيار ولا حساب لمورّدها — لا تُرحَّل بلا قيد العمولة')

    sides = []
    if earn >= CENT:
        revenue_id = _ensure_gold24k_commission_revenue_account()
        sides.append((revenue_id, 'عمولة فرق العيار', supplier.account_id, revenue_id, earn))
    if pay >= CENT:
        expense_id = _ensure_karat_diff_expense_account()
        sides.append((expense_id, 'رسوم فرق العيار', expense_id, supplier.account_id, pay))

    written = []
    for own_account, title, debit_id, credit_id, amount in sides:
        if _written(reference_type, document.id, own_account):
            continue
        entry = JournalEntry(
            entry_number=_generate_journal_entry_number(entry_date=document.date), date=document.date,
            description=f'{title} — {label}', entry_type='عادي',
            reference_type=reference_type, reference_id=document.id,
            is_posted=True, is_draft=False, posted_at=now, posted_by=by, created_by=by)
        db.session.add(entry)
        db.session.flush()
        for account_id, debit, credit in ((debit_id, amount, 0.0), (credit_id, 0.0, amount)):
            line = JournalEntryLine(journal_entry_id=entry.id, account_id=account_id,
                                    cash_debit=debit, cash_credit=credit, description=entry.description)
            line.analytic_amount_cash, line.analytic_weight_24k, line.analytic_weight_main = \
                compute_line_analytics(db.session, line)
            db.session.add(line)
        db.session.flush()
        written.append(entry)
    return written
