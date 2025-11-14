#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
سكريبت للتحقق من إعدادات الحسابات المحاسبية
يستخدم API بدلاً من قاعدة البيانات مباشرة لتجنب مشاكل Flask app context
"""

import requests
import json
from collections import defaultdict

BASE_URL = 'http://localhost:8001/api'

def check_mappings():
    """عرض جميع الإعدادات المحاسبية مجمعة حسب نوع العملية"""
    try:
        response = requests.get(f'{BASE_URL}/accounting-mappings', timeout=5)
        response.raise_for_status()
        
        mappings = response.json()
        
        if not mappings:
            print('⚠️  لا توجد إعدادات محاسبية')
            return
        
        # تجميع حسب نوع العملية
        grouped = defaultdict(list)
        for m in mappings:
            grouped[m['operation_type']].append(m)
        
        print(f'📊 إجمالي الإعدادات: {len(mappings)}\n')
        print('='*70)
        
        for op_type in sorted(grouped.keys()):
            print(f'\n🔹 {op_type}:')
            print('-'*70)
            for m in grouped[op_type]:
                status = '✅' if m.get('is_active', True) else '❌'
                print(f"  {status} {m['account_type']:20} → [{m['account_id']:3}] {m['account_name']}")
        
        print('\n' + '='*70)
        
    except requests.exceptions.ConnectionError:
        print('❌ خطأ: لا يمكن الاتصال بالخادم. تأكد من تشغيل الخادم على المنفذ 8001')
    except Exception as e:
        print(f'❌ خطأ: {str(e)}')


def check_accounts():
    """عرض الحسابات الأساسية المستخدمة في الإعدادات"""
    try:
        response = requests.get(f'{BASE_URL}/accounts', timeout=5)
        response.raise_for_status()
        
        accounts = response.json()
        
        # الحسابات الأساسية
        key_accounts = {
            'المخزون': ['مخزون ذهب'],
            'النقدية': ['صندوق'],
            'العملاء': ['عملاء', 'العملاء'],
            'الموردين': ['موردين', 'الموردين'],
            'الضرائب': ['ضريبة القيمة المضافة'],
            'المبيعات': ['مبيعات'],
            'التكلفة': ['تكلفة'],
            'المردودات': ['مردود'],
        }
        
        print('\n📋 الحسابات الأساسية المتوفرة:\n')
        print('='*70)
        
        for category, search_terms in key_accounts.items():
            print(f'\n🔹 {category}:')
            print('-'*70)
            for acc in accounts:
                if any(term in acc['name'] for term in search_terms):
                    acc_type = acc.get('account_type', 'N/A')
                    print(f"  [{acc['id']:3}] {acc['name']:40} ({acc_type})")
        
        print('\n' + '='*70)
        
    except Exception as e:
        print(f'❌ خطأ في جلب الحسابات: {str(e)}')


def verify_coverage():
    """التحقق من اكتمال الإعدادات لجميع أنواع العمليات"""
    required_operations = {
        'بيع': ['inventory_21k', 'cash', 'customers', 'revenue', 'cost', 'vat_payable'],
        'شراء': ['inventory_21k', 'cash', 'suppliers', 'vat_receivable'],
        'شراء من عميل': ['inventory_21k', 'cash', 'customers', 'vat_receivable'],
        'مرتجع بيع': ['sales_returns', 'cash', 'customers'],
        'مرتجع شراء': ['purchase_returns', 'cash', 'suppliers'],
    }
    
    try:
        response = requests.get(f'{BASE_URL}/accounting-mappings', timeout=5)
        response.raise_for_status()
        
        mappings = response.json()
        
        # تحويل إلى dict للبحث السريع
        mapping_dict = {}
        for m in mappings:
            key = (m['operation_type'], m['account_type'])
            mapping_dict[key] = m
        
        print('\n🔍 التحقق من اكتمال الإعدادات:\n')
        print('='*70)
        
        all_complete = True
        
        for op_type, required_types in required_operations.items():
            print(f'\n🔹 {op_type}:')
            missing = []
            for acc_type in required_types:
                if (op_type, acc_type) in mapping_dict:
                    print(f'  ✅ {acc_type}')
                else:
                    print(f'  ❌ {acc_type} (مفقود)')
                    missing.append(acc_type)
                    all_complete = False
            
            if missing:
                print(f'  ⚠️  يجب إضافة: {", ".join(missing)}')
        
        print('\n' + '='*70)
        
        if all_complete:
            print('\n✅ جميع الإعدادات المطلوبة موجودة')
        else:
            print('\n⚠️  بعض الإعدادات مفقودة، استخدم API لإضافتها')
        
    except Exception as e:
        print(f'❌ خطأ: {str(e)}')


if __name__ == '__main__':
    print('\n' + '='*70)
    print('🔍 فحص إعدادات الحسابات المحاسبية')
    print('='*70)
    
    # عرض الإعدادات الحالية
    check_mappings()
    
    # عرض الحسابات الأساسية
    check_accounts()
    
    # التحقق من الاكتمال
    verify_coverage()
    
    print('\n')
