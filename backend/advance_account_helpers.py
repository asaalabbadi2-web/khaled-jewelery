#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
دوال مساعدة لإدارة حسابات السلف التفصيلية
كل موظف له حساب سلفة خاص مرتبط بحسابه الشخصي
"""

from backend.models import Account, Employee, db

def get_next_advance_account_number():
    """
    توليد رقم الحساب التالي لسلفة جديدة
    
    Returns:
        str: رقم الحساب التالي المتاح (مثل: 140000، 140001...)
    
    Raises:
        ValueError: إذا تجاوزت السعة المتاحة (10,000 سلفة)
    """
    # نطاق حسابات السلف: 140000 - 149999
    start_range = 140000
    end_range = 149999
    
    # البحث عن آخر رقم حساب سلفة
    last_account = Account.query.filter(
        Account.account_number >= str(start_range),
        Account.account_number <= str(end_range)
    ).order_by(Account.account_number.desc()).first()
    
    if last_account:
        last_number = int(last_account.account_number)
        next_number = last_number + 1
    else:
        # أول حساب سلفة
        next_number = start_range
    
    # تحقق من عدم تجاوز النطاق
    if next_number > end_range:
        raise ValueError(
            f"تجاوزت السعة المتاحة لحسابات السلف. "
            f"الحد الأقصى: {end_range - start_range + 1} سلفة"
        )
    
    return str(next_number)


def create_advance_account_for_employee(employee_id, created_by='system'):
    """
    إنشاء حساب سلفة تلقائي لموظف
    
    Args:
        employee_id: معرّف الموظف
        created_by: المستخدم المُنشئ
    
    Returns:
        Account: حساب السلفة المُنشأ
    
    Raises:
        ValueError: إذا كان الموظف غير موجود أو ليس له حساب شخصي
    """
    # جلب بيانات الموظف
    employee = Employee.query.get(employee_id)
    if not employee:
        raise ValueError(f"الموظف {employee_id} غير موجود")
    
    if not employee.account_id:
        raise ValueError(
            f"الموظف {employee.name} ليس له حساب شخصي. "
            "يجب إنشاء حساب للموظف أولاً قبل إنشاء حساب السلفة"
        )
    
    # التحقق من عدم وجود حساب سلفة مسبقاً
    existing_advance = get_employee_advance_account(employee_id)
    if existing_advance:
        return existing_advance
    
    # التحقق من وجود الحساب التجميعي للسلف
    parent_account = Account.query.filter_by(account_number='1400').first()
    if not parent_account:
        raise ValueError(
            "الحساب التجميعي للسلف (1400) غير موجود. "
            "يرجى تشغيل seed_employee_accounts.py أولاً"
        )
    
    # الحصول على رقم الحساب التالي
    account_number = get_next_advance_account_number()
    
    # إنشاء حساب السلفة
    advance_account = Account(
        account_number=account_number,
        name=f"سلفة {employee.name}",
        type='asset',
        transaction_type='cash',
        parent_id=parent_account.id
    )
    
    db.session.add(advance_account)
    # لا نعمل commit هنا، سيتم خارجياً
    
    return advance_account


def get_employee_advance_account(employee_id):
    """
    الحصول على حساب السلفة الخاص بموظف
    
    Args:
        employee_id: معرّف الموظف
    
    Returns:
        Account | None: حساب السلفة أو None إذا لم يكن موجوداً
    """
    employee = Employee.query.get(employee_id)
    if not employee:
        return None
    
    # البحث بالاسم - كل موظف له حساب سلفة واحد باسمه
    advance_account = Account.query.filter(
        Account.account_number >= '140000',
        Account.account_number <= '149999',
        Account.name == f"سلفة {employee.name}"
    ).first()
    
    return advance_account


def get_or_create_employee_advance_account(employee_id, created_by='system'):
    """
    الحصول على حساب السلفة أو إنشاؤه إذا لم يكن موجوداً
    
    Args:
        employee_id: معرّف الموظف
        created_by: المستخدم المُنشئ
    
    Returns:
        Account: حساب السلفة
    """
    existing = get_employee_advance_account(employee_id)
    if existing:
        return existing
    
    return create_advance_account_for_employee(employee_id, created_by)


def get_employee_advance_balance(employee_id):
    """
    الحصول على رصيد سلفة الموظف الحالي
    
    Args:
        employee_id: معرّف الموظف
    
    Returns:
        dict: {'account_id': int, 'account_number': str, 'balance': float}
    """
    from sqlalchemy import func
    from models import JournalEntryLine
    
    advance_account = get_employee_advance_account(employee_id)
    if not advance_account:
        return {
            'account_id': None,
            'account_number': None,
            'balance': 0.0,
            'has_account': False
        }
    
    # حساب الرصيد من سطور القيد
    debit_sum = db.session.query(
        func.coalesce(func.sum(JournalEntryLine.cash_debit), 0)
    ).filter(
        JournalEntryLine.account_id == advance_account.id
    ).scalar() or 0.0
    
    credit_sum = db.session.query(
        func.coalesce(func.sum(JournalEntryLine.cash_credit), 0)
    ).filter(
        JournalEntryLine.account_id == advance_account.id
    ).scalar() or 0.0
    
    balance = debit_sum - credit_sum
    
    return {
        'account_id': advance_account.id,
        'account_number': advance_account.account_number,
        'account_name': advance_account.name,
        'balance': balance,
        'has_account': True
    }


def get_all_advances_summary():
    """
    الحصول على ملخص جميع السلف المستحقة
    
    Returns:
        list: قائمة بمعلومات السلف مع الأرصدة
    """
    from sqlalchemy import func
    from models import JournalEntryLine
    
    # جلب جميع حسابات السلف
    advance_accounts = Account.query.filter(
        Account.account_number >= '140000',
        Account.account_number <= '149999'
    ).all()
    
    summary = []
    total_advances = 0.0
    
    for account in advance_accounts:
        # حساب الرصيد
        debit_sum = db.session.query(
            func.coalesce(func.sum(JournalEntryLine.cash_debit), 0)
        ).filter(
            JournalEntryLine.account_id == account.id
        ).scalar() or 0.0
        
        credit_sum = db.session.query(
            func.coalesce(func.sum(JournalEntryLine.cash_credit), 0)
        ).filter(
            JournalEntryLine.account_id == account.id
        ).scalar() or 0.0
        
        balance = debit_sum - credit_sum
        
        # تجاوز الحسابات بدون رصيد
        if abs(balance) < 0.01:
            continue
        
        # استخراج معلومات الموظف من اسم الحساب
        # الاسم بصيغة: "سلفة أحمد محمد"
        employee_name = account.name.replace('سلفة ', '') if account.name.startswith('سلفة ') else None
        employee_code = None
        employee_account = None
        
        # محاولة العثور على الموظف
        if employee_name:
            employee = Employee.query.filter_by(name=employee_name).first()
            if employee:
                employee_code = employee.employee_code
                if employee.account_id:
                    emp_account = Account.query.get(employee.account_id)
                    if emp_account:
                        employee_account = emp_account.account_number
        
        summary.append({
            'advance_account_id': account.id,
            'advance_account_number': account.account_number,
            'advance_account_name': account.name,
            'balance': balance,
            'employee_code': employee_code,
            'employee_account': employee_account,
            'created_at': account.created_at.isoformat() if hasattr(account, 'created_at') and account.created_at else None
        })
        
        total_advances += balance
    
    return {
        'advances': summary,
        'total_outstanding': total_advances,
        'count': len(summary)
    }


def link_advance_to_employee(advance_account_id, employee_id):
    """
    ربط حساب سلفة موجود بموظف
    
    Args:
        advance_account_id: معرّف حساب السلفة
        employee_id: معرّف الموظف
    
    Returns:
        Account: الحساب المُحدّث
    """
    account = Account.query.get(advance_account_id)
    if not account:
        raise ValueError(f"حساب السلفة {advance_account_id} غير موجود")
    
    employee = Employee.query.get(employee_id)
    if not employee:
        raise ValueError(f"الموظف {employee_id} غير موجود")
    
    if not employee.account_id:
        raise ValueError(f"الموظف {employee.name} ليس له حساب شخصي")
    
    # تحديث اسم الحساب ليرتبط بالموظف
    account.name = f"سلفة {employee.name}"
    
    return account
