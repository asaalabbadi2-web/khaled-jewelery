#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
فحص وتحليل شجرة الحسابات الحالية
"""

import sys
import os

backend_dir = os.path.dirname(os.path.abspath(__file__))
parent_dir = os.path.dirname(backend_dir)
sys.path.insert(0, parent_dir)

from backend.app import app
from backend.models import db, Account

with app.app_context():
    accounts = Account.query.order_by(Account.account_number).all()
    
    print(f'\n📊 إجمالي الحسابات: {len(accounts)}\n')
    print('='*120)
    
    # تجميع حسب الرقم الأول
    groups = {}
    for acc in accounts:
        num = str(acc.account_number)
        first_digit = num[0] if num else '0'
        if first_digit not in groups:
            groups[first_digit] = []
        groups[first_digit].append(acc)
    
    for digit in sorted(groups.keys()):
        print(f'\n📁 المجموعة {digit}xxx ({len(groups[digit])} حساب):')
        print('-'*120)
        for acc in groups[digit]:
            trans_type = acc.transaction_type if hasattr(acc, 'transaction_type') else 'N/A'
            print(f'{acc.account_number:15} {acc.name[:70]:70} [{acc.type:10}] [{trans_type}]')
