#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
إعادة تنظيم وتصحيح شجرة الحسابات
Reorganize and Fix Chart of Accounts

هذا السكريبت يقوم بـ:
1. تصحيح أسماء الحسابات المختلطة
2. تصحيح تصنيفات الحسابات (type)
3. إعادة ترتيب الحسابات المنقولة
4. إضافة الحسابات الناقصة
"""

import sys
import os

backend_dir = os.path.dirname(os.path.abspath(__file__))
parent_dir = os.path.dirname(backend_dir)
sys.path.insert(0, parent_dir)

from backend.app import app
from backend.models import db, Account

def fix_chart_of_accounts():
    """تطبيق التصحيحات على شجرة الحسابات"""
    
    with app.app_context():
        print("\n" + "="*80)
        print("🔧 إعادة تنظيم شجرة الحسابات")
        print("="*80)
        
        changes_made = []
        
        # 1. تصحيح حساب 130
        acc_130 = Account.query.filter_by(account_number='130').first()
        if acc_130:
            if acc_130.name != 'حسابات الموظفين':
                old_name = acc_130.name
                acc_130.name = 'حسابات الموظفين'
                changes_made.append(f"✅ 130: '{old_name}' → 'حسابات الموظفين'")
            if acc_130.type != 'Asset':
                acc_130.type = 'Asset'
                changes_made.append("✅ 130: تصحيح type إلى 'Asset'")
        
        # 2. إنشاء حساب 1300 إذا لم يكن موجوداً
        acc_1300 = Account.query.filter_by(account_number='1300').first()
        if not acc_1300:
            parent_130 = Account.query.filter_by(account_number='130').first()
            acc_1300 = Account(
                account_number='1300',
                name='موظفو الإدارة',
                type='Asset',
                transaction_type='cash',
                parent_id=parent_130.id if parent_130 else None
            )
            db.session.add(acc_1300)
            changes_made.append("✅ إنشاء: 1300 - موظفو الإدارة")
        
        # 3. تصحيح حساب 1310
        acc_1310 = Account.query.filter_by(account_number='1310').first()
        if acc_1310 and 'تأمينات' in acc_1310.name:
            # حفظ الاسم القديم
            old_name_1310 = acc_1310.name
            
            # التحقق من وجود حساب 1410
            acc_1410 = Account.query.filter_by(account_number='1410').first()
            if not acc_1410:
                # إنشاء 1410 للتأمينات
                parent_140 = Account.query.filter_by(account_number='140').first()
                acc_1410 = Account(
                    account_number='1410',
                    name='تأمينات مستردة',
                    type='Asset',
                    transaction_type='cash',
                    parent_id=parent_140.id if parent_140 else None
                )
                db.session.add(acc_1410)
                changes_made.append("✅ إنشاء: 1410 - تأمينات مستردة")
            
            # تحديث 1310
            acc_1310.name = 'موظفو المبيعات'
            acc_1310.type = 'Asset'
            parent_130 = Account.query.filter_by(account_number='130').first()
            if parent_130:
                acc_1310.parent_id = parent_130.id
            changes_made.append(f"✅ 1310: '{old_name_1310}' → 'موظفو المبيعات'")
        
        # 4. تصحيح حساب 1320
        acc_1320 = Account.query.filter_by(account_number='1320').first()
        if acc_1320 and 'ودائع' in acc_1320.name:
            old_name_1320 = acc_1320.name
            
            # إنشاء 1420 للودائع
            acc_1420 = Account.query.filter_by(account_number='1420').first()
            if not acc_1420:
                parent_140 = Account.query.filter_by(account_number='140').first()
                acc_1420 = Account(
                    account_number='1420',
                    name='ودائع قصيرة الأجل',
                    type='Asset',
                    transaction_type='cash',
                    parent_id=parent_140.id if parent_140 else None
                )
                db.session.add(acc_1420)
                changes_made.append("✅ إنشاء: 1420 - ودائع قصيرة الأجل")
            
            # تحديث 1320
            acc_1320.name = 'موظفو الصيانة'
            acc_1320.type = 'Asset'
            parent_130 = Account.query.filter_by(account_number='130').first()
            if parent_130:
                acc_1320.parent_id = parent_130.id
            changes_made.append(f"✅ 1320: '{old_name_1320}' → 'موظفو الصيانة'")
        
        # 5. تصحيح حساب 140
        acc_140 = Account.query.filter_by(account_number='140').first()
        if acc_140:
            if acc_140.name != 'سلف وودائع ومصروفات مقدمة':
                old_name_140 = acc_140.name
                acc_140.name = 'سلف وودائع ومصروفات مقدمة'
                changes_made.append(f"✅ 140: '{old_name_140}' → 'سلف وودائع ومصروفات مقدمة'")
            if acc_140.type != 'Asset':
                acc_140.type = 'Asset'
                changes_made.append("✅ 140: تصحيح type إلى 'Asset'")
        
        # 6. ضبط أب الحساب 1400 تحت 140
        acc_1400 = Account.query.filter_by(account_number='1400').first()
        if acc_1400:
            parent_140 = Account.query.filter_by(account_number='140').first()
            if parent_140 and acc_1400.parent_id != parent_140.id:
                acc_1400.parent_id = parent_140.id
                changes_made.append("✅ 1400: ربط الحساب تحت 140")

        # 7. تصحيح نوع حساب 1330 و 1340
        for acc_num in ['1330', '1340']:
            acc = Account.query.filter_by(account_number=acc_num).first()
            if acc:
                if acc.type.lower() != 'asset':
                    acc.type = 'Asset'
                    changes_made.append(f"✅ {acc_num}: تصحيح type إلى 'Asset'")
        
        # 8. نقل "مشتريات الكسر" من الإيرادات إلى المصروفات
        acc_431 = Account.query.filter_by(account_number='431').first()
        if acc_431 and acc_431.type == 'asset':  # مكتوب خطأ في النوع
            # التحقق من عدم وجود 5230
            acc_5230 = Account.query.filter_by(account_number='5230').first()
            if not acc_5230:
                parent_520 = Account.query.filter_by(account_number='520').first()
                if not parent_520:
                    # إنشاء 520 إذا لم يكن موجوداً
                    parent_52 = Account.query.filter_by(account_number='52').first()
                    parent_520 = Account(
                        account_number='520',
                        name='تكلفة البضاعة المباعة',
                        type='Expense',
                        transaction_type='both',
                        parent_id=parent_52.id if parent_52 else None
                    )
                    db.session.add(parent_520)
                    db.session.flush()
                
                # نقل 431 إلى 5230
                acc_5230 = Account(
                    account_number='5230',
                    name='مشتريات الكسر والتسكير',
                    type='Expense',
                    transaction_type='both',
                    parent_id=parent_520.id
                )
                db.session.add(acc_5230)
                changes_made.append("✅ نقل: 431 → 5230 (مشتريات الكسر من الإيرادات إلى المصروفات)")
                
                # حذف 431 القديم
                db.session.delete(acc_431)
                changes_made.append("✅ حذف: 431 (القديم)")
        
        # 9. تصحيح نوع حساب 5200
        acc_5200 = Account.query.filter_by(account_number='5200').first()
        if acc_5200:
            if acc_5200.name == 'مصروف العمولات' and acc_5200.type != 'Expense':
                acc_5200.type = 'Expense'
                changes_made.append("✅ 5200: تصحيح type إلى 'Expense'")
        
        # 10. إعادة ترقيم الأصول غير المتداولة لتكون ضمن نطاق 20x تحت الأصول
        # الهدف: الأصل الرئيسي رقم 20، وفروعه تبدأ بـ200
        renumber_map = [
            # تحويل حساب الأصول الثابتة/الموجود حالياً إلى "الأصول غير المتداولة" رقم 20
            ('160', '20', 'الأصول غير المتداولة', '1'),
            # فروع الأصول غير المتداولة يجب أن تبدأ بـ200
            ('1610', '200', 'أثاث وتجهيزات', '20'),
            ('1620', '210', 'أجهزة ومعدات', '20'),
            ('1630', '220', 'سيارات', '20'),
            ('1640', '230', 'مصروفات تحسين محل', '20'),
            ('170', '240', 'مجمع إهلاك الأصول الثابتة', '20'),
        ]

        for old_number, new_number, new_name, parent_number in renumber_map:
            acc = Account.query.filter_by(account_number=old_number).first()
            if not acc:
                continue

            if acc.account_number != new_number:
                conflict = Account.query.filter_by(account_number=new_number).first()
                if conflict and conflict.id != acc.id:
                    changes_made.append(
                        f"⚠️ تعذر إعادة ترقيم {old_number} إلى {new_number} (الحساب موجود: {conflict.name})"
                    )
                else:
                    acc.account_number = new_number
                    changes_made.append(f"✅ إعادة ترقيم {old_number} → {new_number}")

            if acc.name != new_name:
                old_name = acc.name
                acc.name = new_name
                changes_made.append(f"✅ {acc.account_number}: '{old_name}' → '{new_name}'")

            if parent_number:
                parent = Account.query.filter_by(account_number=parent_number).first()
                if parent and acc.parent_id != parent.id:
                    acc.parent_id = parent.id
                    changes_made.append(
                        f"✅ {acc.account_number}: تحديث الحساب الأب إلى {parent.account_number}"
                    )

            if acc.type != 'Asset':
                acc.type = 'Asset'
                changes_made.append(f"✅ {acc.account_number}: تصحيح type إلى 'Asset'")

            if acc.transaction_type not in ('cash', 'both'):
                acc.transaction_type = 'cash'

        # ضبط مجموعة الإهلاك لتكون تحت 20 (الأصول غير المتداولة)
        acc_170 = Account.query.filter_by(account_number='170').first()
        if acc_170:
            parent_20 = Account.query.filter_by(account_number='20').first()
            if parent_20 and acc_170.parent_id != parent_20.id:
                acc_170.parent_id = parent_20.id
                changes_made.append("✅ 170: ربط الحساب تحت 20")

        # 11. ربط الحسابات التفصيلية ذات العلاقة
        adjustments = [
            ('5200', '50'),   # مصروف العمولات ضمن المصاريف التشغيلية
            ('5230', '52'),   # مشتريات الكسر ضمن تكلفة البضاعة المباعة
        ]
        for acc_number, parent_number in adjustments:
            acc = Account.query.filter_by(account_number=acc_number).first()
            parent = Account.query.filter_by(account_number=parent_number).first() if parent_number else None
            if acc and parent and acc.parent_id != parent.id:
                acc.parent_id = parent.id
                changes_made.append(
                    f"✅ {acc.account_number}: تحديث الحساب الأب إلى {parent.account_number}"
                )

        # 12. توحيد جميع أنواع الحسابات (Capitalize)
        all_accounts = Account.query.all()
        for acc in all_accounts:
            if acc.type and acc.type[0].islower():
                acc.type = acc.type.capitalize()
        
        # 13. إضافة حساب 150 إذا لم يكن موجوداً
        acc_150 = Account.query.filter_by(account_number='150').first()
        if not acc_150:
            parent_1 = Account.query.filter_by(account_number='1').first()
            acc_150 = Account(
                account_number='150',
                name='ضريبة القيمة المضافة (مدينة)',
                type='Asset',
                transaction_type='cash',
                parent_id=parent_1.id if parent_1 else None
            )
            db.session.add(acc_150)
            changes_made.append("✅ إنشاء: 150 - ضريبة القيمة المضافة (مدينة)")
        
        # الآن نطبق التغييرات
        try:
            db.session.commit()
            print("\n" + "="*80)
            print("✅ تم تطبيق التصحيحات بنجاح!")
            print("="*80)
            print("\nالتغييرات المطبقة:")
            for i, change in enumerate(changes_made, 1):
                print(f"{i}. {change}")
            print("\n" + "="*80)
            print(f"📊 إجمالي التغييرات: {len(changes_made)}")
            print("="*80)
            
        except Exception as e:
            db.session.rollback()
            print(f"\n❌ خطأ: {e}")
            import traceback
            traceback.print_exc()

if __name__ == '__main__':
    import sys
    
    if '--apply' in sys.argv:
        fix_chart_of_accounts()
    else:
        print("\n⚠️  هذا السكريبت سيعدل شجرة الحسابات في قاعدة البيانات")
        print("لتطبيق التغييرات، شغل:")
        print("  python reorganize_chart_of_accounts.py --apply")
