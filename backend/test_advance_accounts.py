#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
سكريبت لاختبار نظام حسابات السلف التفصيلية
"""

import sys
import os

# Add parent directory to path
backend_dir = os.path.dirname(os.path.abspath(__file__))
parent_dir = os.path.dirname(backend_dir)
sys.path.insert(0, parent_dir)

from backend.app import app
from backend.models import db, Employee, Account
from backend.advance_account_helpers import (
    get_or_create_employee_advance_account,
    get_employee_advance_balance,
    get_all_advances_summary
)

def test_advance_accounts():
    """اختبار نظام حسابات السلف"""
    
    with app.app_context():
        print("\n" + "="*60)
        print("🧪 اختبار نظام حسابات السلف التفصيلية")
        print("="*60)
        
        # الحصول على أول موظف للاختبار
        employee = Employee.query.filter_by(is_active=True).first()
        
        if not employee:
            print("\n❌ لا يوجد موظفون في النظام")
            print("💡 قم بإنشاء موظف أولاً عبر: POST /api/employees")
            return
        
        # إعادة تحميل الموظف من قاعدة البيانات (للحصول على آخر تحديث)
        db.session.expire(employee)
        employee = Employee.query.get(employee.id)
        
        if not employee.account_id:
            print(f"\n❌ الموظف {employee.name} ليس له حساب شخصي")
            print("💡 قم بتحديث الموظف ليكون له حساب أولاً")
            return
        
        print(f"\n📋 بيانات الموظف:")
        print(f"   الاسم: {employee.name}")
        print(f"   الكود: {employee.employee_code}")
        
        # التحقق من وجود علاقة account
        account = Account.query.get(employee.account_id)
        if account:
            print(f"   الحساب الشخصي: {account.account_number} - {account.name}")
        else:
            print(f"   ❌ الحساب غير موجود (ID: {employee.account_id})")
            return
        
        # إنشاء حساب سلفة
        print(f"\n🔧 إنشاء حساب سلفة للموظف...")
        
        try:
            advance_account = get_or_create_employee_advance_account(employee.id, 'test-script')
            db.session.commit()
            
            print(f"✅ تم إنشاء حساب السلفة:")
            print(f"   رقم الحساب: {advance_account.account_number}")
            print(f"   اسم الحساب: {advance_account.name}")
            
        except Exception as e:
            print(f"❌ خطأ في الإنشاء: {str(e)}")
            db.session.rollback()
            return
        
        # الحصول على رصيد السلفة
        print(f"\n📊 رصيد السلفة الحالي:")
        balance_info = get_employee_advance_balance(employee.id)
        
        if balance_info['has_account']:
            print(f"   الحساب: {balance_info['account_number']} - {balance_info['account_name']}")
            print(f"   الرصيد: {balance_info['balance']:.2f} ريال")
        else:
            print("   لا يوجد حساب سلفة")
        
        # ملخص جميع السلف
        print(f"\n📈 ملخص جميع السلف في النظام:")
        summary = get_all_advances_summary()
        
        print(f"   عدد السلف المستحقة: {summary['count']}")
        print(f"   الإجمالي المستحق: {summary['total_outstanding']:.2f} ريال")
        
        if summary['advances']:
            print(f"\n   التفاصيل:")
            for adv in summary['advances']:
                print(f"   - {adv['advance_account_number']}: {adv['advance_account_name']}")
                print(f"     الرصيد: {adv['balance']:.2f} ريال")
                if adv['employee_code']:
                    print(f"     الموظف: {adv['employee_code']}")
        
        print("\n" + "="*60)
        print("✅ اكتمل الاختبار بنجاح")
        print("="*60)
        
        print("\n💡 الخطوة التالية:")
        print("   يمكنك الآن استخدام حساب السلفة في سندات الصرف/القبض")
        print(f"   الحساب: {advance_account.account_number} - {advance_account.name}")
        print("\n   مثال قيد صرف سلفة:")
        print(f"   من ح/ {advance_account.account_number} - {advance_account.name}")
        print("        إلى ح/ 1000 - الخزينة النقدية")
        print("="*60)


def show_advance_accounts_list():
    """عرض قائمة جميع حسابات السلف"""
    
    with app.app_context():
        print("\n" + "="*60)
        print("📋 قائمة حسابات السلف التفصيلية")
        print("="*60)
        
        # جلب جميع حسابات السلف
        advance_accounts = Account.query.filter(
            Account.account_number >= '140000',
            Account.account_number <= '149999',
            Account.is_active == True
        ).order_by(Account.account_number).all()
        
        if not advance_accounts:
            print("\n   لا توجد حسابات سلف مُنشأة بعد")
            print("   استخدم --test لإنشاء حساب سلفة تجريبي")
        else:
            print(f"\n   عدد حسابات السلف: {len(advance_accounts)}")
            print("\n   القائمة:")
            for account in advance_accounts:
                print(f"\n   {account.account_number} - {account.name}")
                if account.notes:
                    print(f"   📝 {account.notes}")
        
        print("\n" + "="*60)


if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser(description='اختبار نظام حسابات السلف')
    parser.add_argument('--test', action='store_true', help='تشغيل اختبار كامل')
    parser.add_argument('--list', action='store_true', help='عرض قائمة حسابات السلف')
    
    args = parser.parse_args()
    
    if args.test:
        test_advance_accounts()
    elif args.list:
        show_advance_accounts_list()
    else:
        # العرض الافتراضي
        show_advance_accounts_list()
