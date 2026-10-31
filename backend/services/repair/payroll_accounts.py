"""The run's accounts made and mapped, once (PAYROLL-3; the owner, 1 Nov 2026).

The run's accrual credits the contributions payable and the penalties payable,
and debits the employer's share to the contributions expense -- three roles the
chart had no account for but the expense (5480 «تأمينات إجتماعية» on the 31
Oct copy). The code asks for the roles, never a number (CHART-002): this makes
the two liabilities under the parent it is told and maps the three, each
mapping recorded (services/role_mappings.save). A role already mapped is left
as it is. dry_run (the default) writes it all in a savepoint and rolls it
back -- the numbers it shows are the ones it would make.
"""
from models import Account, db

MADE = (('gosi_payable', 'التأمينات الاجتماعية المستحقة'),
        ('payroll_penalties_payable', 'جزاءات العاملين المستحقة'))


def setup(*, by: str, under: str, contributions_expense: str, dry_run: bool = True) -> dict:
    from account_number_generator import get_next_account_number
    from employee_account_helpers import ensure_memo_for_account
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
    from services.role_mappings import save

    parent = Account.query.filter_by(account_number=str(under)).first()
    if parent is None or (parent.type or '').lower() != 'liability':
        raise ValueError(f'الأب {under}: حساب خصوم موجود يُطلب')
    expense = Account.query.filter_by(account_number=str(contributions_expense)).first()
    if expense is None or (expense.type or '').lower() != 'expense':
        raise ValueError(f'{contributions_expense}: حساب مصروف موجود يُطلب')
    plan = {'made': [], 'mapped': [], 'kept': []}
    savepoint = db.session.begin_nested()
    for role, name in MADE:
        if get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, role):
            plan['kept'].append(role)
            continue
        number = str(get_next_account_number(str(parent.account_number)))
        plan['made'].append({'role': role, 'number': number, 'name': name, 'under': parent.account_number})
        account = Account(account_number=number, name=name, type='Liability', transaction_type='cash',
                          tracks_weight=False, parent_id=parent.id)
        db.session.add(account)
        db.session.flush()
        ensure_memo_for_account(account)          # its weight twin, as every account of the chart
        save(DEFAULT_MAPPING_OPERATION_TYPE, role, account.id, by=by)
    if get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'gosi_expense'):
        plan['kept'].append('gosi_expense')
    else:
        plan['mapped'].append({'role': 'gosi_expense', 'number': expense.account_number, 'name': expense.name})
        save(DEFAULT_MAPPING_OPERATION_TYPE, 'gosi_expense', expense.id, by=by)
    db.session.flush()
    if dry_run:
        savepoint.rollback()
    else:
        savepoint.commit()
    return plan
