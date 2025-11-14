"""
Customer and Supplier Code Generator
مولد أكواد العملاء والموردين والأصناف

يوفر دوال لتوليد أكواد فريدة للعملاء والموردين والأصناف بالشكل:
- العملاء: C-000001, C-000002, C-000003, ...
- الموردين: S-000001, S-000002, S-000003, ...
- الأصناف: I-000001, I-000002, I-000003, ...
"""

from backend.models import Customer, Supplier, Item, db


def generate_customer_code() -> str:
    """
    توليد كود عميل فريد بالشكل C-000001
    
    Returns:
        str: كود العميل الجديد (مثل: C-000001)
        
    Example:
        >>> code = generate_customer_code()
        >>> print(code)
        'C-000001'
    """
    # احصل على آخر عميل
    last_customer = Customer.query.order_by(Customer.id.desc()).first()
    
    if last_customer and last_customer.customer_code:
        try:
            # استخرج الرقم من C-000001
            last_number = int(last_customer.customer_code.split('-')[1])
            next_number = last_number + 1
        except (IndexError, ValueError):
            # إذا كان التنسيق غير صحيح، ابدأ من 1
            next_number = 1
    else:
        # أول عميل
        next_number = 1
    
    # أنشئ الكود بالتنسيق C-000001 (6 خانات)
    return f"C-{next_number:06d}"


def generate_supplier_code() -> str:
    """
    توليد كود مورد فريد بالشكل S-000001
    
    Returns:
        str: كود المورد الجديد (مثل: S-000001)
        
    Example:
        >>> code = generate_supplier_code()
        >>> print(code)
        'S-000001'
    """
    # احصل على آخر مورد
    last_supplier = Supplier.query.order_by(Supplier.id.desc()).first()
    
    if last_supplier and last_supplier.supplier_code:
        try:
            # استخرج الرقم من S-000001
            last_number = int(last_supplier.supplier_code.split('-')[1])
            next_number = last_number + 1
        except (IndexError, ValueError):
            # إذا كان التنسيق غير صحيح، ابدأ من 1
            next_number = 1
    else:
        # أول مورد
        next_number = 1
    
    # أنشئ الكود بالتنسيق S-000001 (6 خانات)
    return f"S-{next_number:06d}"


def generate_item_code() -> str:
    """
    توليد كود صنف فريد بالشكل I-000001
    
    Returns:
        str: كود الصنف الجديد (مثل: I-000001)
        
    Example:
        >>> code = generate_item_code()
        >>> print(code)
        'I-000001'
    """
    # احصل على آخر صنف
    last_item = Item.query.order_by(Item.id.desc()).first()
    
    if last_item:
        if last_item.item_code:
            try:
                # استخرج الرقم من I-000001
                last_number = int(last_item.item_code.split('-')[1])
                next_number = last_number + 1
            except (IndexError, ValueError):
                # إذا كان التنسيق غير صحيح، استخدم ID + 1
                next_number = last_item.id + 1
        else:
            # إذا لم يكن لديه item_code، استخدم ID + 1
            next_number = last_item.id + 1
    else:
        # أول صنف
        next_number = 1
    
    # أنشئ الكود بالتنسيق I-000001 (6 خانات)
    return f"I-{next_number:06d}"


def generate_barcode_from_item_code(item_code: str) -> str:
    """
    توليد باركود من كود الصنف
    
    Args:
        item_code (str): كود الصنف (مثل: I-000001)
        
    Returns:
        str: باركود بالشكل YAS000001
        
    Example:
        >>> barcode = generate_barcode_from_item_code('I-000001')
        >>> print(barcode)
        'YAS000001'
    """
    try:
        # استخرج الرقم من I-000001
        number = item_code.split('-')[1]
        # أنشئ الباركود: YAS + الرقم
        return f"YAS{number}"
    except (IndexError, ValueError):
        # في حالة الخطأ، استخدم رقم عشوائي
        import random
        return f"YAS{random.randint(1, 999999):06d}"


def validate_item_code(code: str) -> dict:
    """
    التحقق من صحة كود صنف
    
    Args:
        code (str): كود الصنف للتحقق منه
        
    Returns:
        dict: نتيجة التحقق مع رسالة توضيحية
        
    Example:
        >>> result = validate_item_code('I-000001')
        >>> print(result)
        {'is_valid': True, 'message': 'الكود صحيح'}
    """
    if not code:
        return {'is_valid': False, 'message': 'الكود مطلوب'}
    
    # تحقق من التنسيق
    if not code.startswith('I-'):
        return {'is_valid': False, 'message': 'الكود يجب أن يبدأ بـ I-'}
    
    try:
        # تحقق من أن الجزء الرقمي صحيح
        number_part = code.split('-')[1]
        int(number_part)
    except (IndexError, ValueError):
        return {'is_valid': False, 'message': 'تنسيق الكود غير صحيح (I-000001)'}
    
    # تحقق من عدم وجود تكرار
    existing = Item.query.filter_by(item_code=code).first()
    if existing:
        return {'is_valid': False, 'message': f'الكود {code} مستخدم بالفعل'}
    
    return {'is_valid': True, 'message': 'الكود صحيح ومتاح'}


def validate_supplier_code(code: str) -> dict:
    """
    التحقق من صحة كود عميل
    
    Args:
        code (str): كود العميل للتحقق منه
        
    Returns:
        dict: نتيجة التحقق مع رسالة توضيحية
        
    Example:
        >>> result = validate_customer_code('C-000001')
        >>> print(result)
        {'is_valid': True, 'message': 'الكود صحيح'}
    """
    if not code:
        return {'is_valid': False, 'message': 'الكود مطلوب'}
    
    # تحقق من التنسيق
    if not code.startswith('C-'):
        return {'is_valid': False, 'message': 'الكود يجب أن يبدأ بـ C-'}
    
    try:
        # تحقق من أن الجزء الرقمي صحيح
        number_part = code.split('-')[1]
        int(number_part)
    except (IndexError, ValueError):
        return {'is_valid': False, 'message': 'تنسيق الكود غير صحيح (C-000001)'}
    
    # تحقق من عدم وجود تكرار
    existing = Customer.query.filter_by(customer_code=code).first()
    if existing:
        return {'is_valid': False, 'message': f'الكود {code} مستخدم بالفعل'}
    
    return {'is_valid': True, 'message': 'الكود صحيح ومتاح'}


def validate_supplier_code(code: str) -> dict:
    """
    التحقق من صحة كود مورد
    
    Args:
        code (str): كود المورد للتحقق منه
        
    Returns:
        dict: نتيجة التحقق مع رسالة توضيحية
    """
    if not code:
        return {'is_valid': False, 'message': 'الكود مطلوب'}
    
    # تحقق من التنسيق
    if not code.startswith('S-'):
        return {'is_valid': False, 'message': 'الكود يجب أن يبدأ بـ S-'}
    
    try:
        # تحقق من أن الجزء الرقمي صحيح
        number_part = code.split('-')[1]
        int(number_part)
    except (IndexError, ValueError):
        return {'is_valid': False, 'message': 'تنسيق الكود غير صحيح (S-000001)'}
    
    # تحقق من عدم وجود تكرار
    existing = Supplier.query.filter_by(supplier_code=code).first()
    if existing:
        return {'is_valid': False, 'message': f'الكود {code} مستخدم بالفعل'}
    
    return {'is_valid': True, 'message': 'الكود صحيح ومتاح'}


def get_item_statistics() -> dict:
    """
    احصل على إحصائيات الأصناف
    
    Returns:
        dict: إحصائيات شاملة عن الأصناف
    """
    total = Item.query.count()
    
    # احصل على آخر كود
    last_item = Item.query.order_by(Item.id.desc()).first()
    last_code = last_item.item_code if last_item else None
    
    capacity = 999999
    remaining = capacity - total
    return {
        'total_items': total,
        'last_item_code': last_code,
        'next_item_code': generate_item_code(),
        'remaining_capacity': remaining
    }


def get_customer_statistics() -> dict:
    """
    احصل على إحصائيات العملاء
    
    Returns:
        dict: إحصائيات شاملة عن العملاء
    """
    total = Customer.query.count()
    active = Customer.query.filter_by(active=True).count()
    inactive = total - active
    
    # احصل على آخر كود
    last_customer = Customer.query.order_by(Customer.id.desc()).first()
    last_code = last_customer.customer_code if last_customer else None
    
    capacity = 999999
    remaining = capacity - total
    return {
        'total_customers': total,
        'active_customers': active,
        'inactive_customers': inactive,
        'last_customer_code': last_code,
        'next_customer_code': generate_customer_code(),
        'remaining_capacity': remaining
    }


def get_supplier_statistics() -> dict:
    """
    احصل على إحصائيات الموردين
    
    Returns:
        dict: إحصائيات شاملة عن الموردين
    """
    total = Supplier.query.count()
    active = Supplier.query.filter_by(active=True).count()
    inactive = total - active
    
    # احصل على آخر كود
    last_supplier = Supplier.query.order_by(Supplier.id.desc()).first()
    last_code = last_supplier.supplier_code if last_supplier else None
    
    capacity = 999999
    remaining = capacity - total
    return {
        'total_suppliers': total,
        'active_suppliers': active,
        'inactive_suppliers': inactive,
        'last_supplier_code': last_code,
        'next_supplier_code': generate_supplier_code(),
        'remaining_capacity': remaining
    }


if __name__ == '__main__':
    # اختبار الدوال
    from app import app
    
    with app.app_context():
        print("=== اختبار توليد أكواد العملاء ===")
        customer_code = generate_customer_code()
        print(f"كود العميل التالي: {customer_code}")
        
        print("\n=== اختبار توليد أكواد الموردين ===")
        supplier_code = generate_supplier_code()
        print(f"كود المورد التالي: {supplier_code}")
        
        print("\n=== إحصائيات العملاء ===")
        stats = get_customer_statistics()
        for key, value in stats.items():
            print(f"{key}: {value}")
        
        print("\n=== إحصائيات الموردين ===")
        stats = get_supplier_statistics()
        for key, value in stats.items():
            print(f"{key}: {value}")
