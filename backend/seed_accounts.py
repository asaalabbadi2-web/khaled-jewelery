import os
import sys
import logging

# Setup logging
logging.basicConfig(level=logging.INFO, format='[%(levelname)s] %(message)s')

# Add project root to Python path to allow importing backend modules
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from backend.app import app, db
from backend.models import Account

# شجرة الحسابات حسب نظام الكتل مع التباعد (Spaced Block System)
# المستوى الأول: 1-5 (التصنيفات الرئيسية)
# المستوى الثاني: 10-90 (المجموعات الفرعية - تباعد 10)
# المستوى الثالث: 100-990 (الحسابات الفرعية - تباعد 10)
# المستوى الرابع: 1000-9990 (الحسابات التفصيلية - تباعد 10)
# 
# transaction_type: 'cash' = نقدي فقط, 'gold' = ذهب فقط, 'both' = نقدي وذهبي
ACCOUNTS_DATA = [
    # ==================== 1 - الأصول ====================
    {'number': '1', 'name': 'الأصول', 'type': 'Asset', 'parent_number': None, 'transaction_type': 'both'},
    
    # المستوى الثاني: الأصول المتداولة والثابتة
    {'number': '10', 'name': 'الأصول المتداولة', 'type': 'Asset', 'parent_number': '1', 'transaction_type': 'both'},
    {'number': '160', 'name': 'الأصول الثابتة', 'type': 'Asset', 'parent_number': '1', 'transaction_type': 'cash'},
    
    # --- فروع الأصول المتداولة (100-190) ---
    {'number': '100', 'name': 'النقدية وما في حكمها', 'type': 'Asset', 'parent_number': '10', 'transaction_type': 'cash'},
    {'number': '110', 'name': 'العملاء', 'type': 'Asset', 'parent_number': '10', 'transaction_type': 'both'},
    {'number': '120', 'name': 'المخزون', 'type': 'Asset', 'parent_number': '10', 'transaction_type': 'gold'},
    {'number': '130', 'name': 'حسابات الموظفين', 'type': 'Asset', 'parent_number': '10', 'transaction_type': 'cash'},
    {'number': '140', 'name': 'سلف وودائع ومصروفات مقدمة', 'type': 'Asset', 'parent_number': '10', 'transaction_type': 'cash'},
    {'number': '150', 'name': 'ضريبة القيمة المضافة (مدينة)', 'type': 'Asset', 'parent_number': '10', 'transaction_type': 'cash'},
    
    # --- فروع الأصول الثابتة (1600-1790) ---
    {'number': '1610', 'name': 'أثاث وتجهيزات', 'type': 'Asset', 'parent_number': '160', 'transaction_type': 'cash'},
    {'number': '1620', 'name': 'أجهزة ومعدات', 'type': 'Asset', 'parent_number': '160', 'transaction_type': 'cash'},
    {'number': '1630', 'name': 'سيارات', 'type': 'Asset', 'parent_number': '160', 'transaction_type': 'cash'},
    {'number': '1640', 'name': 'مصروفات تحسين محل', 'type': 'Asset', 'parent_number': '160', 'transaction_type': 'cash'},
    {'number': '170', 'name': 'مجمع إهلاك الأصول الثابتة', 'type': 'Asset', 'parent_number': '160', 'transaction_type': 'cash'},
    
    # --- تفاصيل النقدية (1000-1090) ---
    {'number': '1000', 'name': 'صندوق النقدية', 'type': 'Asset', 'parent_number': '100', 'transaction_type': 'cash'},
    {'number': '1010', 'name': 'حساب بنك الرياض', 'type': 'Asset', 'parent_number': '100', 'transaction_type': 'cash'},
    {'number': '1020', 'name': 'حساب بنك الراجحي', 'type': 'Asset', 'parent_number': '100', 'transaction_type': 'cash'},
    {'number': '1030', 'name': 'حساب البنك الأهلي', 'type': 'Asset', 'parent_number': '100', 'transaction_type': 'cash'},
    
    # --- تفاصيل العملاء (1100-1190) ---
    {'number': '1100', 'name': 'عملاء بيع ذهب', 'type': 'Asset', 'parent_number': '110', 'transaction_type': 'both'},
    {'number': '1110', 'name': 'عملاء صياغة', 'type': 'Asset', 'parent_number': '110', 'transaction_type': 'both'},
    {'number': '1120', 'name': 'عملاء مجوهرات جاهزة', 'type': 'Asset', 'parent_number': '110', 'transaction_type': 'both'},
    
    # --- تفاصيل المخزون (1200-1290) ---
    {'number': '1200', 'name': 'مخزون ذهب عيار 24', 'type': 'Asset', 'parent_number': '120', 'transaction_type': 'gold'},
    {'number': '1210', 'name': 'مخزون ذهب عيار 22', 'type': 'Asset', 'parent_number': '120', 'transaction_type': 'gold'},
    {'number': '1220', 'name': 'مخزون ذهب عيار 21', 'type': 'Asset', 'parent_number': '120', 'transaction_type': 'gold'},
    {'number': '1230', 'name': 'مخزون ذهب عيار 18', 'type': 'Asset', 'parent_number': '120', 'transaction_type': 'gold'},
    {'number': '1240', 'name': 'مخزون كسر عيار 24', 'type': 'Asset', 'parent_number': '120', 'transaction_type': 'gold'},
    {'number': '1250', 'name': 'مخزون كسر عيار 22', 'type': 'Asset', 'parent_number': '120', 'transaction_type': 'gold'},
    {'number': '1260', 'name': 'مخزون كسر عيار 21', 'type': 'Asset', 'parent_number': '120', 'transaction_type': 'gold'},
    {'number': '1270', 'name': 'مخزون فضة', 'type': 'Asset', 'parent_number': '120', 'transaction_type': 'gold'},
    {'number': '1280', 'name': 'مخزون مجوهرات جاهزة', 'type': 'Asset', 'parent_number': '120', 'transaction_type': 'gold'},
    
    # --- تفاصيل السلف والودائع (1300-1390) ---
    {'number': '1300', 'name': 'موظفو الإدارة', 'type': 'Asset', 'parent_number': '130', 'transaction_type': 'cash'},
    {'number': '1310', 'name': 'موظفو المبيعات', 'type': 'Asset', 'parent_number': '130', 'transaction_type': 'cash'},
    {'number': '1320', 'name': 'موظفو الصيانة', 'type': 'Asset', 'parent_number': '130', 'transaction_type': 'cash'},
    {'number': '1330', 'name': 'موظفو المحاسبة', 'type': 'Asset', 'parent_number': '130', 'transaction_type': 'cash'},
    {'number': '1340', 'name': 'موظفو المستودعات', 'type': 'Asset', 'parent_number': '130', 'transaction_type': 'cash'},

    # --- تفصيل السلف والودائع (1400-1490) ---
    {'number': '1400', 'name': 'سلف موظفين', 'type': 'Asset', 'parent_number': '140', 'transaction_type': 'cash'},
    {'number': '1410', 'name': 'تأمينات مستردة من الموظفين', 'type': 'Asset', 'parent_number': '140', 'transaction_type': 'cash'},
    {'number': '1420', 'name': 'ودائع قصيرة الأجل', 'type': 'Asset', 'parent_number': '140', 'transaction_type': 'cash'},
    
    # ==================== 2 - الخصوم ====================
    {'number': '2', 'name': 'الخصوم (الالتزامات)', 'type': 'Liability', 'parent_number': None, 'transaction_type': 'both'},
    
    # المستوى الثاني: التزامات قصيرة وطويلة
    {'number': '21', 'name': 'التزامات قصيرة الأجل', 'type': 'Liability', 'parent_number': '2', 'transaction_type': 'both'},
    {'number': '22', 'name': 'حسابات دائنة أخرى', 'type': 'Liability', 'parent_number': '2', 'transaction_type': 'cash'},
    {'number': '23', 'name': 'التزامات طويلة الأجل', 'type': 'Liability', 'parent_number': '2', 'transaction_type': 'cash'},
    
    # --- فروع الالتزامات قصيرة الأجل (210-219) ---
    {'number': '211', 'name': 'الموردين', 'type': 'Liability', 'parent_number': '21', 'transaction_type': 'both'},
    {'number': '212', 'name': 'المصنعين', 'type': 'Liability', 'parent_number': '21', 'transaction_type': 'both'},
    
    # --- فروع الحسابات الدائنة الأخرى (220-229) ---
    {'number': '221', 'name': 'ضريبة القيمة المضافة - دائنة', 'type': 'Liability', 'parent_number': '22', 'transaction_type': 'cash'},
    {'number': '222', 'name': 'مستحقات رواتب', 'type': 'Liability', 'parent_number': '22', 'transaction_type': 'cash'},
    {'number': '223', 'name': 'مستحقات إيجار', 'type': 'Liability', 'parent_number': '22', 'transaction_type': 'cash'},
    {'number': '224', 'name': 'دفعات مقدمة من العملاء', 'type': 'Liability', 'parent_number': '22', 'transaction_type': 'both'},
    
    # --- فروع الالتزامات طويلة الأجل (230-239) ---
    {'number': '231', 'name': 'قروض بنكية طويلة الأجل', 'type': 'Liability', 'parent_number': '23', 'transaction_type': 'cash'},
    {'number': '232', 'name': 'التزامات أخرى طويلة الأجل', 'type': 'Liability', 'parent_number': '23', 'transaction_type': 'cash'},
    
    # ==================== 3 - حقوق الملكية ====================
    {'number': '3', 'name': 'حقوق الملكية', 'type': 'Equity', 'parent_number': None, 'transaction_type': 'both'},
    
    # المستوى الثاني: رأس المال والأرباح
    {'number': '30', 'name': 'رأس المال', 'type': 'Equity', 'parent_number': '3', 'transaction_type': 'both'},
    {'number': '31', 'name': 'المسحوبات الشخصية', 'type': 'Equity', 'parent_number': '3', 'transaction_type': 'cash'},
    {'number': '32', 'name': 'الأرباح المحتجزة', 'type': 'Equity', 'parent_number': '3', 'transaction_type': 'both'},
    {'number': '33', 'name': 'أرباح العام الجاري', 'type': 'Equity', 'parent_number': '3', 'transaction_type': 'both'},
    
    # ==================== 4 - الإيرادات ====================
    {'number': '4', 'name': 'الإيرادات', 'type': 'Revenue', 'parent_number': None, 'transaction_type': 'both'},
    
    # المستوى الثاني: إيرادات النشاط والأخرى
    {'number': '40', 'name': 'إيرادات النشاط الأساسي', 'type': 'Revenue', 'parent_number': '4', 'transaction_type': 'both'},
    {'number': '41', 'name': 'إيرادات أخرى', 'type': 'Revenue', 'parent_number': '4', 'transaction_type': 'cash'},
    {'number': '42', 'name': 'مردودات ومسموحات المبيعات', 'type': 'Revenue', 'parent_number': '4', 'transaction_type': 'both'},
    
    # --- فروع إيرادات النشاط (400-490) ---
    {'number': '400', 'name': 'مبيعات ذهب جديد', 'type': 'Revenue', 'parent_number': '40', 'transaction_type': 'both'},
    {'number': '410', 'name': 'مبيعات كسر ذهب', 'type': 'Revenue', 'parent_number': '40', 'transaction_type': 'both'},
    {'number': '420', 'name': 'مبيعات صياغة ومصنعية', 'type': 'Revenue', 'parent_number': '40', 'transaction_type': 'cash'},
    {'number': '430', 'name': 'مبيعات مجوهرات جاهزة', 'type': 'Revenue', 'parent_number': '40', 'transaction_type': 'both'},
    {'number': '440', 'name': 'مبيعات فضة', 'type': 'Revenue', 'parent_number': '40', 'transaction_type': 'both'},
    
    # --- فروع إيرادات أخرى (410-419) ---
    {'number': '411', 'name': 'أرباح بيع أصول ثابتة', 'type': 'Revenue', 'parent_number': '41', 'transaction_type': 'cash'},
    {'number': '412', 'name': 'خصومات مكتسبة', 'type': 'Revenue', 'parent_number': '41', 'transaction_type': 'cash'},
    {'number': '413', 'name': 'إيرادات متنوعة', 'type': 'Revenue', 'parent_number': '41', 'transaction_type': 'cash'},
    
    # ==================== 5 - المصروفات ====================
    {'number': '5', 'name': 'المصروفات', 'type': 'Expense', 'parent_number': None, 'transaction_type': 'cash'},
    
    # المستوى الثاني: مصاريف تشغيلية وإدارية وتكلفة البضاعة
    {'number': '50', 'name': 'مصاريف تشغيلية', 'type': 'Expense', 'parent_number': '5', 'transaction_type': 'cash'},
    {'number': '51', 'name': 'مصاريف إدارية وعمومية', 'type': 'Expense', 'parent_number': '5', 'transaction_type': 'cash'},
    {'number': '52', 'name': 'تكلفة البضاعة المباعة', 'type': 'Expense', 'parent_number': '5', 'transaction_type': 'both'},
    
    # --- فروع مصاريف تشغيلية (500-590) ---
    {'number': '500', 'name': 'الرواتب والأجور', 'type': 'Expense', 'parent_number': '50', 'transaction_type': 'cash'},
    {'number': '510', 'name': 'إيجارات', 'type': 'Expense', 'parent_number': '50', 'transaction_type': 'cash'},
    {'number': '520', 'name': 'كهرباء ومياه', 'type': 'Expense', 'parent_number': '50', 'transaction_type': 'cash'},
    {'number': '5200', 'name': 'مصروف العمولات', 'type': 'Expense', 'parent_number': '50', 'transaction_type': 'cash'},
    {'number': '530', 'name': 'اتصالات وإنترنت', 'type': 'Expense', 'parent_number': '50', 'transaction_type': 'cash'},
    {'number': '540', 'name': 'صيانة وتشغيل', 'type': 'Expense', 'parent_number': '50', 'transaction_type': 'cash'},
    {'number': '550', 'name': 'مواد تعبئة وتغليف', 'type': 'Expense', 'parent_number': '50', 'transaction_type': 'cash'},
    {'number': '560', 'name': 'مصاريف نقل وشحن', 'type': 'Expense', 'parent_number': '50', 'transaction_type': 'cash'},
    {'number': '570', 'name': 'ضيافة وبوفيه', 'type': 'Expense', 'parent_number': '50', 'transaction_type': 'cash'},
    
    # --- تفاصيل الرواتب (5000-5090) ---
    {'number': '5000', 'name': 'رواتب الموظفين', 'type': 'Expense', 'parent_number': '500', 'transaction_type': 'cash'},
    {'number': '5010', 'name': 'رواتب الإداريين', 'type': 'Expense', 'parent_number': '500', 'transaction_type': 'cash'},
    {'number': '5020', 'name': 'رواتب المحاسبين', 'type': 'Expense', 'parent_number': '500', 'transaction_type': 'cash'},
    {'number': '5030', 'name': 'بدلات ومكافآت', 'type': 'Expense', 'parent_number': '500', 'transaction_type': 'cash'},
    
    # --- فروع مصاريف إدارية وعمومية (510-519) ---
    {'number': '511', 'name': 'مستلزمات مكتبية', 'type': 'Expense', 'parent_number': '51', 'transaction_type': 'cash'},
    {'number': '512', 'name': 'رسوم حكومية وتجديدات', 'type': 'Expense', 'parent_number': '51', 'transaction_type': 'cash'},
    {'number': '513', 'name': 'استشارات وخدمات مهنية', 'type': 'Expense', 'parent_number': '51', 'transaction_type': 'cash'},
    {'number': '514', 'name': 'إهلاك الأصول الثابتة', 'type': 'Expense', 'parent_number': '51', 'transaction_type': 'cash'},
    
    # --- فروع تكلفة البضاعة المباعة (520-529) ---
    {'number': '521', 'name': 'تكلفة مبيعات الذهب', 'type': 'Expense', 'parent_number': '52', 'transaction_type': 'gold'},
    {'number': '522', 'name': 'تكلفة مبيعات المجوهرات الجاهزة', 'type': 'Expense', 'parent_number': '52', 'transaction_type': 'gold'},
    {'number': '523', 'name': 'تكلفة مبيعات الفضة', 'type': 'Expense', 'parent_number': '52', 'transaction_type': 'gold'},
    {'number': '5230', 'name': 'مشتريات الكسر والتسكير', 'type': 'Expense', 'parent_number': '52', 'transaction_type': 'both'},
]


def seed_accounts():
    """
    Seeds the database with the chart of accounts.
    It's designed to be idempotent, meaning it can be run multiple times
    without creating duplicate accounts. It checks for an account by its
    'number' before creating it.
    """
    with app.app_context():
        logging.info("Starting to seed accounts...")
        
        # A dictionary to hold parent accounts that have been created,
        # mapping their 'number' to their 'id' in the database.
        parent_map = {}

        for account_data in ACCOUNTS_DATA:
            # Check if account already exists
            existing_account = Account.query.filter_by(account_number=account_data['number']).first()
            if existing_account:
                logging.info(f"Account {account_data['number']} - {account_data['name']} already exists. Skipping.")
                # Store its ID for potential children
                parent_map[existing_account.account_number] = existing_account.id
                continue

            # Resolve parent_id
            parent_id = None
            parent_number = account_data.get('parent_number')
            if parent_number:
                if parent_number in parent_map:
                    parent_id = parent_map[parent_number]
                else:
                    # This case should ideally not happen if ACCOUNTS_DATA is ordered correctly
                    parent_account = Account.query.filter_by(account_number=parent_number).first()
                    if parent_account:
                        parent_id = parent_account.id
                        parent_map[parent_number] = parent_id
                    else:
                        logging.error(f"Could not find parent account with number {parent_number} for account {account_data['number']}. Skipping.")
                        continue
            
            # Create new account instance
            new_account = Account(
                account_number=account_data['number'],
                name=account_data['name'],
                type=account_data['type'],
                parent_id=parent_id,
                transaction_type=account_data.get('transaction_type', 'both') # استخدام القيمة من البيانات أو both كافتراضي
            )
            
            db.session.add(new_account)
            
            try:
                db.session.commit()
                logging.info(f"Successfully created account: {new_account.account_number} - {new_account.name}")
                # Add the newly created account's ID to the map for its children
                parent_map[new_account.account_number] = new_account.id
            except Exception as e:
                db.session.rollback()
                logging.error(f"Failed to create account {account_data['number']}: {e}")

        logging.info("Finished seeding accounts.")

if __name__ == '__main__':
    from backend.models import db, Account
    with app.app_context():
        db.session.query(Account).delete()
        db.session.commit()
        print("تم حذف جميع الحسابات.")
    seed_accounts()
    print("تم تحميل شجرة الحسابات الجديدة بنجاح.")
