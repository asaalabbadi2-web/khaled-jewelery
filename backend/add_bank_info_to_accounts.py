#!/usr/bin/env python3
"""
إضافة أعمدة معلومات البنك إلى جدول accounts
"""
from app import app, db
from models import Account

def add_bank_info_columns():
    """إضافة الأعمدة الجديدة وتحديث البيانات الموجودة"""
    with app.app_context():
        # الأعمدة ستُضاف تلقائياً عند إعادة تشغيل التطبيق
        # هنا نحدث البيانات الموجودة فقط
        
        print("🔄 تحديث معلومات الحسابات البنكية...")
        
        # تحديث الحسابات الموجودة بمعلومات افتراضية
        updates = [
            {
                'account_number': '1112.1',
                'bank_name': 'بنك الرياض',
                'account_type': 'bank_account',
                'account_number_external': 'لم يتم التحديد بعد'
            },
            {
                'account_number': '1112.2',
                'bank_name': 'بنك الراجحي',
                'account_type': 'bank_account',
                'account_number_external': 'لم يتم التحديد بعد'
            },
            {
                'account_number': '1112.3',
                'bank_name': 'بنك الراجحي',
                'account_type': 'bank_account',
                'account_number_external': 'لم يتم التحديد بعد'
            },
            {
                'account_number': '1112.4',
                'bank_name': 'STC Pay',
                'account_type': 'digital_wallet',
                'account_number_external': 'لم يتم التحديد بعد'
            },
            {
                'account_number': '1112.5',
                'bank_name': 'Apple',
                'account_type': 'digital_wallet',
                'account_number_external': 'لم يتم التحديد بعد'
            },
            {
                'account_number': '1115',
                'bank_name': 'تابي (Tabby)',
                'account_type': 'bnpl',
                'account_number_external': 'رقم التاجر: لم يتم التحديد'
            },
            {
                'account_number': '1116',
                'bank_name': 'تمارا (Tamara)',
                'account_type': 'bnpl',
                'account_number_external': 'رقم التاجر: لم يتم التحديد'
            },
            {
                'account_number': '1111',
                'bank_name': None,
                'account_type': 'cash',
                'account_number_external': None
            },
        ]
        
        updated_count = 0
        for update_data in updates:
            account = Account.query.filter_by(account_number=update_data['account_number']).first()
            if account:
                account.bank_name = update_data['bank_name']
                account.account_type = update_data['account_type']
                account.account_number_external = update_data['account_number_external']
                updated_count += 1
                print(f"  ✅ تم تحديث: {account.account_number} - {account.name}")
        
        db.session.commit()
        
        print(f"\n✅ تم تحديث {updated_count} حساب بنجاح!")
        print("\n📝 ملاحظة: يمكنك الآن تعديل معلومات البنوك من شاشة الإعدادات")

if __name__ == '__main__':
    add_bank_info_columns()
