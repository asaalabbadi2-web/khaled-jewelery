"""The payment voucher of an invoice's own payment -- one writer for both postings (LINK-001).

Posted as it is saved, add_invoice wrote each cash payment a voucher: naming
the invoice, linked to its payment row, approved with the entry that carries
the payment. Posted later (held for approval), _create_deferred_payment_entries
wrote the entry lines and the safe rows and no voucher. Both now build it here.
The voucher is the document; the money moves in the invoice's entries.
"""
import json
from datetime import datetime

from models import Customer, Supplier, Voucher, VoucherAccountLine, db


class PaymentPartyMissing(LookupError):
    """The invoice names no supplier or customer the voucher can name (code: the error key)."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def invoice_payment_party(invoice):
    """(party_type, party_id, party_account_id) of the invoice's payment."""
    from party_account_service import ensure_customer_accounts, ensure_supplier_accounts
    if getattr(invoice, 'supplier_id', None):
        supplier = Supplier.query.get(int(invoice.supplier_id))
        if not supplier:
            raise PaymentPartyMissing('supplier_not_found')
        return 'supplier', int(supplier.id), int(ensure_supplier_accounts(supplier).financial.id)
    if getattr(invoice, 'customer_id', None):
        customer = Customer.query.get(int(invoice.customer_id))
        if not customer:
            raise PaymentPartyMissing('customer_not_found')
        return 'customer', int(customer.id), int(ensure_customer_accounts(customer).financial.id)
    raise PaymentPartyMissing('missing_party_for_payment_voucher')


def build_invoice_payment_voucher(invoice, payment_row, *, payment_method_id, safe_account_id, party,
                                  direction, created_by, line_notes=None):
    """The pending voucher of *payment_row*, its two lines, linked to the payment. The caller approves it."""
    from accounting.voucher_engine import generate_voucher_number
    party_type, party_id, party_account_id = party
    voucher_type = 'receipt' if direction == 'in' else 'payment'
    try:
        notes = json.dumps({'source': 'invoice_payment', 'invoice_id': int(invoice.id),
                            'invoice_payment_id': int(payment_row.id),
                            'payment_method_id': int(payment_method_id)}, ensure_ascii=False)
    except (TypeError, ValueError):
        notes = None
    amount = float(payment_row.amount or 0.0)
    voucher = Voucher(
        voucher_number=generate_voucher_number(voucher_type),
        voucher_type=voucher_type,
        date=getattr(invoice, 'date', None) or datetime.now(),
        party_type=party_type,
        customer_id=party_id if party_type == 'customer' else None,
        supplier_id=party_id if party_type == 'supplier' else None,
        amount_cash=amount,
        amount_gold=0.0,
        description=f"دفعة فاتورة {getattr(invoice, 'invoice_type_id', '')}".strip(),
        reference_type='invoice',
        reference_id=int(invoice.id),
        reference_number=str(getattr(invoice, 'invoice_type_id', '') or '') or None,
        notes=notes,
        created_by=created_by or 'system',
        status='pending',
    )
    db.session.add(voucher)
    db.session.flush()
    # This voucher is the one that actually creates the payment.
    payment_row.source_voucher_id = voucher.id
    safe_side, party_side = ('debit', 'credit') if direction == 'in' else ('credit', 'debit')
    db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=int(safe_account_id), line_type=safe_side,
                                      amount_type='cash', amount=amount, description=line_notes))
    db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=int(party_account_id), line_type=party_side,
                                      amount_type='cash', amount=amount, description=line_notes))
    db.session.flush()
    return voucher


def approve_invoice_payment_voucher(voucher, journal_entry, approved_by):
    """Approved with the entry that carries the payment -- posted, as the guard holds (ADR-035)."""
    voucher.status = 'approved'
    voucher.approved_at = datetime.now()
    voucher.approved_by = approved_by or 'system'
    voucher.journal_entry_id = journal_entry.id
