#!/usr/bin/env python3
"""
تفعيل تتبع الوزن لحساب الموردين التجميعي
Enable weight tracking for suppliers account
"""

import sys
import os

# Add the parent directory to the path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from backend.models import db, Account
from flask import Flask
from flask_cors import CORS

def enable_supplier_weight_tracking():
    """تفعيل tracks_weight لحساب الموردين"""
    
    # Create Flask app
    app = Flask(__name__)
    app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('DATABASE_URL', f"sqlite:///{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'app.db')}")
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    
    CORS(app)
    db.init_app(app)
    
    with app.app_context():
        # البحث عن حساب الموردين بالرقم
        supplier_account = Account.query.filter_by(account_number='211').first()
        
        if not supplier_account:
            print("❌ لم يتم العثور على حساب الموردين (211)")
            print("🔍 البحث عن حساب باسم 'الموردين'...")
            
            # محاولة البحث بالاسم
            supplier_account = Account.query.filter(
                Account.name.like('%موردين%')
            ).first()
        
        if supplier_account:
            print(f"✅ تم العثور على الحساب:")
            print(f"   - ID: {supplier_account.id}")
            print(f"   - رقم الحساب: {supplier_account.account_number}")
            print(f"   - الاسم: {supplier_account.name}")
            print(f"   - tracks_weight حالياً: {supplier_account.tracks_weight}")
            
            if not supplier_account.tracks_weight:
                supplier_account.tracks_weight = True
                db.session.commit()
                print(f"✅ تم تفعيل تتبع الوزن للحساب '{supplier_account.name}'")
            else:
                print(f"ℹ️  تتبع الوزن مُفعّل بالفعل")
            
            return True
        else:
            print("❌ لم يتم العثور على حساب الموردين")
            print("\n📋 الحسابات المتاحة:")
            accounts = Account.query.filter(
                Account.type == 'Liability'
            ).all()
            
            for acc in accounts:
                print(f"   - {acc.account_number}: {acc.name} (tracks_weight={acc.tracks_weight})")
            
            return False

if __name__ == '__main__':
    print("=" * 60)
    print("🔧 تفعيل تتبع الوزن لحساب الموردين")
    print("=" * 60)
    
    success = enable_supplier_weight_tracking()
    
    print("\n" + "=" * 60)
    if success:
        print("✅ تمت العملية بنجاح")
    else:
        print("⚠️  يرجى التحقق من شجرة الحسابات")
    print("=" * 60)
