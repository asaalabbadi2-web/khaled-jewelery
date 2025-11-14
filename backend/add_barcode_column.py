#!/usr/bin/env python
"""
إضافة حقل barcode إلى جدول item
"""
import sqlite3

# الاتصال بقاعدة البيانات
conn = sqlite3.connect('app.db')
cursor = conn.cursor()

try:
    # التحقق من وجود العمود
    cursor.execute("PRAGMA table_info(item)")
    columns = [column[1] for column in cursor.fetchall()]
    
    if 'barcode' not in columns:
        # إضافة العمود
        cursor.execute("ALTER TABLE item ADD COLUMN barcode VARCHAR(100)")
        print("✅ تم إضافة عمود barcode بنجاح")
        
        # إنشاء فهرس فريد
        try:
            cursor.execute("CREATE UNIQUE INDEX ix_item_barcode ON item(barcode)")
            print("✅ تم إنشاء الفهرس ix_item_barcode بنجاح")
        except sqlite3.OperationalError as e:
            if "already exists" in str(e):
                print("⚠️ الفهرس موجود بالفعل")
            else:
                raise
        
        conn.commit()
        print("✅ تم حفظ التغييرات بنجاح")
    else:
        print("ℹ️ عمود barcode موجود بالفعل")
        
except sqlite3.Error as e:
    print(f"❌ خطأ: {e}")
    conn.rollback()
finally:
    conn.close()

print("\n📊 بنية جدول item الحالية:")
conn = sqlite3.connect('app.db')
cursor = conn.cursor()
cursor.execute("PRAGMA table_info(item)")
for column in cursor.fetchall():
    print(f"  - {column[1]} ({column[2]})")
conn.close()
