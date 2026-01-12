#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
إعداد الربط المحاسبي لفواتير شراء (مورد) - نسخة مبسطة
"""

import os
import sys

# Add backend to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from flask import Flask
from config import Config

# Create simple Flask app
app = Flask(__name__)
app.config.from_object(Config)

# Import models (db is already defined in models.py)
from models import db, Account, AccountingMapping

# Initialize database
db.init_app(app)

def setup_mappings():
    """إعداد الربط المحاسبي لفواتير شراء (مورد)"""
    
    print("=" * 80)
    print("⚙️  إعداد الربط المحاسبي لفواتير شراء (مورد)")
    print("=" * 80)
    
    with app.app_context():
        # البحث عن الحسابات
        print("\n1️⃣ البحث عن الحسابات...")
        
        # الموردون
        suppliers = Account.query.filter(
            Account.name.like('%مورد%'),
            Account.tracks_weight == True
        ).first()
        
        if not suppliers:
            print("   ⚠️  لم يتم العثور على حساب موردين يتتبع الوزن")
            print("   💡 سأبحث عن أي حساب موردين...")
            suppliers = Account.query.filter(Account.name.like('%مورد%')).first()
        
        if suppliers:
            print(f"   ✅ حساب الموردين: {suppliers.name} (#{suppliers.id})")
        else:
            print("   ❌ لم يتم العثور على حساب موردين - يجب إنشاؤه يدوياً")
            return False
        
        # المخزون
        inventories = {}
        for karat in [18, 21, 22, 24]:
            inv = Account.query.filter(
                Account.name.like(f'%{karat}%'),
                Account.account_type == 'asset',
                Account.tracks_weight == True
            ).first()
            
            if inv:
                inventories[karat] = inv
                print(f"   ✅ مخزون {karat}: {inv.name} (#{inv.id})")
        
        if not inventories:
            print("   ❌ لم يتم العثور على حسابات مخزون")
            return False
        
        # 2️⃣ إنشاء/تحديث الربط
        print("\n2️⃣ إنشاء الربط المحاسبي...")
        
        mappings_data = [
            ('suppliers', suppliers.id),
            ('suppliers_weight', suppliers.id),
            ('supplier_bridge', suppliers.id),  # مؤقتاً نستخدم نفس الحساب
        ]
        
        # إضافة حسابات المخزون
        for karat, inv in inventories.items():
            mappings_data.append((f'inventory_{karat}k', inv.id))
        
        created = 0
        updated = 0
        
        legacy_supplier_purchase = 'شراء' + ' من ' + 'مورد'
        for account_type, account_id in mappings_data:
            existing = AccountingMapping.query.filter_by(
                account_type=account_type
            ).first()

            if not existing:
                existing = AccountingMapping.query.filter_by(
                    invoice_type=legacy_supplier_purchase,
                    account_type=account_type
                ).first()
            
            if existing:
                existing.account_id = account_id
                updated += 1
                print(f"   🔄 {account_type} → #{account_id}")
            else:
                mapping = AccountingMapping(
                    invoice_type='شراء',
                    account_type=account_type,
                    account_id=account_id
                )
                db.session.add(mapping)
                created += 1
                print(f"   ✅ {account_type} → #{account_id}")
        
        try:
            db.session.commit()
            print(f"\n✅ تم الحفظ! (جديد: {created}, محدث: {updated})")
            return True
        except Exception as e:
            db.session.rollback()
            print(f"\n❌ خطأ: {e}")
            return False

if __name__ == "__main__":
    success = setup_mappings()
    sys.exit(0 if success else 1)
