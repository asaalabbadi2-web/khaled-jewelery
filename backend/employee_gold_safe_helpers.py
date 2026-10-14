#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Helpers for creating employee gold safe + linked accounting account.

Requirement:
- الخزائن الذهبية تحت "حساب عهدة ذهب الموظفين وزني" ضمن فرع "مخزون ذهب كسر وزني"

Implementation:
- The grouping account is the mapped role employee_gold_custody_parent (71310001 on production).
- Each employee gets a dedicated gold account under it, with tracks_weight=True
    and a linked SafeBox (gold, karat=None).
"""

from models import Account, SafeBox, db
from account_number_generator import get_next_account_number

from employee_account_naming import (
    employee_gold_custody_account_name,
    employee_gold_safe_name,
)

from typing import Optional


def ensure_employee_gold_group_account(created_by: str = 'system') -> Optional[Account]:
    """The group employee gold safes live under: a mapped role (71310001 on
    production; CHART-002, ADR-046).

    This renamed, re-parented and renumbered accounts on every employee
    created -- 71300011 and 71310000 (the main scrap safe's weight account)
    treated as legacy groups whose children it moved -- and created 71310001
    when missing. The chart is data: an unmapped role refuses."""
    from services.employee_accounts import GOLD_CUSTODY_PARENT, parent_account
    return parent_account(GOLD_CUSTODY_PARENT)


def _next_child_number_under_group(group_account: Account) -> str:
    """Generate next account_number under a group account using chart numbering rules."""
    # Uses existing rules: for an 8-digit parent like 71310001, children are 9-digit numbers.
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
