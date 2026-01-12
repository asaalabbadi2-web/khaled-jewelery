/// نموذج الأدوار والصلاحيات
class Role {
  final String code;
  final String name;
  final int permissionsCount;

  const Role({
    required this.code,
    required this.name,
    required this.permissionsCount,
  });

  factory Role.fromJson(Map<String, dynamic> json) {
    return Role(
      code: json['code'] as String,
      name: json['name'] as String,
      permissionsCount: json['permissions_count'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {'code': code, 'name': name, 'permissions_count': permissionsCount};
  }

  /// الأدوار المعرّفة
  static const String systemAdmin = 'system_admin';
  static const String manager = 'manager';
  static const String accountant = 'accountant';
  static const String employee = 'employee';

  /// تحويل من كود إلى اسم عربي
  static String getDisplayName(String code) {
    switch (code) {
      case systemAdmin:
        return 'مسؤول نظام';
      case manager:
        return 'مدير';
      case accountant:
        return 'محاسب';
      case employee:
        return 'موظف';
      default:
        return code;
    }
  }
}

/// نموذج الصلاحية
class Permission {
  final String code;
  final String name;

  const Permission({required this.code, required this.name});

  factory Permission.fromJson(Map<String, dynamic> json) {
    return Permission(
      code: json['code'] as String,
      name: json['name'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {'code': code, 'name': name};
  }
}

/// نموذج تصنيف الصلاحيات
class PermissionCategory {
  final String category;
  final List<Permission> permissions;

  const PermissionCategory({required this.category, required this.permissions});

  factory PermissionCategory.fromJson(Map<String, dynamic> json) {
    return PermissionCategory(
      category: json['category'] as String,
      permissions:
          (json['permissions'] as List<dynamic>?)
              ?.map((p) => Permission.fromJson(p as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'category': category,
      'permissions': permissions.map((p) => p.toJson()).toList(),
    };
  }
}

/// نموذج صلاحيات المستخدم المفصلة
class UserPermission {
  final String code;
  final String name;
  final bool hasPermission;
  final bool isDefault;
  final bool isCustom;

  const UserPermission({
    required this.code,
    required this.name,
    required this.hasPermission,
    required this.isDefault,
    required this.isCustom,
  });

  factory UserPermission.fromJson(Map<String, dynamic> json) {
    return UserPermission(
      code: json['code'] as String,
      name: json['name'] as String,
      hasPermission: json['has_permission'] as bool? ?? false,
      isDefault: json['is_default'] as bool? ?? false,
      isCustom: json['is_custom'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'code': code,
      'name': name,
      'has_permission': hasPermission,
      'is_default': isDefault,
      'is_custom': isCustom,
    };
  }
}

/// أكواد الصلاحيات المستخدمة في التطبيق
class PermissionCodes {
  // إدارة المستخدمين
  static const String usersView = 'users.view';
  static const String usersCreate = 'users.create';
  static const String usersEdit = 'users.edit';
  static const String usersDelete = 'users.delete';
  static const String usersChangePermissions = 'users.change_permissions';

  // إعدادات النظام
  static const String systemSettings = 'system.settings';
  static const String systemBackup = 'system.backup';
  static const String systemLogs = 'system.logs';

  // الموظفين
  static const String employeesView = 'employees.view';
  static const String employeesCreate = 'employees.create';
  static const String employeesEdit = 'employees.edit';
  static const String employeesDelete = 'employees.delete';
  static const String employeesPayroll = 'employees.payroll';
  static const String employeesBonuses = 'employees.bonuses';

  // الفواتير
  static const String invoicesView = 'invoices.view';
  static const String invoicesCreate = 'invoices.create';
  static const String invoicesEdit = 'invoices.edit';
  static const String invoicesDelete = 'invoices.delete';
  static const String invoicesEditOthers = 'invoices.edit_others';
  static const String invoicesDeleteOthers = 'invoices.delete_others';
  static const String invoicesApprove = 'invoices.approve';
  static const String invoicesCancel = 'invoices.cancel';

  // العملاء والموردين
  static const String customersView = 'customers.view';
  static const String customersCreate = 'customers.create';
  static const String customersEdit = 'customers.edit';
  static const String customersDelete = 'customers.delete';
  static const String suppliersView = 'suppliers.view';
  static const String suppliersCreate = 'suppliers.create';
  static const String suppliersEdit = 'suppliers.edit';
  static const String suppliersDelete = 'suppliers.delete';

  // المخزون
  static const String itemsView = 'items.view';
  static const String itemsCreate = 'items.create';
  static const String itemsEdit = 'items.edit';
  static const String itemsDelete = 'items.delete';
  static const String itemsAdjust = 'items.adjust';
  static const String goldPriceView = 'gold_price.view';
  static const String goldPriceUpdate = 'gold_price.update';

  // المحاسبة
  static const String accountsView = 'accounts.view';
  static const String accountsCreate = 'accounts.create';
  static const String accountsEdit = 'accounts.edit';
  static const String accountsDelete = 'accounts.delete';
  static const String journalView = 'journal.view';
  static const String journalCreate = 'journal.create';
  static const String journalEdit = 'journal.edit';
  static const String journalDelete = 'journal.delete';
  static const String journalPost = 'journal.post';
  static const String vouchersView = 'vouchers.view';
  static const String vouchersCreate = 'vouchers.create';
  static const String vouchersEdit = 'vouchers.edit';
  static const String vouchersDelete = 'vouchers.delete';

  // التقارير
  static const String reportsFinancial = 'reports.financial';
  static const String reportsInventory = 'reports.inventory';
  static const String reportsSales = 'reports.sales';
  static const String reportsPurchases = 'reports.purchases';
  static const String reportsCustomers = 'reports.customers';
  static const String reportsEmployees = 'reports.employees';
  static const String reportsGoldPosition = 'reports.gold_position';

  // الطباعة
  static const String printInvoices = 'print.invoices';
  static const String printReports = 'print.reports';
  static const String printStatements = 'print.statements';
}
