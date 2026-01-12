#!/usr/bin/env python3
"""
تحديث القيود المحاسبية القديمة بإضافة supplier_id
Update old journal entries to add supplier_id linkage
"""

import sys
import os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from backend.models import db, JournalEntry, JournalEntryLine, Invoice, Supplier, Account
from flask import Flask
from flask_cors import CORS

def update_old_entries():
    """تحديث القيود القديمة"""
    
    app = Flask(__name__)
    app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('DATABASE_URL', f"sqlite:///{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'app.db')}")
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    
    CORS(app)
    db.init_app(app)
    
    with app.app_context():
        print("=" * 70)
        print("🔧 تحديث القيود المحاسبية القديمة")
        print("=" * 70)
        
        # 1. البحث عن جميع قيود فواتير الموردين
        print("\n📋 البحث عن فواتير الموردين...")
        legacy_supplier_purchase = 'شراء' + ' من ' + 'مورد'
        legacy_supplier_return = 'مرتجع شراء' + ' من ' + 'مورد'
        supplier_invoices = Invoice.query.filter(
            Invoice.invoice_type.in_([
                'شراء',
                'مرتجع شراء (مورد)',
                legacy_supplier_purchase,
                legacy_supplier_return,
            ])
        ).filter(
            Invoice.supplier_id.isnot(None)
        ).all()
        
        print(f"   وُجد {len(supplier_invoices)} فاتورة مرتبطة بالموردين")
        
        if not supplier_invoices:
            print("\n✅ لا توجد فواتير موردين للتحديث")
            return
        
        # 2. جلب حساب الموردين (211)
        supplier_account = Account.query.filter_by(account_number='211').first()
        if not supplier_account:
            print("\n❌ لم يتم العثور على حساب الموردين (211)")
            return
        
        print(f"\n📊 حساب الموردين: {supplier_account.name} (ID: {supplier_account.id})")
        
        updated_count = 0
        supplier_balances_updated = {}
        
        # 3. تحديث كل فاتورة
        for invoice in supplier_invoices:
            # البحث عن القيود المرتبطة بالفاتورة
            journal_entries = JournalEntry.query.filter_by(
                reference_type='invoice',
                reference_id=invoice.id
            ).all()
            
            for entry in journal_entries:
                # البحث عن سطور القيد على حساب الموردين
                lines = JournalEntryLine.query.filter_by(
                    journal_entry_id=entry.id,
                    account_id=supplier_account.id
                ).all()
                
                for line in lines:
                    if line.supplier_id is None:
                        # تحديث supplier_id
                        line.supplier_id = invoice.supplier_id
                        updated_count += 1
                        
                        # حساب الرصيد لهذا السطر
                        supplier_id = invoice.supplier_id
                        if supplier_id not in supplier_balances_updated:
                            supplier_balances_updated[supplier_id] = {
                                'cash': 0.0,
                                'gold_18k': 0.0,
                                'gold_21k': 0.0,
                                'gold_22k': 0.0,
                                'gold_24k': 0.0,
                            }
                        
                        # تجميع الأرصدة
                        supplier_balances_updated[supplier_id]['cash'] += (line.cash_credit - line.cash_debit)
                        supplier_balances_updated[supplier_id]['gold_18k'] += (line.credit_18k - line.debit_18k)
                        supplier_balances_updated[supplier_id]['gold_21k'] += (line.credit_21k - line.debit_21k)
                        supplier_balances_updated[supplier_id]['gold_22k'] += (line.credit_22k - line.debit_22k)
                        supplier_balances_updated[supplier_id]['gold_24k'] += (line.credit_24k - line.debit_24k)
                        
                        print(f"\n   ✓ قيد #{entry.entry_number} - فاتورة #{invoice.id}")
                        print(f"     supplier_id تم تحديثه إلى: {invoice.supplier_id}")
                        if line.credit_21k > 0:
                            print(f"     ذهب 21k دائن: {line.credit_21k} جم")
        
        # 4. تحديث أرصدة الموردين في الجدول
        print(f"\n📊 تحديث أرصدة الموردين...")
        for supplier_id, balances in supplier_balances_updated.items():
            supplier = db.session.get(Supplier, supplier_id)
            if supplier:
                supplier.balance_cash = round(balances['cash'], 2)
                supplier.balance_gold_18k = round(balances['gold_18k'], 3)
                supplier.balance_gold_21k = round(balances['gold_21k'], 3)
                supplier.balance_gold_22k = round(balances['gold_22k'], 3)
                supplier.balance_gold_24k = round(balances['gold_24k'], 3)
                
                print(f"\n   ✓ {supplier.name} ({supplier.supplier_code}):")
                print(f"     الرصيد النقدي: {supplier.balance_cash} ر.س")
                print(f"     الرصيد الذهبي 21k: {supplier.balance_gold_21k} جم")
        
        # 5. حفظ التغييرات
        try:
            db.session.commit()
            print(f"\n✅ تم تحديث {updated_count} سطر قيد")
            print(f"✅ تم تحديث أرصدة {len(supplier_balances_updated)} مورد")
        except Exception as e:
            db.session.rollback()
            print(f"\n❌ خطأ في الحفظ: {e}")
            return
        
        print("\n" + "=" * 70)
        print("✅ اكتمل التحديث بنجاح!")
        print("=" * 70)

if __name__ == '__main__':
    update_old_entries()
