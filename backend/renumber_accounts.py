#!/usr/bin/env python3
"""
🔄 إعادة ترقيم الشجرة المحاسبية - فصل المذكرة عن المالية
═══════════════════════════════════════════════════════════════

النظام الجديد:
- الحسابات المالية: 1, 11, 110, 120, 1100, 1200, إلخ
- حسابات المذكرة: 7, 71, 710, 720, 7100, 7200, إلخ

الاستخدام:
    cd backend
    source venv/bin/activate
    python renumber_accounts.py
    python renumber_accounts.py --force  # تخطي التأكيد
"""

import sys
from app import app, db
from config import WEIGHT_SUPPORT_ACCOUNTS
from models import Account, JournalEntry, JournalEntryLine

def safe_delete_accounts(force=False):
    """حذف جميع الحسابات بأمان بعد التحقق من عدم وجود قيود"""
    with app.app_context():
        entries_count = JournalEntry.query.count()
        if entries_count > 0:
            print(f"⚠️  تحذير: يوجد {entries_count} قيد محاسبي في النظام")
            if not force:
                response = input("هل تريد حذف جميع القيود والحسابات؟ (yes/no): ")
                if response.lower() != 'yes':
                    print("❌ تم الإلغاء")
                    return False
            else:
                print("🔧 وضع Force مُفعّل - سيتم الحذف تلقائياً")
            
            print("🗑️  جاري حذف القيود المحاسبية...")
            JournalEntryLine.query.delete()
            JournalEntry.query.delete()
            db.session.commit()
            print("✅ تم حذف جميع القيود")
        
        print("🗑️  جاري حذف الحسابات القديمة...")
        accounts_count = Account.query.count()
        
        # حذف الحسابات من الأعمق إلى الأعلى لتجنب مشاكل العلاقات
        # نستخدم raw SQL لتعطيل قيود المفاتيح الأجنبية مؤقتاً
        db.session.execute(db.text("PRAGMA foreign_keys=OFF"))
        Account.query.delete()
        db.session.execute(db.text("PRAGMA foreign_keys=ON"))
        db.session.commit()
        print(f"✅ تم حذف {accounts_count} حساب")
        
        return True


def create_financial_and_memo_accounts(*, force_delete_existing: bool = False):
    """
    إنشاء شجرة الحسابات بالنظام الجديد:
    - المالية: 1, 11, 110, 120, إلخ
    - المذكرة: 7, 71, 710, 720, إلخ
    
    🆕 النظام المحسّن:
    - ينسخ جميع الحسابات المالية تلقائياً إلى حسابات وزنية
    - يضيف الرقم 7 قبل رقم كل حساب وزني (1100 → 71100)
    - يضيف كلمة "وزني" بعد اسم كل حساب
    """
    with app.app_context():
        if force_delete_existing:
            # Destructive mode: ensure we start from an empty account table.
            # This avoids UNIQUE collisions when bootstraps or previous runs left rows behind.
            try:
                db.session.execute(db.text('PRAGMA foreign_keys=OFF'))
            except Exception:
                pass

            try:
                JournalEntryLine.query.delete()
                JournalEntry.query.delete()
                Account.query.delete()
                db.session.commit()
            except Exception:
                db.session.rollback()
                raise
            finally:
                try:
                    db.session.execute(db.text('PRAGMA foreign_keys=ON'))
                    db.session.commit()
                except Exception:
                    db.session.rollback()
        accounts_created = []
        financial_accounts = []  # 🆕 قائمة لتخزين الحسابات المالية لنسخها
        support_accounts_map = {}

        def find_account_by_number(account_number):
            if not account_number:
                return None
            for account in accounts_created:
                if account.account_number == account_number:
                    return account
            return Account.query.filter_by(account_number=account_number).first()

        def create_account_from_payload(payload):
            if not payload:
                return None
            account_number = payload.get('account_number')
            existing = find_account_by_number(account_number)

            parent_number = payload.get('parent_number')
            parent_account = find_account_by_number(parent_number) if parent_number else None
            if parent_number and not parent_account:
                raise ValueError(f"تعذر العثور على الحساب الأب {parent_number} أثناء إنشاء الحساب {payload.get('account_number')}")

            # Avoid duplicate insertions when WEIGHT_SUPPORT_ACCOUNTS references accounts
            # already created in the main chart.
            if existing:
                # Best-effort: align key fields with the payload.
                if payload.get('name'):
                    existing.name = payload.get('name')
                if payload.get('type'):
                    existing.type = payload.get('type')
                if 'transaction_type' in payload and payload.get('transaction_type'):
                    existing.transaction_type = payload.get('transaction_type')
                if 'tracks_weight' in payload:
                    existing.tracks_weight = bool(payload.get('tracks_weight'))
                if parent_account:
                    existing.parent_id = parent_account.id

                db.session.flush()
                if existing not in accounts_created:
                    accounts_created.append(existing)
                return existing

            account = Account(
                account_number=payload.get('account_number'),
                name=payload.get('name'),
                type=payload.get('type'),
                transaction_type=payload.get('transaction_type', 'cash'),
                tracks_weight=payload.get('tracks_weight', False),
                parent_id=parent_account.id if parent_account else None
            )
            db.session.add(account)
            db.session.flush()
            accounts_created.append(account)
            return account
        
        def create_memo_copy_of_financial_accounts():
            """
            🆕 إنشاء نسخة وزنية من جميع الحسابات المالية تلقائياً
            """
            print("\n🟣 إنشاء النسخ الوزنية للحسابات المالية...")
            
            memo_accounts_map = {}  # {رقم_مالي: حساب_وزني}

            # إنشاء جذر المذكرة (7) لتفادي ظهور 71..75 كجذور مستقلة
            memo_root = Account.query.filter_by(account_number='7').first()
            if not memo_root:
                memo_root = Account(
                    account_number='7',
                    name='حسابات المذكرة',
                    type='Equity',
                    transaction_type='gold',
                    tracks_weight=True,
                    parent_id=None,
                )
                db.session.add(memo_root)
                db.session.flush()
                accounts_created.append(memo_root)
            
            # المرور على جميع الحسابات المالية بالترتيب
            for fin_account in financial_accounts:
                # حساب رقم الحساب الوزني: 7 + رقم الحساب المالي
                memo_number = f"7{fin_account.account_number}"
                
                # حساب اسم الحساب الوزني: اسم الحساب + " وزني"
                memo_name = f"{fin_account.name} وزني"
                
                # إيجاد الحساب الأب الوزني
                memo_parent_id = None
                if fin_account.parent_id:
                    # البحث عن الحساب الأب المالي
                    parent_fin = next((acc for acc in financial_accounts if acc.id == fin_account.parent_id), None)
                    if parent_fin and parent_fin.account_number in memo_accounts_map:
                        memo_parent_id = memo_accounts_map[parent_fin.account_number].id
                else:
                    # الحسابات المالية الجذرية (1..5) تصبح تحت 7
                    memo_parent_id = memo_root.id
                
                # إنشاء الحساب الوزني
                memo_account = Account(
                    account_number=memo_number,
                    name=memo_name,
                    type=fin_account.type,  # نفس النوع (Asset, Liability, Revenue, Expense)
                    transaction_type='gold',  # ✅ وزني
                    tracks_weight=True,  # ✅ يتتبع الوزن
                    parent_id=memo_parent_id
                )
                
                db.session.add(memo_account)
                db.session.flush()
                accounts_created.append(memo_account)
                
                # حفظ في الخريطة
                memo_accounts_map[fin_account.account_number] = memo_account
                
                # ربط الحساب المالي بالحساب الوزني
                fin_account.memo_account_id = memo_account.id
                
                print(f"   ✅ {fin_account.account_number} ({fin_account.name}) → {memo_number} ({memo_name})")
            
            db.session.flush()
            print(f"\n✅ تم إنشاء {len(memo_accounts_map)} حساب وزني")
            
            return memo_accounts_map
        
        # ═══════════════════════════════════════════════════════════
        # 1️⃣ الشجرة المالية (النقدية) - transaction_type='cash'
        # ═══════════════════════════════════════════════════════════
        
        print("\n🟡 إنشاء الشجرة المالية (النقدية)...")
        
        # --- الأصول (1) ---
        assets = Account(
            account_number='1',
            name='الأصول',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=None
        )
        db.session.add(assets)
        db.session.flush()
        accounts_created.append(assets)
        
        # الأصول المتداولة (11)
        current_assets = Account(
            account_number='11',
            name='الأصول المتداولة',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=assets.id
        )
        db.session.add(current_assets)
        db.session.flush()
        accounts_created.append(current_assets)
        
        # النقدية والبنوك (110)
        cash_banks = Account(
            account_number='110',
            name='النقدية والبنوك',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=current_assets.id
        )
        db.session.add(cash_banks)
        db.session.flush()
        accounts_created.append(cash_banks)
        
        # الصندوق (1100)
        cash_account = Account(
            account_number='1100',
            name='الصندوق',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=cash_banks.id
        )
        db.session.add(cash_account)
        db.session.flush()
        accounts_created.append(cash_account)
        
        # بنك الأهلي (1110)
        bank_ahli = Account(
            account_number='1110',
            name='بنك الأهلي',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=cash_banks.id
        )
        db.session.add(bank_ahli)
        db.session.flush()
        accounts_created.append(bank_ahli)
        
        # بنك الراجحي (1120)
        bank_rajhi = Account(
            account_number='1120',
            name='بنك الراجحي',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=cash_banks.id
        )
        db.session.add(bank_rajhi)
        db.session.flush()
        accounts_created.append(bank_rajhi)
        
        # العملاء (120)
        customers_group = Account(
            account_number='120',
            name='العملاء',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=current_assets.id
        )
        db.session.add(customers_group)
        db.session.flush()
        accounts_created.append(customers_group)
        
        # عملاء بيع ذهب (1200)
        customers_sales = Account(
            account_number='1200',
            name='عملاء بيع ذهب',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=customers_group.id
        )
        db.session.add(customers_sales)
        db.session.flush()
        accounts_created.append(customers_sales)
        
        # عملاء شراء كسر (1210)
        customers_scrap = Account(
            account_number='1210',
            name='عملاء شراء كسر',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=customers_group.id
        )
        db.session.add(customers_scrap)
        db.session.flush()
        accounts_created.append(customers_scrap)
        
        # المخزون (130)
        inventory_group = Account(
            account_number='130',
            name='المخزون',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=current_assets.id
        )
        db.session.add(inventory_group)
        db.session.flush()
        accounts_created.append(inventory_group)
        
        # مخزون ذهب عيار 18 (1300)
        inv_18k = Account(
            account_number='1300',
            name='مخزون ذهب عيار 18',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=inventory_group.id
        )
        db.session.add(inv_18k)
        db.session.flush()
        accounts_created.append(inv_18k)
        
        # مخزون ذهب عيار 21 (1310)
        inv_21k = Account(
            account_number='1310',
            name='مخزون ذهب عيار 21',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=inventory_group.id
        )
        db.session.add(inv_21k)
        db.session.flush()
        accounts_created.append(inv_21k)
        
        # مخزون ذهب عيار 22 (1320)
        inv_22k = Account(
            account_number='1320',
            name='مخزون ذهب عيار 22',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=inventory_group.id
        )
        db.session.add(inv_22k)
        db.session.flush()
        accounts_created.append(inv_22k)
        
        # مخزون ذهب عيار 24 (1330)
        inv_24k = Account(
            account_number='1330',
            name='مخزون ذهب عيار 24',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=inventory_group.id
        )
        db.session.add(inv_24k)
        db.session.flush()
        accounts_created.append(inv_24k)

        # ضريبة القيمة المضافة المدينة (150)
        vat_asset_group = Account(
            account_number='150',
            name='ضريبة القيمة المضافة (مدينة)',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=current_assets.id
        )
        db.session.add(vat_asset_group)
        db.session.flush()
        accounts_created.append(vat_asset_group)

        vat_input_account = Account(
            account_number='1500',
            name='ضريبة مدفوعة على المشتريات',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=vat_asset_group.id
        )
        db.session.add(vat_input_account)
        db.session.flush()
        accounts_created.append(vat_input_account)

        vat_commission_account = Account(
            account_number='1501',
            name='ضريبة عمولات نقاط البيع (مدفوعة)',
            type='Asset',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=vat_asset_group.id
        )
        db.session.add(vat_commission_account)
        db.session.flush()
        accounts_created.append(vat_commission_account)
        
        # --- الخصوم (2) ---
        liabilities = Account(
            account_number='2',
            name='الخصوم',
            type='Liability',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=None
        )
        db.session.add(liabilities)
        db.session.flush()
        accounts_created.append(liabilities)
        
        # الموردون (21)
        suppliers_group = Account(
            account_number='21',
            name='الموردون',
            type='Liability',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=liabilities.id
        )
        db.session.add(suppliers_group)
        db.session.flush()
        accounts_created.append(suppliers_group)
        
        # موردو ذهب خام (210)
        suppliers_raw = Account(
            account_number='210',
            name='موردو ذهب خام',
            type='Liability',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=suppliers_group.id
        )
        db.session.add(suppliers_raw)
        db.session.flush()
        accounts_created.append(suppliers_raw)
        
        # موردو ذهب مشغول (220)
        suppliers_processed = Account(
            account_number='220',
            name='موردو ذهب مشغول',
            type='Liability',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=suppliers_group.id
        )
        db.session.add(suppliers_processed)
        db.session.flush()
        accounts_created.append(suppliers_processed)

        # الالتزامات الضريبية (22)
        tax_liabilities = Account(
            account_number='22',
            name='الالتزامات الضريبية',
            type='Liability',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=liabilities.id
        )
        db.session.add(tax_liabilities)
        db.session.flush()
        accounts_created.append(tax_liabilities)

        vat_payable_account = Account(
            account_number='2210',
            name='ضريبة القيمة المضافة المستحقة',
            type='Liability',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=tax_liabilities.id
        )
        db.session.add(vat_payable_account)
        db.session.flush()
        accounts_created.append(vat_payable_account)
        
        # --- حقوق الملكية (3) ---
        equity = Account(
            account_number='3',
            name='حقوق الملكية',
            type='Equity',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=None
        )
        db.session.add(equity)
        db.session.flush()
        accounts_created.append(equity)
        
        # رأس المال (31)
        capital = Account(
            account_number='31',
            name='رأس المال',
            type='Equity',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=equity.id
        )
        db.session.add(capital)
        db.session.flush()
        accounts_created.append(capital)
        
        # الأرباح المحتجزة (32)
        retained_earnings = Account(
            account_number='32',
            name='الأرباح المحتجزة',
            type='Equity',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=equity.id
        )
        db.session.add(retained_earnings)
        db.session.flush()
        accounts_created.append(retained_earnings)
        
        # --- الإيرادات (4) ---
        revenues = Account(
            account_number='4',
            name='الإيرادات',
            type='Revenue',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=None
        )
        db.session.add(revenues)
        db.session.flush()
        accounts_created.append(revenues)
        
        # إيرادات بيع ذهب (40)
        revenue_sales = Account(
            account_number='40',
            name='إيرادات بيع ذهب',
            type='Revenue',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=revenues.id
        )
        db.session.add(revenue_sales)
        db.session.flush()
        accounts_created.append(revenue_sales)
        
        # إيرادات مصنعية (41)
        revenue_wage = Account(
            account_number='41',
            name='إيرادات مصنعية',
            type='Revenue',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=revenues.id
        )
        db.session.add(revenue_wage)
        db.session.flush()
        accounts_created.append(revenue_wage)
        
        # --- المصروفات (5) ---
        expenses = Account(
            account_number='5',
            name='المصروفات',
            type='Expense',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=None
        )
        db.session.add(expenses)
        db.session.flush()
        accounts_created.append(expenses)
        
        # تكلفة المبيعات (50)
        cost_of_sales = Account(
            account_number='50',
            name='تكلفة المبيعات',
            type='Expense',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=expenses.id
        )
        db.session.add(cost_of_sales)
        db.session.flush()
        accounts_created.append(cost_of_sales)
        
        # مصاريف تشغيلية (51)
        operating_expenses = Account(
            account_number='51',
            name='مصاريف تشغيلية',
            type='Expense',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=expenses.id
        )
        db.session.add(operating_expenses)
        db.session.flush()
        accounts_created.append(operating_expenses)

        commission_expense = Account(
            account_number='5150',
            name='مصروف عمولات الدفع الإلكتروني',
            type='Expense',
            transaction_type='cash',
            tracks_weight=False,
            parent_id=operating_expenses.id
        )
        db.session.add(commission_expense)
        db.session.flush()
        accounts_created.append(commission_expense)

        # 🆕 ═══════════════════════════════════════════════════════════
        # حفظ جميع الحسابات المالية في قائمة منفصلة
        # ═══════════════════════════════════════════════════════════
        print("\n📋 حفظ الحسابات المالية للنسخ...")
        for account in accounts_created:
            if account.transaction_type == 'cash':
                financial_accounts.append(account)
        print(f"   ✅ تم حفظ {len(financial_accounts)} حساب مالي")
        
        # 🆕 ═══════════════════════════════════════════════════════════
        # إنشاء نسخة وزنية تلقائية من جميع الحسابات المالية
        # ═══════════════════════════════════════════════════════════
        memo_accounts_map = create_memo_copy_of_financial_accounts()

        print("\n⚙️ إنشاء حسابات الدعم الخاصة ببروفايلات الوزن...")
        for entry in WEIGHT_SUPPORT_ACCOUNTS:
            key = entry.get('key')
            support_accounts_map[key] = {}

            financial_details = entry.get('financial')
            if financial_details:
                financial_account = create_account_from_payload(financial_details)
                support_accounts_map[key]['financial'] = financial_account
                # 🆕 إضافة للقائمة المالية إن لم تكن موجودة
                if financial_account.transaction_type == 'cash' and financial_account not in financial_accounts:
                    financial_accounts.append(financial_account)

            memo_details = entry.get('memo')
            if memo_details:
                memo_account = create_account_from_payload(memo_details)
                support_accounts_map[key]['memo'] = memo_account
        
        # 🆕 ═══════════════════════════════════════════════════════════
        # الربط التلقائي تم بالفعل في create_memo_copy_of_financial_accounts
        # ═══════════════════════════════════════════════════════════
        
        db.session.commit()
        
        # الإحصائيات
        cash_count = len([a for a in accounts_created if a.transaction_type == 'cash'])
        gold_count = len([a for a in accounts_created if a.transaction_type == 'gold'])
        linked_count = len([a for a in accounts_created if a.transaction_type == 'cash' and a.memo_account_id])
        
        print(f"\n✅ تم إنشاء الشجرة المحاسبية بنجاح!")
        print(f"📊 إجمالي الحسابات: {len(accounts_created)}")
        print(f"💵 حسابات مالية: {cash_count}")
        print(f"⚖️  حسابات وزنية: {gold_count}")
        print(f"🔗 حسابات مربوطة: {linked_count}/{cash_count}")
        
        return accounts_created


if __name__ == '__main__':
    print("=" * 60)
    print("🏦 إعادة ترقيم الشجرة المحاسبية")
    print("=" * 60)
    
    # التحقق من وجود معامل --force
    force_mode = '--force' in sys.argv
    
    if safe_delete_accounts(force=force_mode):
        create_financial_and_memo_accounts()
        
        print("\n" + "=" * 60)
        print("✅ اكتمل إعداد الشجرة المحاسبية!")
        print("=" * 60)
