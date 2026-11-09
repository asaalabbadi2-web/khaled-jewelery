"""Gold paid with a purchase, attributed to it after the fact (9 Nov 2026).

Until the fix in add_invoice, the purchase screen's «سداد ذهب للمورد» voucher
-- approved in the request, its notes' source 'invoice_gold_settlement' --
wrote no attribution row; the nightly check found it (GOLD_ATTRIBUTION_MISSING:
PV-2026-01515 and PV-2026-01518 on the 9 Nov backup). Each such voucher the
check finds gets its rows from the one writer
(sync_gold_attribution_after_voucher_approval), as the fix now writes them.
A voucher of any other source the check finds is said, not touched: whom it
paid is the employee's to declare. Nor a finding the owner accepted
(PV-2026-01293, 0.01 g, a rounding difference -- 12 Oct 2026): his decision
stands. dry_run (the default) writes nothing.
"""
from __future__ import annotations

import json

from models import AuditLog, Voucher, VoucherInvoiceGoldAttribution, db

SOURCE = 'invoice_gold_settlement'


def _source(voucher):
    try:
        notes = json.loads(voucher.notes or '{}')
    except (TypeError, ValueError):
        return None
    return notes.get('source') if isinstance(notes, dict) else None


def attribute_purchase_gold(*, by: str, dry_run: bool = True) -> dict:
    from services.books_invariants import check_gold_attribution_missing
    from services.gold_allocation_service import sync_gold_attribution_after_voucher_approval

    from models import ReconciliationFinding
    accepted = {r.subject_key for r in ReconciliationFinding.query.filter(
        ReconciliationFinding.kind == 'GOLD_ATTRIBUTION_MISSING', ReconciliationFinding.resolved_at.is_(None),
        ReconciliationFinding.accepted_at.isnot(None))}
    done, left = [], []
    for fact in check_gold_attribution_missing():
        voucher = db.session.get(Voucher, int(fact.subject_key.split(':', 1)[1]))
        item = {'voucher': voucher.voucher_number, 'voucher_id': voucher.id, 'invoice_id': voucher.reference_id,
                'gold_main_karat': fact.metric}
        if fact.subject_key in accepted:
            left.append({**item, 'why': 'accepted by the owner: his decision stands'})
            continue
        if _source(voucher) != SOURCE:
            left.append({**item, 'why': 'not the purchase screen\'s: whom it paid is declared, not inferred'})
            continue
        if not dry_run:
            try:
                with db.session.begin_nested():
                    sync_gold_attribution_after_voucher_approval(voucher)
            except ValueError as refused:
                left.append({**item, 'why': str(refused)})
                continue
            rows = VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=voucher.id).all()
            item['rows'] = [{'karat': r.karat, 'weight': r.weight, 'main': r.weight_main_karat} for r in rows]
            db.session.add(AuditLog(user_name=by, action='repair_purchase_gold_attribution', entity_type='Voucher',
                                    entity_id=voucher.id, entity_number=voucher.voucher_number,
                                    details=json.dumps(item, ensure_ascii=False)))
            db.session.flush()
        done.append(item)
    return {'attributed': done, 'left': left, 'dry_run': dry_run}
