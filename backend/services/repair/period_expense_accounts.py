"""The period expenses' two accounts made and mapped, once (ADR-090, phase 3).

A payment on a period expense goes to «مصروفات مقدَّمة» (an asset) or
«مصروفات مستحقة» (a liability), and a month's accrual the other way (law 4).
The chart has neither (ref_1112c, 14 Nov 2026). The code asks for the roles,
never a number (CHART-002): this makes each under the parent it is told and
maps its role, the mapping recorded (services/role_mappings.save). A role
already mapped is kept. dry_run (the default) writes it all in a savepoint and
rolls it back -- the numbers it shows are the ones it would make.
"""
from __future__ import annotations

from models import Account, db

MADE = (('prepaid_expenses', 'مصروفات مقدَّمة', 'asset', 'Asset'),
        ('accrued_expenses', 'مصروفات مستحقة', 'liability', 'Liability'))


def setup(*, by: str, prepaid_under: str, accrued_under: str, dry_run: bool = True) -> dict:
    from account_number_generator import get_next_account_number
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
    from employee_account_helpers import ensure_memo_for_account
    from services.role_mappings import save

    parents = {'prepaid_expenses': prepaid_under, 'accrued_expenses': accrued_under}
    plan = {'made': [], 'kept': []}
    savepoint = db.session.begin_nested()
    for role, name, kind, account_type in MADE:
        if get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, role):
            plan['kept'].append(role)
            continue
        parent = Account.query.filter_by(account_number=str(parents[role])).first()
        if parent is None or (parent.type or '').lower() != kind:
            savepoint.rollback()
            raise ValueError(f'الأب {parents[role]}: حساب {"أصول" if kind == "asset" else "خصوم"} موجود يُطلب')
        number = str(get_next_account_number(str(parent.account_number)))
        plan['made'].append({'role': role, 'number': number, 'name': name, 'under': parent.account_number})
        account = Account(account_number=number, name=name, type=account_type, transaction_type='cash',
                          tracks_weight=False, parent_id=parent.id)
        db.session.add(account)
        db.session.flush()
        ensure_memo_for_account(account)          # its weight twin, as every account of the chart
        save(DEFAULT_MAPPING_OPERATION_TYPE, role, account.id, by=by)
    db.session.flush()
    if dry_run:
        savepoint.rollback()
    else:
        savepoint.commit()
    return plan
