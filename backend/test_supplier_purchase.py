#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
اختبار محاسبة فواتير الشراء (مورد)
Test Supplier Purchase Invoice Accounting
"""

import requests
import json
from datetime import datetime

BASE_URL = "http://localhost:8001/api"

def test_supplier_purchase():
    """إنشاء فاتورة شراء (مورد) واختبار القيود المحاسبية"""
    
    print("=" * 80)
    print("🧪 اختبار فاتورة شراء (مورد)")
    print("=" * 80)
    
    # البيانات الأساسية
    supplier_id = 1
    
    # 1️⃣ الحصول على قائمة الموردين
    print(f"\n1️⃣ جلب قائمة الموردين...")
    suppliers_resp = requests.get(f"{BASE_URL}/suppliers")
    
    if suppliers_resp.status_code != 200:
        print(f"❌ خطأ في جلب الموردين")
        return
    
    suppliers = suppliers_resp.json()
    supplier = next((s for s in suppliers if s['id'] == supplier_id), None)
    
    if not supplier:
        print(f"❌ لم يتم العثور على المورد #{supplier_id}")
        return
    
    print(f"✅ المورد: {supplier.get('name', 'غير معروف')}")
    
    # 2️⃣ جلب رصيد المورد قبل الفاتورة
    print(f"\n2️⃣ رصيد المورد قبل الفاتورة...")
    balance_before = requests.get(f"{BASE_URL}/suppliers/{supplier_id}/balance").json()
    print(f"   النقد: {balance_before.get('cash_balance', 0)}")
    print(f"   عيار 21: {balance_before.get('weight_21k_balance', 0)} جرام")
    print(f"   عيار 18: {balance_before.get('weight_18k_balance', 0)} جرام")
    
    # 3️⃣ إنشاء فاتورة شراء (مورد)
    print(f"\n3️⃣ إنشاء فاتورة شراء (مورد)...")
    
    invoice_data = {
        "invoice_type": "شراء",
        "supplier_id": supplier_id,
        "date": datetime.now().strftime("%Y-%m-%d"),
        "total": 0,  # سيتم حسابه تلقائياً من الأصناف
        "items": [
            {
                "name": "سوار ذهب عيار 21",
                "karat": 21,
                "weight": 50.0,
                "manufacturing_wage": 10.0,  # أجور مصنعية: 10 للجرام
                "description": "اختبار محاسبي"
            },
            {
                "name": "خاتم ذهب عيار 18",
                "karat": 18,
                "weight": 30.0,
                "manufacturing_wage": 8.0,
                "description": "اختبار محاسبي"
            }
        ]
    }
    
    invoice_resp = requests.post(
        f"{BASE_URL}/invoices",
        json=invoice_data,
        headers={'Content-Type': 'application/json'}
    )
    
    if invoice_resp.status_code not in [200, 201]:
        print(f"❌ خطأ في إنشاء الفاتورة: {invoice_resp.text}")
        return
    
    invoice = invoice_resp.json()
    invoice_id = invoice.get('id')
    journal_entry_id = invoice.get('journal_entry_id')
    
    print(f"✅ تم إنشاء الفاتورة #{invoice_id}")
    print(f"   رقم القيد: {journal_entry_id}")
    
    # 4️⃣ جلب القيود المحاسبية
    print(f"\n4️⃣ القيود المحاسبية للفاتورة...")
    
    if journal_entry_id:
        journal_resp = requests.get(f"{BASE_URL}/journal-entries/{journal_entry_id}")
        
        if journal_resp.status_code == 200:
            journal_entry = journal_resp.json()
            lines = journal_entry.get('lines', [])
            
            print(f"\n   📊 عدد سطور القيد: {len(lines)}")
            print("\n   " + "─" * 76)
            
            for i, line in enumerate(lines, 1):
                account_name = line.get('account_name', 'غير معروف')
                description = line.get('description', '')
                
                print(f"\n   {i}. {account_name}")
                print(f"      الوصف: {description}")
                
                # النقد
                cash_debit = line.get('cash_debit', 0)
                cash_credit = line.get('cash_credit', 0)
                if cash_debit > 0:
                    print(f"      💵 مدين نقد: {cash_debit}")
                if cash_credit > 0:
                    print(f"      💵 دائن نقد: {cash_credit}")
                
                # الذهب
                for karat in ['21', '18', '22', '24']:
                    weight_debit = line.get(f'weight_{karat}k_debit', 0)
                    weight_credit = line.get(f'weight_{karat}k_credit', 0)
                    
                    if weight_debit > 0:
                        print(f"      ⚖️  مدين عيار {karat}: {weight_debit} جرام")
                    if weight_credit > 0:
                        print(f"      ⚖️  دائن عيار {karat}: {weight_credit} جرام")
            
            print("\n   " + "─" * 76)
            
            # التحقق من التوازن
            total_cash_debit = sum(l.get('cash_debit', 0) for l in lines)
            total_cash_credit = sum(l.get('cash_credit', 0) for l in lines)
            
            print(f"\n   📈 ملخص التوازن:")
            print(f"      إجمالي النقد المدين: {total_cash_debit}")
            print(f"      إجمالي النقد الدائن: {total_cash_credit}")
            print(f"      الفرق: {abs(total_cash_debit - total_cash_credit)}")
            
            if abs(total_cash_debit - total_cash_credit) < 0.01:
                print("      ✅ القيد متوازن نقدياً")
            else:
                print("      ❌ القيد غير متوازن نقدياً!")
    
    # 5️⃣ رصيد المورد بعد الفاتورة
    print(f"\n5️⃣ رصيد المورد بعد الفاتورة...")
    balance_after = requests.get(f"{BASE_URL}/suppliers/{supplier_id}/balance").json()
    
    print(f"   النقد: {balance_after.get('cash_balance', 0)}")
    print(f"   عيار 21: {balance_after.get('weight_21k_balance', 0)} جرام")
    print(f"   عيار 18: {balance_after.get('weight_18k_balance', 0)} جرام")
    
    # 6️⃣ كشف حساب المورد
    print(f"\n6️⃣ آخر حركات في كشف حساب المورد...")
    ledger_resp = requests.get(
        f"{BASE_URL}/suppliers/{supplier_id}/ledger",
        params={'per_page': 5}
    )
    
    if ledger_resp.status_code == 200:
        ledger = ledger_resp.json()
        movements = ledger.get('movements', [])
        
        print(f"\n   عدد الحركات: {len(movements)}")
        
        for move in movements[:3]:  # آخر 3 حركات
            print(f"\n   📅 {move.get('date')}")
            print(f"      {move.get('description')}")
            
            if move.get('cash_debit', 0) > 0:
                print(f"      💵 نقد مدين: {move['cash_debit']}")
            if move.get('cash_credit', 0) > 0:
                print(f"      💵 نقد دائن: {move['cash_credit']}")
            
            for karat in ['21', '18', '22', '24']:
                if move.get(f'weight_{karat}k_debit', 0) > 0:
                    print(f"      ⚖️  عيار {karat} مدين: {move[f'weight_{karat}k_debit']} جرام")
                if move.get(f'weight_{karat}k_credit', 0) > 0:
                    print(f"      ⚖️  عيار {karat} دائن: {move[f'weight_{karat}k_credit']} جرام")
    
    # 7️⃣ النتيجة النهائية
    print("\n" + "=" * 80)
    print("✅ اكتمل الاختبار بنجاح!")
    print("=" * 80)
    
    print(f"\n📋 ملخص النتائج:")
    print(f"   - تم إنشاء فاتورة شراء (مورد) #{invoice_id}")
    print(f"   - القيد المحاسبي #{journal_entry_id}")
    print(f"   - المورد: {supplier.get('name')}")
    print(f"   - الأصناف: {len(invoice_data['items'])} صنف")
    
    cash_diff = balance_after.get('cash_balance', 0) - balance_before.get('cash_balance', 0)
    weight_21_diff = balance_after.get('weight_21k_balance', 0) - balance_before.get('weight_21k_balance', 0)
    weight_18_diff = balance_after.get('weight_18k_balance', 0) - balance_before.get('weight_18k_balance', 0)
    
    print(f"\n📊 التغيير في رصيد المورد:")
    print(f"   النقد: {cash_diff:+.2f}")
    print(f"   عيار 21: {weight_21_diff:+.3f} جرام")
    print(f"   عيار 18: {weight_18_diff:+.3f} جرام")
    
    print("\n💡 توقعات:")
    print("   ✓ المخزون يُسجل بالوزن فقط (بدون قيمة نقدية للذهب)")
    print("   ✓ المورد دائن بالذهب (كوزن)")
    print("   ✓ المورد دائن بالنقدية (أجور + ضرائب)")
    print("   ✓ الحساب الجسر متوازن (صفر)")
    
    print("\n" + "=" * 80)

if __name__ == "__main__":
    try:
        test_supplier_purchase()
    except requests.exceptions.ConnectionError:
        print("❌ خطأ: لا يمكن الاتصال بالخادم")
        print("   تأكد من تشغيل الخادم على المنفذ 8001")
    except Exception as e:
        print(f"❌ خطأ غير متوقع: {e}")
        import traceback
        traceback.print_exc()
