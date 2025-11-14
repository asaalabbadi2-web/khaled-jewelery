#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
إضافة حقل invoice_number المميز لجدول الفواتير
وتحديث الفواتير الموجودة بأرقام مميزة
"""

import sys
import os

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from backend.models import db, Invoice
from backend.app import app
from invoice_number_generator import generate_invoice_number
from sqlalchemy import text

def add_invoice_number_column():
    """إضافة حقل invoice_number إلى جدول Invoice"""
    
    with app.app_context():
        print("\n📝 إضافة حقل invoice_number...")
        
        try:
            # إضافة العمود
            with db.engine.connect() as conn:
                # التحقق من وجود العمود
                result = conn.execute(text("PRAGMA table_info(invoice)"))
                columns = [row[1] for row in result]
                
                if 'invoice_number' in columns:
                    print("⚠️  حقل invoice_number موجود بالفعل")
                else:
                    # إضافة العمود
                    conn.execute(text(
                        "ALTER TABLE invoice ADD COLUMN invoice_number VARCHAR(50)"
                    ))
                    conn.commit()
                    print("✅ تم إضافة حقل invoice_number")
            
            # تحديث الفواتير الموجودة
            print("\n🔄 تحديث الفواتير الموجودة بأرقام مميزة...")
            
            invoices = Invoice.query.all()
            print(f"📊 عدد الفواتير: {len(invoices)}")
            
            updated_count = 0
            for invoice in invoices:
                # توليد رقم مميز
                invoice_number = generate_invoice_number(
                    invoice_type=invoice.invoice_type,
                    invoice_type_id=invoice.invoice_type_id,
                    invoice_date=invoice.date,
                    use_arabic=False  # استخدام البادئة الإنجليزية
                )
                
                # تحديث الفاتورة
                invoice.invoice_number = invoice_number
                updated_count += 1
                
                print(f"  ✓ الفاتورة #{invoice.id}: {invoice.invoice_type} → {invoice_number}")
            
            db.session.commit()
            print(f"\n✅ تم تحديث {updated_count} فاتورة بنجاح!")
            
            return True
            
        except Exception as e:
            db.session.rollback()
            print(f"\n❌ خطأ: {e}")
            return False


def verify_invoice_numbers():
    """التحقق من أرقام الفواتير"""
    
    with app.app_context():
        print("\n🔍 التحقق من أرقام الفواتير...\n")
        print("=" * 80)
        
        invoice_types = [
            'بيع',
            'شراء من عميل',
            'مرتجع بيع',
            'مرتجع شراء',
            'شراء من مورد',
            'مرتجع شراء من مورد'
        ]
        
        for invoice_type in invoice_types:
            invoices = Invoice.query.filter_by(invoice_type=invoice_type).order_by(Invoice.invoice_type_id).all()
            
            if invoices:
                print(f"\n📄 {invoice_type} ({len(invoices)} فاتورة):")
                for inv in invoices[:5]:  # عرض أول 5 فواتير فقط
                    print(f"   ID: {inv.id:3d} | Type ID: {inv.invoice_type_id:3d} | Number: {inv.invoice_number}")
                
                if len(invoices) > 5:
                    print(f"   ... و {len(invoices) - 5} فاتورة أخرى")
            else:
                print(f"\n📄 {invoice_type}: لا توجد فواتير")
        
        print("\n" + "=" * 80)


if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser(
        description='إضافة وتحديث أرقام الفواتير المميزة'
    )
    parser.add_argument(
        '--add',
        action='store_true',
        help='إضافة الحقل وتحديث الفواتير'
    )
    parser.add_argument(
        '--verify',
        action='store_true',
        help='التحقق من الأرقام'
    )
    
    args = parser.parse_args()
    
    if args.add:
        success = add_invoice_number_column()
        if success:
            verify_invoice_numbers()
    elif args.verify:
        verify_invoice_numbers()
    else:
        # الوضع الافتراضي
        success = add_invoice_number_column()
        if success:
            verify_invoice_numbers()
