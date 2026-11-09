"""Which way a payment's money went, from its own records (8 Nov 2026).

'in' -- received (a sale's payment); 'out' -- paid out (a purchase's). Read,
never inferred from the invoice's type: its safe row says it, or else the
side its voucher's entry took on the old safe's account. None when neither
does. A payment-method correction follows it (routes/invoices.py), and so
does the repair of the one written backwards
(services/repair/reversed_method_corrections.py).
"""
from __future__ import annotations

from models import JournalEntryLine, SafeBoxTransaction, Voucher, db


def payment_direction(ip, old_safe_account_id=None):
    """Which way a payment's money went -- 'in' (received) or 'out' (paid
    out), from its own records: its safe row, else the side its voucher's
    entry took on the old safe's account. None when neither says.

    A correction follows it: «credit the old safe, debit the new» is money
    received put right; money paid out goes back to the old safe and out of
    the new one. Written both ways as 'in', 494.5 paid the Dewan and put
    right to the bank credited the cash box twice (JE-2026-07425, 8 Nov 2026)."""
    row = SafeBoxTransaction.query.filter_by(invoice_payment_id=ip.id).first()
    if row is not None and row.direction in ('in', 'out'):
        return row.direction
    voucher = db.session.get(Voucher, ip.source_voucher_id) if getattr(ip, 'source_voucher_id', None) else None
    if voucher is not None and voucher.journal_entry_id and old_safe_account_id:
        for line in JournalEntryLine.query.filter_by(journal_entry_id=voucher.journal_entry_id,
                                                     account_id=int(old_safe_account_id), is_deleted=False):
            if float(line.cash_credit or 0.0) > 0.005:
                return 'out'
            if float(line.cash_debit or 0.0) > 0.005:
                return 'in'
    return None
