"""An invoice payment's line, said by its own payment (the owner, 31 Oct 2026).

«في كشف حساب البنك إذا كان الدفع للفاتورة تحويل لا يتم توضيح ذلك في الكشف».
Every payment of an invoice shares one entry (reference_type
'invoice_payments'), and the statements said the entry's description: the
bank's row for sale 1785's transfer read «دفعات فاتورة SELL-2026-1785
(RV-2026-02155, RV-2026-02156, RV-2026-02157)» -- no «تحويل», and the Mada
and cash vouchers that never reached the bank. The line's own wording said
«استلام نقد» whatever the method.

A statement now says each such line as its payment: its method, its invoice,
its voucher -- «تحويل — دفعة فاتورة SELL-2026-1785 (RV-2026-02156)». Read at
the statement, so the past reads so too and no row is written. The payment is
the line's voucher's (source_voucher_id, the newer lines), else the «دفعة #n»
its wording names when that payment is its invoice's; a line found by neither
keeps the entry's description.
"""
from __future__ import annotations

import re

_PAYMENT_NO = re.compile(r'دفعة #(\d+)')
_VOUCHER_NO = re.compile(r'\(([A-Z]+-\d{4}-\d+)\)')

KIND = 'invoice_payments'


def describe(lines) -> dict:
    """{line id: its payment's description} for the lines of invoice payments."""
    from models import InvoicePayment, PaymentMethod, Voucher

    lines = [l for l in lines if getattr(getattr(l, 'journal_entry', None), 'reference_type', None) == KIND]
    if not lines:
        return {}
    voucher_ids = {l.source_voucher_id for l in lines if l.source_voucher_id}
    payment_ids = {int(m.group(1)) for l in lines if not l.source_voucher_id
                   for m in [_PAYMENT_NO.search(l.description or '')] if m}

    by_voucher, by_id = {}, {}
    if voucher_ids:
        for p in InvoicePayment.query.filter(InvoicePayment.source_voucher_id.in_(voucher_ids)).all():
            by_voucher[p.source_voucher_id] = p
    if payment_ids:
        by_id = {p.id: p for p in InvoicePayment.query.filter(InvoicePayment.id.in_(payment_ids)).all()}
    method_ids = {p.payment_method_id for p in [*by_voucher.values(), *by_id.values()] if p.payment_method_id}
    methods = dict(PaymentMethod.query.filter(PaymentMethod.id.in_(method_ids))
                   .with_entities(PaymentMethod.id, PaymentMethod.name).all()) if method_ids else {}
    numbers = dict(Voucher.query.filter(Voucher.id.in_(voucher_ids))
                   .with_entities(Voucher.id, Voucher.voucher_number).all()) if voucher_ids else {}

    out = {}
    for line in lines:
        je = line.journal_entry
        if line.source_voucher_id:
            payment = by_voucher.get(line.source_voucher_id)
        else:
            m = _PAYMENT_NO.search(line.description or '')
            payment = by_id.get(int(m.group(1))) if m else None
            if payment is not None and payment.invoice_id != je.reference_id:
                payment = None            # a number that is not this invoice's payment
        if payment is None or payment.payment_method_id not in methods:
            continue
        voucher = numbers.get(line.source_voucher_id)
        if not voucher:
            m = _VOUCHER_NO.search(line.description or '')
            voucher = m.group(1) if m else None
        invoice = je.reference_number or je.reference_id
        out[line.id] = (f'{methods[payment.payment_method_id]} — دفعة فاتورة {invoice}'
                        + (f' ({voucher})' if voucher else ''))
    return out


def method_word(payment_id) -> str:
    """What a payment line says it is as it is written: its method's name --
    «تحويل», «مدى», «نقداً» -- not «نقد» whatever it was (31 Oct 2026)."""
    from models import InvoicePayment, PaymentMethod, db
    payment = db.session.get(InvoicePayment, int(payment_id)) if payment_id else None
    method = db.session.get(PaymentMethod, payment.payment_method_id) if payment and payment.payment_method_id else None
    return (method.name or '').strip() if method and (method.name or '').strip() else 'نقد'
