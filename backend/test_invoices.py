#!/usr/bin/env python3
"""
اختبار شامل لجميع أنواع الفواتير الـ 6 والقيود المحاسبية
Test Suite for 6 Invoice Types and Journal Entries
"""

import requests
import json
from datetime import datetime

BASE_URL = "http://localhost:8001"

def print_section(title):
    """Print a formatted section header"""
    print("\n" + "=" * 70)
    print(f"  {title}")
    print("=" * 70)

def print_test(test_name, passed, details=""):
    """Print test result"""
    status = "✅ PASS" if passed else "❌ FAIL"
    print(f"{status}: {test_name}")
    if details:
        print(f"   {details}")

def test_create_customer():
    """Test 1: Create a customer for testing"""
    print_section("Test 1: إنشاء عميل للاختبار")
    
    customer_data = {
        "name": "عميل اختبار",
        "phone": "0500000001",
        "email": "test@example.com",
        "address": "الرياض"
    }
    
    response = requests.post(f"{BASE_URL}/api/customers", json=customer_data)
    
    if response.status_code == 201:
        customer = response.json()
        print_test("إنشاء العميل", True, f"Customer ID: {customer['id']}")
        return customer['id']
    else:
        print_test("إنشاء العميل", False, f"Error: {response.text}")
        return None

def test_invoice_type_1_sale(customer_id):
    """Test 2: Create بيع invoice"""
    print_section("Test 2: فاتورة بيع (مبيعات)")
    
    invoice_data = {
        "customer_id": customer_id,
        "invoice_type": "بيع",
        "date": datetime.now().strftime("%Y-%m-%d"),
        "items": [
            {
                "description": "خاتم ذهب عيار 21",
                "karat": 21,
                "weight": 5.5,
                "wage_per_gram": 10.0,
                "net_cost": 0,
                "tax": 0,
                "total_cost": 0
            }
        ],
        "payment_method": "نقدي",
        "amount_paid": 1000.0
    }
    
    response = requests.post(f"{BASE_URL}/api/invoices", json=invoice_data)
    
    if response.status_code == 201:
        invoice = response.json()
        print_test("إنشاء فاتورة بيع", True, f"Invoice ID: {invoice['id']}")
        
        # Check journal entry
        je_response = requests.get(f"{BASE_URL}/api/journal-entries")
        if je_response.status_code == 200:
            entries = je_response.json()
            latest = entries[0] if entries else None
            if latest and latest['description'].startswith('بيع'):
                print_test("القيد المحاسبي للبيع", True, f"Entry ID: {latest['id']}")
                print(f"   المدين: الصندوق | الدائن: المبيعات + المخزون")
            else:
                print_test("القيد المحاسبي للبيع", False, "لم يتم إنشاء القيد")
        
        return invoice['id']
    else:
        print_test("إنشاء فاتورة بيع", False, f"Error: {response.text}")
        return None

def test_invoice_type_2_purchase_from_customer(customer_id):
    """Test 3: Create شراء من عميل invoice"""
    print_section("Test 3: فاتورة شراء كسر من عميل")
    
    invoice_data = {
        "customer_id": customer_id,
        "invoice_type": "شراء من عميل",
        "gold_type": "scrap",
        "date": datetime.now().strftime("%Y-%m-%d"),
        "items": [
            {
                "description": "ذهب كسر عيار 18",
                "karat": 18,
                "weight": 10.0,
                "wage_per_gram": 0,
                "net_cost": 0,
                "tax": 0,
                "total_cost": 0
            }
        ],
        "payment_method": "نقدي",
        "amount_paid": 2000.0
    }
    
    response = requests.post(f"{BASE_URL}/api/invoices", json=invoice_data)
    
    if response.status_code == 201:
        invoice = response.json()
        print_test("إنشاء فاتورة شراء من عميل", True, f"Invoice ID: {invoice['id']}")
        print_test("التحقق من gold_type", invoice.get('gold_type') == 'scrap', 
                   f"gold_type: {invoice.get('gold_type')}")
        
        # Check journal entry
        je_response = requests.get(f"{BASE_URL}/api/journal-entries")
        if je_response.status_code == 200:
            entries = je_response.json()
            latest = entries[0] if entries else None
            if latest and 'شراء من عميل' in latest['description']:
                print_test("القيد المحاسبي للشراء", True, f"Entry ID: {latest['id']}")
                print(f"   المدين: المخزون | الدائن: الصندوق")
            else:
                print_test("القيد المحاسبي للشراء", False, "لم يتم إنشاء القيد")
        
        return invoice['id']
    else:
        print_test("إنشاء فاتورة شراء من عميل", False, f"Error: {response.text}")
        return None

def test_invoice_type_3_purchase_from_supplier():
    """Test 4: Create شراء من مورد invoice"""
    print_section("Test 4: فاتورة شراء من مورد")
    
    invoice_data = {
        "supplier_id": 1,  # Assuming supplier exists or will be created
        "invoice_type": "شراء من مورد",
        "gold_type": "new",
        "date": datetime.now().strftime("%Y-%m-%d"),
        "items": [
            {
                "description": "ذهب جديد عيار 21",
                "karat": 21,
                "weight": 20.0,
                "wage_per_gram": 5.0,
                "net_cost": 0,
                "tax": 0,
                "total_cost": 0
            }
        ],
        "payment_method": "آجل",
        "amount_paid": 0
    }
    
    response = requests.post(f"{BASE_URL}/api/invoices", json=invoice_data)
    
    if response.status_code == 201:
        invoice = response.json()
        print_test("إنشاء فاتورة شراء من مورد", True, f"Invoice ID: {invoice['id']}")
        print_test("التحقق من gold_type", invoice.get('gold_type') == 'new', 
                   f"gold_type: {invoice.get('gold_type')}")
        
        # Check journal entry
        je_response = requests.get(f"{BASE_URL}/api/journal-entries")
        if je_response.status_code == 200:
            entries = je_response.json()
            latest = entries[0] if entries else None
            if latest and 'شراء من مورد' in latest['description']:
                print_test("القيد المحاسبي للشراء من مورد", True, f"Entry ID: {latest['id']}")
                print(f"   المدين: المخزون | الدائن: الموردين")
            else:
                print_test("القيد المحاسبي للشراء من مورد", False, "لم يتم إنشاء القيد")
        
        return invoice['id']
    else:
        print_test("إنشاء فاتورة شراء من مورد", False, f"Error: {response.text}")
        return None

def test_invoice_type_4_sales_return(original_invoice_id, customer_id):
    """Test 5: Create مرتجع بيع invoice"""
    print_section("Test 5: فاتورة مرتجع بيع")
    
    if not original_invoice_id:
        print_test("مرتجع بيع", False, "لا توجد فاتورة بيع أصلية")
        return None
    
    invoice_data = {
        "customer_id": customer_id,
        "invoice_type": "مرتجع بيع",
        "original_invoice_id": original_invoice_id,
        "return_reason": "عيب في المنتج - اختبار",
        "date": datetime.now().strftime("%Y-%m-%d"),
        "items": [
            {
                "description": "خاتم ذهب عيار 21 (مرتجع)",
                "karat": 21,
                "weight": 5.5,
                "wage_per_gram": 10.0,
                "net_cost": 0,
                "tax": 0,
                "total_cost": 0
            }
        ],
        "payment_method": "نقدي",
        "amount_paid": -1000.0
    }
    
    response = requests.post(f"{BASE_URL}/api/invoices", json=invoice_data)
    
    if response.status_code == 201:
        invoice = response.json()
        print_test("إنشاء مرتجع بيع", True, f"Invoice ID: {invoice['id']}")
        print_test("الربط بالفاتورة الأصلية", 
                   invoice.get('original_invoice_id') == original_invoice_id,
                   f"Original ID: {invoice.get('original_invoice_id')}")
        print_test("سبب الإرجاع موجود", 
                   invoice.get('return_reason') is not None,
                   f"Reason: {invoice.get('return_reason')}")
        
        # Check journal entry
        je_response = requests.get(f"{BASE_URL}/api/journal-entries")
        if je_response.status_code == 200:
            entries = je_response.json()
            latest = entries[0] if entries else None
            if latest and 'مرتجع بيع' in latest['description']:
                print_test("القيد المحاسبي لمرتجع البيع", True, f"Entry ID: {latest['id']}")
                print(f"   المدين: المبيعات + المخزون | الدائن: الصندوق")
            else:
                print_test("القيد المحاسبي لمرتجع البيع", False, "لم يتم إنشاء القيد")
        
        return invoice['id']
    else:
        print_test("إنشاء مرتجع بيع", False, f"Error: {response.text}")
        return None

def test_invoice_type_5_purchase_return(original_invoice_id, customer_id):
    """Test 6: Create مرتجع شراء invoice"""
    print_section("Test 6: فاتورة مرتجع شراء من عميل")
    
    if not original_invoice_id:
        print_test("مرتجع شراء", False, "لا توجد فاتورة شراء أصلية")
        return None
    
    invoice_data = {
        "customer_id": customer_id,
        "invoice_type": "مرتجع شراء",
        "original_invoice_id": original_invoice_id,
        "return_reason": "تغيير رأي العميل - اختبار",
        "date": datetime.now().strftime("%Y-%m-%d"),
        "items": [
            {
                "description": "ذهب كسر عيار 18 (مرتجع)",
                "karat": 18,
                "weight": 10.0,
                "wage_per_gram": 0,
                "net_cost": 0,
                "tax": 0,
                "total_cost": 0
            }
        ],
        "payment_method": "نقدي",
        "amount_paid": -2000.0
    }
    
    response = requests.post(f"{BASE_URL}/api/invoices", json=invoice_data)
    
    if response.status_code == 201:
        invoice = response.json()
        print_test("إنشاء مرتجع شراء", True, f"Invoice ID: {invoice['id']}")
        print_test("الربط بالفاتورة الأصلية", 
                   invoice.get('original_invoice_id') == original_invoice_id,
                   f"Original ID: {invoice.get('original_invoice_id')}")
        
        # Check journal entry
        je_response = requests.get(f"{BASE_URL}/api/journal-entries")
        if je_response.status_code == 200:
            entries = je_response.json()
            latest = entries[0] if entries else None
            if latest and 'مرتجع شراء' in latest['description']:
                print_test("القيد المحاسبي لمرتجع الشراء", True, f"Entry ID: {latest['id']}")
                print(f"   المدين: الصندوق | الدائن: المخزون")
            else:
                print_test("القيد المحاسبي لمرتجع الشراء", False, "لم يتم إنشاء القيد")
        
        return invoice['id']
    else:
        print_test("إنشاء مرتجع شراء", False, f"Error: {response.text}")
        return None

def test_invoice_type_6_supplier_return(original_invoice_id):
    """Test 7: Create مرتجع شراء من مورد invoice"""
    print_section("Test 7: فاتورة مرتجع شراء من مورد")
    
    if not original_invoice_id:
        print_test("مرتجع شراء من مورد", False, "لا توجد فاتورة شراء من مورد أصلية")
        return None
    
    invoice_data = {
        "supplier_id": 1,
        "invoice_type": "مرتجع شراء من مورد",
        "original_invoice_id": original_invoice_id,
        "return_reason": "عدم مطابقة المواصفات - اختبار",
        "date": datetime.now().strftime("%Y-%m-%d"),
        "items": [
            {
                "description": "ذهب جديد عيار 21 (مرتجع)",
                "karat": 21,
                "weight": 20.0,
                "wage_per_gram": 5.0,
                "net_cost": 0,
                "tax": 0,
                "total_cost": 0
            }
        ],
        "payment_method": "آجل",
        "amount_paid": 0
    }
    
    response = requests.post(f"{BASE_URL}/api/invoices", json=invoice_data)
    
    if response.status_code == 201:
        invoice = response.json()
        print_test("إنشاء مرتجع شراء من مورد", True, f"Invoice ID: {invoice['id']}")
        print_test("الربط بالفاتورة الأصلية", 
                   invoice.get('original_invoice_id') == original_invoice_id,
                   f"Original ID: {invoice.get('original_invoice_id')}")
        
        # Check journal entry
        je_response = requests.get(f"{BASE_URL}/api/journal-entries")
        if je_response.status_code == 200:
            entries = je_response.json()
            latest = entries[0] if entries else None
            if latest and 'مرتجع شراء من مورد' in latest['description']:
                print_test("القيد المحاسبي لمرتجع شراء من مورد", True, f"Entry ID: {latest['id']}")
                print(f"   المدين: الموردين | الدائن: المخزون")
            else:
                print_test("القيد المحاسبي لمرتجع شراء من مورد", False, "لم يتم إنشاء القيد")
        
        return invoice['id']
    else:
        print_test("إنشاء مرتجع شراء من مورد", False, f"Error: {response.text}")
        return None

def test_returnable_invoices_api():
    """Test 8: Test returnable invoices API"""
    print_section("Test 8: اختبار API الفواتير القابلة للإرجاع")
    
    # Test for sales invoices
    response = requests.get(f"{BASE_URL}/api/invoices/returnable?invoice_type=بيع")
    
    if response.status_code == 200:
        data = response.json()
        print_test("API الفواتير القابلة للإرجاع (بيع)", True, 
                   f"عدد الفواتير: {len(data.get('invoices', []))}")
    else:
        print_test("API الفواتير القابلة للإرجاع", False, f"Error: {response.text}")

def test_validation():
    """Test 9: Test validation rules"""
    print_section("Test 9: اختبار قواعد Validation")
    
    # Test 1: Return without original_invoice_id
    invalid_return = {
        "customer_id": 1,
        "invoice_type": "مرتجع بيع",
        # Missing original_invoice_id
        "date": datetime.now().strftime("%Y-%m-%d"),
        "items": []
    }
    
    response = requests.post(f"{BASE_URL}/api/invoices", json=invalid_return)
    print_test("رفض المرتجع بدون فاتورة أصلية", 
               response.status_code == 400,
               "يجب رفض المرتجع بدون original_invoice_id")
    
    # Test 2: Return without return_reason
    invalid_return2 = {
        "customer_id": 1,
        "invoice_type": "مرتجع بيع",
        "original_invoice_id": 1,
        # Missing return_reason
        "date": datetime.now().strftime("%Y-%m-%d"),
        "items": []
    }
    
    response = requests.post(f"{BASE_URL}/api/invoices", json=invalid_return2)
    print_test("رفض المرتجع بدون سبب إرجاع", 
               response.status_code == 400,
               "يجب رفض المرتجع بدون return_reason")

def main():
    """Run all tests"""
    print("\n" + "🧪" * 35)
    print("  اختبار شامل لنظام الفواتير والمرتجعات")
    print("  Complete Test Suite for Invoice & Returns System")
    print("🧪" * 35)
    
    # Create test customer
    customer_id = test_create_customer()
    
    if not customer_id:
        print("\n❌ فشل الاختبار: لم يتم إنشاء العميل")
        return
    
    # Test all 6 invoice types
    sale_invoice_id = test_invoice_type_1_sale(customer_id)
    purchase_invoice_id = test_invoice_type_2_purchase_from_customer(customer_id)
    supplier_purchase_id = test_invoice_type_3_purchase_from_supplier()
    sales_return_id = test_invoice_type_4_sales_return(sale_invoice_id, customer_id)
    purchase_return_id = test_invoice_type_5_purchase_return(purchase_invoice_id, customer_id)
    supplier_return_id = test_invoice_type_6_supplier_return(supplier_purchase_id)
    
    # Test APIs
    test_returnable_invoices_api()
    test_validation()
    
    # Summary
    print_section("📊 ملخص الاختبار")
    print(f"""
    ✅ فاتورة بيع: {"نجح" if sale_invoice_id else "فشل"}
    ✅ فاتورة شراء من عميل: {"نجح" if purchase_invoice_id else "فشل"}
    ✅ فاتورة شراء من مورد: {"نجح" if supplier_purchase_id else "فشل"}
    ✅ مرتجع بيع: {"نجح" if sales_return_id else "فشل"}
    ✅ مرتجع شراء: {"نجح" if purchase_return_id else "فشل"}
    ✅ مرتجع شراء من مورد: {"نجح" if supplier_return_id else "فشل"}
    
    📝 جميع الاختبارات مكتملة!
    """)

if __name__ == "__main__":
    main()
