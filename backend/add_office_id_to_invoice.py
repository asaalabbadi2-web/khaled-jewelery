#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
إضافة حقل office_id لجدول الفواتير
"""

from app import app, db

print("=" * 60)
print("إضافة حقل office_id لجدول الفواتير")
print("=" * 60)

with app.app_context():
    try:
        # إضافة عمود office_id إذا لم يكن موجوداً
        with db.engine.connect() as conn:
            # التحقق من وجود العمود
            result = conn.execute(db.text("PRAGMA table_info(invoice)")).fetchall()
            columns = [col[1] for col in result]
            
            if 'office_id' not in columns:
                print("\n✅ إضافة عمود office_id...")
                conn.execute(db.text("ALTER TABLE invoice ADD COLUMN office_id INTEGER"))
                conn.execute(db.text("CREATE INDEX IF NOT EXISTS ix_invoice_office_id ON invoice (office_id)"))
                conn.commit()
                print("✅ تم إضافة office_id بنجاح")
            else:
                print("\n✅ عمود office_id موجود بالفعل")
        
        print("\n" + "=" * 60)
        print("✅ تم التحديث بنجاح!")
        print("=" * 60)
        
    except Exception as e:
        print(f"\n❌ خطأ في التحديث: {e}")
        db.session.rollback()
