"""Each office's gold is a deposit, as money in a bank (ADR-052).

The owner (18 Oct 2026, «نموذج البنك»): the gold kept with an office -- bought
from it by a reservation, or sent to it -- is ours, held for us, and pays
suppliers. It sat on the office's supplier weight account (72100..., a
liability), so our gold read as the office's debt, a transfer from it could
not tell taking our deposit back from buying from it (AV-2026-00012), and its
balance flipped between «لنا» and «علينا».

Once, per office with a gold safe on its supplier account:
  - the parent (services/office_deposits): the role `office_gold_deposit_parent`. Unmapped, it is
    made -- «ذهب مودع لدى المكاتب» under the mapped gold inventory root, its
    weight twin under that root's twin (1330 / 71330 on production) -- and mapped;
  - the deposit: «ذهب مودع لدى <office>», a weight-only asset under it, and its
    safe at the place «deposit» -- stock, counted with the shop's gold;
  - the office's supplier takes it as its gold safe (a reservation's gold goes
    there), and the old safe on the supplier account is stopped;
  - what is ours on the supplier weight account, per karat, moves to the deposit
    in one entry at the run's date. Grams under DUST stay: a supplier's balance.

A second run finds every office done and writes nothing. Caller commits; the
CLI rolls back a dry run -- the run is the same, its writes are not kept.
"""
from __future__ import annotations

import json

from models import Account, AuditLog, Office, SafeBox, Supplier, db
from services.office_deposits import DEPOSIT_PARENT, deposit_of, deposit_parent, ensure_deposit  # noqa: F401
from services.repair.entries import write_entry

REFERENCE = 'office_gold_deposit'
KARATS = (18, 21, 22, 24)
DUST = 0.05


def _supplier_weight_account(office):
    cash = db.session.get(Account, office.account_category_id) if office.account_category_id else None
    twin = db.session.get(Account, cash.memo_account_id) if cash is not None and cash.memo_account_id else None
    return twin if twin is not None and twin.tracks_weight else None


def make_deposits(*, by, now) -> dict:
    """Run once: the parent, a deposit per office, and our gold moved to it."""
    from services.live_balances import live_balances_by_account_ids

    parent, parent_made = deposit_parent(by=by, create=True)
    out = {'parent': parent.account_number, 'parent_made': parent_made, 'offices': []}
    for office in Office.query.order_by(Office.id).all():
        supplier = db.session.get(Supplier, office.supplier_id) if office.supplier_id else None
        plan = {'office': office.name}
        out['offices'].append(plan)
        supplier_gold = _supplier_weight_account(office)
        if supplier is None or supplier_gold is None:
            plan['skipped'] = 'no supplier or no supplier weight account'
            continue
        current = db.session.get(SafeBox, supplier.default_safe_box_id) if supplier.default_safe_box_id else None
        if deposit_of(supplier) is None and (current is None or not current.holds_party_gold):
            plan['skipped'] = 'no gold safe with the office: a deposit is made when it holds gold of ours'
            continue
        deposit_safe, made = ensure_deposit(office, by=by, parent=parent)
        if made:
            plan.update({'made': db.session.get(Account, deposit_safe.account_id).account_number,
                         'stopped_safe': current.name if current is not None else None})
        plan['deposit'] = db.session.get(Account, deposit_safe.account_id).account_number

        balance = live_balances_by_account_ids([supplier_gold.id]).get(supplier_gold.id) or {}
        ours = {k: round(float(balance.get(f'{k}k') or 0.0), 3) for k in KARATS}
        moved = {k: v for k, v in ours.items() if v >= DUST}
        plan['left_on_supplier'] = {f'{k}k': v for k, v in ours.items() if v and k not in moved}
        if not moved:
            continue
        put = {'account_id': deposit_safe.account_id, 'description': f'وديعة {office.name} من حساب المورد'}
        take = {'account_id': supplier_gold.id, 'supplier_id': supplier.id,
                'description': f'نقل ذهبنا لدى {office.name} إلى حساب الوديعة'}
        for k, v in moved.items():
            put[f'debit_{k}k'], take[f'credit_{k}k'] = v, v
        entry = write_entry(date=now, description=f'نقل ذهبنا لدى {office.name} إلى «{deposit_safe.name}» (ADR-052)',
                            reference_type=REFERENCE, reference_id=office.id, lines=[put, take], by=by, now=now)
        plan.update({'moved': {f'{k}k': v for k, v in moved.items()}, 'entry': entry.entry_number})
        AuditLog.log_action(user_name=by, action='repair_office_gold_deposit', entity_type='Office',
                            entity_id=office.id, entity_number=office.name,
                            details=json.dumps(plan, ensure_ascii=False, default=str))
    return out
