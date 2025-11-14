#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
اختبار نظام الحذف الآمن
Test Soft Delete System
"""

import requests
import json
import sqlite3
import sys

BASE_URL = "http://127.0.0.1:8001/api"

def test_soft_delete():
    print("🧪 اختبار نظام الحذف الآمن...")
    print("=" * 50)
    
    # 1. جلب القيود الحالية
    print("1️⃣ جلب القيود الحالية...")
    try:
        response = requests.get(f"{BASE_URL}/journal_entries")
        if response.status_code == 200:
            entries = response.json()
            print(f"✅ تم العثور على {len(entries)} قيد يومي")
            if entries:
                entry_id = entries[0]['id']
                entry_desc = entries[0]['description']
                print(f"📄 سنختبر على القيد: ID={entry_id}, الوصف='{entry_desc}'")
            else:
                print("❌ لا توجد قيود للاختبار")
                return
        else:
            print(f"❌ فشل في جلب القيود: {response.status_code}")
            return
    except Exception as e:
        print(f"❌ خطأ في الاتصال: {e}")
        return
    
    # 2. اختبار الحذف الآمن
    print("\n2️⃣ اختبار الحذف الآمن...")
    try:
        delete_data = {
            "deleted_by": "مختبر النظام",
            "reason": "اختبار آلي لنظام الحذف الآمن"
        }
        
        response = requests.post(
            f"{BASE_URL}/journal_entries/{entry_id}/soft_delete",
            json=delete_data,
            headers={"Content-Type": "application/json"}
        )
        
        if response.status_code == 200:
            result = response.json()
            print(f"✅ تم حذف القيد بنجاح: {result.get('message', 'تم الحذف')}")
        else:
            print(f"❌ فشل في حذف القيد: {response.status_code} - {response.text}")
            return
    except Exception as e:
        print(f"❌ خطأ في حذف القيد: {e}")
        return
    
    # 3. التحقق من قاعدة البيانات
    print("\n3️⃣ التحقق من قاعدة البيانات...")
    try:
        conn = sqlite3.connect('backend/app.db')
        cursor = conn.cursor()
        
        # فحص حالة القيد المحذوف
        cursor.execute("""
            SELECT id, description, is_deleted, deleted_at, deleted_by, deletion_reason 
            FROM journal_entry 
            WHERE id = ?
        """, (entry_id,))
        
        result = cursor.fetchone()
        if result:
            print(f"📊 حالة القيد في قاعدة البيانات:")
            print(f"   - ID: {result[0]}")
            print(f"   - الوصف: {result[1]}")
            print(f"   - محذوف: {'نعم' if result[2] else 'لا'}")
            print(f"   - تاريخ الحذف: {result[3]}")
            print(f"   - حذف بواسطة: {result[4]}")
            print(f"   - سبب الحذف: {result[5]}")
        
        # إحصائيات عامة
        cursor.execute("SELECT COUNT(*) FROM journal_entry")
        total = cursor.fetchone()[0]
        
        cursor.execute("SELECT COUNT(*) FROM journal_entry WHERE is_deleted = 1")
        deleted = cursor.fetchone()[0]
        
        cursor.execute("SELECT COUNT(*) FROM journal_entry WHERE is_deleted = 0")
        active = cursor.fetchone()[0]
        
        print(f"\n📈 إحصائيات القيود:")
        print(f"   - إجمالي القيود: {total}")
        print(f"   - القيود النشطة: {active}")
        print(f"   - القيود المحذوفة: {deleted}")
        
        conn.close()
        
    except Exception as e:
        print(f"❌ خطأ في قاعدة البيانات: {e}")
    
    # 4. التحقق من عدم ظهور القيد في API
    print("\n4️⃣ التحقق من إخفاء القيد المحذوف...")
    try:
        response = requests.get(f"{BASE_URL}/journal_entries")
        if response.status_code == 200:
            entries = response.json()
            entry_ids = [e['id'] for e in entries]
            
            if entry_id not in entry_ids:
                print(f"✅ القيد المحذوف (ID={entry_id}) لا يظهر في القائمة - نجح الإخفاء!")
            else:
                print(f"❌ القيد المحذوف ما زال يظهر في القائمة!")
                
            print(f"📄 عدد القيود الظاهرة حالياً: {len(entries)}")
        else:
            print(f"❌ فشل في جلب القيود: {response.status_code}")
    except Exception as e:
        print(f"❌ خطأ في التحقق: {e}")
    
    # 5. اختبار جلب القيود المحذوفة
    print("\n5️⃣ اختبار جلب القيود المحذوفة...")
    try:
        response = requests.get(f"{BASE_URL}/journal_entries/deleted")
        if response.status_code == 200:
            deleted_entries = response.json()
            print(f"✅ تم جلب {len(deleted_entries)} قيد محذوف")
            
            if deleted_entries:
                for entry in deleted_entries:
                    print(f"🗑️ قيد محذوف: ID={entry['id']}, الوصف='{entry['description'][:50]}...'")
                    print(f"   حذف بواسطة: {entry.get('deleted_by', 'غير محدد')}")
                    print(f"   السبب: {entry.get('deletion_reason', 'غير محدد')}")
        else:
            print(f"❌ فشل في جلب القيود المحذوفة: {response.status_code}")
    except Exception as e:
        print(f"❌ خطأ في جلب القيود المحذوفة: {e}")
    
    # 6. اختبار الاستعادة
    print("\n6️⃣ اختبار استعادة القيد...")
    try:
        restore_data = {
            "restored_by": "مختبر النظام"
        }
        
        response = requests.post(
            f"{BASE_URL}/journal_entries/{entry_id}/restore",
            json=restore_data,
            headers={"Content-Type": "application/json"}
        )
        
        if response.status_code == 200:
            result = response.json()
            print(f"✅ تم استعادة القيد بنجاح: {result.get('message', 'تم الاستعادة')}")
            
            # التحقق من الاستعادة
            response = requests.get(f"{BASE_URL}/journal_entries")
            if response.status_code == 200:
                entries = response.json()
                entry_ids = [e['id'] for e in entries]
                
                if entry_id in entry_ids:
                    print(f"✅ القيد المستعاد (ID={entry_id}) يظهر في القائمة مرة أخرى!")
                else:
                    print(f"❌ القيد المستعاد لا يظهر في القائمة!")
        else:
            print(f"❌ فشل في استعادة القيد: {response.status_code} - {response.text}")
    except Exception as e:
        print(f"❌ خطأ في استعادة القيد: {e}")
    
    print("\n" + "=" * 50)
    print("🎉 انتهى اختبار نظام الحذف الآمن!")

if __name__ == "__main__":
    test_soft_delete()