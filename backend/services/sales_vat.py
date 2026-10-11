"""The VAT a sale carries -- as its posted entry says it (the owner, 11 Oct 2026).

A sale's VAT is what its posted entry credits to the sales VAT accounts, a
sale return's what its entry debits there -- the mapped account «بيع /
vat_payable» (2300), and 2210, the mapping's fallback number: three sale
returns of April 2026 gave their VAT back there, before 2300 was mapped. Not
the invoice's total_tax: it reads 15/115 of the whole total, and the posting
taxed less on 91 invoices of January-April 2026 (the 10 Oct copy) -- the
entry is what the books, and the authority, hold. A sale with no VAT line
carries none: its total is all revenue. Nor does a sale whose month's VAT
was moved to revenue (the owner, 11 Oct 2026: January-May 2026's VAT is sales).
"""
from __future__ import annotations

from sqlalchemy import func

from accounting.balances import counted_line_filters
from accounting.mappings import get_account_id_for_mapping
from models import Account, JournalEntry, JournalEntryLine, db


# The entries that moved a month's sales VAT to revenue (stage-4 item 22).
VAT_TO_REVENUE = 'sales_vat_to_revenue'

# The number accounting/mappings.py falls back to for «vat_payable» when nothing is
# mapped -- where April 2026's three sale returns wrote their VAT. Not 230's whole
# subtree: commissions payable (2310) and the end-of-service provision (2320) sit
# under it too.
FALLBACK_SALES_VAT = ('2210',)


def sales_vat_account_ids() -> set[int]:
    """Every account a posting could have written sales VAT to: the mapped one, and the fallback."""
    mapped = get_account_id_for_mapping('بيع', 'vat_payable')
    found = {a.id for a in Account.query.filter(Account.account_number.in_(FALLBACK_SALES_VAT)).all()}
    return found | ({mapped} if mapped else set())


def moved_months() -> set[str]:
    """The months whose sales VAT was moved to revenue (stage-4 item 22)."""
    return {n for (n,) in db.session.query(JournalEntry.reference_number)
            .filter(JournalEntry.reference_type == VAT_TO_REVENUE, JournalEntry.is_deleted.is_(False)).all()}


def posted_sales_vat(invoice_ids) -> dict[int, float]:
    """{invoice id: the VAT its posted entries moved on the sales VAT accounts, unsigned}
    -- the VAT still owed: a month whose VAT was moved to revenue carries none."""
    vat_accounts = sales_vat_account_ids()
    ids = list(invoice_ids or [])
    if not vat_accounts or not ids:
        return {}
    month = func.to_char(JournalEntry.date, 'YYYY-MM')
    rows = (db.session.query(JournalEntry.reference_id, month,
                             func.sum(JournalEntryLine.cash_credit - JournalEntryLine.cash_debit))
            .join(JournalEntryLine, JournalEntryLine.journal_entry_id == JournalEntry.id)
            .filter(*counted_line_filters(), JournalEntry.reference_type == 'invoice',
                    JournalEntry.reference_id.in_(ids), JournalEntryLine.account_id.in_(vat_accounts))
            .group_by(JournalEntry.reference_id, month).all())
    moved = moved_months()
    out = {}
    for i, m, v in rows:
        if m not in moved:
            out[int(i)] = out.get(int(i), 0.0) + float(v or 0)
    return {i: abs(v) for i, v in out.items()}
