#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
فحص الموظفين وإنشاء حسابات لهم
"""

import sys
import os

backend_dir = os.path.dirname(os.path.abspath(__file__))
parent_dir = os.path.dirname(backend_dir)
sys.path.insert(0, parent_dir)

from backend.app import app
from backend.models import db, Employee
from backend.employee_account_helpers import create_employee_account

def setup_employee_accounts():
    with app.app_context():
        employees = Employee.query.filter_by(is_active=True).all()
        print(f'\n📊 عدد الموظفين النشطين: {len(employees)}\n')
        print("="*70)
        
        for emp in employees:
            print(f'👤 {emp.name}:')
            print(f'   كود: {emp.employee_code}')
            print(f'   القسم: {emp.department or "غير محدد"}')
            print(f'   حساب شخصي: {"نعم ✅" if emp.account_id else "لا ❌"}')
            
            # إنشاء حساب إذا لم يكن موجوداً
            if not emp.account_id:
                try:
                    # تحويل اسم القسم العربي إلى الإنجليزي
                    department_map = {
                        'الإدارة': 'administration',
                        'المبيعات': 'sales',
                        'الصيانة': 'maintenance',
                        'المحاسبة': 'accounting',
                        'المستودعات': 'warehouse'
                    }
                    
                    dept = emp.department or 'الإدارة'
                    dept_en = department_map.get(dept, 'administration')
                    
                    account = create_employee_account(
                        employee_name=emp.name,
                        department=dept_en
                    )
                    
                    # لا تعمل commit هنا - سيتم بعد ربط الحساب بالموظف
                    db.session.flush()  # flush فقط لضمان حصول الحساب على ID
                    
                    # ربط الحساب بالموظف
                    emp.account_id = account.id
                    
                    # الآن نعمل commit
                    db.session.commit()
                    
                    print(f'   ✅ تم إنشاء وربط الحساب: {account.account_number} - {account.name}')
                except Exception as e:
                    db.session.rollback()
                    print(f'   ❌ خطأ: {e}')
                    import traceback
                    traceback.print_exc()
            print()
        
        print("="*70)

if __name__ == '__main__':
    setup_employee_accounts()
