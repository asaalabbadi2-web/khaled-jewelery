"""
نظام الصلاحيات المتكامل لنظام مجوهرات خالد
يحدد الصلاحيات التفصيلية لكل دور (مسؤول نظام، مدير، محاسب، موظف)
"""

# ==========================================
# تعريف الأدوار الأربعة
# ==========================================

ROLES = {
    'system_admin': 'مسؤول نظام',
    'manager': 'مدير',
    'accountant': 'محاسب',
    'employee': 'موظف',
}

# ==========================================
# تصنيف الصلاحيات حسب الوحدات
# ==========================================

# 1. إدارة المستخدمين والنظام
SYSTEM_PERMISSIONS = {
    'users.view': 'عرض المستخدمين',
    'users.create': 'إضافة مستخدمين',
    'users.edit': 'تعديل المستخدمين',
    'users.delete': 'حذف المستخدمين',
    'users.change_permissions': 'تغيير صلاحيات المستخدمين',
    'system.settings': 'إعدادات النظام',
    'system.backup': 'النسخ الاحتياطي والاستعادة',
    'system.logs': 'عرض سجلات النظام',
}

# 2. إدارة الموظفين
EMPLOYEE_PERMISSIONS = {
    'employees.view': 'عرض الموظفين',
    'employees.create': 'إضافة موظفين',
    'employees.edit': 'تعديل بيانات الموظفين',
    'employees.delete': 'حذف موظفين',
    'employees.payroll': 'إدارة الرواتب',
    'employees.bonuses': 'إدارة الحوافز',
}

# 3. الفواتير والمعاملات
INVOICE_PERMISSIONS = {
    'invoices.view': 'عرض الفواتير',
    'invoices.create': 'إنشاء فواتير',
    'invoices.edit': 'تعديل الفواتير',
    'invoices.delete': 'حذف الفواتير',
    'invoices.edit_others': 'تعديل فواتير الآخرين',
    'invoices.delete_others': 'حذف فواتير الآخرين',
    'invoices.approve': 'اعتماد الفواتير',
    'invoices.cancel': 'إلغاء فواتير معتمدة',
}

# 4. العملاء والموردين
CUSTOMER_PERMISSIONS = {
    'customers.view': 'عرض العملاء',
    'customers.create': 'إضافة عملاء',
    'customers.edit': 'تعديل بيانات العملاء',
    'customers.delete': 'حذف عملاء',
    'suppliers.view': 'عرض الموردين',
    'suppliers.create': 'إضافة موردين',
    'suppliers.edit': 'تعديل بيانات الموردين',
    'suppliers.delete': 'حذف موردين',
}

# 5. المخزون والأصناف
INVENTORY_PERMISSIONS = {
    'items.view': 'عرض الأصناف',
    'items.create': 'إضافة أصناف',
    'items.edit': 'تعديل الأصناف',
    'items.delete': 'حذف أصناف',
    'items.adjust': 'تعديل المخزون',
    'gold_price.view': 'عرض أسعار الذهب',
    'gold_price.update': 'تحديث أسعار الذهب',
    # جرد الذهب الفعلي (Inventory Engine)
    'inventory.view':    'عرض أرصدة الجرد والتقارير',
    'inventory.count':   'فتح وتسجيل جلسات الجرد الفعلي',
    'inventory.approve': 'اعتماد الجرد وتوليد قيود التسوية',
}

# 6. القيود والحسابات
ACCOUNTING_PERMISSIONS = {
    'accounts.view': 'عرض الحسابات',
    'accounts.create': 'إنشاء حسابات',
    'accounts.edit': 'تعديل الحسابات',
    'accounts.delete': 'حذف حسابات',

    # Safe Boxes (الخزائن)
    'safe_boxes.view': 'عرض الخزائن',
    'safe_boxes.create': 'إنشاء خزائن',
    'safe_boxes.edit': 'تعديل الخزائن',
    'safe_boxes.delete': 'حذف الخزائن',

    'journal.view': 'عرض القيود',
    'journal.create': 'إنشاء قيود',
    'journal.edit': 'تعديل القيود',
    'journal.delete': 'حذف قيود',
    'journal.post': 'ترحيل القيود',
    'vouchers.view': 'عرض السندات',
    'vouchers.create': 'إنشاء سندات',
    'vouchers.edit': 'تعديل السندات',
    'vouchers.delete': 'حذف سندات',

    # Supplier Settlement Adjustments (تسويات فروقات حسابات الموردين) — ADR-025
    # approve_other هي عتبة الاعتماد الإداري للسبب OTHER، وليست دوراً جديداً:
    # تُمنح لدور manager ولا تُمنح للمحاسب.
    'supplier_settlement_adjustments.view': 'عرض تسويات فروقات الموردين',
    'supplier_settlement_adjustments.create': 'إنشاء تسويات فروقات الموردين',
    'supplier_settlement_adjustments.approve': 'اعتماد تسويات فروقات الموردين',
    'supplier_settlement_adjustments.approve_other': 'اعتماد تسوية بسبب «أخرى» (اعتماد إداري)',
    'supplier_settlement_adjustments.post': 'ترحيل تسويات فروقات الموردين',
    'supplier_settlement_adjustments.reverse': 'عكس تسويات فروقات الموردين',
    'supplier_settlement_adjustments.cancel': 'إلغاء تسويات فروقات الموردين',
}

# 7. التقارير
REPORTS_PERMISSIONS = {
    'reports.financial': 'التقارير المالية',
    'reports.inventory': 'تقارير المخزون',
    'reports.sales': 'تقارير المبيعات',
    'reports.purchases': 'تقارير المشتريات',
    'reports.customers': 'تقارير العملاء',
    'reports.employees': 'تقارير الموظفين',
    'reports.gold_position': 'تقرير مركز الذهب',
}

# 8. الطباعة
PRINT_PERMISSIONS = {
    'print.invoices': 'طباعة الفواتير',
    'print.reports': 'طباعة التقارير',
    'print.statements': 'طباعة كشوف الحسابات',
}

# دمج جميع الصلاحيات
ALL_PERMISSIONS = {
    **SYSTEM_PERMISSIONS,
    **EMPLOYEE_PERMISSIONS,
    **INVOICE_PERMISSIONS,
    **CUSTOMER_PERMISSIONS,
    **INVENTORY_PERMISSIONS,
    **ACCOUNTING_PERMISSIONS,
    **REPORTS_PERMISSIONS,
    **PRINT_PERMISSIONS,
}

# ==========================================
# تحديد الصلاحيات الافتراضية لكل دور
# ==========================================

ROLE_PERMISSIONS = {
    # 1. مسؤول النظام - صلاحيات كاملة
    'system_admin': list(ALL_PERMISSIONS.keys()),
    
    # 2. المدير - جميع العمليات ما عدا إدارة النظام
    'manager': [
        # الموظفين
        'employees.view', 'employees.create', 'employees.edit', 'employees.delete',
        'employees.payroll', 'employees.bonuses',
        
        # الفواتير
        'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.delete',
        'invoices.edit_others', 'invoices.delete_others', 'invoices.approve', 'invoices.cancel',
        
        # العملاء والموردين
        'customers.view', 'customers.create', 'customers.edit', 'customers.delete',
        'suppliers.view', 'suppliers.create', 'suppliers.edit', 'suppliers.delete',
        
        # المخزون
        'items.view', 'items.create', 'items.edit', 'items.delete', 'items.adjust',
        'gold_price.view', 'gold_price.update',
        'inventory.view', 'inventory.count', 'inventory.approve',
        
        # المحاسبة (عرض فقط للحسابات، تحكم كامل بالقيود)
        'accounts.view',
        'safe_boxes.view', 'safe_boxes.create', 'safe_boxes.edit', 'safe_boxes.delete',
        'journal.view', 'journal.create', 'journal.edit', 'journal.post',
        'vouchers.view', 'vouchers.create', 'vouchers.edit',

        # تسويات فروقات الموردين — المدير وحده يملك عتبة الاعتماد الإداري
        'supplier_settlement_adjustments.view',
        'supplier_settlement_adjustments.create',
        'supplier_settlement_adjustments.approve',
        'supplier_settlement_adjustments.approve_other',
        'supplier_settlement_adjustments.post',
        'supplier_settlement_adjustments.reverse',
        'supplier_settlement_adjustments.cancel',
        
        # التقارير
        'reports.financial', 'reports.inventory', 'reports.sales', 'reports.purchases',
        'reports.customers', 'reports.employees', 'reports.gold_position',
        
        # الطباعة
        'print.invoices', 'print.reports', 'print.statements',
    ],
    
    # 3. المحاسب - العمليات المالية والتقارير
    'accountant': [
        # الفواتير (تحكم كامل)
        'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.delete',
        
        # العملاء والموردين (عرض وإضافة فقط)
        'customers.view', 'customers.create',
        'suppliers.view', 'suppliers.create',
        
        # المخزون (عرض وجرد)
        'items.view',
        'gold_price.view',
        'inventory.view', 'inventory.count',

        # المحاسبة (تحكم كامل)
        'accounts.view', 'accounts.create', 'accounts.edit',
        'safe_boxes.view',
        'journal.view', 'journal.create', 'journal.edit', 'journal.post',
        'vouchers.view', 'vouchers.create', 'vouchers.edit',

        # تسويات فروقات الموردين — بلا approve_other: السبب «أخرى» يستلزم مديراً
        'supplier_settlement_adjustments.view',
        'supplier_settlement_adjustments.create',
        'supplier_settlement_adjustments.approve',
        'supplier_settlement_adjustments.post',
        'supplier_settlement_adjustments.reverse',
        'supplier_settlement_adjustments.cancel',
        
        # التقارير المالية
        'reports.financial', 'reports.sales', 'reports.purchases',
        'reports.customers', 'reports.gold_position',
        
        # الطباعة
        'print.invoices', 'print.reports', 'print.statements',
    ],
    
    # 4. الموظف - العمليات اليومية البسيطة
    'employee': [
        # الفواتير (إنشاء وعرض فواتيره فقط)
        'invoices.view', 'invoices.create',
        
        # العملاء والموردين (عرض وإضافة)
        'customers.view', 'customers.create',
        'suppliers.view',
        
        # المخزون (عرض فقط)
        'items.view',
        'gold_price.view',
        'inventory.view',

        # الخزائن (للاختيار داخل الفواتير)
        'safe_boxes.view',

        # القيود اليومية (عرض فقط)
        'journal.view',

        # الطباعة (الفواتير فقط)
        'print.invoices',
    ],
}


# ==========================================
# دوال مساعدة
# ==========================================

def get_role_permissions(role: str) -> list:
    """احصل على قائمة الصلاحيات لدور معين"""
    return ROLE_PERMISSIONS.get(role, [])


def has_permission(user_role: str, user_permissions: dict, permission_code: str) -> bool:
    """
    تحقق من وجود صلاحية معينة للمستخدم
    
    Args:
        user_role: دور المستخدم
        user_permissions: صلاحيات المستخدم المخصصة (JSON)
        permission_code: كود الصلاحية المطلوب التحقق منها
    
    Returns:
        True إذا كان المستخدم لديه الصلاحية
    """
    # مسؤول النظام لديه كل الصلاحيات
    if user_role == 'system_admin':
        return True
    
    # التحقق من الصلاحيات المخصصة أولاً
    if user_permissions:
        if isinstance(user_permissions, dict):
            # إذا كانت الصلاحية موجودة صراحةً، استخدم قيمتها
            if permission_code in user_permissions:
                return bool(user_permissions[permission_code])
        elif isinstance(user_permissions, list):
            if permission_code in user_permissions:
                return True
    
    # الصلاحيات الافتراضية حسب الدور
    default_permissions = get_role_permissions(user_role)
    return permission_code in default_permissions


def get_permissions_by_category():
    """احصل على الصلاحيات مصنفة حسب الوحدات"""
    return {
        'النظام والمستخدمين': SYSTEM_PERMISSIONS,
        'الموظفين': EMPLOYEE_PERMISSIONS,
        'الفواتير': INVOICE_PERMISSIONS,
        'العملاء والموردين': CUSTOMER_PERMISSIONS,
        'المخزون': INVENTORY_PERMISSIONS,
        'المحاسبة': ACCOUNTING_PERMISSIONS,
        'التقارير': REPORTS_PERMISSIONS,
        'الطباعة': PRINT_PERMISSIONS,
    }


def validate_role(role: str) -> bool:
    """تحقق من صحة الدور"""
    return role in ROLES
