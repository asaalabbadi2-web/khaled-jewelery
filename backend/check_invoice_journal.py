#!/usr/bin/env python3
"""
فحص تفاصيل القيود المحاسبية لفاتورة معينة
"""

import sys
import os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from backend.models import db, JournalEntry, JournalEntryLine, Account
from flask import Flask
from flask_cors import CORS

def check_invoice_journal_entry(invoice_id=1):
    """فحص قيود فاتورة معينة"""
    
    app = Flask(__name__)
    app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('DATABASE_URL', f"sqlite:///{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'app.db')}")
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    
    CORS(app)
    db.init_app(app)
    
    with app.app_context():
        print("=" * 70)
        print(f"🔍 فحص جميع قيود الفاتورة #{invoice_id}")
        print("=" * 70)
        
        entry = JournalEntry.query.filter_by(reference_type='invoice', reference_id=invoice_id).first()
        
        if not entry:
            print(f"\n❌ لم يتم العثور على قيد للفاتورة #{invoice_id}")
            return
        
        print(f"\nالقيد: #{entry.entry_number}")
        print(f"التاريخ: {entry.date}")
        print(f"الوصف: {entry.description}")
        print(f"\n{'الحساب':<30} {'نقدي مدين':>15} {'نقدي دائن':>15} {'ذهب 21k دائن':>15} {'supplier_id':>12}")
        print("-" * 90)
        
        lines = JournalEntryLine.query.filter_by(journal_entry_id=entry.id).all()
        
        total_debit = 0
        total_credit = 0
        
        for line in lines:
            acc = db.session.get(Account, line.account_id)
            acc_name = acc.name if acc else "N/A"
            
            print(f"{acc_name:<30} {line.cash_debit:>15.2f} {line.cash_credit:>15.2f} {line.credit_21k:>15.3f} {str(line.supplier_id):>12}")
            
            total_debit += line.cash_debit
            total_credit += line.cash_credit
        
        print("-" * 90)
        print(f"{'الإجمالي':<30} {total_debit:>15.2f} {total_credit:>15.2f}")
        
        if abs(total_debit - total_credit) < 0.01:
            print("\n✅ القيد متوازن")
        else:
            print(f"\n❌ القيد غير متوازن! الفرق: {total_debit - total_credit:.2f}")
        
        print("\n" + "=" * 70)

if __name__ == '__main__':
    import sys
    invoice_id = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    check_invoice_journal_entry(invoice_id)
