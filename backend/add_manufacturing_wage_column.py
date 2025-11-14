#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Migration Script: إضافة حقل manufacturing_wage_per_gram لجدول Item
تاريخ الإنشاء: 12 أكتوبر 2025
"""

import sqlite3

DB_PATH = '/Users/salehalabbadi/yasargold/backend/app.db'

def migrate():
    """إضافة حقل manufacturing_wage_per_gram لجدول item"""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    try:
        # التحقق من وجود الحقل
        cursor.execute("PRAGMA table_info(item);")
        columns = [column[1] for column in cursor.fetchall()]
        
        if 'manufacturing_wage_per_gram' in columns:
            print("✅ الحقل manufacturing_wage_per_gram موجود بالفعل")
            return
        
        # إضافة الحقل
        print("🔧 إضافة حقل manufacturing_wage_per_gram...")
        cursor.execute("""
            ALTER TABLE item 
            ADD COLUMN manufacturing_wage_per_gram REAL DEFAULT 0.0;
        """)
        
        conn.commit()
        print("✅ تم إضافة الحقل بنجاح!")
        
        # عرض الأعمدة الحالية
        cursor.execute("PRAGMA table_info(item);")
        columns = cursor.fetchall()
        print("\n📋 الأعمدة الحالية في جدول item:")
        for col in columns:
            print(f"  - {col[1]} ({col[2]})")
            
    except sqlite3.Error as e:
        print(f"❌ خطأ: {e}")
        conn.rollback()
    finally:
        conn.close()

if __name__ == '__main__':
    migrate()
