#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
سكريبت لإنشاء الحسابات التجميعية للموظفين
يتبع نفس نهج العملاء والموردين
"""

import sys
import os

# Add parent directory to path
backend_dir = os.path.dirname(os.path.abspath(__file__))
parent_dir = os.path.dirname(backend_dir)
sys.path.insert(0, parent_dir)

from backend.app import app
from backend.models import db, Account

def create_employee_group_accounts():
    """إنشاء الحسابات التجميعية للموظفين"""
    
    with app.app_context():
        # الحساب التجميعي الرئيسي
        main_account = Account.query.filter_by(account_number='130').first()
        if not main_account:
            main_account = Account(
                account_number='130',
                name='حسابات الموظفين',
                type='asset',
                transaction_type='cash',
                parent_id=None
            )
            db.session.add(main_account)
            print("✅ تم إنشاء الحساب التجميعي الرئيسي: 130 - حسابات الموظفين")
        else:
            print("ℹ️  الحساب التجميعي الرئيسي موجود بالفعل: 130")

        db.session.flush()

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
                    parent_id=main_account.id
                )
                db.session.add(account)
                print(f"✅ تم إنشاء الحساب التجميعي الفرعي: {acc_num} - {name_ar}")
            else:
                print(f"ℹ️  الحساب التجميعي الفرعي موجود بالفعل: {acc_num} - {name_ar}")

        # تحديث حساب السلف (تغيير الرقم من 1300 إلى 1400)
        old_advances_account = Account.query.filter_by(account_number='1300').first()
        if old_advances_account and old_advances_account.name == 'سلف موظفين':
            # تحقق من عدم وجود حساب بالرقم الجديد
            new_advances_account = Account.query.filter_by(account_number='1400').first()
            if not new_advances_account:
                old_advances_account.account_number = '1400'
                old_advances_account.parent_id = None  # سيكون تحت 140
                print("✅ تم تحديث رقم حساب سلف الموظفين من 1300 إلى 1400")
            else:
                print("⚠️  تحذير: يوجد حساب بالرقم 1400 بالفعل")

        # إنشاء حساب السلف الجديد إن لم يكن موجوداً
        advances_account = Account.query.filter_by(account_number='1400').first()
        if not advances_account:
            advances_account = Account(
                account_number='1400',
                name='سلف موظفين',
                type='asset',
                transaction_type='cash',
                parent_id=None
            )
            db.session.add(advances_account)
            print("✅ تم إنشاء حساب: 1400 - سلف موظفين (تجميعي)")
        else:
            print("ℹ️  حساب السلف موجود بالفعل: 1400")

        try:
            db.session.commit()
            print("\n" + "="*60)
            print("✅ تم إنشاء جميع الحسابات التجميعية للموظفين بنجاح")
            print("="*60)
            print("\nالحسابات المُنشأة:")
            print("  130  - حسابات الموظفين (حساب تجميعي رئيسي)")
            print("  1300 - موظفو الإدارة (حساب تجميعي فرعي)")
            print("       └─ نطاق الحسابات التفصيلية: 130000 - 130999")
            print("  1310 - موظفو المبيعات (حساب تجميعي فرعي)")
            print("       └─ نطاق الحسابات التفصيلية: 131000 - 131999")
            print("  1320 - موظفو الصيانة (حساب تجميعي فرعي)")
            print("       └─ نطاق الحسابات التفصيلية: 132000 - 132999")
            print("  1330 - موظفو المحاسبة (حساب تجميعي فرعي)")
            print("       └─ نطاق الحسابات التفصيلية: 133000 - 133999")
            print("  1340 - موظفو المستودعات (حساب تجميعي فرعي)")
            print("       └─ نطاق الحسابات التفصيلية: 134000 - 134999")
            print("\n  1400 - سلف موظفين")
            print("="*60)
            print("\n💡 ملاحظة: حسابات السلف التفصيلية (140000-149999)")
            print("   يتم إنشاؤها تلقائياً عند صرف سلفة لموظف")
            print("="*60)
            
        except Exception as e:
            db.session.rollback()
            print(f"\n❌ خطأ في الحفظ: {str(e)}")
            raise

def show_employee_accounts_structure():
    """عرض هيكل حسابات الموظفين"""
    with app.app_context():
        print("\n" + "="*60)
        print("📊 هيكل حسابات الموظفين الحالي")
        print("="*60)
        
        main_account = Account.query.filter_by(account_number='130').first()
        if main_account:
            print(f"\n{main_account.account_number} - {main_account.name}")
            
            # الحسابات التجميعية الفرعية
            sub_accounts = Account.query.filter(
                Account.parent_id == main_account.id
            ).order_by(Account.account_number).all()
            
            for sub in sub_accounts:
                print(f"  ├── {sub.account_number} - {sub.name}")
                
                # عدّ الموظفين تحت كل قسم
                start_range = f"{sub.account_number}000"
                end_range = f"{sub.account_number}999"
                
                employees_count = Account.query.filter(
                    Account.account_number >= start_range,
                    Account.account_number <= end_range
                ).count()
                
                print(f"  │    └─ عدد الموظفين: {employees_count}")
        
        print("\n" + "="*60)

if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser(description='إدارة حسابات الموظفين التجميعية')
    parser.add_argument('--create', action='store_true', help='إنشاء الحسابات التجميعية')
    parser.add_argument('--show', action='store_true', help='عرض هيكل الحسابات')
    
    args = parser.parse_args()
    
    if args.create:
        create_employee_group_accounts()
    
    if args.show or not (args.create):
        show_employee_accounts_structure()
