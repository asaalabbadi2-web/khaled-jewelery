#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Employee account helpers.

✨ Updated to support a chart-of-accounts structure where employee-related
accounts live under these grouping numbers:

- 1700: حسابات الموظفين (تفصيلي تحتها)
- 1710: سلف الموظفين (تفصيلي تحتها)
- 230/240/250: مجاميع التزامات الموظفين (اختياري إنشاء تفصيلي تحت 2300/2400/2500)

The helpers remain defensive: they create missing grouping accounts when
possible, without force-changing existing account parents/types.
"""

# استخدم نفس الوحدة التي يهيئها app.py لتفادي إنشاء نسخة SQLAlchemy ثانية
from models import Account, db

from employee_account_naming import (
    employee_payable_account_name,
    employee_personal_account_name,
    group_account_name,
)

from account_number_generator import get_next_account_number

from typing import Dict, List, Optional, Tuple


def _digits_only(value: str) -> str:
    return ''.join(ch for ch in str(value or '').strip() if ch.isdigit())


def _find_existing_parent_by_prefix(account_number: str) -> Optional[Account]:
    """Try to find a reasonable parent by stripping digits from the end.

    Example: 230 -> 23 -> 2
    """

    digits = _digits_only(account_number)
    while len(digits) > 1:
        digits = digits[:-1]
        parent = Account.query.filter_by(account_number=digits).first()
        if parent:
            return parent
    return None


def _ensure_account(
    *,
    account_number: str,
    name: str,
    acc_type: str,
    transaction_type: str,
    tracks_weight: bool,
    parent_account: Optional[Account],
) -> Account:
    existing = Account.query.filter_by(account_number=str(account_number)).first()
    if existing:
        # Keep it non-destructive: only normalize the name if empty.
        if not (existing.name or '').strip():
            existing.name = name
            db.session.flush()
        return existing

    account = Account(
        account_number=str(account_number),
        name=name,
        type=acc_type,
        transaction_type=transaction_type,
        tracks_weight=tracks_weight,
        parent_id=(parent_account.id if parent_account else None),
    )
    db.session.add(account)
    db.session.flush()
    return account


def ensure_employee_group_accounts(created_by: str = 'system'):
    """Ensure required employee grouping accounts exist.

    Primary structure (requested):
    - 1700: حسابات الموظفين
    - 1710: سلف الموظفين (prefer as child of 1700 if created here)
    - 230/240/250: مجاميع التزامات الموظفين
      - create detail group accounts 2300/2400/2500 for per-employee accounts.

    Legacy compatibility:
    - Keeps existing 130/13xx and 1400 untouched if present.
    """

    # 1700 - حسابات الموظفين
    parent_1700 = Account.query.filter_by(account_number='1700').first()
    if not parent_1700:
        inferred_parent = _find_existing_parent_by_prefix('1700')
        parent_1700 = _ensure_account(
            account_number='1700',
            name=group_account_name('employees'),
            acc_type='asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_account=inferred_parent,
        )

    # 1710 - سلف الموظفين (prefer under 1700)
    parent_1710 = Account.query.filter_by(account_number='1710').first()
    if not parent_1710:
        parent_1710 = _ensure_account(
            account_number='1710',
            name=group_account_name('employee_advances'),
            acc_type='asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_account=parent_1700,
        )

    # 230/240/250 - employee payables/obligations group accounts
    payables_groups: Dict[str, Tuple[str, str]] = {
        '230': (group_account_name('employee_payables_salary'), '2300'),
        '240': (group_account_name('employee_payables_bonus'), '2400'),
        '250': (group_account_name('employee_payables_other'), '2500'),
    }

    ensured: Dict[str, Account] = {
        '1700': parent_1700,
        '1710': parent_1710,
    }

    for parent_num, (parent_name, detail_num) in payables_groups.items():
        parent = Account.query.filter_by(account_number=parent_num).first()
        if not parent:
            inferred_parent = _find_existing_parent_by_prefix(parent_num)
            parent = _ensure_account(
                account_number=parent_num,
                name=parent_name,
                acc_type='liability',
                transaction_type='cash',
                tracks_weight=False,
                parent_account=inferred_parent,
            )

        detail = Account.query.filter_by(account_number=detail_num).first()
        if not detail:
            detail = _ensure_account(
                account_number=detail_num,
                name=parent_name,
                acc_type='liability',
                transaction_type='cash',
                tracks_weight=False,
                parent_account=parent,
            )

        ensured[parent_num] = parent
        ensured[detail_num] = detail

    # Keep changes in the current transaction; caller will commit.
    db.session.flush()
    return ensured

def get_next_employee_account_number(parent_account_number: str = '1700') -> str:
    """Generate next employee account number under the requested parent."""
    return get_next_account_number(str(parent_account_number))


def create_employee_account(employee_name, department='administration', created_by='system'):
    """
    إنشاء حساب تلقائي لموظف جديد
    
    Args:
        employee_name: اسم الموظف
        department: القسم (administration, sales, maintenance, accounting, warehouse)
        created_by: المستخدم المُنشئ
    
    Returns:
        Account: الحساب المُنشأ
    
    Raises:
        ValueError: إذا كان القسم غير صحيح أو تجاوزت السعة
    """
    # Primary requested structure: all employee personal accounts under 1700.
    parent_account = Account.query.filter_by(account_number='1700').first()
    if not parent_account:
        # Be defensive on fresh DBs.
        ensured = ensure_employee_group_accounts(created_by=created_by)
        parent_account = ensured.get('1700')
    if not parent_account:
        raise ValueError('تعذر تحديد/إنشاء الحساب التجميعي للموظفين (1700).')

    account_number = get_next_employee_account_number('1700')
    
    # إنشاء الحساب
    account = Account(
        account_number=account_number,
        name=employee_personal_account_name(employee_name),
        type='asset',
        transaction_type='cash',
        parent_id=parent_account.id,
    )
    
    db.session.add(account)
    # لا نعمل commit هنا، سيتم في create_employee
    
    return account


def create_employee_payables_accounts(employee_name: str, created_by: str = 'system') -> List[Account]:
    """Create employee-specific payables accounts under 2300/2400/2500.

    Notes:
    - These accounts are not linked to the Employee model directly.
    - Intended for future payroll/benefits/obligations posting.
    """

    ensured = ensure_employee_group_accounts(created_by=created_by)
    created: List[Account] = []

    specs = [
        ('2300', f'مستحقات رواتب {employee_name}'),
        ('2400', f'مستحقات مكافآت {employee_name}'),
        ('2500', f'مستحقات أخرى {employee_name}'),
    ]

    for parent_num, acc_name in specs:
        parent = ensured.get(parent_num) or Account.query.filter_by(account_number=parent_num).first()
        if not parent:
            continue

        acc_number = get_next_account_number(str(parent.account_number))
        account = Account(
            account_number=str(acc_number),
            name=employee_payable_account_name(
                employee_name,
                category_ar='رواتب' if parent_num == '2300' else 'مكافآت' if parent_num == '2400' else 'أخرى',
            ),
            type='liability',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=parent.id,
        )
        db.session.add(account)
        db.session.flush()
        created.append(account)

    return created


def get_employee_department_from_code(employee_code):
    """
    استخراج القسم من كود الموظف أو تخمينه من المسمى الوظيفي
    
    Args:
        employee_code: كود الموظف (مثل: EMP-2025-0001)
    
    Returns:
        str: رمز القسم (administration, sales, etc.) - افتراضي: administration
    """
    # يمكن تطوير هذه الدالة لاستخراج القسم من الكود إذا كان متضمناً
    # حالياً: نرجع القسم الافتراضي
    return 'administration'


def get_department_summary():
    """
    الحصول على ملخص لكل قسم وعدد الموظفين فيه
    
    Returns:
        list: قائمة بمعلومات الأقسام
    """
    # Legacy summary (kept for backwards compatibility)
    departments = [
        ('1300', 'موظفو الإدارة', 'Administration'),
        ('1310', 'موظفو المبيعات', 'Sales'),
        ('1320', 'موظفو الصيانة', 'Maintenance'),
        ('1330', 'موظفو المحاسبة', 'Accounting'),
        ('1340', 'موظفو المستودعات', 'Warehouse'),
    ]
    
    summary = []
    for code, name_ar, name_en in departments:
        parent = Account.query.filter_by(account_number=code).first()
        if not parent:
            continue
        
        # عدّ الموظفين
        start_range = f"{code}000"
        end_range = f"{code}999"
        
        count = Account.query.filter(
            Account.account_number >= start_range,
            Account.account_number <= end_range
        ).count()
        
        summary.append({
            'code': code,
            'name_ar': name_ar,
            'name_en': name_en,
            'employee_count': count,
            'capacity': 1000,
            'available': 1000 - count,
            'parent_id': parent.id
        })
    
    return summary
