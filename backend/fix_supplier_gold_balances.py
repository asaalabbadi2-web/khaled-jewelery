#!/usr/bin/env python3
"""
إصلاح قيود الموردين: نقل أوزان الذهب من الحسابات الخاطئة إلى حساب الموردين
"""

import sys
import os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from backend.models import db, JournalEntry, JournalEntryLine, Invoice, Account
from flask import Flask
from flask_cors import CORS

def fix_supplier_gold_entries():
    """إصلاح قيود أوزان الذهب للموردين"""
    
    app = Flask(__name__)
    app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('DATABASE_URL', f"sqlite:///{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'app.db')}")
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    
    CORS(app)
    db.init_app(app)
    
    with app.app_context():
        print("=" * 70)
        print("🔧 إصلاح قيود أوزان الذهب للموردين")
        print("=" * 70)
        
        # 1. جلب حساب الموردين
        supplier_account = Account.query.filter_by(account_number='211').first()
        if not supplier_account:
            print("\n❌ لم يتم العثور على حساب الموردين (211)")
            return
        
        print(f"\n✓ حساب الموردين: {supplier_account.name} (ID: {supplier_account.id})")
        
        # 2. جلب فواتير الموردين
        legacy_supplier_purchase = 'شراء' + ' من ' + 'مورد'
        supplier_invoices = Invoice.query.filter(Invoice.invoice_type.in_(['شراء', legacy_supplier_purchase])).all()
        print(f"✓ عدد الفواتير: {len(supplier_invoices)}")
        
        fixed_count = 0
        
        for invoice in supplier_invoices:
            # جلب القيد المرتبط
            entry = JournalEntry.query.filter_by(
                reference_type='invoice',
                reference_id=invoice.id
            ).first()
            
            if not entry:
                continue
            
            print(f"\n📄 فاتورة #{invoice.id} - قيد #{entry.entry_number}")
            
            # البحث عن سطور فيها أوزان ذهب دائنة (للمورد) لكن في حساب خاطئ
            lines = JournalEntryLine.query.filter_by(journal_entry_id=entry.id).all()
            
            gold_weights = {
                '18k': 0.0,
                '21k': 0.0,
                '22k': 0.0,
                '24k': 0.0,
            }
            
            # جمع الأوزان من السطور الخاطئة
            for line in lines:
                # إذا كان السطر فيه ذهب دائن ولكن ليس على حساب الموردين
                if line.account_id != supplier_account.id:
                    if line.credit_18k > 0:
                        gold_weights['18k'] += line.credit_18k
                        print(f"  ❌ وجد ذهب 18k ({line.credit_18k} جم) في حساب {line.account.name if line.account else 'N/A'}")
                        # حذف من السطر الخاطئ
                        line.credit_18k = 0.0
                    
                    if line.credit_21k > 0:
                        gold_weights['21k'] += line.credit_21k
                        print(f"  ❌ وجد ذهب 21k ({line.credit_21k} جم) في حساب {line.account.name if line.account else 'N/A'}")
                        line.credit_21k = 0.0
                    
                    if line.credit_22k > 0:
                        gold_weights['22k'] += line.credit_22k
                        print(f"  ❌ وجد ذهب 22k ({line.credit_22k} جم) في حساب {line.account.name if line.account else 'N/A'}")
                        line.credit_22k = 0.0
                    
                    if line.credit_24k > 0:
                        gold_weights['24k'] += line.credit_24k
                        print(f"  ❌ وجد ذهب 24k ({line.credit_24k} جم) في حساب {line.account.name if line.account else 'N/A'}")
                        line.credit_24k = 0.0
            
            # إذا وُجدت أوزان، أضفها لحساب المورد
            if any(gold_weights.values()):
                # البحث عن سطر المورد الموجود أو إنشاء واحد جديد
                supplier_line = JournalEntryLine.query.filter_by(
                    journal_entry_id=entry.id,
                    account_id=supplier_account.id,
                    supplier_id=invoice.supplier_id
                ).first()
                
                if not supplier_line:
                    # إنشاء سطر جديد
                    supplier_line = JournalEntryLine(
                        journal_entry_id=entry.id,
                        account_id=supplier_account.id,
                        supplier_id=invoice.supplier_id,
                        cash_debit=0.0,
                        cash_credit=0.0
                    )
                    db.session.add(supplier_line)
                    print(f"  ✓ إنشاء سطر جديد للمورد")
                
                # إضافة الأوزان
                supplier_line.credit_18k = round(supplier_line.credit_18k + gold_weights['18k'], 3)
                supplier_line.credit_21k = round(supplier_line.credit_21k + gold_weights['21k'], 3)
                supplier_line.credit_22k = round(supplier_line.credit_22k + gold_weights['22k'], 3)
                supplier_line.credit_24k = round(supplier_line.credit_24k + gold_weights['24k'], 3)
                
                print(f"  ✅ تم نقل الأوزان إلى حساب المورد:")
                if gold_weights['18k'] > 0:
                    print(f"     18k: {gold_weights['18k']} جم")
                if gold_weights['21k'] > 0:
                    print(f"     21k: {gold_weights['21k']} جم")
                if gold_weights['22k'] > 0:
                    print(f"     22k: {gold_weights['22k']} جم")
                if gold_weights['24k'] > 0:
                    print(f"     24k: {gold_weights['24k']} جم")
                
                fixed_count += 1
        
        # حفظ التغييرات
        try:
            db.session.commit()
            print(f"\n✅ تم إصلاح {fixed_count} فاتورة")
        except Exception as e:
            db.session.rollback()
            print(f"\n❌ خطأ: {e}")
            return
        
        # إعادة حساب أرصدة الموردين
        print("\n📊 إعادة حساب أرصدة الموردين...")
        from backend.models import Supplier
        
        suppliers = Supplier.query.all()
        for supplier in suppliers:
            # حساب الأرصدة من القيود
            lines = JournalEntryLine.query.filter_by(supplier_id=supplier.id).all()
            
            cash = sum(line.cash_credit - line.cash_debit for line in lines)
            gold_18k = sum(line.credit_18k - line.debit_18k for line in lines)
            gold_21k = sum(line.credit_21k - line.debit_21k for line in lines)
            gold_22k = sum(line.credit_22k - line.debit_22k for line in lines)
            gold_24k = sum(line.credit_24k - line.debit_24k for line in lines)
            
            supplier.balance_cash = round(cash, 2)
            supplier.balance_gold_18k = round(gold_18k, 3)
            supplier.balance_gold_21k = round(gold_21k, 3)
            supplier.balance_gold_22k = round(gold_22k, 3)
            supplier.balance_gold_24k = round(gold_24k, 3)
            
            print(f"\n  ✓ {supplier.name}:")
            print(f"    النقدي: {supplier.balance_cash} ر.س")
            print(f"    18k: {supplier.balance_gold_18k} جم")
            print(f"    21k: {supplier.balance_gold_21k} جم")
            print(f"    22k: {supplier.balance_gold_22k} جم")
            print(f"    24k: {supplier.balance_gold_24k} جم")
        
        db.session.commit()
        
        print("\n" + "=" * 70)
        print("✅ اكتمل الإصلاح بنجاح!")
        print("=" * 70)

if __name__ == '__main__':
    fix_supplier_gold_entries()
