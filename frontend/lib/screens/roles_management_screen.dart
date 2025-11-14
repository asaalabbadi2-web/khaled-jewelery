import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api_service.dart';

/// شاشة إدارة الأدوار (مع JWT)
class RolesManagementScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const RolesManagementScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<RolesManagementScreen> createState() => _RolesManagementScreenState();
}

class _RolesManagementScreenState extends State<RolesManagementScreen> {
  List<Map<String, dynamic>> _roles = [];
  List<Map<String, dynamic>> _permissions = [];
  bool _loading = false;
  String? _token;

  @override
  void initState() {
    super.initState();
    _loadToken();
  }

  Future<void> _loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('auth_token');
    if (_token != null) {
      _loadRoles();
      _loadPermissions();
    } else {
      _showSnack('الرجاء تسجيل الدخول أولاً', isError: true);
    }
  }

  Future<void> _loadRoles() async {
    if (_token == null) return;

    setState(() => _loading = true);
    try {
      final response = await widget.api.getRoles(_token!, includeUsers: true);
      if (response['success'] == true) {
        setState(() {
          _roles = List<Map<String, dynamic>>.from(response['roles'] ?? []);
        });
      }
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadPermissions() async {
    if (_token == null) return;

    try {
      final response = await widget.api.getPermissions(_token!);
      if (response['success'] == true) {
        setState(() {
          _permissions = List<Map<String, dynamic>>.from(
            response['permissions'] ?? [],
          );
        });
      }
    } catch (e) {
      debugPrint('Error loading permissions: $e');
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : const Color(0xFFFFD700),
      ),
    );
  }

  Widget _buildStatisticsRow(ThemeData theme) {
    if (_roles.isEmpty) {
      return const SizedBox.shrink();
    }

    final total = _roles.length;
    final systemRoles = _roles.where((r) => r['is_system'] == true).length;
    final customRoles = total - systemRoles;

    Widget buildCard(
      String titleAr,
      String titleEn,
      int value,
      IconData icon,
      Color color,
    ) {
      return Expanded(
        child: Card(
          elevation: 2,
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: color.withValues(alpha: 0.15),
                  child: Icon(icon, color: color, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.isArabic ? titleAr : titleEn,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$value',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          buildCard(
            'إجمالي الأدوار',
            'Total Roles',
            total,
            Icons.group_work_outlined,
            const Color(0xFFFFD700),
          ),
          buildCard(
            'أدوار النظام',
            'System Roles',
            systemRoles,
            Icons.settings_outlined,
            Colors.blue.shade700,
          ),
          buildCard(
            'أدوار مخصصة',
            'Custom Roles',
            customRoles,
            Icons.tune_outlined,
            Colors.green.shade700,
          ),
        ],
      ),
    );
  }

  Widget _buildRoleCard(Map<String, dynamic> role, ThemeData theme) {
    final name = role['name'] ?? '';
    final nameAr = role['name_ar'] ?? name;
    final description = role['description'] ?? '';
    final isSystem = role['is_system'] == true;
    final permissions = role['permissions'] as List<dynamic>? ?? [];
    final users = role['users'] as List<dynamic>? ?? [];

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      elevation: 2,
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: isSystem
              ? Colors.blue.shade100
              : const Color(0xFFFFD700).withValues(alpha: 0.3),
          child: Icon(
            isSystem ? Icons.shield_outlined : Icons.person_pin_outlined,
            color: isSystem ? Colors.blue.shade700 : const Color(0xFFB8860B),
          ),
        ),
        title: Text(
          widget.isArabic ? nameAr : name,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.vpn_key_outlined, size: 16, color: Colors.grey[600]),
                const SizedBox(width: 4),
                Text(
                  '${permissions.length} ${widget.isArabic ? 'صلاحية' : 'permissions'}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 16),
                Icon(Icons.people_outline, size: 16, color: Colors.grey[600]),
                const SizedBox(width: 4),
                Text(
                  '${users.length} ${widget.isArabic ? 'مستخدم' : 'users'}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
        trailing: isSystem
            ? Chip(
                label: Text(
                  widget.isArabic ? 'نظام' : 'System',
                  style: const TextStyle(fontSize: 11),
                ),
                backgroundColor: Colors.blue.shade50,
                padding: EdgeInsets.zero,
              )
            : PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  switch (value) {
                    case 'edit':
                      _showRoleDialog(role: role);
                      break;
                    case 'permissions':
                      _showPermissionsDialog(role);
                      break;
                    case 'delete':
                      _deleteRole(role);
                      break;
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        const Icon(Icons.edit_outlined, size: 20),
                        const SizedBox(width: 12),
                        Text(widget.isArabic ? 'تعديل' : 'Edit'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'permissions',
                    child: Row(
                      children: [
                        const Icon(Icons.vpn_key_outlined, size: 20),
                        const SizedBox(width: 12),
                        Text(widget.isArabic ? 'إدارة الصلاحيات' : 'Permissions'),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        const Icon(Icons.delete_outline,
                            color: Colors.red, size: 20),
                        const SizedBox(width: 12),
                        Text(
                          widget.isArabic ? 'حذف' : 'Delete',
                          style: const TextStyle(color: Colors.red),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
        children: [
          if (permissions.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.isArabic ? 'الصلاحيات:' : 'Permissions:',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: permissions.map((perm) {
                      final permName = widget.isArabic
                          ? (perm['name_ar'] ?? perm['code'])
                          : perm['code'];
                      return Chip(
                        label: Text(
                          permName,
                          style: const TextStyle(fontSize: 11),
                        ),
                        backgroundColor:
                            const Color(0xFFFFD700).withValues(alpha: 0.15),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _deleteRole(Map<String, dynamic> role) async {
    if (_token == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.isArabic ? 'حذف دور' : 'Delete Role'),
        content: Text(
          widget.isArabic
              ? 'هل تريد حذف الدور "${role['name_ar'] ?? role['name']}"؟'
              : 'Delete role "${role['name']}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(widget.isArabic ? 'حذف' : 'Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final response = await widget.api.deleteRole(_token!, role['id']);

      if (response['success'] == true) {
        _showSnack(response['message'] ?? 'تم حذف الدور');
        _loadRoles();
      }
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  Future<void> _showRoleDialog({Map<String, dynamic>? role}) async {
    final isEdit = role != null;
    final nameController = TextEditingController(text: role?['name']);
    final nameArController = TextEditingController(text: role?['name_ar']);
    final descriptionController =
        TextEditingController(text: role?['description']);

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          isEdit
              ? (widget.isArabic ? 'تعديل دور' : 'Edit Role')
              : (widget.isArabic ? 'إضافة دور' : 'Add Role'),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: widget.isArabic ? 'الاسم (English)' : 'Name (English)',
                  prefixIcon: const Icon(Icons.label_outline),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameArController,
                decoration: InputDecoration(
                  labelText: widget.isArabic ? 'الاسم (العربي)' : 'Name (Arabic)',
                  prefixIcon: const Icon(Icons.label_outline),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: descriptionController,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: widget.isArabic ? 'الوصف' : 'Description',
                  prefixIcon: const Icon(Icons.description_outlined),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameController.text.trim();
              final nameAr = nameArController.text.trim();

              if (name.isEmpty) {
                _showSnack(
                  widget.isArabic
                      ? 'الاسم الإنجليزي مطلوب'
                      : 'English name is required',
                  isError: true,
                );
                return;
              }

              try {
                if (isEdit) {
                  await widget.api.updateRole(
                    _token!,
                    role['id'],
                    {
                      'name': name,
                      'name_ar': nameAr,
                      'description': descriptionController.text.trim(),
                    },
                  );
                } else {
                  await widget.api.createRole(
                    _token!,
                    name,
                    nameAr,
                    descriptionController.text.trim(),
                    [],
                  );
                }

                Navigator.of(context).pop(true);
              } catch (e) {
                _showSnack(e.toString(), isError: true);
              }
            },
            child: Text(widget.isArabic ? 'حفظ' : 'Save'),
          ),
        ],
      ),
    );

    if (result == true) {
      _loadRoles();
    }
  }

  Future<void> _showPermissionsDialog(Map<String, dynamic> role) async {
    final rolePermissions = (role['permissions'] as List?)
            ?.map((p) => p['id'] as int)
            .toList() ??
        [];
    final selectedPermissions = Set<int>.from(rolePermissions);

    // Group permissions by category
    final Map<String, List<Map<String, dynamic>>> groupedPermissions = {};
    for (final perm in _permissions) {
      final category = perm['category'] ?? 'other';
      groupedPermissions.putIfAbsent(category, () => []).add(perm);
    }

    final result = await showDialog<Set<int>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(widget.isArabic ? 'إدارة الصلاحيات' : 'Manage Permissions'),
          content: SizedBox(
            width: double.maxFinite,
            child: _permissions.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    shrinkWrap: true,
                    children: groupedPermissions.entries.map((entry) {
                      final category = entry.key;
                      final perms = entry.value;

                      return ExpansionTile(
                        title: Text(
                          _getCategoryName(category),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        initiallyExpanded: true,
                        children: perms.map((perm) {
                          final permId = perm['id'] as int;
                          final permName = widget.isArabic
                              ? (perm['name_ar'] ?? perm['code'])
                              : perm['code'];

                          return CheckboxListTile(
                            title: Text(permName),
                            dense: true,
                            value: selectedPermissions.contains(permId),
                            onChanged: (checked) {
                              setState(() {
                                if (checked == true) {
                                  selectedPermissions.add(permId);
                                } else {
                                  selectedPermissions.remove(permId);
                                }
                              });
                            },
                          );
                        }).toList(),
                      );
                    }).toList(),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(selectedPermissions),
              child: Text(widget.isArabic ? 'حفظ' : 'Save'),
            ),
          ],
        ),
      ),
    );

    if (result == null || _token == null) return;

    try {
      // Update role with new permissions
      await widget.api.updateRole(_token!, role['id'], {
        'permission_ids': result.toList(),
      });

      _showSnack(widget.isArabic ? 'تم تحديث الصلاحيات' : 'Permissions updated');
      _loadRoles();
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  String _getCategoryName(String category) {
    if (!widget.isArabic) return category;

    switch (category) {
      case 'invoice':
        return 'الفواتير';
      case 'journal':
        return 'القيود';
      case 'user':
        return 'المستخدمين';
      case 'role':
        return 'الأدوار';
      case 'report':
        return 'التقارير';
      case 'settings':
        return 'الإعدادات';
      case 'audit':
        return 'سجل التدقيق';
      default:
        return category;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isArabic ? 'إدارة الأدوار' : 'Roles Management'),
        backgroundColor: const Color(0xFFFFD700),
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: widget.isArabic ? 'تحديث' : 'Refresh',
            onPressed: _loadRoles,
          ),
        ],
      ),
      body: Column(
        children: [
          // Statistics Row
          _buildStatisticsRow(theme),

          // Roles List
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _roles.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.group_work_outlined,
                              size: 80,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              widget.isArabic ? 'لا يوجد أدوار' : 'No roles found',
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadRoles,
                        child: ListView.builder(
                          itemCount: _roles.length,
                          itemBuilder: (context, index) {
                            return _buildRoleCard(_roles[index], theme);
                          },
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showRoleDialog(),
        backgroundColor: const Color(0xFFFFD700),
        foregroundColor: Colors.black87,
        icon: const Icon(Icons.add),
        label: Text(widget.isArabic ? 'إضافة دور' : 'Add Role'),
      ),
    );
  }
}
