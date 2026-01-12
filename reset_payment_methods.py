#!/usr/bin/env python3
"""
سكريبت لحذف وإعادة تهيئة وسائل الدفع الافتراضية
يُستخدم عندما نريد إعادة ضبط النظام بالكامل
"""
import sys
import os

# Add backend to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'backend'))

from app import app, db
from models import PaymentMethod, Account, JournalEntryLine, SafeBox

def reset_payment_methods():
    """حذف وإعادة تهيئة وسائل الدفع"""
    with app.app_context():
        print("🔄 بدء عملية إعادة تهيئة وسائل الدفع...")
        
        # 1. حذف جميع وسائل الدفع
        payment_methods_count = PaymentMethod.query.count()
        print(f"📋 وسائل الدفع الحالية: {payment_methods_count}")
        
        PaymentMethod.query.delete()
        db.session.commit()
        print("✅ تم حذف جميع وسائل الدفع القديمة")
        
        # 2. حذف حسابات وسائل الدفع غير المستخدمة
        payment_account_numbers = [
            '1111', '1112', '1113', '1114', '1115', '1116', '1117', '1118', '1119',
            '5111', '5112', '5113', '5114', '5115', '5116'
        ]
        
        deleted_accounts = []
        for acc_num in payment_account_numbers:
            acc = Account.query.filter_by(account_number=acc_num).first()
            if acc:
                # تحقق من عدم استخدام الحساب
                journal_lines_count = JournalEntryLine.query.filter_by(account_id=acc.id).count()
                if journal_lines_count == 0:
                    db.session.delete(acc)
                    deleted_accounts.append(acc_num)
                else:
                    print(f"⚠️  الحساب {acc_num} ({acc.name}) مستخدم في {journal_lines_count} قيد - تم تجاهله")
        
        if deleted_accounts:
            db.session.commit()
            print(f"✅ تم حذف {len(deleted_accounts)} حساب غير مستخدم")
        
        # 3. إنشاء شجرة الحسابات الجديدة
        accounts_data = [
            # الأصول المتداولة
            {'account_number': '1111', 'name': 'الصندوق (نقداً)', 'type': 'Asset', 'transaction_type': 'both'},
            {'account_number': '1112', 'name': 'البنك - الحساب الجاري', 'type': 'Asset', 'transaction_type': 'both'},
            {'account_number': '1113', 'name': 'بطاقة مدى - نقاط البيع', 'type': 'Asset', 'transaction_type': 'both'},
            {'account_number': '1114', 'name': 'بطاقات فيزا/ماستركارد', 'type': 'Asset', 'transaction_type': 'both'},
            {'account_number': '1115', 'name': 'تابي - مستحقات قصيرة الأجل', 'type': 'Asset', 'transaction_type': 'both'},
            {'account_number': '1116', 'name': 'تمارا - مستحقات قصيرة الأجل', 'type': 'Asset', 'transaction_type': 'both'},
            {'account_number': '1117', 'name': 'STC Pay - المحفظة الرقمية', 'type': 'Asset', 'transaction_type': 'both'},
            {'account_number': '1118', 'name': 'Apple Pay / Google Pay', 'type': 'Asset', 'transaction_type': 'both'},
            {'account_number': '1119', 'name': 'التحويل البنكي المباشر', 'type': 'Asset', 'transaction_type': 'both'},
            
            # المصروفات - العمولات
            {'account_number': '5111', 'name': 'عمولة البنك - بطاقة مدى', 'type': 'Expense', 'transaction_type': 'both'},
            {'account_number': '5112', 'name': 'عمولة البنك - فيزا/ماستركارد', 'type': 'Expense', 'transaction_type': 'both'},
            {'account_number': '5113', 'name': 'عمولة تابي (BNPL)', 'type': 'Expense', 'transaction_type': 'both'},
            {'account_number': '5114', 'name': 'عمولة تمارا (BNPL)', 'type': 'Expense', 'transaction_type': 'both'},
            {'account_number': '5115', 'name': 'عمولة STC Pay', 'type': 'Expense', 'transaction_type': 'both'},
            {'account_number': '5116', 'name': 'عمولة Apple/Google Pay', 'type': 'Expense', 'transaction_type': 'both'},
        ]
        
        created_accounts = []
        for acc_data in accounts_data:
            existing = Account.query.filter_by(account_number=acc_data['account_number']).first()
            if not existing:
                account = Account(
                    account_number=acc_data['account_number'],
                    name=acc_data['name'],
                    type=acc_data['type'],
                    transaction_type=acc_data['transaction_type']
                )
                db.session.add(account)
                created_accounts.append(acc_data['account_number'])
        
        db.session.commit()
        print(f"✅ تم إنشاء {len(created_accounts)} حساب جديد")
        
        # 4. إنشاء الخزائن الافتراضية
        safe_boxes_data = [
            {'name': 'الصندوق الرئيسي', 'safe_type': 'cash', 'account_number': '1111'},
            {'name': 'البنك - الحساب الجاري', 'safe_type': 'bank', 'account_number': '1112'},
            {'name': 'مدى - نقاط البيع', 'safe_type': 'bank', 'account_number': '1113'},
            {'name': 'فيزا/ماستركارد', 'safe_type': 'bank', 'account_number': '1114'},
        ]
        
        created_safe_boxes = []
        for sb_data in safe_boxes_data:
            account = Account.query.filter_by(account_number=sb_data['account_number']).first()
            if account:
                existing_sb = SafeBox.query.filter_by(name=sb_data['name']).first()
                if not existing_sb:
                    safe_box = SafeBox(
                        name=sb_data['name'],
                        safe_type=sb_data['safe_type'],
                        account_id=account.id,
                        is_default=(sb_data['safe_type'] == 'cash')
                    )
                    db.session.add(safe_box)
                    created_safe_boxes.append(sb_data['name'])
        
        db.session.commit()
        print(f"✅ تم إنشاء {len(created_safe_boxes)} خزينة")
        
        # 5. إنشاء وسائل الدفع الافتراضية
        payment_methods_data = [
            {
                'payment_type': 'cash',
                'name': 'نقداً',
                'commission_rate': 0.0,
                'settlement_days': 0,
                'account_number': '1111',
                'safe_box_name': 'الصندوق الرئيسي',
                'applicable_invoice_types': ['بيع', 'شراء من عميل', 'شراء']
            },
            {
                'payment_type': 'mada',
                'name': 'بطاقة مدى',
                'commission_rate': 1.5,
                'settlement_days': 2,
                'account_number': '1113',
                'safe_box_name': 'مدى - نقاط البيع',
                'applicable_invoice_types': ['بيع']
            },
            {
                'payment_type': 'visa',
                'name': 'فيزا',
                'commission_rate': 2.5,
                'settlement_days': 3,
                'account_number': '1114',
                'safe_box_name': 'فيزا/ماستركارد',
                'applicable_invoice_types': ['بيع']
            },
            {
                'payment_type': 'mastercard',
                'name': 'ماستركارد',
                'commission_rate': 2.5,
                'settlement_days': 3,
                'account_number': '1114',
                'safe_box_name': 'فيزا/ماستركارد',
                'applicable_invoice_types': ['بيع']
            },
            {
                'payment_type': 'stc_pay',
                'name': 'STC Pay',
                'commission_rate': 1.5,
                'settlement_days': 1,
                'account_number': '1117',
                'safe_box_name': None,
                'applicable_invoice_types': ['بيع']
            },
            {
                'payment_type': 'apple_pay',
                'name': 'Apple Pay',
                'commission_rate': 2.0,
                'settlement_days': 2,
                'account_number': '1118',
                'safe_box_name': None,
                'applicable_invoice_types': ['بيع']
            },
            {
                'payment_type': 'tabby',
                'name': 'تابي (Tabby)',
                'commission_rate': 4.0,
                'settlement_days': 7,
                'account_number': '1115',
                'safe_box_name': None,
                'applicable_invoice_types': ['بيع']
            },
            {
                'payment_type': 'tamara',
                'name': 'تمارا (Tamara)',
                'commission_rate': 4.0,
                'settlement_days': 7,
                'account_number': '1116',
                'safe_box_name': None,
                'applicable_invoice_types': ['بيع']
            },
            {
                'payment_type': 'bank_transfer',
                'name': 'تحويل بنكي',
                'commission_rate': 0.0,
                'settlement_days': 1,
                'account_number': '1112',
                'safe_box_name': 'البنك - الحساب الجاري',
                'applicable_invoice_types': ['بيع', 'شراء من عميل', 'شراء']
            },
        ]
        
        created_methods = []
        for method_data in payment_methods_data:
            # البحث عن الحساب
            account = Account.query.filter_by(account_number=method_data['account_number']).first()
            
            # البحث عن الخزينة
            safe_box = None
            if method_data['safe_box_name']:
                safe_box = SafeBox.query.filter_by(name=method_data['safe_box_name']).first()
            
            if account:
                existing_method = PaymentMethod.query.filter_by(name=method_data['name']).first()
                if not existing_method:
                    payment_method = PaymentMethod(
                        payment_type=method_data['payment_type'],
                        name=method_data['name'],
                        commission_rate=method_data['commission_rate'],
                        settlement_days=method_data['settlement_days'],
                        default_safe_box_id=safe_box.id if safe_box else None,
                        applicable_invoice_types=method_data['applicable_invoice_types'],
                        is_active=True,
                        display_order=len(created_methods) + 1
                    )
                    db.session.add(payment_method)
                    created_methods.append(method_data['name'])
        
        db.session.commit()
        print(f"✅ تم إنشاء {len(created_methods)} وسيلة دفع")
        
        print("\n" + "="*60)
        print("✨ تمت إعادة تهيئة نظام وسائل الدفع بنجاح!")
        print("="*60)
        print(f"📊 الإحصائيات:")
        print(f"  • حسابات جديدة: {len(created_accounts)}")
        print(f"  • خزائن جديدة: {len(created_safe_boxes)}")
        print(f"  • وسائل دفع: {len(created_methods)}")
        print("\n📋 وسائل الدفع المتاحة:")
        for method in created_methods:
            print(f"  ✓ {method}")

if __name__ == '__main__':
    reset_payment_methods()
