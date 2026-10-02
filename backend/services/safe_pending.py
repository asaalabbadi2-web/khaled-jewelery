"""What waits for approval on each safe -- read only (the owner, 2 Oct 2026).

A safe's movement is written when its document posts (ADR-034): one truth for
the books. Beside the posted balance the safes screen shows what is pending,
so posted + pending = what should be in hand:

- a pending voucher's lines on a safe's account: debit in, credit out; cash
  in riyals, gold by karat;
- a held invoice's cash payments, on the safe its posting will use
  (posting_routes' own resolver), in or out by the invoice type;
- a held invoice's gold: the rows its posting will write, by karat
  (posting_routes.invoice_gold_plan -- the one rule for both).

A pending voucher that already has an entry is one of V0's inconsistent legacy
vouchers (stage 4) -- it waits for repair, not approval, and is left out. A
Nothing here writes.
"""
import json
from collections import defaultdict


def _empty():
    return {'cash': 0.0, 'weight': defaultdict(float), 'documents': set()}


def pending_by_safe() -> dict:
    """{safe_box_id: {'cash': float, 'weight': {'21k': g, ...}, 'documents': int}}"""
    from models import Invoice, PaymentMethod, SafeBox, Voucher, VoucherAccountLine
    from posting_routes import (
        _direction_for_invoice_cash, _is_receivable_pm, _resolve_cash_safe_box_id_for_invoice, invoice_gold_plan,
    )

    safe_by_account = {int(sb.account_id): int(sb.id) for sb in SafeBox.query.filter(SafeBox.account_id.isnot(None))}
    out = defaultdict(_empty)

    rows = (VoucherAccountLine.query.join(Voucher, Voucher.id == VoucherAccountLine.voucher_id)
            .filter(Voucher.status == 'pending',
                    # a pending voucher with an entry is V0's legacy (stage 4), not awaiting approval
                    Voucher.journal_entry_id.is_(None),
                    VoucherAccountLine.account_id.in_(list(safe_by_account) or [-1])).all())
    for line in rows:
        sid = safe_by_account[int(line.account_id)]
        sign = 1.0 if (line.line_type or '') == 'debit' else -1.0
        if (line.amount_type or '') == 'gold':
            out[sid]['weight'][f"{int(float(line.karat or 0))}k"] += sign * float(line.amount or 0.0)
        else:
            out[sid]['cash'] += sign * float(line.amount or 0.0)
        out[sid]['documents'].add(('voucher', int(line.voucher_id)))

    held = Invoice.query.filter(Invoice.is_posted.is_(False),
                                ~Invoice.status.in_(['rejected', 'cancelled'])).all()
    for invoice in held:
        sign = 1.0 if _direction_for_invoice_cash(invoice.invoice_type) == 'in' else -1.0
        for pay in list(getattr(invoice, 'payments', []) or []):
            pm = PaymentMethod.query.get(pay.payment_method_id) if pay.payment_method_id else None
            if _is_receivable_pm(pm):
                continue
            explicit = None
            try:
                notes = json.loads(pay.notes) if pay.notes else None
                if isinstance(notes, dict) and notes.get('safe_box_id'):
                    explicit = int(notes['safe_box_id'])
            except (TypeError, ValueError):
                explicit = None
            sid = _resolve_cash_safe_box_id_for_invoice(invoice=invoice, pm_obj=pm, explicit_safe_box_id=explicit)
            if sid is None:
                continue
            out[int(sid)]['cash'] += sign * float(pay.amount or 0.0)
            out[int(sid)]['documents'].add(('invoice', int(invoice.id)))
        # Its gold: the rows its posting will write -- the same plan (posting_routes.invoice_gold_plan).
        try:
            plan = invoice_gold_plan(invoice, posted=False)
        except Exception:
            plan = []
        for row in plan:
            gsign = 1.0 if row['direction'] == 'in' else -1.0
            for karat, grams in row['weights'].items():
                if grams > 0.0005:
                    out[row['safe_box_id']]['weight'][karat] += gsign * float(grams)
            out[row['safe_box_id']]['documents'].add(('invoice', int(invoice.id)))

    return {sid: {'cash': round(v['cash'], 2),
                  'weight': {k: round(w, 3) for k, w in v['weight'].items() if abs(w) > 1e-9},
                  'documents': len(v['documents'])}
            for sid, v in out.items()}
