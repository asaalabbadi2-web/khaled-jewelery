#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
تحديث جدول المكاتب (Office) لإضافة account_category_id
"""

from app import app, db
from models import Office

print("=" * 60)
print("تحديث جدول المكاتب (Office)")
print("=" * 60)

with app.app_context():
    try:
        # إضافة عمود account_category_id إذا لم يكن موجوداً
        with db.engine.connect() as conn:
            # التحقق من وجود العمود
            result = conn.execute(db.text("PRAGMA table_info(office)")).fetchall()
            columns = [col[1] for col in result]
            
            if 'account_category_id' not in columns:
                print("\n✅ إضافة عمود account_category_id...")
                conn.execute(db.text("ALTER TABLE office ADD COLUMN account_category_id INTEGER"))
                conn.execute(db.text("CREATE INDEX IF NOT EXISTS ix_office_account_category_id ON office (account_category_id)"))
                conn.commit()
                print("✅ تم إضافة account_category_id بنجاح")
            else:
                print("\n✅ عمود account_category_id موجود بالفعل")
            
            # نسخ البيانات من account_id إلى account_category_id
            if 'account_id' in columns:
                print("\n📋 نسخ البيانات من account_id إلى account_category_id...")
                conn.execute(db.text("UPDATE office SET account_category_id = account_id WHERE account_id IS NOT NULL"))
                conn.commit()
                print("✅ تم نسخ البيانات بنجاح")
        
        print("\n" + "=" * 60)
        print("✅ تم تحديث جدول المكاتب بنجاح!")
        print("=" * 60)
        
    except Exception as e:
        print(f"\n❌ خطأ في تحديث الجدول: {e}")
        db.session.rollback()
