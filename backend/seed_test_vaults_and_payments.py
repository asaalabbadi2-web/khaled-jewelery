#!/usr/bin/env python3
"""
إنشاء خزائن ووسائل دفع تجريبية للاختبار والتطوير
"""
import os
import sys
from datetime import datetime

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(BASE_DIR, '..'))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from app import app
from models import db, SafeBox, PaymentMethod, Account


def seed_test_vaults_and_payments():
    """إنشاء خزائن ووسائل دفع تجريبية"""
    with app.app_context():
        print("\n" + "="*80)
        print("🏦 بدء إنشاء الخزائن ووسائل الدفع التجريبية")
        print("="*80 + "\n")

        # ==================== البحث عن الحسابات ====================
        print("📊 البحث عن الحسابات المرتبطة...")
        
        accounts = {
            'cash_main': Account.query.filter_by(account_number='1100').first(),
            'cash_backup': Account.query.filter_by(account_number='1110').first(),
            'bank_main': Account.query.filter_by(account_number='1120').first(),
            'bank_rajhi': Account.query.filter_by(account_number='1130').first(),
            'bank_riyad': Account.query.filter_by(account_number='1140').first(),
            'gold': Account.query.filter_by(account_number='1200').first(),
            'receivables': Account.query.filter_by(account_number='1300').first(),
            'credit_cards': Account.query.filter_by(account_number='1400').first(),
        }
        
        # إذا لم نجد الحسابات بالأرقام، ابحث بالأسماء
        if not accounts['cash_main']:
            accounts['cash_main'] = Account.query.filter(
                Account.name.like('%النقدية%')
            ).first()
        if not accounts['bank_main']:
            accounts['bank_main'] = Account.query.filter(
                Account.name.like('%بنك%') | Account.name.like('%البنك%')
            ).first()
        if not accounts['gold']:
            accounts['gold'] = Account.query.filter(
                Account.name.like('%ذهب%') | Account.name.like('%الذهب%')
            ).first()
        
        # استخدم حسابات افتراضية إذا لم نجد الحسابات
        if not accounts['cash_main']:
            accounts['cash_main'] = Account.query.first()
        
        if not accounts['bank_main']:
            accounts['bank_main'] = Account.query.filter(
                Account.type == 'Asset'
            ).offset(1).first() or accounts['cash_main']
        
        if not accounts['gold']:
            accounts['gold'] = accounts['cash_main']

        print(f"✓ حساب النقدية الرئيسي: {accounts['cash_main'].name if accounts['cash_main'] else 'غير موجود'}")
        print(f"✓ حساب البنك الرئيسي: {accounts['bank_main'].name if accounts['bank_main'] else 'غير موجود'}")
        print(f"✓ حساب الذهب: {accounts['gold'].name if accounts['gold'] else 'غير موجود'}\n")

        # ==================== إنشاء الخزائن ====================
        print("📦 إنشاء الخزائن...")
        
        safes_to_create = [
            {
                'name': 'صندوق النقدية الرئيسي',
                'name_en': 'Main Cash Box',
                'safe_type': 'cash',
                'account': accounts['cash_main'],
                'is_default': True,
                'notes': 'الصندوق النقدي الرئيسي للمحل (تجريبي)',
            },
            {
                'name': 'صندوق النقدية الاحتياطي',
                'name_en': 'Backup Cash Box',
                'safe_type': 'cash',
                'account': accounts.get('cash_backup') or accounts['cash_main'],
                'is_default': False,
                'notes': 'صندوق نقدي احتياطي للطوارئ',
            },
            {
                'name': 'بنك الراجحي الرئيسي',
                'name_en': 'Al Rajhi Bank - Main Account',
                'safe_type': 'bank',
                'account': accounts['bank_main'],
                'is_default': True,
                'bank_name': 'مصرف الراجحي',
                'iban': 'SA0380000000608010167519',
                'branch': 'الفرع الرئيسي - الرياض',
                'notes': 'الحساب البنكي الرئيسي (تجريبي)',
            },
            {
                'name': 'بنك الرياض',
                'name_en': 'Riyad Bank',
                'safe_type': 'bank',
                'account': accounts.get('bank_riyad') or accounts['bank_main'],
                'is_default': False,
                'bank_name': 'بنك الرياض',
                'iban': 'SA4510000000550000001234',
                'branch': 'فرع الملز - الرياض',
                'notes': 'حساب بنكي إضافي',
            },
            {
                'name': 'بنك الإمارات',
                'name_en': 'Emirates NBD',
                'safe_type': 'bank',
                'account': accounts.get('bank_rajhi') or accounts['bank_main'],
                'is_default': False,
                'bank_name': 'بنك الإمارات',
                'iban': 'AE070331234567890123456',
                'branch': 'دبي - الإمارات',
                'notes': 'فرع خارجي للحسابات الدولية',
            },
            {
                'name': 'صندوق الذهب الرئيسي',
                'name_en': 'Main Gold Box',
                'safe_type': 'gold',
                'account': accounts['gold'],
                'karat': 21,
                'is_default': True,
                'notes': 'خزينة الذهب عيار 21 (تجريبي)',
            },
            {
                'name': 'صندوق ذهب عيار 24',
                'name_en': 'Gold Box 24K',
                'safe_type': 'gold',
                'account': accounts['gold'],
                'karat': 24,
                'is_default': False,
                'notes': 'خزينة الذهب عيار 24 (خالص)',
            },
            {
                'name': 'صندوق ذهب عيار 18',
                'name_en': 'Gold Box 18K',
                'safe_type': 'gold',
                'account': accounts['gold'],
                'karat': 18,
                'is_default': False,
                'notes': 'خزينة الذهب عيار 18',
            },
        ]

        created_safes = []
        for safe_data in safes_to_create:
            if safe_data['account'] is None:
                print(f"⚠️  تجاوز إنشاء {safe_data['name']}: لا يوجد حساب متصل")
                continue
            
            # تحقق من عدم وجود الخزينة مسبقاً
            existing = SafeBox.query.filter_by(name=safe_data['name']).first()
            if existing:
                print(f"⏭️  {safe_data['name']}: موجودة مسبقاً (معرف: {existing.id})")
                created_safes.append(existing)
                continue
            
            safe = SafeBox(
                name=safe_data['name'],
                name_en=safe_data['name_en'],
                safe_type=safe_data['safe_type'],
                account_id=safe_data['account'].id,
                karat=safe_data.get('karat'),
                bank_name=safe_data.get('bank_name'),
                iban=safe_data.get('iban'),
                branch=safe_data.get('branch'),
                is_active=True,
                is_default=safe_data.get('is_default', False),
                notes=safe_data.get('notes'),
                created_by='test_seeder',
            )
            db.session.add(safe)
            db.session.flush()
            created_safes.append(safe)
            print(f"✅ {safe_data['name']} (معرف: {safe.id})")

        db.session.commit()
        print(f"\n📊 إجمالي الخزائن المُنشأة: {len(created_safes)}\n")

        # ==================== إنشاء وسائل الدفع ====================
        print("💳 إنشاء وسائل الدفع...")
        
        payments_to_create = [
            {
                'name': 'النقد',
                'name_en': 'Cash',
                'payment_type': 'cash',
                'commission_rate': 0.0,
                'commission_fixed_amount': 0.0,
                'settlement_days': 0,
                'is_active': True,
                'display_order': 1,
                'default_safe_box': next((s for s in created_safes if s.name == 'صندوق النقدية الرئيسي'), None),
                'notes': 'الدفع بالنقد مباشرة',
            },
            {
                'name': 'مدى - بنك الراجحي',
                'name_en': 'Mada - Al Rajhi',
                'payment_type': 'mada',
                'commission_rate': 1.5,
                'commission_fixed_amount': 0.0,
                'commission_timing': 'invoice',
                'settlement_days': 3,
                'is_active': True,
                'display_order': 2,
                'default_safe_box': next((s for s in created_safes if 'الراجحي' in s.name), None),
                'settlement_bank_safe_box': next((s for s in created_safes if 'الراجحي' in s.name), None),
                'notes': 'بطاقة مدى من مصرف الراجحي',
            },
            {
                'name': 'فيزا',
                'name_en': 'Visa',
                'payment_type': 'visa',
                'commission_rate': 2.0,
                'commission_fixed_amount': 0.0,
                'commission_timing': 'invoice',
                'settlement_days': 2,
                'is_active': True,
                'display_order': 3,
                'default_safe_box': next((s for s in created_safes if 'الراجحي' in s.name), None),
                'settlement_bank_safe_box': next((s for s in created_safes if 'الراجحي' in s.name), None),
                'notes': 'بطاقات فيزا من البنوك المختلفة',
            },
            {
                'name': 'ماستركارد',
                'name_en': 'Mastercard',
                'payment_type': 'mastercard',
                'commission_rate': 2.0,
                'commission_fixed_amount': 0.0,
                'commission_timing': 'invoice',
                'settlement_days': 2,
                'is_active': True,
                'display_order': 4,
                'default_safe_box': next((s for s in created_safes if 'الراجحي' in s.name), None),
                'settlement_bank_safe_box': next((s for s in created_safes if 'الراجحي' in s.name), None),
                'notes': 'بطاقات ماستركارد الائتمانية',
            },
            {
                'name': 'STC Pay',
                'name_en': 'STC Pay',
                'payment_type': 'stc_pay',
                'commission_rate': 1.0,
                'commission_fixed_amount': 0.0,
                'commission_timing': 'settlement',
                'settlement_days': 1,
                'is_active': True,
                'display_order': 5,
                'default_safe_box': next((s for s in created_safes if s.name == 'صندوق النقدية الرئيسي'), None),
                'settlement_bank_safe_box': next((s for s in created_safes if 'الراجحي' in s.name), None),
                'notes': 'محفظة STC Pay الإلكترونية',
            },
            {
                'name': 'Apple Pay',
                'name_en': 'Apple Pay',
                'payment_type': 'apple_pay',
                'commission_rate': 2.5,
                'commission_fixed_amount': 0.0,
                'commission_timing': 'invoice',
                'settlement_days': 2,
                'is_active': True,
                'display_order': 6,
                'default_safe_box': next((s for s in created_safes if 'الراجحي' in s.name), None),
                'settlement_bank_safe_box': next((s for s in created_safes if 'الراجحي' in s.name), None),
                'notes': 'محفظة Apple Pay',
            },
            {
                'name': 'تمارا',
                'name_en': 'Tamara',
                'payment_type': 'tamara',
                'commission_rate': 3.0,
                'commission_fixed_amount': 5.0,
                'commission_timing': 'settlement',
                'settlement_days': 7,
                'is_active': True,
                'display_order': 7,
                'default_safe_box': next((s for s in created_safes if 'الراجحي' in s.name), None),
                'settlement_bank_safe_box': next((s for s in created_safes if 'الراجحي' in s.name), None),
                'notes': 'خدمة الشراء الآن والدفع لاحقاً - تمارا',
            },
            {
                'name': 'تابي',
                'name_en': 'Tabby',
                'payment_type': 'tabby',
                'commission_rate': 2.5,
                'commission_fixed_amount': 0.0,
                'commission_timing': 'settlement',
                'settlement_days': 5,
                'is_active': True,
                'display_order': 8,
                'default_safe_box': next((s for s in created_safes if 'الراجحي' in s.name), None),
                'settlement_bank_safe_box': next((s for s in created_safes if 'الراجحي' in s.name), None),
                'notes': 'خدمة الشراء الآن والدفع لاحقاً - تابي',
            },
        ]

        created_payments = 0
        for payment_data in payments_to_create:
            # تحقق من عدم وجود وسيلة الدفع مسبقاً
            existing = PaymentMethod.query.filter_by(name=payment_data['name']).first()
            if existing:
                print(f"⏭️  {payment_data['name']}: موجودة مسبقاً (معرف: {existing.id})")
                continue
            
            if payment_data.get('default_safe_box') is None:
                print(f"⚠️  تجاوز إنشاء {payment_data['name']}: لا يوجد خزينة افتراضية")
                continue
            
            payment = PaymentMethod(
                name=payment_data['name'],
                payment_type=payment_data['payment_type'],
                commission_rate=payment_data.get('commission_rate', 0.0),
                commission_fixed_amount=payment_data.get('commission_fixed_amount', 0.0),
                commission_timing=payment_data.get('commission_timing', 'invoice'),
                settlement_days=payment_data.get('settlement_days', 0),
                auto_settlement_enabled=payment_data.get('settlement_days', 0) > 0,
                settlement_schedule_type='days',
                settlement_bank_safe_box_id=payment_data.get('settlement_bank_safe_box').id if payment_data.get('settlement_bank_safe_box') else None,
                is_active=payment_data.get('is_active', True),
                display_order=payment_data.get('display_order', 999),
                applicable_invoice_types=['buy', 'sell'],
                default_safe_box_id=payment_data['default_safe_box'].id,
            )
            db.session.add(payment)
            db.session.flush()
            created_payments += 1
            print(f"✅ {payment_data['name']} (معرف: {payment.id})")

        db.session.commit()
        print(f"\n📊 إجمالي وسائل الدفع المُنشأة: {created_payments}\n")

        # ==================== ملخص النتائج ====================
        print("="*80)
        print("📋 ملخص البيانات التجريبية المُنشأة:")
        print("="*80)
        
        all_safes = SafeBox.query.all()
        print(f"\n🏦 الخزائن ({len(all_safes)} إجمالي):")
        for safe in all_safes:
            status = "✅" if safe.is_active else "❌"
            default = "⭐" if safe.is_default else ""
            print(f"   {status} {safe.name:<30} ({safe.safe_type:<6}) {default}")

        all_payments = PaymentMethod.query.all()
        print(f"\n💳 وسائل الدفع ({len(all_payments)} إجمالي):")
        for payment in all_payments:
            status = "✅" if payment.is_active else "❌"
            commission = f"{payment.commission_rate}%" if payment.commission_rate > 0 else "بلا عمولة"
            print(f"   {status} {payment.name:<30} ({commission})")
        
        print("\n" + "="*80)
        print("🎉 تم إنشاء البيانات التجريبية بنجاح!")
        print("="*80 + "\n")
        
        return {
            'safes_created': len(created_safes),
            'payments_created': created_payments,
            'total_safes': len(all_safes),
            'total_payments': len(all_payments),
        }


if __name__ == '__main__':
    try:
        result = seed_test_vaults_and_payments()
        sys.exit(0)
    except Exception as e:
        print(f"\n❌ خطأ: {str(e)}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
