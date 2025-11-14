"""
إنشاء بيانات شجرة الحسابات الأولية ووسائل الدفع
"""
import sys
sys.path.insert(0, '/Users/salehalabbadi/yasargold/backend')

from app import app, db
from models import Account, PaymentMethod

def init_chart_of_accounts():
    """إنشاء شجرة الحسابات الأساسية"""
    
    accounts = [
        # ===== الأصول المتداولة - النقدية والبنوك =====
        {'account_number': '1110', 'name': 'النقدية والبنوك', 'type': 'Asset', 'transaction_type': 'both'},
        {'account_number': '1111', 'name': 'الصندوق (نقداً)', 'type': 'Asset', 'transaction_type': 'cash'},
        {'account_number': '1112', 'name': 'البنك - الحساب الجاري', 'type': 'Asset', 'transaction_type': 'cash'},
        {'account_number': '1113', 'name': 'بطاقة مدى (قيد التحويل)', 'type': 'Asset', 'transaction_type': 'cash'},
        {'account_number': '1114', 'name': 'بطاقات الائتمان (فيزا/ماستر)', 'type': 'Asset', 'transaction_type': 'cash'},
        {'account_number': '1115', 'name': 'تابي - مستحقات', 'type': 'Asset', 'transaction_type': 'cash'},
        {'account_number': '1116', 'name': 'تمارا - مستحقات', 'type': 'Asset', 'transaction_type': 'cash'},
        {'account_number': '1117', 'name': 'STC Pay', 'type': 'Asset', 'transaction_type': 'cash'},
        {'account_number': '1118', 'name': 'Apple Pay / Samsung Pay', 'type': 'Asset', 'transaction_type': 'cash'},
        {'account_number': '1119', 'name': 'تحويل بنكي مباشر', 'type': 'Asset', 'transaction_type': 'cash'},
        
        # ===== المصروفات - عمولات وسائل الدفع =====
        {'account_number': '5110', 'name': 'عمولات وسائل الدفع', 'type': 'Expense', 'transaction_type': 'cash'},
        {'account_number': '5111', 'name': 'عمولة بطاقة مدى', 'type': 'Expense', 'transaction_type': 'cash'},
        {'account_number': '5112', 'name': 'عمولة فيزا/ماستر', 'type': 'Expense', 'transaction_type': 'cash'},
        {'account_number': '5113', 'name': 'عمولة تابي', 'type': 'Expense', 'transaction_type': 'cash'},
        {'account_number': '5114', 'name': 'عمولة تمارا', 'type': 'Expense', 'transaction_type': 'cash'},
        {'account_number': '5115', 'name': 'عمولة STC Pay', 'type': 'Expense', 'transaction_type': 'cash'},
        {'account_number': '5116', 'name': 'عمولات أخرى', 'type': 'Expense', 'transaction_type': 'cash'},
    ]
    
    print("🏦 إنشاء شجرة الحسابات...")
    for acc_data in accounts:
        existing = Account.query.filter_by(account_number=acc_data['account_number']).first()
        if not existing:
            account = Account(**acc_data)
            db.session.add(account)
            print(f"  ✅ {acc_data['account_number']} - {acc_data['name']}")
        else:
            print(f"  ⏭️  {acc_data['account_number']} - {acc_data['name']}")
    
    db.session.commit()
    print("✅ تم إنشاء شجرة الحسابات!\n")


def init_payment_methods():
    """إنشاء وسائل الدفع"""
    
    methods = [
        {'name': 'نقداً', 'name_en': 'Cash', 'commission_rate': 0.0, 'account_number': '1111', 'settlement_days': 0},
        {'name': 'بطاقة مدى', 'name_en': 'Mada', 'commission_rate': 1.5, 'account_number': '1113', 'settlement_days': 2},
        {'name': 'فيزا/ماستر', 'name_en': 'Visa/Master', 'commission_rate': 2.5, 'account_number': '1114', 'settlement_days': 3},
        {'name': 'تابي', 'name_en': 'Tabby', 'commission_rate': 4.0, 'account_number': '1115', 'settlement_days': 7},
        {'name': 'تمارا', 'name_en': 'Tamara', 'commission_rate': 4.0, 'account_number': '1116', 'settlement_days': 7},
        {'name': 'STC Pay', 'name_en': 'STC Pay', 'commission_rate': 1.5, 'account_number': '1117', 'settlement_days': 1},
        {'name': 'Apple Pay', 'name_en': 'Apple Pay', 'commission_rate': 2.0, 'account_number': '1118', 'settlement_days': 2},
        {'name': 'تحويل بنكي', 'name_en': 'Bank Transfer', 'commission_rate': 0.0, 'account_number': '1119', 'settlement_days': 0},
    ]
    
    print("💳 إنشاء وسائل الدفع...")
    for pm in methods:
        account = Account.query.filter_by(account_number=pm['account_number']).first()
        if not account:
            print(f"  ⚠️  لم يتم العثور على الحساب {pm['account_number']}")
            continue
        
        existing = PaymentMethod.query.filter_by(name=pm['name']).first()
        if not existing:
            payment_method = PaymentMethod(
                name=pm['name'],
                name_en=pm['name_en'],
                commission_rate=pm['commission_rate'],
                account_id=account.id,
                settlement_days=pm['settlement_days'],
                is_active=True
            )
            db.session.add(payment_method)
            print(f"  ✅ {pm['name']} → {account.account_number} ({pm['commission_rate']}%)")
        else:
            print(f"  ⏭️  {pm['name']}")
    
    db.session.commit()
    print("✅ تم إنشاء وسائل الدفع!\n")


if __name__ == '__main__':
    with app.app_context():
        db.create_all()
        
        print("\n" + "="*60)
        print("   🚀 تهيئة شجرة الحسابات ووسائل الدفع")
        print("="*60 + "\n")
        
        init_chart_of_accounts()
        init_payment_methods()
        
        print("="*60)
        print(f"   ✅ إجمالي الحسابات: {Account.query.count()}")
        print(f"   ✅ وسائل الدفع: {PaymentMethod.query.count()}")
        print("="*60 + "\n")
