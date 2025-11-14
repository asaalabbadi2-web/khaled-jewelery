#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
سكريبت لإنشاء إعدادات الربط المحاسبي الافتراضية
يُنشئ ربطاً بين عمليات الفواتير والحسابات المحاسبية

الاستخدام:
    cd backend
    source venv/bin/activate
    python init_accounting_mappings.py
"""

import sys
import os

# إضافة المسار الحالي لـ Python path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app import app, db
from models import AccountingMapping, Account

# إعدادات الربط الافتراضية
DEFAULT_MAPPINGS = {
    'بيع': {
        'inventory_21k': 120,      # مخزون ذهب عيار 21
        'cash': 101,               # الصندوق
        'revenue': 4,              # الإيرادات
        'cost': 120,               # تكلفة البضاعة المباعة (من المخزون)
        'commission': 5200,        # مصروف العمولات
        'commission_vat': 1303,    # ضريبة القيمة المضافة المدفوعة
        'vat_payable': 2101,       # ضريبة القيمة المضافة المستحقة
        'customers': 1100,         # العملاء
    },
    'شراء من عميل': {
        'inventory_21k': 120,
        'cash': 101,
        'customers': 1100,
        'vat_receivable': 1303,
    },
    'مرتجع بيع': {
        'inventory_21k': 120,
        'cash': 101,
        'revenue': 4,
        'sales_returns': 401,      # مردودات المبيعات
        'customers': 1100,
        'vat_payable': 2101,
    },
    'مرتجع شراء': {
        'inventory_21k': 120,
        'cash': 101,
        'purchase_returns': 501,   # مردودات المشتريات
        'suppliers': 211,          # الموردين
    },
    'شراء من مورد': {
        'inventory_21k': 120,
        'cash': 101,
        'suppliers': 211,
        'vat_receivable': 1303,
    },
    'مرتجع شراء من مورد': {
        'inventory_21k': 120,
        'cash': 101,
        'suppliers': 211,
        'purchase_returns': 501,
    },
}

def create_default_mappings():
    """إنشاء إعدادات الربط الافتراضية"""
    
    with app.app_context():
        created_count = 0
        skipped_count = 0
        error_count = 0
        
        print("🚀 بدء إنشاء إعدادات الربط المحاسبي الافتراضية...\n")
        
        for operation_type, mappings in DEFAULT_MAPPINGS.items():
            print(f"📌 معالجة عملية: {operation_type}")
            
            for account_type, account_id in mappings.items():
                # التحقق من وجود الحساب
                account = Account.query.get(account_id)
                
                if not account:
                    print(f"   ⚠️  الحساب {account_id} غير موجود - تخطي {account_type}")
                    error_count += 1
                    continue
                
                # التحقق من وجود ربط مسبق
                existing = AccountingMapping.query.filter_by(
                    operation_type=operation_type,
                    account_type=account_type
                ).first()
                
                if existing:
                    print(f"   ⏭️  {account_type} → {account.name} (موجود مسبقاً)")
                    skipped_count += 1
                    continue
                
                # إنشاء الربط
                mapping = AccountingMapping(
                    operation_type=operation_type,
                    account_type=account_type,
                    account_id=account_id,
                    description=f'ربط افتراضي: {operation_type} → {account_type}',
                    is_active=True,
                    created_by='system'
                )
                
                db.session.add(mapping)
                print(f"   ✅ {account_type} → {account.account_number} - {account.name}")
                created_count += 1
            
            print()
        
        # حفظ التغييرات
        try:
            db.session.commit()
            print("=" * 60)
            print(f"✨ تم بنجاح!")
            print(f"   📊 تم إنشاء: {created_count} ربط")
            print(f"   ⏭️  تم تخطي: {skipped_count} ربط (موجود مسبقاً)")
            print(f"   ⚠️  أخطاء: {error_count} ربط")
            print("=" * 60)
        except Exception as e:
            db.session.rollback()
            print(f"❌ خطأ في حفظ البيانات: {e}")

def list_current_mappings():
    """عرض الإعدادات الحالية"""
    
    with app.app_context():
        mappings = AccountingMapping.query.all()
        
        if not mappings:
            print("\n📋 لا توجد إعدادات ربط محفوظة حالياً")
            return
        
        print("\n📋 الإعدادات الحالية:")
        print("=" * 80)
        
        current_operation = None
        for mapping in mappings:
            if current_operation != mapping.operation_type:
                current_operation = mapping.operation_type
                print(f"\n📌 {current_operation}:")
            
            account_name = mapping.account.name if mapping.account else "غير موجود"
            account_number = mapping.account.account_number if mapping.account else "N/A"
            
            print(f"   • {mapping.account_type:20s} → {account_number} - {account_name}")
        
        print("=" * 80)

def clear_all_mappings():
    """حذف جميع الإعدادات (للاختبار فقط)"""
    
    with app.app_context():
        count = AccountingMapping.query.delete()
        db.session.commit()
        print(f"🗑️  تم حذف {count} إعداد")

if __name__ == '__main__':
    import sys
    
    if len(sys.argv) > 1:
        command = sys.argv[1]
        
        if command == 'create':
            create_default_mappings()
        elif command == 'list':
            list_current_mappings()
        elif command == 'clear':
            confirm = input("⚠️  هل أنت متأكد من حذف جميع الإعدادات؟ (yes/no): ")
            if confirm.lower() == 'yes':
                clear_all_mappings()
            else:
                print("❌ تم الإلغاء")
        else:
            print("الأوامر المتاحة:")
            print("  python init_accounting_mappings.py create  - إنشاء الإعدادات الافتراضية")
            print("  python init_accounting_mappings.py list    - عرض الإعدادات الحالية")
            print("  python init_accounting_mappings.py clear   - حذف جميع الإعدادات")
    else:
        # السلوك الافتراضي: إنشاء + عرض
        create_default_mappings()
        list_current_mappings()
