#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Helpers for creating employee gold safe + linked accounting account.

Requirement:
- الخزائن الذهبية تحت "صناديق الموظفين (عهد)" ضمن فرع "ذهب الكسر"

Implementation (matches the current chart-of-accounts):
- Ensure a grouping account exists: 71300011 "صناديق الموظفين (عهد)" under 7130001 "ذهب الكسر"
    (fallback to 7130 "المخزون وزني" if needed).
- Each employee gets a dedicated gold account under it (713000110, 713000111, ...),
    with tracks_weight=True and a linked SafeBox (gold, karat=None).
"""

from models import Account, SafeBox, db
from account_number_generator import get_next_account_number

from employee_account_naming import (
    employee_gold_custody_account_name,
    employee_gold_safe_name,
    group_account_name,
)

from typing import Optional


def ensure_employee_gold_group_account(created_by: str = 'system') -> Optional[Account]:
    """Ensure a parent/group account exists for employee gold safes.

    Returns:
        Account | None: the group account, or None if it cannot be ensured.
    """

    group = Account.query.filter_by(account_number='71300011').first()
    if group:
        desired = group_account_name('employee_gold_custody')
        if (group.name or '').strip() in ('', 'صناديق الموظفين (عهد)') and (group.name or '').strip() != desired:
            group.name = desired
            db.session.flush()
        return group

    parent = Account.query.filter_by(account_number='7130001').first()
    if not parent:
        parent = Account.query.filter_by(account_number='7130').first()
    if not parent:
        return None

    group = Account(
        account_number='71300011',
        name=group_account_name('employee_gold_custody'),
        type='asset',
        transaction_type='gold',
        tracks_weight=True,
        parent_id=parent.id,
    )
    db.session.add(group)
    db.session.flush()
    return group


def _next_child_number_under_group(group_account: Account) -> str:
    """Generate next account_number under a group account using chart numbering rules."""
    # Uses existing rules: for an 8-digit parent like 71300011, children are 713000110..713000119.
    candidate = get_next_account_number(str(group_account.account_number))
    while Account.query.filter_by(account_number=str(candidate)).first() is not None:
        candidate = str(int(candidate) + 1)
    return str(candidate)


def create_employee_gold_safe(employee_name: str, created_by: str = 'system', employee_code: Optional[str] = None):
    """Create (Account + SafeBox) for an employee gold custody safe.

    Returns:
        tuple[Account, SafeBox]

    Raises:
        ValueError if chart structure is missing.
    """

    group = ensure_employee_gold_group_account(created_by=created_by)
    if not group:
        raise ValueError('تعذر تحديد/إنشاء الحساب التجميعي لصناديق الموظفين (عهد) للذهب (71300011).')

    acc_number = _next_child_number_under_group(group)
    label = employee_name
    if employee_code:
        label = f'{employee_name} ({employee_code})'

    account = Account(
        account_number=acc_number,
        name=employee_gold_custody_account_name(label),
        type='asset',
        transaction_type='gold',
        tracks_weight=True,
        parent_id=group.id,
    )
    db.session.add(account)
    db.session.flush()

    safe = SafeBox(
        name=employee_gold_safe_name(employee_name),
        name_en=None,
        safe_type='gold',
        account_id=account.id,
        karat=None,
        is_active=True,
        is_default=False,
        notes='خزينة ذهب خاصة بالموظف (متعددة العيارات)',
        created_by=created_by,
    )
    db.session.add(safe)
    db.session.flush()

    return account, safe
