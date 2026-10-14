#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Employee account helpers -- the parents are mapped roles, the employee's accounts linked (CHART-002).

An employee's personal account lives under the mapped role
employee_personal_parent (1700 on production); the payables under
employee_salary_payable_parent / _commission_ / _eos_ / employee_bonus_payable_parent
(2400, 2410, 2420, 2310), linked per employee in employee_account
(services/employee_accounts.py). The code creates an employee's own accounts
and their weight twins; never a parent -- the chart is data (ADR-046).
"""

# استخدم نفس الوحدة التي يهيئها app.py لتفادي إنشاء نسخة SQLAlchemy ثانية
from models import Account, db
from account_pair_service import link_accounts

from employee_account_naming import employee_personal_account_name

from account_number_generator import get_next_account_number

from typing import List, Optional




def _normalize_type(value: str) -> str:
    return (value or '').strip().lower()


def _memo_root_number_for_type(account_type: str) -> str:
    t = _normalize_type(account_type)
    if t == 'asset':
        return '71'
    if t == 'liability':
        return '72'
    if t == 'equity':
        return '73'
    if t == 'revenue':
        return '74'
    if t == 'expense':
        return '75'
    # Fallback: default to assets memo root.
    return '71'


def _ensure_memo_root(account_type: str) -> Optional[Account]:
    root_number = _memo_root_number_for_type(account_type)
    root = Account.query.filter_by(account_number=root_number).first()
    if root:
        return root

    # Create minimal memo root if missing.
    names = {
        '71': 'الأصول وزني',
        '72': 'الخصوم وزني',
        '73': 'حقوق الملكية وزني',
        '74': 'الإيرادات وزني',
        '75': 'المصروفات وزني',
    }

    root = Account(
        account_number=root_number,
        name=names.get(root_number, f'{root_number} (وزني)'),
        type=account_type or 'Asset',
        transaction_type='gold',
        tracks_weight=True,
        parent_id=None,
    )
    db.session.add(root)
    db.session.flush()
    return root


def ensure_memo_for_account(fin_account: Account) -> Optional[Account]:
    """Ensure a weight/memo parallel account exists and is linked.

    Works even when transaction_type='both' (where Account.create_parallel_account
    would early-return).
    """

    if not fin_account:
        return None

    # If already linked and exists, return it.
    if getattr(fin_account, 'memo_account_id', None):
        memo = Account.query.get(int(fin_account.memo_account_id))
        if memo:
            return memo

    from accounting.twins import twin_number
    memo_number = twin_number(fin_account.account_number)
    existing = Account.query.filter_by(account_number=memo_number).first()
    if existing:
        # الربط الثنائي عبر الخدمة المركزية فقط -- كانت هذه الدالة تضبط
        # اتجاهاً واحداً فقط (fin_account.memo_account_id) بلا أي تحديث
        # لمؤشر الحساب الوزني نفسه، وهي السبب الجذري لعشرات حالات
        # one_way_link لحسابات الموظفين المكتشفة على الإنتاج.
        link_accounts(fin_account, existing, created_by='employee_account_helpers')
        db.session.flush()
        return existing

    # Determine memo parent.
    memo_parent_id = None
    if getattr(fin_account, 'parent_id', None):
        parent = Account.query.get(int(fin_account.parent_id))
        if parent:
            # Ensure parent memo exists first.
            parent_memo = ensure_memo_for_account(parent)
            if parent_memo:
                memo_parent_id = parent_memo.id

    if memo_parent_id is None:
        memo_root = _ensure_memo_root(getattr(fin_account, 'type', 'Asset'))
        memo_parent_id = memo_root.id if memo_root else None

    memo_account = Account(
        account_number=memo_number,
        name=f"{fin_account.name} وزني",
        type=getattr(fin_account, 'type', 'Asset'),
        transaction_type='gold',
        tracks_weight=True,
        parent_id=memo_parent_id,
    )
    db.session.add(memo_account)
    db.session.flush()

    link_accounts(fin_account, memo_account, created_by='employee_account_helpers')
    db.session.flush()
    return memo_account


def ensure_employee_group_accounts(created_by: str = 'system'):
    """The employee structure's parents, by their roles (CHART-002, ADR-046).

    This built 170, 1700, 240, 2400-2420 and 2310 by their 2026 numbers when
    missing; the chart is data now -- the parents are mapped roles, and an
    unmapped one refuses (AccountNotMapped). Returns {role: account}.
    """
    from services.employee_accounts import PAYABLE_ROLES, PERSONAL_PARENT, parent_account

    roles = (PERSONAL_PARENT, *(parent for parent, _ in PAYABLE_ROLES.values()))
    return {role: parent_account(role) for role in roles}


def create_employee_account(employee_name, department='administration', created_by='system'):
    """The personal account of a new employee, under the mapped personal parent
    (1700 on production); the caller links it as Employee.account_id."""
    from services.employee_accounts import PERSONAL_PARENT, parent_account

    parent = parent_account(PERSONAL_PARENT)
    account = Account(
        account_number=get_next_account_number(str(parent.account_number)),
        name=employee_personal_account_name(employee_name),
        type='Asset',
        transaction_type='cash',
        parent_id=parent.id,
    )
    db.session.add(account)
    db.session.flush()
    # Ensure memo/weight parallel exists and is linked.
    ensure_memo_for_account(account)
    return account


def get_or_create_employee_payables_accounts(employee, created_by: str = 'system') -> List[Account]:
    """The employee's payable accounts -- salaries, commissions, end of service,
    bonuses -- by their links, made under their mapped parents when missing."""
    from services.employee_accounts import ensure_payable_accounts
    return ensure_payable_accounts(employee, by=created_by)


create_employee_payables_accounts = get_or_create_employee_payables_accounts
