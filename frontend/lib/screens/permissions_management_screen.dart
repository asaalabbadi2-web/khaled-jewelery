import 'package:flutter/material.dart';
import '../api_service.dart';
import '../models/permissions_model.dart';
import '../models/app_user_model.dart';

/// شاشة إدارة الصلاحيات والأدوار
class PermissionsManagementScreen extends StatefulWidget {
  final AppUserModel user;

  const PermissionsManagementScreen({super.key, required this.user});

  @override
  State<PermissionsManagementScreen> createState() =>
      _PermissionsManagementScreenState();
}

class _PermissionsManagementScreenState
    extends State<PermissionsManagementScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _api = ApiService();

  bool _isLoading = true;
  String? _errorMessage;

  // بيانات الأدوار
  List<Role> _roles = [];
  String? _selectedRole;

  // بيانات الصلاحيات
  List<PermissionCategory> _categories = [];
  List<UserPermission> _userPermissions = [];
  final Map<String, bool> _permissionChanges = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _selectedRole = widget.user.role;
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // تحميل الأدوار
      final rolesData = await _api.getPermissionRoles();
      _roles = rolesData.map((r) => Role.fromJson(r)).toList();

      // تحميل صلاحيات المستخدم
      final userPermsData = await _api.getUserPermissions(widget.user.id!);
      _userPermissions = (userPermsData['permissions'] as List<dynamic>)
          .map((p) => UserPermission.fromJson(p))
          .toList();

      // تحميل جميع الصلاحيات
      final categoriesData = await _api.getAllPermissions();
      _categories = categoriesData
          .map((c) => PermissionCategory.fromJson(c))
          .toList();

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _saveChanges() async {
    if (_permissionChanges.isEmpty && _selectedRole == widget.user.role) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('لا توجد تغييرات لحفظها')));
      return;
    }

    setState(() => _isLoading = true);

    try {
      // تحديث الدور إذا تغير
      if (_selectedRole != widget.user.role) {
        await _api.updateUserRole(
          widget.user.id!,
          _selectedRole!,
          resetPermissions: false,
        );
      }

      // تحديث الصلاحيات المخصصة
      if (_permissionChanges.isNotEmpty) {
        await _api.updateUserPermissions(widget.user.id!, {
          'permissions': _permissionChanges,
        });
      }

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✓ تم تحديث الصلاحيات بنجاح'),
          backgroundColor: Colors.green,
        ),
      );

      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;

      setState(() => _isLoading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطأ: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('صلاحيات: ${widget.user.username}'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'الدور', icon: Icon(Icons.person_outline)),
            Tab(text: 'الصلاحيات التفصيلية', icon: Icon(Icons.security)),
          ],
        ),
        actions: [
          if (!_isLoading)
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _saveChanges,
              tooltip: 'حفظ التغييرات',
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 16),
                  Text(
                    (_errorMessage ?? '').replaceFirst('Exception: ', ''),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _loadData,
                    child: const Text('إعادة المحاولة'),
                  ),
                ],
              ),
            )
          : TabBarView(
              controller: _tabController,
              children: [_buildRoleTab(), _buildPermissionsTab()],
            ),
    );
  }

  Widget _buildRoleTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'اختر دور المستخدم:',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                RadioGroup<String>(
                  groupValue: _selectedRole,
                  onChanged: (value) {
                    setState(() {
                      _selectedRole = value;
                    });
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: _roles
                        .map(
                          (role) => ListTile(
                            leading: Radio<String>(value: role.code),
                            title: Text(role.name),
                            subtitle: Text(
                              '${role.permissionsCount} صلاحية افتراضية',
                            ),
                            onTap: () {
                              setState(() {
                                _selectedRole = role.code;
                              });
                            },
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          color: Colors.blue.shade50,
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue),
                    SizedBox(width: 8),
                    Text(
                      'معلومات الأدوار:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                Text('• مسؤول نظام: صلاحيات كاملة على النظام'),
                Text('• مدير: الإشراف والاعتماد والإلغاء وفك الترحيل والبيانات الأساسية'),
                Text('• محاسب: السندات والقيود والنسب والتسويات ومشتريات الموردين والتقارير المالية'),
                Text('• أمين مخزون: تحويل الخزائن وتصحيح العيار والجرد والأصناف'),
                Text('• بائع: البيع وشراء الكسر والتحصيل على فواتيره'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPermissionsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: Colors.orange.shade50,
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(Icons.warning_amber, color: Colors.orange),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'الصلاحيات المخصصة تتجاوز الصلاحيات الافتراضية للدور',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        ..._categories.map((category) {
          return Card(
            margin: const EdgeInsets.only(bottom: 16),
            child: ExpansionTile(
              title: Text(
                category.category,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              children: category.permissions.map((perm) {
                final userPerm = _userPermissions.firstWhere(
                  (up) => up.code == perm.code,
                  orElse: () => UserPermission(
                    code: perm.code,
                    name: perm.name,
                    hasPermission: false,
                    isDefault: false,
                    isCustom: false,
                  ),
                );

                final bool currentValue =
                    _permissionChanges.containsKey(perm.code)
                    ? _permissionChanges[perm.code]!
                    : userPerm.hasPermission;

                return CheckboxListTile(
                  value: currentValue,
                  onChanged: (bool? value) {
                    setState(() {
                      if (value != null) {
                        _permissionChanges[perm.code] = value;
                      }
                    });
                  },
                  title: Text(perm.name),
                  subtitle: userPerm.isDefault
                      ? const Text(
                          'صلاحية افتراضية',
                          style: TextStyle(fontSize: 11, color: Colors.green),
                        )
                      : userPerm.isCustom
                      ? const Text(
                          'صلاحية مخصصة',
                          style: TextStyle(fontSize: 11, color: Colors.blue),
                        )
                      : null,
                  secondary: Icon(
                    userPerm.isDefault ? Icons.check_circle : Icons.security,
                    color: userPerm.isDefault ? Colors.green : Colors.grey,
                  ),
                );
              }).toList(),
            ),
          );
        }),
      ],
    );
  }
}
