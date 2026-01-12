#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
إعداد الربط المحاسبي لفواتير شراء (مورد)
Setup Accounting Mappings for Supplier Purchase Invoices
"""

import sys
import os

# تأكد من تشغيل السكريبت من مجلد backend
if not os.path.exists('app.py'):
    print("❌ يجب تشغيل هذا السكريبت من مجلد backend")
    sys.exit(1)

# استيراد التطبيق والنماذج باستخدام نفس مثيل SQLAlchemy كما في الخادم الرئيسي
from app import app, db
from models import Account, AccountingMapping

def setup_mappings():
    """إعداد الربط المحاسبي الأساسي لفواتير شراء (مورد)"""
    
    print("=" * 80)
    print("⚙️  إعداد الربط المحاسبي لفواتير شراء (مورد)")
    print("=" * 80)
    
    with app.app_context():
        # 1️⃣ البحث عن الحسابات المطلوبة
        print("\n1️⃣ البحث عن الحسابات المحاسبية...")
        
        # حساب الموردين (يتتبع الوزن)
        suppliers_account = Account.query.filter(
            Account.name.like('%مورد%'),
            Account.tracks_weight == True
        ).first()
        
        if not suppliers_account:
            # إنشاء حساب موردين إذا لم يكن موجوداً
            suppliers_account = Account(
                name="الموردون",
                account_number="211",
                type="Liability",
                account_type="liability",
                tracks_weight=True
            )
            db.session.add(suppliers_account)
            db.session.flush()
            print(f"   ✅ تم إنشاء حساب الموردين #{suppliers_account.id}")
        else:
            print(f"   ✅ حساب الموردين: {suppliers_account.name} (#{suppliers_account.id})")
        
        # حساب جسر المورد
        bridge_account = Account.query.filter(
            Account.name.like('%جسر%'),
            Account.name.like('%مورد%')
        ).first()
        
        if not bridge_account:
            bridge_account = Account(
                name="حساب جسر الموردين",
                account_number="211-99",
                type="Liability",
                account_type="liability",
                tracks_weight=False
            )
            db.session.add(bridge_account)
            db.session.flush()
            print(f"   ✅ تم إنشاء حساب الجسر #{bridge_account.id}")
        else:
            print(f"   ✅ حساب الجسر: {bridge_account.name} (#{bridge_account.id})")
        
        # حسابات المخزون
        inventory_accounts = {}
        for karat in [18, 21, 22, 24]:
            inv_acc = Account.query.filter(
                Account.name.like(f'%مخزون%{karat}%'),
                Account.tracks_weight == True
            ).first()
            
            if not inv_acc:
                inv_acc = Account(
                    name=f"مخزون ذهب عيار {karat}",
                    account_number=f"14{karat}",
                    type="Asset",
                    account_type="asset",
                    tracks_weight=True
                )
                db.session.add(inv_acc)
                db.session.flush()
                print(f"   ✅ تم إنشاء حساب مخزون عيار {karat} #{inv_acc.id}")
            else:
                print(f"   ✅ مخزون عيار {karat}: {inv_acc.name} (#{inv_acc.id})")
            
            inventory_accounts[karat] = inv_acc
        
        # ضريبة القيمة المضافة
        vat_account = Account.query.filter(
            Account.name.like('%ضريبة%'),
            Account.name.like('%مضافة%')
        ).first()
        
        if not vat_account:
            vat_account = Account(
                name="ضريبة القيمة المضافة المستحقة",
                account_number="1361",
                type="Asset",
                account_type="asset",
                tracks_weight=False
            )
            db.session.add(vat_account)
            db.session.flush()
            print(f"   ✅ تم إنشاء حساب الضريبة #{vat_account.id}")
        else:
            print(f"   ✅ حساب الضريبة: {vat_account.name} (#{vat_account.id})")
        
        # أجور المصنعية
        wage_account = Account.query.filter(
            Account.name.like('%أجور%'),
            Account.name.like('%مصنعية%')
        ).first()
        
        if not wage_account:
            # يمكن استخدام حساب المخزون لأجور المصنعية
            wage_account = inventory_accounts[21]  # نستخدم مخزون 21 كبديل
            print(f"   ⚠️  لم يتم العثور على حساب أجور مصنعية، سيتم استخدام مخزون 21")
        else:
            print(f"   ✅ حساب الأجور: {wage_account.name} (#{wage_account.id})")
        
        # 2️⃣ إنشاء الربط المحاسبي
        print("\n2️⃣ إنشاء الربط المحاسبي...")
        
        mappings_to_create = [
            ('suppliers', suppliers_account.id, 'حساب الموردين الأساسي'),
            ('suppliers_weight', suppliers_account.id, 'حساب الموردين (يتتبع الوزن)'),
            ('supplier_bridge', bridge_account.id, 'حساب جسر تقييم المورد'),
            ('inventory_18k', inventory_accounts[18].id, 'مخزون عيار 18'),
            ('inventory_21k', inventory_accounts[21].id, 'مخزون عيار 21'),
            ('inventory_22k', inventory_accounts[22].id, 'مخزون عيار 22'),
            ('inventory_24k', inventory_accounts[24].id, 'مخزون عيار 24'),
            ('vat_receivable', vat_account.id, 'ضريبة القيمة المضافة'),
            ('manufacturing_wage', wage_account.id, 'أجور المصنعية (مصروف)'),
            ('manufacturing_wage_inventory', wage_account.id, 'أجور المصنعية (رسملة ضمن المخزون)'),
        ]
        
        created_count = 0
        updated_count = 0

        legacy_supplier_purchase = 'شراء' + ' من ' + 'مورد'
        
        for account_type, account_id, description in mappings_to_create:
            # التحقق من وجود الربط
            existing = AccountingMapping.query.filter_by(
                operation_type='شراء',
                account_type=account_type
            ).first()

            if not existing:
                existing = AccountingMapping.query.filter_by(
                    operation_type=legacy_supplier_purchase,
                    account_type=account_type
                ).first()
            
            if existing:
                existing.account_id = account_id
                updated_count += 1
                print(f"   🔄 تحديث: {account_type} → حساب #{account_id}")
            else:
                mapping = AccountingMapping(
                    operation_type='شراء',
                    account_type=account_type,
                    account_id=account_id
                )
                db.session.add(mapping)
                created_count += 1
                print(f"   ✅ إضافة: {account_type} → حساب #{account_id}")
        
        # 3️⃣ حفظ التغييرات
        try:
            db.session.commit()
            print(f"\n✅ تم حفظ الإعدادات بنجاح!")
            print(f"   - جديد: {created_count}")
            print(f"   - محدث: {updated_count}")
            print(f"   - الإجمالي: {created_count + updated_count}")
        except Exception as e:
            db.session.rollback()
            print(f"\n❌ خطأ في حفظ الإعدادات: {e}")
            return False
        
        # 4️⃣ عرض ملخص الإعدادات
        print("\n" + "=" * 80)
        print("📋 ملخص الربط المحاسبي لفواتير شراء (مورد):")
        print("=" * 80)
        
        mappings = AccountingMapping.query.filter_by(
            operation_type='شراء'
        ).all()
        
        for mapping in mappings:
            account = Account.query.get(mapping.account_id)
            print(f"\n  🔸 {mapping.account_type}")
            print(f"     الحساب: {account.name if account else 'غير معروف'}")
            print(f"     رقم الحساب: {account.account_number if account else 'N/A'}")
            print(f"     يتتبع الوزن: {'✅ نعم' if account and account.tracks_weight else '❌ لا'}")
        
        print("\n" + "=" * 80)
        print("✅ تم إعداد النظام بنجاح! يمكنك الآن إنشاء فواتير شراء (مورد)")
        print("=" * 80)
        
        return True

if __name__ == "__main__":
    success = setup_mappings()
    sys.exit(0 if success else 1)
