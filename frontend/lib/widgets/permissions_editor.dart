import 'package:flutter/material.dart';

/// محرر صلاحيات متقدم للمستخدمين
class PermissionsEditor extends StatefulWidget {
  final Map<String, dynamic>? initialPermissions;
  final bool isArabic;
  final Function(Map<String, dynamic>) onPermissionsChanged;

  const PermissionsEditor({
    super.key,
    this.initialPermissions,
    this.isArabic = true,
    required this.onPermissionsChanged,
  });

  @override
  State<PermissionsEditor> createState() => _PermissionsEditorState();
}

class _PermissionsEditorState extends State<PermissionsEditor> {
  late Map<String, dynamic> _permissions;

  // تعريف الصلاحيات المتاحة
  static const Map<String, Map<String, String>> permissionsDefinitions = {
    'invoices': {'ar': 'الفواتير', 'en': 'Invoices'},
    'invoices_read': {'ar': 'قراءة الفواتير', 'en': 'Read Invoices'},
    'invoices_create': {'ar': 'إنشاء فواتير', 'en': 'Create Invoices'},
    'invoices_edit': {'ar': 'تعديل الفواتير', 'en': 'Edit Invoices'},
    'invoices_delete': {'ar': 'حذف الفواتير', 'en': 'Delete Invoices'},
    'items': {'ar': 'المخزون', 'en': 'Inventory'},
    'items_read': {'ar': 'قراءة الأصناف', 'en': 'Read Items'},
    'items_create': {'ar': 'إضافة أصناف', 'en': 'Add Items'},
    'items_edit': {'ar': 'تعديل الأصناف', 'en': 'Edit Items'},
    'items_delete': {'ar': 'حذف الأصناف', 'en': 'Delete Items'},
    'customers': {'ar': 'العملاء والموردين', 'en': 'Customers & Suppliers'},
    'customers_read': {'ar': 'قراءة العملاء', 'en': 'Read Customers'},
    'customers_create': {'ar': 'إضافة عملاء', 'en': 'Add Customers'},
    'customers_edit': {'ar': 'تعديل العملاء', 'en': 'Edit Customers'},
    'customers_delete': {'ar': 'حذف العملاء', 'en': 'Delete Customers'},
    'accounting': {'ar': 'المحاسبة', 'en': 'Accounting'},
    'accounting_read': {
      'ar': 'قراءة السجلات المحاسبية',
      'en': 'Read Accounting',
    },
    'accounting_create': {'ar': 'إنشاء قيود', 'en': 'Create Entries'},
    'accounting_edit': {'ar': 'تعديل القيود', 'en': 'Edit Entries'},
    'accounting_delete': {'ar': 'حذف القيود', 'en': 'Delete Entries'},
    'reports': {'ar': 'التقارير', 'en': 'Reports'},
    'reports_financial': {'ar': 'التقارير المالية', 'en': 'Financial Reports'},
    'reports_sales': {'ar': 'تقارير المبيعات', 'en': 'Sales Reports'},
    'reports_inventory': {'ar': 'تقارير المخزون', 'en': 'Inventory Reports'},
    'hr': {'ar': 'الموارد البشرية', 'en': 'Human Resources'},
    'hr_employees': {'ar': 'إدارة الموظفين', 'en': 'Manage Employees'},
    'hr_payroll': {'ar': 'إدارة الرواتب', 'en': 'Manage Payroll'},
    'hr_attendance': {'ar': 'إدارة الحضور', 'en': 'Manage Attendance'},
    'settings': {'ar': 'الإعدادات', 'en': 'Settings'},
    'settings_system': {'ar': 'إعدادات النظام', 'en': 'System Settings'},
    'settings_users': {'ar': 'إدارة المستخدمين', 'en': 'Manage Users'},
    'settings_gold_price': {'ar': 'تحديث سعر الذهب', 'en': 'Update Gold Price'},
  };

  // تنظيم الصلاحيات في مجموعات
  static const Map<String, List<String>> permissionGroups = {
    'invoices': [
      'invoices_read',
      'invoices_create',
      'invoices_edit',
      'invoices_delete',
    ],
    'items': ['items_read', 'items_create', 'items_edit', 'items_delete'],
    'customers': [
      'customers_read',
      'customers_create',
      'customers_edit',
      'customers_delete',
    ],
    'accounting': [
      'accounting_read',
      'accounting_create',
      'accounting_edit',
      'accounting_delete',
    ],
    'reports': ['reports_financial', 'reports_sales', 'reports_inventory'],
    'hr': ['hr_employees', 'hr_payroll', 'hr_attendance'],
    'settings': ['settings_system', 'settings_users', 'settings_gold_price'],
  };

  @override
  void initState() {
    super.initState();
    _permissions = Map<String, dynamic>.from(widget.initialPermissions ?? {});
  }

  String _getLabel(String key) {
    final lang = widget.isArabic ? 'ar' : 'en';
    return permissionsDefinitions[key]?[lang] ?? key;
  }

  bool _isAllSelected() {
    final allPerms = permissionGroups.values.expand((v) => v).toSet();
    if (allPerms.isEmpty) return false;
    return allPerms.every((p) => _permissions[p] == true);
  }

  void _toggleAll(bool value) {
    setState(() {
      final allPerms = permissionGroups.values.expand((v) => v).toSet();
      if (value) {
        for (final p in allPerms) {
          _permissions[p] = true;
        }
      } else {
        for (final p in allPerms) {
          _permissions.remove(p);
        }
      }
    });
    widget.onPermissionsChanged(_permissions);
  }

  void _togglePermission(String key, bool? value) {
    setState(() {
      if (value == true) {
        _permissions[key] = true;
      } else {
        _permissions.remove(key);
      }
    });
    widget.onPermissionsChanged(_permissions);
  }

  void _toggleGroup(String groupKey, bool value) {
    setState(() {
      final permissions = permissionGroups[groupKey] ?? [];
      for (final permission in permissions) {
        if (value) {
          _permissions[permission] = true;
        } else {
          _permissions.remove(permission);
        }
      }
    });
    widget.onPermissionsChanged(_permissions);
  }

  bool _isGroupFullySelected(String groupKey) {
    final permissions = permissionGroups[groupKey] ?? [];
    if (permissions.isEmpty) return false;
    return permissions.every((p) => _permissions[p] == true);
  }

  bool _isGroupPartiallySelected(String groupKey) {
    final permissions = permissionGroups[groupKey] ?? [];
    if (permissions.isEmpty) return false;
    final selectedCount = permissions
        .where((p) => _permissions[p] == true)
        .length;
    return selectedCount > 0 && selectedCount < permissions.length;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.security, color: colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.isArabic ? 'صلاحيات النظام' : 'System Permissions',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                // Select All checkbox
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.isArabic ? 'تحديد الكل' : 'Select All',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(width: 6),
                    Checkbox(
                      value: _isAllSelected(),
                      onChanged: (v) => _toggleAll(v ?? false),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: permissionGroups.entries.map((group) {
                  final isFullySelected = _isGroupFullySelected(group.key);
                  final isPartiallySelected = _isGroupPartiallySelected(
                    group.key,
                  );

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ExpansionTile(
                      leading: Checkbox(
                        value: isFullySelected,
                        tristate: true,
                        onChanged: (value) {
                          _toggleGroup(group.key, value ?? false);
                        },
                      ),
                      title: Text(
                        _getLabel(group.key),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: isPartiallySelected
                          ? Text(
                              widget.isArabic
                                  ? 'محدد جزئياً'
                                  : 'Partially selected',
                              style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.primary,
                              ),
                            )
                          : null,
                      children: group.value.map((permission) {
                        return CheckboxListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.only(
                            left: 48,
                            right: 16,
                          ),
                          title: Text(
                            _getLabel(permission),
                            style: theme.textTheme.bodyMedium,
                          ),
                          value: _permissions[permission] == true,
                          onChanged: (value) =>
                              _togglePermission(permission, value),
                        );
                      }).toList(),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
