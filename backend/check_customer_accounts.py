#!/usr/bin/env python3
"""
فحص حسابات العملاء التفصيلية في النظام
"""

import sys
import os

# Set up path before imports
backend_dir = os.path.dirname(os.path.abspath(__file__))
parent_dir = os.path.dirname(backend_dir)
sys.path.insert(0, parent_dir)

# Import Flask app first to initialize db
from backend.app import app
from backend.models import db, Customer, Account

def check_customer_accounts():
    with app.app_context():
        print("=" * 70)
        print("📊 تقرير حسابات العملاء التفصيلية")
        print("=" * 70)
        
        # عدد العملاء
        total_customers = Customer.query.count()
        print(f'\n✅ إجمالي العملاء: {total_customers}')
        
        # فحص العملاء الذين لهم حسابات تفصيلية
        customers_with_accounts = Customer.query.filter(
            Customer.account_id.isnot(None)
        ).all()
        
        print(f'✅ عملاء لديهم حسابات تفصيلية: {len(customers_with_accounts)}')
        print(f'❌ عملاء بدون حسابات: {total_customers - len(customers_with_accounts)}')
        
        # عرض أمثلة للعملاء بحساباتهم
        if customers_with_accounts:
            print('\n' + '─' * 70)
            print('📋 أمثلة للعملاء وحساباتهم التفصيلية:')
            print('─' * 70)
            for i, customer in enumerate(customers_with_accounts[:10], 1):
                account = Account.query.get(customer.account_id)
                if account:
                    print(f'{i}. {customer.name}')
                    print(f'   └─ كود العميل: {customer.customer_code}')
                    print(f'   └─ رقم الحساب: {account.account_number}')
                    print(f'   └─ اسم الحساب: {account.name}')
                    print(f'   └─ نوع الحساب: {account.type}')
                    if customer.account_category_id:
                        category = Account.query.get(customer.account_category_id)
                        if category:
                            print(f'   └─ الفئة: {category.account_number} - {category.name}')
                    print()
        
        # فحص الحسابات التجميعية للعملاء
        print('─' * 70)
        print('🗂️ الحسابات التجميعية للعملاء:')
        print('─' * 70)
        
        customer_group_accounts = Account.query.filter(
            Account.account_number.in_(['1100', '1110', '1120'])
        ).all()
        
        if customer_group_accounts:
            for acc in customer_group_accounts:
                # عدد العملاء في هذه الفئة
                customers_in_category = Customer.query.filter_by(
                    account_category_id=acc.id
                ).count()
                
                print(f'  📁 {acc.account_number} - {acc.name}')
                print(f'     └─ عدد العملاء: {customers_in_category}')
        else:
            print('  ⚠️ لا توجد حسابات تجميعية')
        
        # فحص الحسابات التفصيلية للعملاء (110000-119999)
        print('\n' + '─' * 70)
        print('📄 الحسابات التفصيلية للعملاء (110000-119999):')
        print('─' * 70)
        
        # نطاق عملاء بيع ذهب (110000-119999)
        detail_accounts_gold = Account.query.filter(
            Account.account_number >= '110000',
            Account.account_number < '120000'
        ).order_by(Account.account_number).all()
        
        print(f'  💰 نطاق عملاء بيع ذهب (110000-119999): {len(detail_accounts_gold)}')
        
        if detail_accounts_gold:
            print('  أول 5 حسابات:')
            for acc in detail_accounts_gold[:5]:
                print(f'    • {acc.account_number} - {acc.name}')
        
        # نطاق عملاء صياغة (111000-111999)
        detail_accounts_craft = Account.query.filter(
            Account.account_number >= '111000',
            Account.account_number < '112000'
        ).order_by(Account.account_number).all()
        
        print(f'\n  ⚒️ نطاق عملاء صياغة (111000-111999): {len(detail_accounts_craft)}')
        
        if detail_accounts_craft:
            print('  أول 5 حسابات:')
            for acc in detail_accounts_craft[:5]:
                print(f'    • {acc.account_number} - {acc.name}')
        
        # نطاق عملاء مجوهرات (112000-112999)
        detail_accounts_jewelry = Account.query.filter(
            Account.account_number >= '112000',
            Account.account_number < '113000'
        ).order_by(Account.account_number).all()
        
        print(f'\n  💎 نطاق عملاء مجوهرات (112000-112999): {len(detail_accounts_jewelry)}')
        
        if detail_accounts_jewelry:
            print('  أول 5 حسابات:')
            for acc in detail_accounts_jewelry[:5]:
                print(f'    • {acc.account_number} - {acc.name}')
        
        print('\n' + '=' * 70)
        print('✅ تم الانتهاء من الفحص')
        print('=' * 70)

if __name__ == '__main__':
    check_customer_accounts()
