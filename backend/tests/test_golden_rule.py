#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
🧪 اختبار القاعدة الذهبية - فاتورة بيع
"""

import requests
import json
from datetime import date

import pytest

@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    """Its commits stay in the test (TEST-003): brought under tests/ from the
    root, where the gate never ran it and what it wrote stayed in the run's
    database."""
    yield


# عنوان الـAPI
BASE_URL = "http://127.0.0.1:8001/api"

def test_golden_rule_sale():
    """
    اختبار فاتورة بيع مع القاعدة الذهبية
    """
    print("=" * 60)
    print("🧪 اختبار القاعدة الذهبية - فاتورة بيع")
    print("=" * 60)
    
    # 1. الحصول على السعر المباشر للذهب
    print("\n1️⃣ جلب السعر المباشر للذهب...")
    gold_price_resp = requests.get(f"{BASE_URL}/gold_price")
    if gold_price_resp.status_code == 200:
        gold_price_data = gold_price_resp.json()
        direct_price = gold_price_data.get('price_per_gram_24k', 400.0)
        print(f"✅ السعر المباشر: {direct_price} ريال/جرام (عيار 24)")
    else:
        direct_price = 400.0
        print(f"⚠️ تعذر جلب السعر، استخدام القيمة الافتراضية: {direct_price}")
    
    # 2. إنشاء فاتورة بيع
    print("\n2️⃣ إنشاء فاتورة بيع...")
    invoice_data = {
        "customer_id": 1,
        "invoice_type": "بيع",
        "date": str(date.today()),
        "total": 10000.0,  # 10,000 ريال
        "payment_method_id": 1,
        "safe_box_id": 1,
        "items": [
            {
                "name": "خاتم ذهب",
                "karat": 21,
                "weight": 25.0,  # 25 جرام
                "selling_price": 9434.78,  # السعر قبل الضريبة
                "tax": 565.22,  # الضريبة 15%
                "quantity": 1
            }
        ]
    }
    
    print(f"📄 بيانات الفاتورة:")
    print(f"   - الإجمالي: {invoice_data['total']} ريال")
    print(f"   - الوزن: 25 جرام (عيار 21)")
    print(f"   - سعر البيع للجرام: {invoice_data['total'] / 25} ريال/جرام")
    
    # إرسال الفاتورة
    resp = requests.post(f"{BASE_URL}/invoices", json=invoice_data)
    
    if resp.status_code == 201:
        invoice = resp.json()
        print(f"✅ تم إنشاء الفاتورة #{invoice.get('id')} بنجاح!")
        
        # 3. التحقق من القيود المحاسبية
        print("\n3️⃣ التحقق من القيود المحاسبية...")
        journal_entry_id = invoice.get('journal_entry_id')
        
        if journal_entry_id:
            je_resp = requests.get(f"{BASE_URL}/journal-entries/{journal_entry_id}")
            if je_resp.status_code == 200:
                je_data = je_resp.json()
                
                print(f"\n📊 تفاصيل القيد المحاسبي:")
                print(f"   رقم القيد: {je_data.get('entry_number')}")
                print(f"   التاريخ: {je_data.get('date')}")
                
                lines = je_data.get('lines', [])
                print(f"\n   السطور ({len(lines)}):")
                
                for line in lines:
                    account_name = line.get('account', {}).get('name', 'غير معروف')
                    cash_debit = line.get('cash_debit', 0)
                    cash_credit = line.get('cash_credit', 0)
                    weight_21k_debit = line.get('debit_21k', 0)
                    weight_21k_credit = line.get('credit_21k', 0)
                    
                    print(f"\n   • {account_name}")
                    if cash_debit > 0:
                        print(f"     مدين نقد: {cash_debit} ريال")
                    if cash_credit > 0:
                        print(f"     دائن نقد: {cash_credit} ريال")
                    if weight_21k_debit > 0:
                        print(f"     مدين وزن (21k): {weight_21k_debit} جرام")
                    if weight_21k_credit > 0:
                        print(f"     دائن وزن (21k): {weight_21k_credit} جرام")
                
                # 4. التحقق من تطبيق القاعدة الذهبية
                print("\n4️⃣ التحقق من القاعدة الذهبية...")
                
                # حساب الوزن المعادل المتوقع
                expected_weight = invoice_data['total'] / direct_price
                print(f"   الوزن المعادل المتوقع: {invoice_data['total']} ÷ {direct_price} = {expected_weight:.3f} جرام")
                
                # البحث عن قيد الصندوق الوزني
                cash_memo_lines = [l for l in lines if 'وزني' in l.get('account', {}).get('name', '')]
                if cash_memo_lines:
                    for line in cash_memo_lines:
                        actual_weight = line.get('debit_21k', 0) or line.get('credit_21k', 0)
                        if actual_weight > 0:
                            print(f"   الوزن الفعلي المسجل: {actual_weight:.3f} جرام")
                            
                            # التحقق من التطابق
                            diff = abs(actual_weight - expected_weight)
                            if diff < 0.01:  # هامش خطأ 0.01 جرام
                                print(f"   ✅ القاعدة الذهبية مُطبّقة بنجاح! (فرق: {diff:.6f})")
                            else:
                                print(f"   ⚠️ يوجد فرق: {diff:.3f} جرام")
                else:
                    print("   ⚠️ لم يتم العثور على قيود وزنية")
            else:
                print(f"   ❌ فشل جلب القيد: {je_resp.status_code}")
        else:
            print("   ⚠️ لم يتم إنشاء قيد محاسبي للفاتورة")
    else:
        print(f"❌ فشل إنشاء الفاتورة: {resp.status_code}")
        try:
            error_data = resp.json()
            print(f"التفاصيل: {json.dumps(error_data, ensure_ascii=False, indent=2)}")
        except:
            print(f"النص: {resp.text}")
    
    print("\n" + "=" * 60)

if __name__ == "__main__":
    test_golden_rule_sale()
