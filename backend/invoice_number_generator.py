#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
نظام توليد أرقام فواتير مميزة لكل نوع
مثال: SELL-2025-001، BUY-2025-015، RETSELL-2025-003
"""

from datetime import datetime
from typing import Optional

# خريطة البادئات لكل نوع فاتورة
INVOICE_TYPE_PREFIXES = {
    'بيع': 'SELL',
    'شراء من عميل': 'BUY',
    'مرتجع بيع': 'RETSELL',
    'مرتجع شراء': 'RETBUY',
    'شراء من مورد': 'SUPP',
    'مرتجع شراء من مورد': 'RETSUPP',
}

# البادئات العربية (اختياري)
INVOICE_TYPE_PREFIXES_AR = {
    'بيع': 'بيع',
    'شراء من عميل': 'شراء',
    'مرتجع بيع': 'م.بيع',
    'مرتجع شراء': 'م.شراء',
    'شراء من مورد': 'مورد',
    'مرتجع شراء من مورد': 'م.مورد',
}


def generate_invoice_number(
    invoice_type: str,
    invoice_type_id: int,
    invoice_date: Optional[datetime] = None,
    use_arabic: bool = False,
    digits: int = 3
) -> str:
    """
    توليد رقم فاتورة مميز
    
    Args:
        invoice_type: نوع الفاتورة (بيع، شراء من عميل، إلخ)
        invoice_type_id: الرقم التسلسلي للفاتورة (1, 2, 3...)
        invoice_date: تاريخ الفاتورة (اختياري، افتراضي اليوم)
        use_arabic: استخدام البادئة العربية؟
        digits: عدد الأرقام في الرقم التسلسلي (افتراضي 3)
    
    Returns:
        رقم الفاتورة المميز (مثال: SELL-2025-001)
    
    Examples:
        >>> generate_invoice_number('بيع', 1)
        'SELL-2025-001'
        
        >>> generate_invoice_number('شراء من عميل', 15)
        'BUY-2025-015'
        
        >>> generate_invoice_number('بيع', 1, use_arabic=True)
        'بيع-2025-001'
    """
    # تحديد التاريخ
    if invoice_date is None:
        invoice_date = datetime.now()
    
    year = invoice_date.year
    
    # تحديد البادئة
    if use_arabic:
        prefix = INVOICE_TYPE_PREFIXES_AR.get(invoice_type, 'INV')
    else:
        prefix = INVOICE_TYPE_PREFIXES.get(invoice_type, 'INV')
    
    # تنسيق الرقم التسلسلي
    sequence = str(invoice_type_id).zfill(digits)
    
    # تكوين الرقم النهائي
    invoice_number = f'{prefix}-{year}-{sequence}'
    
    return invoice_number


def parse_invoice_number(invoice_number: str) -> dict:
    """
    تحليل رقم الفاتورة المميز
    
    Args:
        invoice_number: رقم الفاتورة (مثال: SELL-2025-001)
    
    Returns:
        قاموس يحتوي على: prefix, year, sequence
    
    Examples:
        >>> parse_invoice_number('SELL-2025-001')
        {'prefix': 'SELL', 'year': 2025, 'sequence': 1}
    """
    try:
        parts = invoice_number.split('-')
        if len(parts) != 3:
            return None
        
        prefix = parts[0]
        year = int(parts[1])
        sequence = int(parts[2])
        
        return {
            'prefix': prefix,
            'year': year,
            'sequence': sequence
        }
    except (ValueError, AttributeError):
        return None


def get_invoice_type_from_prefix(prefix: str, use_arabic: bool = False) -> Optional[str]:
    """
    الحصول على نوع الفاتورة من البادئة
    
    Args:
        prefix: البادئة (SELL، BUY، إلخ)
        use_arabic: هل البادئة عربية؟
    
    Returns:
        نوع الفاتورة (بيع، شراء من عميل، إلخ) أو None
    
    Examples:
        >>> get_invoice_type_from_prefix('SELL')
        'بيع'
        
        >>> get_invoice_type_from_prefix('بيع', use_arabic=True)
        'بيع'
    """
    prefixes = INVOICE_TYPE_PREFIXES_AR if use_arabic else INVOICE_TYPE_PREFIXES
    
    # عكس القاموس للبحث
    reverse_map = {v: k for k, v in prefixes.items()}
    
    return reverse_map.get(prefix)


def validate_invoice_number_format(invoice_number: str) -> bool:
    """
    التحقق من صحة تنسيق رقم الفاتورة
    
    Args:
        invoice_number: رقم الفاتورة
    
    Returns:
        True إذا كان التنسيق صحيح، False خلاف ذلك
    
    Examples:
        >>> validate_invoice_number_format('SELL-2025-001')
        True
        
        >>> validate_invoice_number_format('INVALID')
        False
    """
    parsed = parse_invoice_number(invoice_number)
    return parsed is not None


# دالة مساعدة للاستخدام المباشر
def format_invoice_display(invoice_type: str, invoice_number: str) -> str:
    """
    تنسيق رقم الفاتورة للعرض
    
    Args:
        invoice_type: نوع الفاتورة
        invoice_number: رقم الفاتورة المميز
    
    Returns:
        نص معروض (مثال: "فاتورة بيع: SELL-2025-001")
    
    Examples:
        >>> format_invoice_display('بيع', 'SELL-2025-001')
        'فاتورة بيع: SELL-2025-001'
    """
    return f'فاتورة {invoice_type}: {invoice_number}'


if __name__ == '__main__':
    # اختبار النظام
    print("🧪 اختبار نظام توليد أرقام الفواتير المميزة\n")
    print("=" * 60)
    
    test_cases = [
        ('بيع', 1),
        ('شراء من عميل', 15),
        ('مرتجع بيع', 3),
        ('شراء من مورد', 42),
        ('مرتجع شراء', 7),
        ('مرتجع شراء من مورد', 2),
    ]
    
    for invoice_type, type_id in test_cases:
        # الإنجليزية
        number_en = generate_invoice_number(invoice_type, type_id, use_arabic=False)
        print(f"\n{invoice_type}:")
        print(f"  الرقم (إنجليزي): {number_en}")
        
        # العربية
        number_ar = generate_invoice_number(invoice_type, type_id, use_arabic=True)
        print(f"  الرقم (عربي): {number_ar}")
        
        # التحليل
        parsed = parse_invoice_number(number_en)
        print(f"  التحليل: {parsed}")
        
        # العرض
        display = format_invoice_display(invoice_type, number_en)
        print(f"  العرض: {display}")
    
    print("\n" + "=" * 60)
    print("✅ الاختبار مكتمل!")
