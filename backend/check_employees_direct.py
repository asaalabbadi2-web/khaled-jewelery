#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
فحص مباشر للموظفين وحساباتهم
"""

import sys
import os

backend_dir = os.path.dirname(os.path.abspath(__file__))
parent_dir = os.path.dirname(backend_dir)
sys.path.insert(0, parent_dir)

from backend.app import app
from backend.models import db, Employee, Account

with app.app_context():
    print("\n" + "="*70)
    print("🔍 فحص مباشر للموظفين")
    print("="*70)
    
    employees = Employee.query.all()
    print(f"\nإجمالي الموظفين: {len(employees)}\n")
    
    for emp in employees:
        print(f"👤 {emp.name} (ID: {emp.id})")
        print(f"   كود: {emp.employee_code}")
        print(f"   account_id: {emp.account_id}")
        
        if emp.account_id:
            acc = Account.query.get(emp.account_id)
            if acc:
                print(f"   ✅ الحساب: {acc.account_number} - {acc.name}")
            else:
                print(f"   ❌ account_id موجود لكن الحساب غير موجود!")
        else:
            print(f"   ❌ لا يوجد account_id")
        print()
    
    print("="*70)
    print("\n🗂️ الحسابات التي تبدأ بـ 131:")
    accounts = Account.query.filter(Account.account_number.like('131%')).all()
    for acc in accounts:
        print(f"   {acc.account_number} - {acc.name}")
    
    print("="*70)
