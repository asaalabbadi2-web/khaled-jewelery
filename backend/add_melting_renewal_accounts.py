#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
إضافة حسابات التجديد والتكسير إلى شجرة الحسابات
- حساب في المصروفات: أحجار وفصوص التكسير
- حساب في الإيرادات: أحجار وفصوص التجديد
"""

import sys
import os

# إضافة المسار الجذري للمشروع
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from backend.models import db, Account
from flask import Flask

# إنشاء تطبيق Flask
app = Flask(__name__)
app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('DATABASE_URL', f"sqlite:///{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'app.db')}")
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
db.init_app(app)

def add_melting_renewal_accounts():
    """إضافة حسابات التجديد والتكسير"""
    
    with app.app_context():
        print("\n🔍 البحث عن الحسابات الرئيسية...")
        
        # البحث عن حساب المصروفات الرئيسي
        expenses_account = Account.query.filter_by(
            account_number='5',
            name='المصروفات'
        ).first()
        
        if not expenses_account:
            print("❌ لم يتم العثور على حساب المصروفات الرئيسي (5)")
            return False
        
        print(f"✅ تم العثور على حساب المصروفات: {expenses_account.name}")
        
        # البحث عن حساب الإيرادات الرئيسي - نستخدم حساب إيرادات أخرى
        revenue_account = Account.query.filter_by(
            account_number='41',
            name='إيرادات أخرى'
        ).first()
        
        if not revenue_account:
            print("❌ لم يتم العثور على حساب إيرادات أخرى (41)")
            return False
        
        print(f"✅ تم العثور على حساب الإيرادات: {revenue_account.name}")
        
        # إنشاء حساب أحجار وفصوص التكسير (مصروفات)
        melting_expense = Account.query.filter_by(
            account_number='531'
        ).first()
        
        if melting_expense:
            print(f"⚠️  حساب أحجار وفصوص التكسير موجود بالفعل: {melting_expense.name}")
        else:
            melting_expense = Account(
                account_number='531',
                name='أحجار وفصوص التكسير',
                type='expense',
                transaction_type='cash',
                parent_id=expenses_account.id
            )
            db.session.add(melting_expense)
            print(f"✅ تم إنشاء حساب أحجار وفصوص التكسير (531)")
        
        # إنشاء حساب أحجار وفصوص التجديد (إيرادات)
        renewal_revenue = Account.query.filter_by(
            account_number='416'
        ).first()
        
        if renewal_revenue:
            print(f"⚠️  حساب أحجار وفصوص التجديد موجود بالفعل: {renewal_revenue.name}")
        else:
            renewal_revenue = Account(
                account_number='416',
                name='أحجار وفصوص التجديد',
                type='revenue',
                transaction_type='cash',
                parent_id=revenue_account.id
            )
            db.session.add(renewal_revenue)
            print(f"✅ تم إنشاء حساب أحجار وفصوص التجديد (416)")
        
        # حفظ التغييرات
        try:
            db.session.commit()
            print("\n✅ تم حفظ الحسابات بنجاح!")
            print("\n📊 ملخص الحسابات المضافة:")
            print("=" * 60)
            print(f"1. حساب المصروفات:")
            print(f"   - رقم الحساب: 531")
            print(f"   - الاسم: أحجار وفصوص التكسير")
            print(f"   - النوع: مصروفات")
            print(f"\n2. حساب الإيرادات:")
            print(f"   - رقم الحساب: 416")
            print(f"   - الاسم: أحجار وفصوص التجديد")
            print(f"   - النوع: إيرادات")
            print("=" * 60)
            return True
        except Exception as e:
            db.session.rollback()
            print(f"\n❌ خطأ في حفظ الحسابات: {e}")
            return False

def check_accounts():
    """التحقق من وجود الحسابات"""
    
    with app.app_context():
        print("\n🔍 التحقق من حسابات التجديد والتكسير...")
        print("=" * 60)
        
        melting_expense = Account.query.filter_by(
            account_number='531'
        ).first()
        
        renewal_revenue = Account.query.filter_by(
            account_number='416'
        ).first()
        
        if melting_expense:
            print(f"✅ حساب التكسير موجود:")
            print(f"   - ID: {melting_expense.id}")
            print(f"   - رقم الحساب: {melting_expense.account_number}")
            print(f"   - الاسم: {melting_expense.name}")
            print(f"   - النوع: {melting_expense.account_type}")
        else:
            print("❌ حساب التكسير غير موجود")
        
        print()
        
        if renewal_revenue:
            print(f"✅ حساب التجديد موجود:")
            print(f"   - ID: {renewal_revenue.id}")
            print(f"   - رقم الحساب: {renewal_revenue.account_number}")
            print(f"   - الاسم: {renewal_revenue.name}")
            print(f"   - النوع: {renewal_revenue.account_type}")
        else:
            print("❌ حساب التجديد غير موجود")
        
        print("=" * 60)

if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser(
        description='إدارة حسابات التجديد والتكسير'
    )
    parser.add_argument(
        '--add',
        action='store_true',
        help='إضافة الحسابات'
    )
    parser.add_argument(
        '--check',
        action='store_true',
        help='التحقق من الحسابات'
    )
    
    args = parser.parse_args()
    
    if args.add:
        print("\n📝 إضافة حسابات التجديد والتكسير...")
        success = add_melting_renewal_accounts()
        if success:
            check_accounts()
    elif args.check:
        check_accounts()
    else:
        # الوضع الافتراضي: إضافة والتحقق
        print("\n📝 إضافة حسابات التجديد والتكسير...")
        success = add_melting_renewal_accounts()
        if success:
            check_accounts()
