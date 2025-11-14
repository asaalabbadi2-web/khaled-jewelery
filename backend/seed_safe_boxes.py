#!/usr/bin/env python3
"""
إنشاء الخزائن الافتراضية
"""
from sqlalchemy import or_

def seed_safe_boxes():
    """إنشاء الخزائن الافتراضية"""
    import sys
    import os
    sys.path.insert(0, os.path.dirname(__file__))
    
    from app import app
    from backend.models import db, SafeBox, Account
    
    with app.app_context():
        print("🔄 بدء إنشاء الخزائن الافتراضية...")
        
        # البحث عن الحسابات
        accounts = {
            'cash_main': Account.query.filter(
                or_(
                    Account.account_number == '1000',
                    Account.account_number == '1000.1',
                    Account.name.like('%صندوق النقدية%'),
                    Account.name.like('%الصندوق الرئيسي%')
                )
            ).first(),
            'bank_riyadh': Account.query.filter(
                or_(
                    Account.account_number == '1010',
                    Account.name.like('%بنك الرياض%')
                )
            ).first(),
            'bank_rajhi': Account.query.filter(
                or_(
                    Account.account_number == '1020',
                    Account.name.like('%بنك الراجحي%')
                )
            ).first(),
            'bank_ahli': Account.query.filter(
                or_(
                    Account.account_number == '1030',
                    Account.name.like('%البنك الأهلي%')
                )
            ).first(),
        }
        
        # البحث عن حسابات الذهب (يمكن إضافتها لاحقاً)
        gold_accounts = {
            18: Account.query.filter(Account.name.like('%عيار 18%')).first(),
            21: Account.query.filter(Account.name.like('%عيار 21%')).first(),
            22: Account.query.filter(Account.name.like('%عيار 22%')).first(),
            24: Account.query.filter(Account.name.like('%عيار 24%')).first(),
        }
        
        safe_boxes = []
        
        # 1. خزينة النقدية الرئيسية
        if accounts['cash_main']:
            if not SafeBox.query.filter_by(name='صندوق النقدية الرئيسي').first():
                safe_boxes.append(SafeBox(
                    name='صندوق النقدية الرئيسي',
                    name_en='Main Cash Box',
                    safe_type='cash',
                    account_id=accounts['cash_main'].id,
                    is_active=True,
                    is_default=True,
                    notes='الصندوق النقدي الرئيسي للمحل',
                    created_by='system'
                ))
        
        # 2. خزائن البنوك
        if accounts['bank_riyadh']:
            if not SafeBox.query.filter_by(name='بنك الرياض').first():
                safe_boxes.append(SafeBox(
                    name='بنك الرياض',
                    name_en='Riyad Bank',
                    safe_type='bank',
                    account_id=accounts['bank_riyadh'].id,
                    bank_name='بنك الرياض',
                    is_active=True,
                    is_default=True,  # البنك الافتراضي
                    notes='الحساب البنكي الرئيسي',
                    created_by='system'
                ))
        
        if accounts['bank_rajhi']:
            if not SafeBox.query.filter_by(name='مصرف الراجحي').first():
                safe_boxes.append(SafeBox(
                    name='مصرف الراجحي',
                    name_en='Al Rajhi Bank',
                    safe_type='bank',
                    account_id=accounts['bank_rajhi'].id,
                    bank_name='مصرف الراجحي',
                    is_active=True,
                    is_default=False,
                    notes='حساب بنكي ثانوي',
                    created_by='system'
                ))
        
        if accounts['bank_ahli']:
            if not SafeBox.query.filter_by(name='البنك الأهلي').first():
                safe_boxes.append(SafeBox(
                    name='البنك الأهلي',
                    name_en='Al Ahli Bank',
                    safe_type='bank',
                    account_id=accounts['bank_ahli'].id,
                    bank_name='البنك الأهلي التجاري',
                    is_active=True,
                    is_default=False,
                    notes='حساب بنكي ثانوي',
                    created_by='system'
                ))
        
        # 3. خزائن الذهب (حسب العيار)
        karats = [18, 21, 22, 24]
        karat_names = {
            18: 'صندوق الذهب عيار 18',
            21: 'صندوق الذهب عيار 21',
            22: 'صندوق الذهب عيار 22',
            24: 'صندوق الكسر عيار 24',
        }
        
        for karat in karats:
            if gold_accounts.get(karat):
                name = karat_names[karat]
                if not SafeBox.query.filter_by(name=name).first():
                    safe_boxes.append(SafeBox(
                        name=name,
                        name_en=f'Gold Box {karat}K',
                        safe_type='gold',
                        account_id=gold_accounts[karat].id,
                        karat=karat,
                        is_active=True,
                        is_default=(karat == 21),  # عيار 21 هو الافتراضي
                        notes=f'خزينة الذهب عيار {karat}',
                        created_by='system'
                    ))
        
        # حفظ جميع الخزائن
        if safe_boxes:
            db.session.add_all(safe_boxes)
            db.session.commit()
            print(f"✅ تم إنشاء {len(safe_boxes)} خزينة بنجاح:")
            for sb in safe_boxes:
                print(f"   - {sb.name} ({sb.safe_type})")
        else:
            print("⚠️ لم يتم إنشاء أي خزائن (قد تكون موجودة مسبقاً)")
        
        # عرض جميع الخزائن
        all_safes = SafeBox.query.all()
        print(f"\n📦 إجمالي الخزائن: {len(all_safes)}")
        for sb in all_safes:
            default_str = "⭐ افتراضي" if sb.is_default else ""
            active_str = "✅" if sb.is_active else "❌"
            print(f"   {active_str} {sb.name} ({sb.safe_type}) {default_str}")

if __name__ == '__main__':
    seed_safe_boxes()
