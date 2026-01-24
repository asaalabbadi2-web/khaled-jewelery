#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Employee account helpers.

This project supports a dual ledger (cash + weight/memo). For employees, the
requested structure (per screenshots) is:

- Assets (debtors):
    - 170: أرصدة مدينة أخرى
        - 1700: حسابات الموظفين

- Liabilities (creditors):
    - 230: ذمم الموظفين
        - 2300: رواتب موظفين مستحقة
        - 2310: عولات بائعين ومشترين مستحقة
        - 2320: مخصص مكافئة نهاية الخدمة

All created/ensured accounts should have a weight (memo) parallel account:
    memo_number = '7' + financial_number

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


EMPLOYEE_DEBTORS_ROOT_NUMBER = '170'
EMPLOYEE_PERSONAL_PARENT_NUMBER = '1700'
EMPLOYEE_PAYABLES_ROOT_NUMBER = '230'


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

    memo_number = f"7{str(fin_account.account_number)}"
    existing = Account.query.filter_by(account_number=memo_number).first()
    if existing:
        fin_account.memo_account_id = existing.id
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

    fin_account.memo_account_id = memo_account.id
    db.session.flush()
    return memo_account


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

        Requested structure:
        - 170: أرصدة مدينة أخرى (تجميعي)
            - 1700: حسابات الموظفين (تجميعي)
        - 230: ذمم الموظفين (تجميعي)
            - 2300/2310/2320: مجموعات ذمم الموظفين
    """

    ensured: Dict[str, Account] = {}

    # 170 - other debtors under assets
    root_assets = Account.query.filter_by(account_number=EMPLOYEE_DEBTORS_ROOT_NUMBER).first()
    if not root_assets:
        inferred_parent = Account.query.filter_by(account_number='11').first() or _find_existing_parent_by_prefix('11')
        root_assets = _ensure_account(
            account_number=EMPLOYEE_DEBTORS_ROOT_NUMBER,
            name='أرصدة مدينة أخرى',
            acc_type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_account=inferred_parent,
        )
    ensured[EMPLOYEE_DEBTORS_ROOT_NUMBER] = root_assets
    ensure_memo_for_account(root_assets)

    # 1700 - employee personal accounts group under 170
    parent_1700 = Account.query.filter_by(account_number=EMPLOYEE_PERSONAL_PARENT_NUMBER).first()
    if not parent_1700:
        parent_1700 = _ensure_account(
            account_number=EMPLOYEE_PERSONAL_PARENT_NUMBER,
            name='حسابات الموظفين',
            acc_type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_account=root_assets,
        )
    ensured[EMPLOYEE_PERSONAL_PARENT_NUMBER] = parent_1700
    ensure_memo_for_account(parent_1700)

    # 230 - employee payables root under liabilities
    root_liab = Account.query.filter_by(account_number=EMPLOYEE_PAYABLES_ROOT_NUMBER).first()
    if not root_liab:
        inferred_parent = Account.query.filter_by(account_number='2').first() or _find_existing_parent_by_prefix('2')
        root_liab = _ensure_account(
            account_number=EMPLOYEE_PAYABLES_ROOT_NUMBER,
            name='ذمم الموظفين',
            acc_type='Liability',
            transaction_type='cash',
            tracks_weight=False,
            parent_account=inferred_parent,
        )
    ensured[EMPLOYEE_PAYABLES_ROOT_NUMBER] = root_liab
    ensure_memo_for_account(root_liab)

    # Detail groups under 230 for employee payables
    detail_groups: List[Tuple[str, str]] = [
        ('2300', 'رواتب موظفين مستحقة'),
        ('2310', 'عولات بائعين ومشترين مستحقة'),
        ('2320', 'مخصص مكافئة نهاية الخدمة'),
    ]

    for acc_num, name_ar in detail_groups:
        detail = Account.query.filter_by(account_number=acc_num).first()
        if not detail:
            detail = _ensure_account(
                account_number=acc_num,
                name=name_ar,
                acc_type='Liability',
                transaction_type='cash',
                tracks_weight=False,
                parent_account=root_liab,
            )
        ensured[acc_num] = detail
        ensure_memo_for_account(detail)

        # Backfill: ensure memo copies for any existing per-employee accounts under this group.
        try:
            children = Account.query.filter_by(parent_id=detail.id).all()
            for child in children:
                if getattr(child, 'transaction_type', None) == 'gold':
                    continue
                ensure_memo_for_account(child)
        except Exception:
            pass

    # Backfill: ensure memo copies for any existing employee personal accounts under 1700.
    try:
        personal_children = Account.query.filter_by(parent_id=parent_1700.id).all()
        for child in personal_children:
            if getattr(child, 'transaction_type', None) == 'gold':
                continue
            ensure_memo_for_account(child)
    except Exception:
        pass

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
    # Requested structure: employee personal accounts under 1700 (employee accounts group).
    parent_account = Account.query.filter_by(account_number=EMPLOYEE_PERSONAL_PARENT_NUMBER).first()
    if not parent_account:
        ensured = ensure_employee_group_accounts(created_by=created_by)
        parent_account = ensured.get(EMPLOYEE_PERSONAL_PARENT_NUMBER)
    if not parent_account:
        raise ValueError(f'تعذر تحديد/إنشاء حساب تجميعي للموظفين ({EMPLOYEE_PERSONAL_PARENT_NUMBER}).')

    account_number = get_next_employee_account_number(EMPLOYEE_PERSONAL_PARENT_NUMBER)
    
    # إنشاء الحساب
    account = Account(
        account_number=account_number,
        name=employee_personal_account_name(employee_name),
        type='Asset',
        transaction_type='cash',
        parent_id=parent_account.id,
    )
    
    db.session.add(account)
    db.session.flush()  # ensure account.id is available immediately

    # Ensure memo/weight parallel exists and is linked.
    ensure_memo_for_account(account)
    # لا نعمل commit هنا، سيتم في create_employee
    
    return account


def create_employee_payables_accounts(employee_name: str, created_by: str = 'system') -> List[Account]:
    """Create employee-specific payables accounts under 2300/2400/2500.

    Notes:
    - These accounts are not linked to the Employee model directly.
    - Intended for future payroll/benefits/obligations posting.
    """

    return get_or_create_employee_payables_accounts(employee_name, created_by=created_by)


def get_or_create_employee_payables_accounts(employee_name: str, created_by: str = 'system') -> List[Account]:
    """Idempotently ensure employee-specific payables accounts under (23) groups.

    Creates per-employee accounts under:
    - 2300 رواتب مستحقة
    - 2310 مكافآت مستحقة
    - 2320 مستحقات موظفين أخرى
    """

    ensured = ensure_employee_group_accounts(created_by=created_by)
    result: List[Account] = []

    specs = [
        ('2300', 'رواتب'),
        ('2310', 'مكافآت'),
        ('2320', 'أخرى'),
    ]

    for parent_num, category_ar in specs:
        parent = ensured.get(parent_num) or Account.query.filter_by(account_number=parent_num).first()
        if not parent:
            continue

        expected_name = employee_payable_account_name(employee_name, category_ar=category_ar)
        existing = Account.query.filter_by(parent_id=parent.id, name=expected_name).first()
        if existing:
            # Ensure memo exists for legacy rows.
            ensure_memo_for_account(existing)
            result.append(existing)
            continue

        acc_number = get_next_account_number(str(parent.account_number))
        account = Account(
            account_number=str(acc_number),
            name=expected_name,
            type='Liability',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=parent.id,
        )
        db.session.add(account)
        db.session.flush()
        ensure_memo_for_account(account)
        result.append(account)

    return result


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
