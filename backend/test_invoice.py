#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
اختبار سريع لإنشاء فاتورة بيع
"""

from app import app
from models import db, Invoice, InvoiceItem, Customer
from datetime import datetime
import json

with app.app_context():
    # التأكد من وجود عميل
    customer = Customer.query.first()
    if not customer:
        print("❌ لا يوجد عملاء في النظام")
        exit(1)
    
    print(f"✅ سيتم استخدام العميل: {customer.name} (ID: {customer.id})")
    
    # بيانات الفاتورة
    invoice_data = {
        "customer_id": customer.id,
        "date": datetime.now().isoformat(),
        "total": 1000.0,
        "total_weight": 2.0,
        "invoice_type": "بيع",
        "items": [
            {
                "name": "خاتم",
                "karat": 21,
                "weight": 2.0,
                "wage": 50,
                "net": 950,
                "tax": 0,
                "price": 1000,
                "quantity": 1
            }
        ]
    }
    
    print(f"\n📋 بيانات الفاتورة:")
    print(json.dumps(invoice_data, ensure_ascii=False, indent=2))
    
    # محاكاة الطلب
    print("\n🔄 سيتم إرسال الطلب إلى /api/invoices...")
    print("⏳ انتظر...")
    
    # استخدام requests لإرسال الطلب
    import requests
    
    try:
        response = requests.post(
            "http://127.0.0.1:8001/api/invoices",
            json=invoice_data,
            headers={"Content-Type": "application/json"}
        )
        
        if response.status_code == 201:
            print("\n✅ تم إنشاء الفاتورة بنجاح!")
            result = response.json()
            print(f"رقم الفاتورة: #{result.get('id')}")
            print(f"الإجمالي: {result.get('total')} ر.س")
            print(f"الوزن: {result.get('total_weight')} جم")
        else:
            print(f"\n❌ فشل في إنشاء الفاتورة (HTTP {response.status_code})")
            print(f"الخطأ: {response.text}")
            
    except Exception as e:
        print(f"\n❌ حدث خطأ: {e}")
