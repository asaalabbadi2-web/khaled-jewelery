"""
اختبار النظام المزدوج
"""
from app import app, db
from models import Account, JournalEntry
from dual_system_helpers import create_dual_journal_entry, verify_dual_balance, get_account_balances
from datetime import datetime

def test_dual_system_sale():
    """
    اختبار: بيع 2 جم عيار 24 @ 500 ر.س/جم = 1000 ر.س
    التكلفة من المخزون: 2 × 318.75 = 637.50 ر.س
    الربح: 1000 - 637.50 = 362.50 ر.س
    """
    with app.app_context():
        print('🧪 اختبار النظام المزدوج: بيع ذهب')
        print('=' * 60)
        
        # 1. إنشاء قيد محاسبي
        journal_entry = JournalEntry(
            date=datetime.now(),
            description='اختبار: بيع 2 جم عيار 24 @ 500 ر.س/جم'
        )
        db.session.add(journal_entry)
        db.session.flush()
        
        print(f'\n✅ تم إنشاء قيد محاسبي #{journal_entry.id}')
        
        # 2. القيد الأول: النقدية (مدين 1000 ر.س)
        print('\n📝 القيد الأول: من حـ/ النقدية')
        create_dual_journal_entry(
            journal_entry_id=journal_entry.id,
            account_id=15,  # صندوق النقدية
            cash_debit=1000,
            description='استلام نقدية من بيع ذهب'
        )
        print('   ✅ مدين: 1000 ر.س')
        
        # 3. القيد الثاني: المبيعات (دائن 1000 ر.س)
        print('\n📝 القيد الثاني: إلى حـ/ مبيعات ذهب جديد')
        create_dual_journal_entry(
            journal_entry_id=journal_entry.id,
            account_id=400,  # مبيعات ذهب جديد
            cash_credit=1000,
            description='إيراد من بيع ذهب عيار 24'
        )
        print('   ✅ دائن: 1000 ر.س')
        
        # 4. القيد الثالث: تكلفة المبيعات (مدين 637.50 ر.س + 2 جم)
        print('\n📝 القيد الثالث: من حـ/ تكلفة مبيعات الذهب')
        create_dual_journal_entry(
            journal_entry_id=journal_entry.id,
            account_id=521,  # تكلفة مبيعات الذهب
            cash_debit=637.50,
            weight_24k_debit=2.0,
            description='تكلفة بيع 2 جم عيار 24'
        )
        print('   ✅ مدين: 637.50 ر.س + 2.000 جم (عيار 24)')
        
        # 5. القيد الرابع: المخزون (دائن 637.50 ر.س + 2 جم)
        print('\n📝 القيد الرابع: إلى حـ/ مخزون ذهب عيار 24')
        create_dual_journal_entry(
            journal_entry_id=journal_entry.id,
            account_id=1200,  # مخزون عيار 24
            cash_credit=637.50,
            weight_24k_credit=2.0,
            description='خصم من المخزون'
        )
        print('   ✅ دائن: 637.50 ر.س + 2.000 جم (عيار 24)')
        
        # 6. التحقق من التوازن
        print('\n' + '=' * 60)
        print('🔍 التحقق من توازن القيد...')
        balance = verify_dual_balance(journal_entry.id)
        
        if balance['balanced']:
            print('✅ القيد متوازن! (نقداً ووزناً)')
        else:
            print('❌ القيد غير متوازن!')
            for error in balance['errors']:
                print(f'   {error}')
        
        print(f'\n📊 الأرصدة النقدية:')
        print(f'   المدين: {balance["cash_balance"] + (balance["cash_balance"] if balance["cash_balance"] > 0 else 0):.2f} ر.س')
        print(f'   الدائن: {abs(balance["cash_balance"]) if balance["cash_balance"] < 0 else 0:.2f} ر.س')
        print(f'   الفرق: {balance["cash_balance"]:.2f} ر.س')
        
        print(f'\n⚖️  الأرصدة الوزنية:')
        for karat, weight_balance in balance['weight_balances'].items():
            if weight_balance != 0:
                print(f'   عيار {karat}: {weight_balance:+.3f} جم')
        
        # 7. عرض أرصدة الحسابات
        print('\n' + '=' * 60)
        print('💰 أرصدة الحسابات بعد العملية:')
        
        accounts_to_check = [
            (15, 'صندوق النقدية'),
            (400, 'مبيعات ذهب جديد'),
            (521, 'تكلفة مبيعات الذهب'),
            (1200, 'مخزون ذهب عيار 24')
        ]
        
        for acc_id, acc_name in accounts_to_check:
            balances = get_account_balances(acc_id)
            print(f'\n📌 {acc_name}:')
            print(f'   النقد: {balances["cash"]:+.2f} ر.س')
            if 'weight' in balances:
                print(f'   الوزن:')
                for karat, weight in balances['weight'].items():
                    if karat != 'total' and weight != 0:
                        print(f'     - عيار {karat}: {weight:+.3f} جم')
                if balances['weight']['total'] != 0:
                    print(f'   الإجمالي: {balances["weight"]["total"]:+.3f} جم')
        
        # 8. حفظ التغييرات
        db.session.commit()
        print('\n' + '=' * 60)
        print('✅ تم حفظ القيد المحاسبي بنجاح!')
        print('=' * 60)
        
        return journal_entry.id


def test_dual_system_purchase():
    """
    اختبار: شراء 5 جم عيار 21 @ 250 ر.س/جم = 1250 ر.س
    """
    with app.app_context():
        print('\n\n🧪 اختبار النظام المزدوج: شراء ذهب')
        print('=' * 60)
        
        # 1. إنشاء قيد محاسبي
        journal_entry = JournalEntry(
            date=datetime.now(),
            description='اختبار: شراء 5 جم عيار 21 @ 250 ر.س/جم'
        )
        db.session.add(journal_entry)
        db.session.flush()
        
        print(f'\n✅ تم إنشاء قيد محاسبي #{journal_entry.id}')
        
        # 2. القيد الأول: المخزون (مدين 1250 ر.س + 5 جم)
        print('\n📝 القيد الأول: من حـ/ مخزون ذهب عيار 21')
        create_dual_journal_entry(
            journal_entry_id=journal_entry.id,
            account_id=1220,  # مخزون عيار 21
            cash_debit=1250,
            weight_21k_debit=5.0,
            description='إضافة للمخزون'
        )
        print('   ✅ مدين: 1250 ر.س + 5.000 جم (عيار 21)')
        
        # 3. القيد الثاني: النقدية (دائن 1250 ر.س)
        print('\n📝 القيد الثاني: إلى حـ/ النقدية')
        create_dual_journal_entry(
            journal_entry_id=journal_entry.id,
            account_id=15,  # صندوق النقدية
            cash_credit=1250,
            description='دفع نقدية لشراء ذهب'
        )
        print('   ✅ دائن: 1250 ر.س')
        
        # 4. التحقق من التوازن
        print('\n' + '=' * 60)
        print('🔍 التحقق من توازن القيد...')
        balance = verify_dual_balance(journal_entry.id)
        
        if balance['balanced']:
            print('✅ القيد متوازن! (نقداً ووزناً)')
        else:
            print('❌ القيد غير متوازن!')
            for error in balance['errors']:
                print(f'   {error}')
        
        # 5. عرض أرصدة الحسابات
        print('\n' + '=' * 60)
        print('💰 أرصدة الحسابات بعد العملية:')
        
        accounts_to_check = [
            (15, 'صندوق النقدية'),
            (1220, 'مخزون ذهب عيار 21')
        ]
        
        for acc_id, acc_name in accounts_to_check:
            balances = get_account_balances(acc_id)
            print(f'\n📌 {acc_name}:')
            print(f'   النقد: {balances["cash"]:+.2f} ر.س')
            if 'weight' in balances:
                print(f'   الوزن:')
                for karat, weight in balances['weight'].items():
                    if karat != 'total' and weight != 0:
                        print(f'     - عيار {karat}: {weight:+.3f} جم')
        
        # 6. حفظ التغييرات
        db.session.commit()
        print('\n' + '=' * 60)
        print('✅ تم حفظ القيد المحاسبي بنجاح!')
        print('=' * 60)
        
        return journal_entry.id


if __name__ == '__main__':
    print('🚀 بدء اختبار النظام المزدوج...\n')
    
    try:
        # اختبار البيع
        sale_entry_id = test_dual_system_sale()
        
        # اختبار الشراء
        purchase_entry_id = test_dual_system_purchase()
        
        print('\n\n' + '=' * 60)
        print('✅ اكتملت جميع الاختبارات بنجاح!')
        print(f'   - قيد البيع: #{sale_entry_id}')
        print(f'   - قيد الشراء: #{purchase_entry_id}')
        print('=' * 60)
        
    except Exception as e:
        print(f'\n❌ خطأ في الاختبار: {e}')
        import traceback
        traceback.print_exc()
