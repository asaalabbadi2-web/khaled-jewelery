#!/usr/bin/env python3
"""
فحص أرصدة الموردين والقيود المحاسبية
"""

import sys
import os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from backend.models import db, Supplier, JournalEntryLine, JournalEntry, Invoice, Account
from flask import Flask
from flask_cors import CORS

def check_supplier_data():
    """فحص بيانات المورد"""
    
    app = Flask(__name__)
    app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('DATABASE_URL', f"sqlite:///{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'app.db')}")
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    
    CORS(app)
    db.init_app(app)
    
    with app.app_context():
        print("=" * 70)
        print("🔍 فحص بيانات المورد والقيود المحاسبية")
        print("=" * 70)
        
        # فحص المورد
        supplier = db.session.get(Supplier, 1)
        if supplier:
            print(f'\n📋 المورد: {supplier.name} ({supplier.supplier_code})')
            print(f'   الرصيد النقدي: {supplier.balance_cash} ر.س')
            print(f'   الرصيد الذهبي 18k: {supplier.balance_gold_18k} جم')
            print(f'   الرصيد الذهبي 21k: {supplier.balance_gold_21k} جم')
            print(f'   الرصيد الذهبي 22k: {supplier.balance_gold_22k} جم')
            print(f'   الرصيد الذهبي 24k: {supplier.balance_gold_24k} جم')
            print(f'   account_category_id: {supplier.account_category_id}')
            
            if supplier.account_category_id:
                category = db.session.get(Account, supplier.account_category_id)
                if category:
                    print(f'   الحساب التجميعي: {category.name} ({category.account_number})')
                    print(f'   tracks_weight: {category.tracks_weight}')
        else:
            print("\n❌ لم يتم العثور على المورد")
            return
        
        # فحص الفواتير
        print(f'\n📄 الفواتير المرتبطة بالمورد:')
        invoices = Invoice.query.filter_by(supplier_id=1).all()
        print(f'   عدد الفواتير: {len(invoices)}')
        
        if invoices:
            for inv in invoices:
                print(f'\n   ✓ فاتورة #{inv.id}:')
                print(f'     النوع: {inv.invoice_type}')
                print(f'     التاريخ: {inv.date}')
                print(f'     الإجمالي: {inv.total} ر.س')
                print(f'     الوزن الإجمالي: {inv.total_weight} جم')
                print(f'     gold_subtotal: {inv.gold_subtotal}')
                print(f'     wage_subtotal: {inv.wage_subtotal}')
                print(f'     payment_gold_weight: {inv.payment_gold_weight}')
        
        # فحص القيود المحاسبية
        print(f'\n📊 القيود المحاسبية المرتبطة بالمورد (supplier_id=1):')
        lines = JournalEntryLine.query.filter_by(supplier_id=1).all()
        print(f'   عدد السطور: {len(lines)}')
        
        if lines:
            for line in lines:
                entry = db.session.get(JournalEntry, line.journal_entry_id)
                if entry:
                    print(f'\n   ✓ قيد #{entry.entry_number}:')
                    print(f'     التاريخ: {entry.date}')
                    print(f'     الوصف: {entry.description}')
                    print(f'     الحساب: {line.account.name if line.account else "N/A"} (ID: {line.account_id})')
                    print(f'     نقدي - مدين: {line.cash_debit}, دائن: {line.cash_credit}')
                    print(f'     ذهب 18k - مدين: {line.debit_18k}, دائن: {line.credit_18k}')
                    print(f'     ذهب 21k - مدين: {line.debit_21k}, دائن: {line.credit_21k}')
                    print(f'     ذهب 22k - مدين: {line.debit_22k}, دائن: {line.credit_22k}')
                    print(f'     ذهب 24k - مدين: {line.debit_24k}, دائن: {line.credit_24k}')
        else:
            print('   ⚠️  لا توجد قيود محاسبية مرتبطة بهذا المورد')
            print('   💡 ربما لم يتم حفظ supplier_id في القيود عند إنشاء الفاتورة')
        
        # فحص القيود على حساب الموردين (211)
        print(f'\n📊 القيود على حساب "الموردين" (211):')
        supplier_account = Account.query.filter_by(account_number='211').first()
        
        if supplier_account:
            print(f'   الحساب: {supplier_account.name} (ID: {supplier_account.id})')
            print(f'   tracks_weight: {supplier_account.tracks_weight}')
            print(f'   الرصيد النقدي: {supplier_account.balance_cash}')
            print(f'   الرصيد 21k: {supplier_account.balance_21k}')
            
            # جميع السطور على هذا الحساب
            all_lines = JournalEntryLine.query.filter_by(account_id=supplier_account.id).all()
            print(f'\n   عدد السطور على حساب الموردين: {len(all_lines)}')
            
            if all_lines:
                for line in all_lines[:5]:  # أول 5 فقط
                    entry = db.session.get(JournalEntry, line.journal_entry_id)
                    if entry:
                        print(f'\n   ✓ قيد #{entry.entry_number}:')
                        print(f'     supplier_id في السطر: {line.supplier_id}')
                        print(f'     ذهب 21k دائن: {line.credit_21k}')
        
        print("\n" + "=" * 70)

if __name__ == '__main__':
    check_supplier_data()
