"""
نظام الصلاحيات المتكامل لنظام مجوهرات خالد
يحدد الصلاحيات التفصيلية لكل دور (مسؤول نظام، مدير، محاسب، أمين مخزون، بائع) — ADR-036
"""

# ==========================================
# الأدوار الخمسة
# ==========================================

ROLES = {
    'system_admin': 'مسؤول نظام',
    'manager': 'مدير',
    'accountant': 'محاسب',
    'storekeeper': 'أمين مخزون',
    'employee': 'بائع',
}

# ==========================================
# الكتالوج: كل رمز يطلبه مسار موجود هنا (ADR-036، tests/test_permission_catalog.py)
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
    'business.setup': 'إعداد وسائل الدفع والفروع والمكاتب وربط الحسابات',
    'audit.view': 'عرض سجل التدقيق ونتائج الفحص',
}

# 2. إدارة الموظفين
EMPLOYEE_PERMISSIONS = {
    'employees.view': 'عرض الموظفين',
    'employees.create': 'إضافة موظفين',
    'employees.edit': 'تعديل بيانات الموظفين',
    'employees.delete': 'حذف موظفين',
    'employees.payroll': 'إدارة الرواتب',
    'employees.bonuses': 'إدارة الحوافز والأهداف',
    'bonus.calculate': 'حساب الحوافز',
    'bonus.approve': 'اعتماد الحوافز',
    'bonus.pay': 'دفع الحوافز',
    'bonus_rule.view': 'عرض قواعد الحوافز',
    'bonus_rule.create': 'إضافة قواعد الحوافز',
    'bonus_rule.update': 'تعديل قواعد الحوافز',
    'bonus_rule.delete': 'حذف قواعد الحوافز',
}

# 3. الفواتير والمعاملات
INVOICE_PERMISSIONS = {
    'invoices.view': 'عرض الفواتير',
    'invoices.create': 'إنشاء فواتير',
    'invoices.edit': 'تعديل الفواتير غير المرحّلة ورفضها',
    'invoices.delete': 'حذف الفواتير غير المرحّلة',
    'invoices.edit_others': 'تعديل فواتير الآخرين',
    'invoices.delete_others': 'حذف فواتير الآخرين',
    'invoices.approve': 'اعتماد الفواتير وترحيلها',
    'invoices.cancel': 'إلغاء فواتير معتمدة',
    'invoices.unpost': 'فك ترحيل الفواتير',
    'invoices.supplier': 'فواتير الموردين: الشراء ومرتجعه',
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
    'costing.recompute': 'إعادة حساب تكلفة الذهب',
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
    'safe_boxes.transfer': 'تحويل بين الخزائن وتصحيح العيار وإعادة الصهر',

    'journal.view': 'عرض القيود',
    'journal.create': 'إنشاء قيود',
    'journal.edit': 'تعديل القيود',
    'journal.delete': 'حذف قيود',
    'journal.post': 'ترحيل القيود',
    'journal.unpost': 'فك ترحيل القيود',
    'vouchers.view': 'عرض السندات',
    'vouchers.create': 'إنشاء سندات',
    'vouchers.edit': 'تعديل السندات',
    'vouchers.approve': 'اعتماد السندات ورفضها',
    'vouchers.delete': 'حذف سندات',
    'vouchers.cancel': 'إلغاء سندات',
    'vouchers.attribute': 'نسب ذهب السند ونقده إلى فاتورة',

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
# صلاحيات كل دور — مصفوفة المالك (2 أكتوبر 2026، ADR-036)
# سياسة لا قانون: تُعدَّل بقرار، والاختبار يثبّت القرار المعتمد.
# ==========================================

ROLE_PERMISSIONS = {
    # 1. مسؤول النظام (المالك) — كل شيء، ووحده: الإعداد والمستخدمون والنسخ الاحتياطي
    'system_admin': list(ALL_PERMISSIONS.keys()),

    # 2. المدير — الإشراف والاعتماد: الموافقات والإلغاء وفك الترحيل والبيانات الأساسية
    'manager': [
        'audit.view',
        'employees.view', 'employees.create', 'employees.edit', 'employees.delete',
        'employees.payroll', 'employees.bonuses',
        'bonus.calculate', 'bonus.approve', 'bonus.pay',
        'bonus_rule.view', 'bonus_rule.create', 'bonus_rule.update', 'bonus_rule.delete',
        'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.delete',
        'invoices.edit_others', 'invoices.delete_others', 'invoices.approve', 'invoices.cancel',
        'invoices.unpost', 'invoices.supplier',
        'customers.view', 'customers.create', 'customers.edit', 'customers.delete',
        'suppliers.view', 'suppliers.create', 'suppliers.edit', 'suppliers.delete',
        'items.view', 'items.create', 'items.edit', 'items.delete', 'items.adjust',
        'gold_price.view', 'gold_price.update', 'costing.recompute',
        'inventory.view', 'inventory.count', 'inventory.approve',
        'accounts.view',
        'safe_boxes.view', 'safe_boxes.create', 'safe_boxes.edit', 'safe_boxes.delete',
        'safe_boxes.transfer',
        'journal.view', 'journal.create', 'journal.edit', 'journal.post', 'journal.unpost',
        'vouchers.view', 'vouchers.create', 'vouchers.edit', 'vouchers.approve',
        'vouchers.delete', 'vouchers.cancel', 'vouchers.attribute',
        'supplier_settlement_adjustments.view',
        'supplier_settlement_adjustments.create',
        'supplier_settlement_adjustments.approve',
        'supplier_settlement_adjustments.approve_other',
        'supplier_settlement_adjustments.post',
        'supplier_settlement_adjustments.reverse',
        'supplier_settlement_adjustments.cancel',
        'reports.financial', 'reports.inventory', 'reports.sales', 'reports.purchases',
        'reports.customers', 'reports.employees', 'reports.gold_position',
        'print.invoices', 'print.reports', 'print.statements',
    ],

    # 3. المحاسب — الدفاتر: السندات والقيود والنسب والتسويات ومشتريات الموردين
    'accountant': [
        'business.setup',
        'audit.view',
        'employees.view', 'employees.payroll',
        'bonus.calculate', 'bonus.pay', 'bonus_rule.view',
        'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.delete',
        'invoices.edit_others', 'invoices.delete_others', 'invoices.supplier',
        'customers.view', 'customers.create', 'customers.edit',
        'suppliers.view', 'suppliers.create', 'suppliers.edit',
        'items.view',
        'gold_price.view', 'costing.recompute',
        'inventory.view',
        'accounts.view', 'accounts.create', 'accounts.edit',
        'safe_boxes.view', 'safe_boxes.transfer',
        'journal.view', 'journal.create', 'journal.edit', 'journal.post',
        'vouchers.view', 'vouchers.create', 'vouchers.edit', 'vouchers.attribute',
        # تسويات فروقات الموردين — بلا approve_other: السبب «أخرى» يستلزم مديراً
        'supplier_settlement_adjustments.view',
        'supplier_settlement_adjustments.create',
        'supplier_settlement_adjustments.approve',
        'supplier_settlement_adjustments.post',
        'supplier_settlement_adjustments.reverse',
        'supplier_settlement_adjustments.cancel',
        'reports.financial', 'reports.inventory', 'reports.sales', 'reports.purchases',
        'reports.customers', 'reports.gold_position',
        'print.invoices', 'print.reports', 'print.statements',
    ],

    # 4. أمين المخزون — الذهب الفعلي: تحويل الخزائن وتصحيح العيار والجرد والأصناف
    'storekeeper': [
        'items.view', 'items.create', 'items.edit',
        'gold_price.view',
        'inventory.view', 'inventory.count',
        'safe_boxes.view', 'safe_boxes.transfer',
        'reports.inventory',
        'print.reports',
    ],

    # 5. البائع — نقطة البيع: البيع وشراء الكسر والتحصيل على فواتيره هو
    'employee': [
        'invoices.view', 'invoices.create', 'invoices.edit',   # edit: his own only (invoices.edit_others)
        'customers.view', 'customers.create',
        'suppliers.view',
        'items.view',
        'gold_price.view',
        'inventory.view',
        'safe_boxes.view',
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


def effective_permissions(role: str, overrides) -> list:
    """What the user may do: the role's grants, with the user's overrides on top.

    The one answer the server checks and the app is sent (ADR-036) -- the app
    read the overrides alone and hid from a role what the server allowed it.
    """
    if role == 'system_admin':
        return sorted(ALL_PERMISSIONS)
    held = set(get_role_permissions(role))
    if isinstance(overrides, dict):
        for code, granted in overrides.items():
            (held.add if granted else held.discard)(code)
    elif isinstance(overrides, list):
        held.update(overrides)
    return sorted(held)


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
