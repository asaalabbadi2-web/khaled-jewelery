#!/usr/bin/env python3
"""
اختبار نظام مخزون أجور المصنعية
"""
import requests
import json
from datetime import datetime

BASE_URL = "http://localhost:8001/api"

def test_purchase_with_wage():
    """اختبار شراء (مورد) مع مصنعية"""
    print("\n🔵 Test 1: شراء (مورد) (100g + 500 ريال مصنعية)")
    print("="*60)
    
    payload = {
        "invoice_type": "شراء",
        "date": datetime.now().isoformat(),
        "supplier_id": 1,
        "gold_type": "new",
        "total": 45867.0,  # 45367 (ذهب) + 500 (مصنعية)
        "gold_subtotal": 45367.0,
        "wage_subtotal": 500.0,
        "manufacturing_wage_cash": 500.0,
        "total_tax": 0,
        "karat_lines": [
            {
                "karat": 21,
                "weight_grams": 100.0,
                "gold_value_cash": 45367.0,
                "manufacturing_wage_cash": 500.0
            }
        ],
        "items": []
    }
    
    try:
        response = requests.post(
            f"{BASE_URL}/invoices",
            json=payload,
            timeout=10
        )
        
        if response.status_code == 201:
            result = response.json()
            print(f"✅ Invoice created: #{result['id']}")
            print(f"   Total: {result['total']} SAR")
            print(f"   Gold: {result.get('gold_subtotal', 0)} SAR")
            print(f"   Wage: {result.get('wage_subtotal', 0)} SAR")
            return result['id']
        else:
            print(f"❌ Error {response.status_code}")
            print(response.text[:500])
            return None
            
    except Exception as e:
        print(f"❌ Error: {e}")
        return None


def check_wage_inventory_balance():
    """التحقق من رصيد حساب 1340"""
    print("\n🔵 Test 2: التحقق من رصيد حساب 1340")
    print("="*60)
    
    try:
        response = requests.get(f"{BASE_URL}/accounts", timeout=10)
        accounts = response.json()
        
        for acc in accounts:
            if acc.get('account_number') == '1340':
                print(f"✅ Account 1340: {acc['name']}")
                balance = acc.get('balance_cash', 0)
                print(f"   Balance: {balance} SAR")
                print(f"   Expected: 500 SAR")
                
                if abs(balance - 500) < 0.01:
                    print("   ✅ Balance is correct!")
                    return True
                else:
                    print(f"   ⚠️ Unexpected balance")
                    return False
                    
        print("❌ Account 1340 not found")
        return False
        
    except Exception as e:
        print(f"❌ Error: {e}")
        return False


def test_sale_with_wage(purchase_invoice_id=None):
    """اختبار بيع مع استهلاك المصنعية"""
    print("\n🔵 Test 3: بيع 10g (يجب استهلاك 50 ريال من 1340)")
    print("="*60)
    
    payload = {
        "invoice_type": "بيع",
        "date": datetime.now().isoformat(),
        "customer_id": 1,
        "total": 5000.0,
        "karat_lines": [
            {
                "karat": 21,
                "weight_grams": 10.0,
                "gold_value_cash": 4536.7,
                "manufacturing_wage_cash": 50.0  # 10% من المصنعية
            }
        ],
        "items": []
    }
    
    try:
        response = requests.post(
            f"{BASE_URL}/invoices",
            json=payload,
            timeout=10
        )
        
        if response.status_code == 201:
            result = response.json()
            print(f"✅ Sale invoice created: #{result['id']}")
            return result['id']
        else:
            print(f"❌ Error {response.status_code}")
            print(response.text[:500])
            return None
            
    except Exception as e:
        print(f"❌ Error: {e}")
        return None


def check_wage_balance_after_sale():
    """التحقق من رصيد 1340 بعد البيع"""
    print("\n🔵 Test 4: التحقق من رصيد 1340 بعد البيع")
    print("="*60)
    
    try:
        response = requests.get(f"{BASE_URL}/accounts", timeout=10)
        accounts = response.json()
        
        for acc in accounts:
            if acc.get('account_number') == '1340':
                balance = acc.get('balance_cash', 0)
                print(f"✅ Balance after sale: {balance} SAR")
                print(f"   Expected: 450 SAR (500 - 50)")
                
                if abs(balance - 450) < 0.01:
                    print("   ✅ Wage consumption is correct!")
                    return True
                else:
                    print(f"   ⚠️ Unexpected balance")
                    return False
                    
        return False
        
    except Exception as e:
        print(f"❌ Error: {e}")
        return False


if __name__ == "__main__":
    print("\n" + "="*60)
    print("🧪 Testing Manufacturing Wage Inventory System")
    print("="*60)
    
    # Test 1: Purchase with wage
    purchase_id = test_purchase_with_wage()
    
    if purchase_id:
        # Test 2: Check balance
        if check_wage_inventory_balance():
            # Test 3: Sale with wage
            sale_id = test_sale_with_wage(purchase_id)
            
            if sale_id:
                # Test 4: Check balance after sale
                check_wage_balance_after_sale()
    
    print("\n" + "="*60)
    print("✅ Testing completed!")
    print("="*60)
