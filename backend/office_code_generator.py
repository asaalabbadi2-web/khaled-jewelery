#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
مولد أكواد المكاتب (مكاتب بيع وشراء الذهب)
مثال: OFF-000001, OFF-000002, ...
"""

from models import db, Office


def generate_office_code():
    """
    توليد كود فريد للمكتب
    
    الصيغة: OFF-XXXXXX
    حيث XXXXXX رقم تسلسلي من 6 خانات
    
    Returns:
        str: كود المكتب الفريد (مثال: OFF-000001)
    """
    # الحصول على آخر مكتب مسجل
    last_office = Office.query.order_by(Office.id.desc()).first()
    
    if last_office and last_office.office_code:
        try:
            # استخراج الرقم من الكود الأخير
            last_number = int(last_office.office_code.split('-')[1])
            new_number = last_number + 1
        except (IndexError, ValueError):
            # في حالة وجود خطأ في الصيغة، نبدأ من 1
            new_number = 1
    else:
        # أول مكتب في النظام
        new_number = 1
    
    # تنسيق الكود: OFF-XXXXXX
    office_code = f'OFF-{new_number:06d}'
    
    # التأكد من عدم وجود تكرار
    while Office.query.filter_by(office_code=office_code).first():
        new_number += 1
        office_code = f'OFF-{new_number:06d}'
    
    return office_code


def validate_office_code(office_code):
    """
    التحقق من صحة صيغة كود المكتب
    
    Args:
        office_code (str): كود المكتب
    
    Returns:
        bool: True إذا كان الكود صحيح
    """
    if not office_code:
        return False
    
    parts = office_code.split('-')
    if len(parts) != 2:
        return False
    
    prefix, number = parts
    if prefix != 'OFF':
        return False
    
    try:
        num = int(number)
        return len(number) == 6 and num > 0
    except ValueError:
        return False


if __name__ == '__main__':
    # اختبار المولد
    print("🧪 اختبار مولد أكواد المكاتب")
    print("=" * 50)
    
    # اختبار التوليد
    for i in range(5):
        code = generate_office_code()
        print(f"كود {i+1}: {code}")
        is_valid = validate_office_code(code)
        print(f"  صالح: {'✅' if is_valid else '❌'}")
    
    print("\n" + "=" * 50)
    print("✅ الاختبار مكتمل")
