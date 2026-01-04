#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
دوال مساعدة لإنشاء حسابات الموظفين تلقائياً
يتبع نفس نهج العملاء والموردين
"""

# استخدم نفس الوحدة التي يهيئها app.py لتفادي إنشاء نسخة SQLAlchemy ثانية
from models import Account, db


def ensure_employee_group_accounts(created_by: str = 'system'):
    """Ensure required employee grouping accounts exist.

    This makes employee creation robust on fresh databases where seed scripts
    have not been executed yet.
    """
    # الحساب التجميعي الرئيسي
    main_account = Account.query.filter_by(account_number='130').first()
    if not main_account:
        main_account = Account(
            account_number='130',
            name='حسابات الموظفين',
            type='asset',
            transaction_type='cash',
            parent_id=None,
        )
        db.session.add(main_account)
        db.session.flush()

    # معالجة تعارض قديم: إذا كان 1300 مستخدمًا كـ "سلف موظفين" ننقله إلى 1400
    old_advances_account = Account.query.filter_by(account_number='1300').first()
    if old_advances_account and (old_advances_account.name or '').strip() == 'سلف موظفين':
        new_advances_account = Account.query.filter_by(account_number='1400').first()
        if not new_advances_account:
            old_advances_account.account_number = '1400'
            old_advances_account.parent_id = None

    # الحسابات التجميعية الفرعية حسب الأقسام
    departments = [
        ('1300', 'موظفو الإدارة'),
        ('1310', 'موظفو المبيعات'),
        ('1320', 'موظفو الصيانة'),
        ('1330', 'موظفو المحاسبة'),
        ('1340', 'موظفو المستودعات'),
    ]

    for acc_num, name_ar in departments:
        account = Account.query.filter_by(account_number=acc_num).first()
        if not account:
            account = Account(
                account_number=acc_num,
                name=name_ar,
                type='asset',
                transaction_type='cash',
                parent_id=main_account.id,
            )
            db.session.add(account)

    # حساب السلف التجميعي
    advances_account = Account.query.filter_by(account_number='1400').first()
    if not advances_account:
        advances_account = Account(
            account_number='1400',
            name='سلف موظفين',
            type='asset',
            transaction_type='cash',
            parent_id=None,
        )
        db.session.add(advances_account)

    # Keep changes in the current transaction; caller will commit.
    db.session.flush()

    return main_account

def get_next_employee_account_number(department_code='1300'):
    """
    توليد رقم الحساب التالي لموظف جديد ضمن قسم محدد
    
    Args:
        department_code: رقم القسم (1300 للإدارة، 1310 للمبيعات، إلخ)
    
    Returns:
        str: رقم الحساب التالي المتاح (مثل: 130000، 130001...)
    
    Raises:
        ValueError: إذا تجاوزت السعة المتاحة للقسم
    """
    # تحديد النطاق بناءً على القسم
    # مثلاً: إذا كان القسم '1300'، النطاق 130000-130999
    start_range = int(department_code + '000')
    end_range = int(department_code + '999')
    
    # البحث عن آخر رقم حساب في هذا النطاق
    last_account = Account.query.filter(
        Account.account_number >= str(start_range),
        Account.account_number <= str(end_range)
    ).order_by(Account.account_number.desc()).first()
    
    if last_account:
        last_number = int(last_account.account_number)
        next_number = last_number + 1
    else:
        # أول موظف في هذا القسم
        next_number = start_range
    
    # تحقق من عدم تجاوز النطاق
    if next_number > end_range:
        raise ValueError(
            f"تجاوزت السعة المتاحة للقسم {department_code}. "
            f"الحد الأقصى: {end_range - start_range + 1} موظف"
        )
    
    return str(next_number)


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
    # تحديد رمز القسم
    department_codes = {
        'administration': '1300',  # موظفو الإدارة
        'sales': '1310',            # موظفو المبيعات
        'maintenance': '1320',      # موظفو الصيانة
        'accounting': '1330',       # موظفو المحاسبة
        'warehouse': '1340',        # موظفو المستودعات
    }
    
    department_code = department_codes.get(department)
    if not department_code:
        raise ValueError(
            f"قسم غير صحيح: {department}. "
            f"الأقسام المتاحة: {', '.join(department_codes.keys())}"
        )
    
    # الحصول على رقم الحساب التالي
    account_number = get_next_employee_account_number(department_code)
    
    # التحقق من وجود الحساب التجميعي للقسم
    parent_account = Account.query.filter_by(account_number=department_code).first()
    if not parent_account:
        raise ValueError(
            f"الحساب التجميعي للقسم {department_code} غير موجود. "
            "يرجى تشغيل seed_employee_accounts.py أولاً"
        )
    
    # إنشاء الحساب
    account = Account(
        account_number=account_number,
        name=f"ح/ {employee_name}",
        type='asset',
        transaction_type='cash',
        parent_id=parent_account.id
    )
    
    db.session.add(account)
    # لا نعمل commit هنا، سيتم في create_employee
    
    return account


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
