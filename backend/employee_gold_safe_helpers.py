#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Helpers for creating employee gold safe + linked accounting account.

Requirement:
- الخزائن الذهبية تحت "حساب عهدة ذهب الموظفين وزني" ضمن فرع "مخزون ذهب كسر وزني"

Implementation (matches the standard chart-of-accounts):
- Ensure a grouping account exists: 71310001 "حساب عهدة ذهب الموظفين وزني" under 71310 "مخزون ذهب كسر وزني"
    (fallback to 7130 "المخزون وزني" if needed).
- Each employee gets a dedicated gold account under it (e.g. 713100010, 713100011, ...),
    with tracks_weight=True and a linked SafeBox (gold, karat=None).
"""

from models import Account, SafeBox, JournalEntryLine, db
from account_number_generator import get_next_account_number

from employee_account_naming import (
    employee_gold_custody_account_name,
    employee_gold_safe_name,
    group_account_name,
)

from typing import Optional


def _normalize_employee_gold_group(group: Account, parent: Account) -> None:
    """Normalize standard fields/parent for the employee gold custody group account."""
    desired = group_account_name('employee_gold_custody')
    if (group.name or '').strip() != desired:
        group.name = desired
    group.type = group.type or 'asset'
    group.transaction_type = group.transaction_type or 'gold'
    group.tracks_weight = True
    if group.parent_id != parent.id:
        group.parent_id = parent.id
    db.session.add(group)


def _migrate_legacy_employee_gold_children(group: Account) -> None:
    """Move children from legacy/incorrect employee gold group accounts under the standard group."""
    for legacy_no in ('71300011', '71310000'):
        legacy = Account.query.filter_by(account_number=legacy_no).first()
        if not legacy or legacy.id == group.id:
            continue

        legacy_children = Account.query.filter_by(parent_id=legacy.id).all()
        for child in legacy_children:
            child.parent_id = group.id
            # Keep account_id stable; normalize numbering to the new sequence if needed.
            if not str(child.account_number).startswith('71310001'):
                child.account_number = _next_child_number_under_group(group)
            db.session.add(child)

        # Keep the legacy group as-is (id stable), but it becomes empty.
        db.session.add(legacy)

        # If the legacy group is the known-wrong one (71300011) and is now fully orphaned,
        # delete it to avoid confusing duplicates in the chart UI.
        if legacy_no == '71300011':
            remaining_children = Account.query.filter_by(parent_id=legacy.id).count()
            safe_refs = SafeBox.query.filter_by(account_id=legacy.id).count()
            jl_refs = JournalEntryLine.query.filter_by(account_id=legacy.id).count()
            if remaining_children == 0 and safe_refs == 0 and jl_refs == 0:
                db.session.delete(legacy)


def ensure_employee_gold_group_account(created_by: str = 'system') -> Optional[Account]:
    """Ensure a parent/group account exists for employee gold safes.

    Returns:
        Account | None: the group account, or None if it cannot be ensured.
    """

    parent = Account.query.filter_by(account_number='71310').first()
    if not parent:
        parent = Account.query.filter_by(account_number='7130').first()
    if not parent:
        return None

    # Standard group account number:
    group = Account.query.filter_by(account_number='71310001').first()
    if group:
        _normalize_employee_gold_group(group, parent)
        _migrate_legacy_employee_gold_children(group)
        db.session.flush()
        return group

    # If an incorrect-but-recent group exists (71310000) and the standard doesn't, rename it.
    group_71310000 = Account.query.filter_by(account_number='71310000').first()
    if group_71310000 and not Account.query.filter_by(account_number='71310001').first():
        group_71310000.account_number = '71310001'
        _normalize_employee_gold_group(group_71310000, parent)
        _migrate_legacy_employee_gold_children(group_71310000)
        db.session.flush()
        return group_71310000

    # Otherwise, create the standard group account.
    group = Account(
        account_number='71310001',
        name=group_account_name('employee_gold_custody'),
        type='asset',
        transaction_type='gold',
        tracks_weight=True,
        parent_id=parent.id,
    )
    db.session.add(group)
    db.session.flush()
    _migrate_legacy_employee_gold_children(group)
    db.session.flush()
    return group


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
    if not group:
        raise ValueError('تعذر تحديد/إنشاء الحساب التجميعي لعهدة ذهب الموظفين (71310001).')

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
