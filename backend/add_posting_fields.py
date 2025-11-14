#!/usr/bin/env python3
"""
إضافة حقول نظام الترحيل (Posting System) للفواتير والقيود
===========================================================

هذا السكريبت يضيف الحقول التالية:
- is_posted (Boolean): هل تم الترحيل؟
- posted_at (DateTime): متى تم الترحيل؟
- posted_by (String): من قام بالترحيل؟

لكل من:
- جدول invoice
- جدول journal_entry

الاستخدام:
    source venv/bin/activate
    python add_posting_fields.py
"""

import sys
import os
from sqlalchemy import create_engine, text, inspect

# إضافة المسار للوصول إلى المجلد الحالي
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# بناء مسار قاعدة البيانات
DATABASE_URI = f"sqlite:///{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'app.db')}"

def add_posting_fields():
    """إضافة حقول الترحيل لجداول الفواتير والقيود"""
    engine = create_engine(DATABASE_URI)
    inspector = inspect(engine)
    
    with engine.connect() as conn:
        print("🔍 التحقق من حقول نظام الترحيل...")
        
        # ==========================================
        # 1️⃣ جدول invoice
        # ==========================================
        if 'invoice' in inspector.get_table_names():
            invoice_columns = [col['name'] for col in inspector.get_columns('invoice')]
            
            if 'is_posted' not in invoice_columns:
                print("\n📝 إضافة حقل is_posted لجدول invoice...")
                conn.execute(text("""
                    ALTER TABLE invoice 
                    ADD COLUMN is_posted BOOLEAN DEFAULT 0 NOT NULL
                """))
                conn.commit()
                print("   ✅ تم إضافة is_posted")
            else:
                print("\n   ℹ️  حقل is_posted موجود بالفعل في invoice")
            
            if 'posted_at' not in invoice_columns:
                print("📝 إضافة حقل posted_at لجدول invoice...")
                conn.execute(text("""
                    ALTER TABLE invoice 
                    ADD COLUMN posted_at DATETIME
                """))
                conn.commit()
                print("   ✅ تم إضافة posted_at")
            else:
                print("   ℹ️  حقل posted_at موجود بالفعل في invoice")
            
            if 'posted_by' not in invoice_columns:
                print("📝 إضافة حقل posted_by لجدول invoice...")
                conn.execute(text("""
                    ALTER TABLE invoice 
                    ADD COLUMN posted_by VARCHAR(100)
                """))
                conn.commit()
                print("   ✅ تم إضافة posted_by")
            else:
                print("   ℹ️  حقل posted_by موجود بالفعل في invoice")
        else:
            print("\n⚠️  جدول invoice غير موجود")
        
        # ==========================================
        # 2️⃣ جدول journal_entry
        # ==========================================
        if 'journal_entry' in inspector.get_table_names():
            journal_columns = [col['name'] for col in inspector.get_columns('journal_entry')]
            
            if 'is_posted' not in journal_columns:
                print("\n📝 إضافة حقل is_posted لجدول journal_entry...")
                conn.execute(text("""
                    ALTER TABLE journal_entry 
                    ADD COLUMN is_posted BOOLEAN DEFAULT 0 NOT NULL
                """))
                conn.commit()
                print("   ✅ تم إضافة is_posted")
            else:
                print("\n   ℹ️  حقل is_posted موجود بالفعل في journal_entry")
            
            if 'posted_at' not in journal_columns:
                print("📝 إضافة حقل posted_at لجدول journal_entry...")
                conn.execute(text("""
                    ALTER TABLE journal_entry 
                    ADD COLUMN posted_at DATETIME
                """))
                conn.commit()
                print("   ✅ تم إضافة posted_at")
            else:
                print("   ℹ️  حقل posted_at موجود بالفعل في journal_entry")
            
            if 'posted_by' not in journal_columns:
                print("📝 إضافة حقل posted_by لجدول journal_entry...")
                conn.execute(text("""
                    ALTER TABLE journal_entry 
                    ADD COLUMN posted_by VARCHAR(100)
                """))
                conn.commit()
                print("   ✅ تم إضافة posted_by")
            else:
                print("   ℹ️  حقل posted_by موجود بالفعل في journal_entry")
        else:
            print("\n⚠️  جدول journal_entry غير موجود")
        
        print("\n" + "="*60)
        print("✅ اكتملت إضافة حقول نظام الترحيل بنجاح!")
        print("="*60)
        
        # عرض إحصائيات
        print("\n📊 الإحصائيات:")
        
        result = conn.execute(text("SELECT COUNT(*) as count FROM invoice WHERE is_posted = 0"))
        unposted_invoices = result.fetchone()[0]
        print(f"   - الفواتير غير المرحلة: {unposted_invoices}")
        
        result = conn.execute(text("SELECT COUNT(*) as count FROM journal_entry WHERE is_posted = 0"))
        unposted_entries = result.fetchone()[0]
        print(f"   - القيود غير المرحلة: {unposted_entries}")

if __name__ == '__main__':
    print("="*60)
    print("       إضافة حقول نظام الترحيل للفواتير والقيود")
    print("="*60)
    print()
    
    try:
        add_posting_fields()
    except Exception as e:
        print(f"\n❌ خطأ: {e}", file=sys.stderr)
        sys.exit(1)
