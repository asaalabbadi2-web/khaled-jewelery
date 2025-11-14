"""
إضافة عمود item_code لجدول Item
وتوليد أكواد تلقائية للأصناف الموجودة
"""

import sqlite3
import sys

def add_item_code_column():
    """إضافة عمود item_code وتوليد أكواد للأصناف الموجودة"""
    
    conn = sqlite3.connect('app.db')
    cursor = conn.cursor()
    
    try:
        print("=== إضافة عمود item_code لجدول Item ===")
        
        # 1. إضافة العمود (nullable في البداية)
        print("1. إضافة عمود item_code...")
        cursor.execute("""
            ALTER TABLE item 
            ADD COLUMN item_code VARCHAR(20)
        """)
        conn.commit()
        print("✓ تمت إضافة العمود")
        
        # 2. توليد أكواد للأصناف الموجودة
        print("\n2. توليد أكواد للأصناف الموجودة...")
        cursor.execute("SELECT id FROM item ORDER BY id")
        items = cursor.fetchall()
        
        for idx, (item_id,) in enumerate(items, start=1):
            item_code = f"I-{idx:06d}"
            cursor.execute("""
                UPDATE item 
                SET item_code = ? 
                WHERE id = ?
            """, (item_code, item_id))
            print(f"  - الصنف {item_id} → {item_code}")
        
        conn.commit()
        print(f"✓ تم توليد {len(items)} كود")
        
        # 3. إنشاء Index فريد
        print("\n3. إنشاء Index فريد على item_code...")
        cursor.execute("""
            CREATE UNIQUE INDEX idx_item_code 
            ON item(item_code)
        """)
        conn.commit()
        print("✓ تم إنشاء Index")
        
        # 4. توليد باركودات للأصناف التي ليس لديها
        print("\n4. توليد باركودات للأصناف التي ليس لديها...")
        cursor.execute("""
            SELECT id, item_code 
            FROM item 
            WHERE barcode IS NULL OR barcode = ''
        """)
        items_without_barcode = cursor.fetchall()
        
        for item_id, item_code in items_without_barcode:
            # توليد باركود من item_code: I-000001 → YAS000001
            number = item_code.split('-')[1]
            barcode = f"YAS{number}"
            
            cursor.execute("""
                UPDATE item 
                SET barcode = ? 
                WHERE id = ?
            """, (barcode, item_id))
            print(f"  - الصنف {item_code} → باركود {barcode}")
        
        conn.commit()
        print(f"✓ تم توليد {len(items_without_barcode)} باركود")
        
        # 5. التحقق النهائي
        print("\n5. التحقق النهائي...")
        cursor.execute("SELECT COUNT(*) FROM item WHERE item_code IS NULL")
        null_count = cursor.fetchone()[0]
        
        if null_count > 0:
            print(f"⚠️ تحذير: {null_count} صنف بدون كود!")
        else:
            print("✓ جميع الأصناف لديها أكواد")
        
        cursor.execute("SELECT COUNT(*), COUNT(DISTINCT item_code) FROM item")
        total, unique = cursor.fetchone()
        print(f"  - إجمالي الأصناف: {total}")
        print(f"  - الأكواد الفريدة: {unique}")
        
        if total != unique:
            print("⚠️ خطأ: يوجد تكرار في الأكواد!")
            return False
        
        print("\n✅ اكتمل الترحيل بنجاح!")
        return True
        
    except sqlite3.Error as e:
        print(f"\n❌ خطأ: {e}")
        conn.rollback()
        return False
        
    finally:
        conn.close()


if __name__ == '__main__':
    success = add_item_code_column()
    sys.exit(0 if success else 1)
