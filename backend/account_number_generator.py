"""
Account Number Generator - مولد أرقام الحسابات التلقائي

هذا الملف يحتوي على دوال مساعدة لتوليد أرقام الحسابات بشكل تلقائي
يدعم:
- الترقيم المتصل (للعملاء والموردين بالآلاف)
- الترقيم مع التباعد (للحسابات العادية)
"""

from backend.models import Account, db


def get_next_account_number(parent_account_number: str, use_spacing: bool = False) -> str:
    """
    توليد رقم الحساب التالي المتاح لحساب فرعي
    
    Args:
        parent_account_number (str): رقم الحساب الأب (مثل '1100' لعملاء بيع الذهب)
        use_spacing (bool): إذا كان True، استخدم تباعد 10، وإلا استخدم ترقيم متصل (1,2,3...)
    
    Returns:
        str: رقم الحساب التالي المتاح
        
    Raises:
        ValueError: إذا تجاوزت السعة المتاحة للنطاق
        
    Examples:
        >>> get_next_account_number('1100', use_spacing=False)
        '110000'  # أول عميل بيع ذهب
        
        >>> get_next_account_number('1100', use_spacing=False)
        '110001'  # ثاني عميل بيع ذهب
        
        >>> get_next_account_number('100', use_spacing=True)
        '1040'  # رابع حساب بنكي (بعد 1000, 1010, 1020, 1030)
    """
    
    # حدد نطاق البحث بناءً على طول رقم الحساب الأب
    parent_len = len(parent_account_number)
    
    if parent_len <= 3:
        # حسابات من 3 خانات أو أقل (مثل 100، 110، 120)
        # نضيف خانة واحدة (تباعد 10) أو نضيف 3 خانات للعملاء
        # نتحقق من نوع الحساب
        if parent_account_number in ['1100', '1110', '1120']:  # حسابات العملاء
            # استخدم 6 خانات (ترقيم متصل للآلاف)
            start_range = int(parent_account_number + '000')
            end_range = int(parent_account_number.replace('11', '11') + '999')
            # مثال: 1100 -> start=110000, end=119999
        else:
            # حسابات عادية (4 خانات)
            start_range = int(parent_account_number + '0')
            end_range = int(parent_account_number + '90')
            
    elif parent_len == 4:
        # حسابات من 4 خانات (مثل 1000، 1100، 1200)
        # نضيف خانتين
        start_range = int(parent_account_number + '00')
        end_range = int(parent_account_number + '99')
        
    else:
        # حسابات أطول
        start_range = int(parent_account_number + '0')
        end_range = int(parent_account_number + '9')
    
    # ابحث عن آخر رقم حساب مستخدم في هذا النطاق
    last_account = Account.query.filter(
        db.cast(Account.account_number, db.Integer) >= start_range,
        db.cast(Account.account_number, db.Integer) <= end_range
    ).order_by(db.cast(Account.account_number, db.Integer).desc()).first()
    
    if last_account:
        last_number = int(last_account.account_number)
        if use_spacing:
            # استخدم تباعد 10
            next_number = last_number + 10
        else:
            # ترقيم متصل (+1)
            next_number = last_number + 1
    else:
        # أول حساب في هذا النطاق
        next_number = start_range
    
    # تحقق من عدم تجاوز النطاق المسموح
    if next_number > end_range:
        raise ValueError(
            f"تجاوزت السعة المتاحة للحساب {parent_account_number}. "
            f"النطاق المسموح: {start_range} - {end_range}"
        )
    
    return str(next_number)


def get_customer_account_capacity(customer_category: str = '1100') -> dict:
    """
    احصل على معلومات السعة المتاحة لفئة عملاء معينة
    
    Args:
        customer_category (str): رقم فئة العملاء (1100، 1110، 1120...)
        
    Returns:
        dict: معلومات السعة والاستخدام
        
    Example:
        >>> get_customer_account_capacity('1100')
        {
            'total_capacity': 10000,
            'used': 150,
            'available': 9850,
            'next_number': '110150',
            'usage_percentage': 1.5
        }
    """
    
    # حدد النطاق الكامل
    start_range = int(customer_category + '000')
    
    # النطاق النهائي يعتمد على الرقم
    if customer_category == '1100':
        # عملاء بيع ذهب: من 110000 إلى 119999
        end_range = 119999
    else:
        # فئات أخرى: من XXX000 إلى XXX999
        end_range = int(customer_category + '999')
    
    total_capacity = end_range - start_range + 1
    
    # عدد الحسابات المستخدمة
    used_count = Account.query.filter(
        db.cast(Account.account_number, db.Integer) >= start_range,
        db.cast(Account.account_number, db.Integer) <= end_range
    ).count()
    
    available = total_capacity - used_count
    
    # احصل على الرقم التالي
    try:
        next_number = get_next_account_number(customer_category, use_spacing=False)
    except ValueError:
        next_number = None
    
    usage_percentage = (used_count / total_capacity) * 100
    
    return {
        'category': customer_category,
        'total_capacity': total_capacity,
        'used': used_count,
        'available': available,
        'next_number': next_number,
        'usage_percentage': round(usage_percentage, 2),
        'start_range': start_range,
        'end_range': end_range
    }


def suggest_account_number_with_validation(parent_account_number: str) -> dict:
    """
    اقترح رقم الحساب التالي مع التحقق من الصحة
    
    Args:
        parent_account_number (str): رقم الحساب الأب
        
    Returns:
        dict: الرقم المقترح ومعلومات إضافية
        
    Example:
        >>> suggest_account_number_with_validation('1100')
        {
            'suggested_number': '110000',
            'is_valid': True,
            'message': 'رقم الحساب متاح',
            'capacity_info': {...}
        }
    """
    
    try:
        # تحديد ما إذا كان يجب استخدام التباعد
        # العملاء والموردين: بدون تباعد
        # البقية: مع تباعد
        use_spacing = parent_account_number not in ['1100', '1110', '1120', '211', '212']
        
        suggested_number = get_next_account_number(parent_account_number, use_spacing)
        
        # احصل على معلومات السعة إذا كان حساب عملاء
        capacity_info = None
        if parent_account_number in ['1100', '1110', '1120']:
            capacity_info = get_customer_account_capacity(parent_account_number)
        
        return {
            'suggested_number': suggested_number,
            'is_valid': True,
            'message': 'رقم الحساب متاح',
            'use_spacing': use_spacing,
            'capacity_info': capacity_info
        }
        
    except ValueError as e:
        return {
            'suggested_number': None,
            'is_valid': False,
            'message': str(e),
            'use_spacing': use_spacing,
            'capacity_info': None
        }


def validate_account_number(account_number: str, parent_account_number: str) -> dict:
    """
    التحقق من صحة رقم حساب مقترح
    
    Args:
        account_number (str): رقم الحساب المقترح
        parent_account_number (str): رقم الحساب الأب
        
    Returns:
        dict: نتيجة التحقق
        
    Example:
        >>> validate_account_number('110000', '1100')
        {'is_valid': True, 'message': 'رقم الحساب صحيح ومتاح'}
    """
    
    # تحقق من أن الرقم يبدأ برقم الأب
    if not account_number.startswith(parent_account_number):
        return {
            'is_valid': False,
            'message': f'رقم الحساب يجب أن يبدأ بـ {parent_account_number}'
        }
    
    # تحقق من أن الرقم غير مستخدم
    existing = Account.query.filter_by(account_number=account_number).first()
    if existing:
        return {
            'is_valid': False,
            'message': f'رقم الحساب {account_number} مستخدم بالفعل'
        }
    
    # تحقق من النطاق
    account_num = int(account_number)
    parent_len = len(parent_account_number)
    
    if parent_account_number in ['1100', '1110', '1120']:
        # عملاء
        if parent_account_number == '1100':
            start, end = 110000, 119999
        else:
            start = int(parent_account_number + '000')
            end = int(parent_account_number + '999')
    else:
        # حسابات عادية
        if parent_len <= 3:
            start = int(parent_account_number + '0')
            end = int(parent_account_number + '90')
        else:
            start = int(parent_account_number + '0')
            end = int(parent_account_number + '9')
    
    if account_num < start or account_num > end:
        return {
            'is_valid': False,
            'message': f'رقم الحساب خارج النطاق المسموح ({start} - {end})'
        }
    
    return {
        'is_valid': True,
        'message': 'رقم الحساب صحيح ومتاح'
    }


if __name__ == '__main__':
    # اختبار الدوال
    from app import app
    
    with app.app_context():
        # مثال 1: عملاء بيع ذهب
        print("=== عملاء بيع ذهب ===")
        result = suggest_account_number_with_validation('1100')
        print(f"الرقم المقترح: {result['suggested_number']}")
        if result['capacity_info']:
            print(f"السعة المستخدمة: {result['capacity_info']['used']} / {result['capacity_info']['total_capacity']}")
            print(f"نسبة الاستخدام: {result['capacity_info']['usage_percentage']}%")
        
        print("\n=== حسابات بنكية ===")
        result = suggest_account_number_with_validation('100')
        print(f"الرقم المقترح للبنك الجديد: {result['suggested_number']}")
        print(f"استخدام التباعد: {result['use_spacing']}")
