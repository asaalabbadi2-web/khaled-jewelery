import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_service.dart';
import '../models/app_user_model.dart';
import '../models/employee_model.dart';
import '../widgets/permissions_editor.dart';
import '../providers/auth_provider.dart';
import 'package:provider/provider.dart';

class UsersScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  const UsersScreen({super.key, required this.api, this.isArabic = true});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<AppUserModel> _users = [];
  bool? _activeFilter;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadUsers();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    setState(() => _loading = true);
    try {
      final users = await widget.api.getUsers(
        search: _searchController.text.trim().isEmpty
            ? null
            : _searchController.text.trim(),
        isActive: _activeFilter,
      );
      setState(() => _users = users);
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _onSearchChanged() {
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) {
        _loadUsers();
      }
    });
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? Colors.red
            : Theme.of(context).colorScheme.primary,
      ),
    );
  }

  IconData _roleIcon(String role) {
    switch (role) {
      case 'admin':
        return Icons.workspace_premium_outlined;
      case 'manager':
        return Icons.manage_accounts_outlined;
      case 'staff':
      default:
        return Icons.person_outline;
    }
  }

  String _formatLastLogin(DateTime? value, bool isArabic) {
    if (value == null) {
      return isArabic ? 'لم يسجل الدخول بعد' : 'No login yet';
    }

    final formatter = DateFormat('yyyy/MM/dd | HH:mm');
    return formatter.format(value);
  }

  Widget _buildStatisticsRow(
    ThemeData theme,
    ColorScheme colorScheme,
    bool isArabic,
  ) {
    if (_users.isEmpty) {
      return const SizedBox.shrink();
    }

    final total = _users.length;
    final active = _users.where((user) => user.isActive).length;
    final admins = _users.where((user) => user.role == 'admin').length;

    Widget buildCard(
      String titleAr,
      String titleEn,
      int value,
      IconData icon,
      Color color,
    ) {
      return Expanded(
        child: Card(
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: color.withValues(alpha: 0.12),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        isArabic ? titleAr : titleEn,
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$value',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
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
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          buildCard(
            'إجمالي المستخدمين',
            'Total Users',
            total,
            Icons.people_alt_outlined,
            colorScheme.primary,
          ),
          buildCard(
            'الحسابات النشطة',
            'Active Accounts',
            active,
            Icons.verified_user_outlined,
            Colors.green.shade700,
          ),
          buildCard(
            'مدراء النظام',
            'Administrators',
            admins,
            Icons.security_outlined,
            Colors.deepPurple.shade600,
          ),
        ],
      ),
    );
  }

  Future<void> _toggleUser(AppUserModel user) async {
    try {
      final isActive = await widget.api.toggleUserActive(user.id ?? 0);
      setState(() {
        final index = _users.indexWhere((u) => u.id == user.id);
        if (index != -1) {
          _users[index] = user.copyWith(isActive: isActive);
        }
      });
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  Future<void> _deleteUser(AppUserModel user) async {
    final isAr = widget.isArabic;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isAr ? 'حذف مستخدم' : 'Delete User'),
        content: Text(
          isAr
              ? 'هل تريد حذف المستخدم ${user.username}؟'
              : 'Delete user ${user.username}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(isAr ? 'حذف' : 'Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await widget.api.deleteUser(user.id ?? 0);
      setState(() => _users.removeWhere((u) => u.id == user.id));
      _showSnack(widget.isArabic ? 'تم حذف المستخدم' : 'User deleted');
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  Future<void> _resetPassword(AppUserModel user) async {
    final isAr = widget.isArabic;
    final controller = TextEditingController();
    final newPassword = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isAr ? 'إعادة تعيين كلمة المرور' : 'Reset Password'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: isAr ? 'كلمة المرور الجديدة' : 'New Password',
          ),
          obscureText: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(isAr ? 'حفظ' : 'Save'),
          ),
        ],
      ),
    );

    if (newPassword == null || newPassword.isEmpty) return;

    try {
      await widget.api.resetUserPassword(user.id ?? 0, newPassword);
      _showSnack(isAr ? 'تم تحديث كلمة المرور' : 'Password updated');
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  Future<void> _openUserForm({AppUserModel? user}) async {
    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (context) =>
          UserFormDialog(isArabic: widget.isArabic, user: user),
    );

    if (result == null) return;

    try {
      if (user == null) {
        final created = await widget.api.createUser(result);
        setState(() => _users.insert(0, created));
        _showSnack(widget.isArabic ? 'تم إنشاء المستخدم' : 'User created');
      } else {
        final updated = await widget.api.updateUser(user.id ?? 0, result);
        setState(() {
          final index = _users.indexWhere((u) => u.id == user.id);
          if (index != -1) {
            _users[index] = updated;
          }
        });
        _showSnack(widget.isArabic ? 'تم تحديث المستخدم' : 'User updated');
      }
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'المستخدمون' : 'Users'),
        actions: [
          IconButton(onPressed: _loadUsers, icon: const Icon(Icons.refresh)),
          // show user avatar + username (constrained) to match home screen
          Consumer<AuthProvider>(
            builder: (context, auth, _) {
              final displayName = auth.username.isEmpty
                  ? (isAr ? 'حساب المستخدم' : 'Account')
                  : auth.username;
              return PopupMenuButton<String>(
                tooltip: displayName,
                offset: const Offset(0, 48),
                // keep the action height equal to the toolbar height to avoid growing the AppBar
                child: SizedBox(
                  height: kToolbarHeight,
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.15),
                          child: Icon(
                            Icons.person,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 120),
                          child: Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                    ),
                  ),
                ),
                itemBuilder: (context) => [
                  PopupMenuItem<String>(
                    value: 'info',
                    enabled: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          displayName,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isAr ? 'الدور:  ' : 'Role: \u00A0',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem<String>(
                    value: 'logout',
                    child: Text(isAr ? 'تسجيل خروج' : 'Logout'),
                  ),
                ],
              );
            },
          ),
          PopupMenuButton<bool?>(
            icon: const Icon(Icons.filter_alt),
            onSelected: (value) {
              setState(() => _activeFilter = value);
              _loadUsers();
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: null, child: Text(isAr ? 'الجميع' : 'All')),
              PopupMenuItem(value: true, child: Text(isAr ? 'نشط' : 'Active')),
              PopupMenuItem(
                value: false,
                child: Text(isAr ? 'موقوف' : 'Inactive'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openUserForm(),
        icon: const Icon(Icons.person_add_alt_1),
        label: Text(isAr ? 'مستخدم جديد' : 'New User'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                // Search field
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: isAr
                            ? 'بحث باسم المستخدم...'
                            : 'Search by username...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),
                // Statistics row
                if (_users.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _buildStatisticsRow(theme, colorScheme, isAr),
                  ),
                // Users list or empty state
                _users.isEmpty
                    ? SliverFillRemaining(
                        child: Center(
                          child: Text(
                            isAr ? 'لا يوجد مستخدمون' : 'No users found',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: colorScheme.primary,
                            ),
                          ),
                        ),
                      )
                    : SliverList(
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final user = _users[index];
                          final roleLabel = isAr
                              ? {
                                      'admin': 'مدير النظام',
                                      'manager': 'مشرف',
                                      'staff': 'موظف',
                                    }[user.role] ??
                                    'مستخدم'
                              : {
                                      'admin': 'Administrator',
                                      'manager': 'Manager',
                                      'staff': 'Staff',
                                    }[user.role] ??
                                    'User';
                          final lastLoginText = _formatLastLogin(
                            user.lastLoginAt,
                            isAr,
                          );
                          final statusColor = user.isActive
                              ? colorScheme.primary
                              : Colors.grey;
                          final statusLabel = user.isActive
                              ? (isAr ? 'نشط' : 'Active')
                              : (isAr ? 'موقوف' : 'Inactive');
                          return Card(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 6,
                            ),
                            child: ListTile(
                              leading: Stack(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: statusColor.withValues(alpha: 
                                      0.15,
                                    ),
                                    child: Icon(
                                      _roleIcon(user.role),
                                      color: statusColor,
                                    ),
                                  ),
                                  if (!user.isActive)
                                    Positioned(
                                      right: 0,
                                      bottom: 0,
                                      child: Container(
                                        decoration: const BoxDecoration(
                                          color: Colors.red,
                                          shape: BoxShape.circle,
                                        ),
                                        padding: const EdgeInsets.all(3),
                                        child: const Icon(
                                          Icons.block,
                                          size: 10,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              title: Text(
                                user.username,
                                style: theme.textTheme.titleMedium,
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${isAr ? 'الدور' : 'Role'}: $roleLabel',
                                  ),
                                  if (user.employee != null)
                                    Text(
                                      '${isAr ? 'الموظف' : 'Employee'}: ${user.employee!.name}',
                                    ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${isAr ? 'آخر تسجيل دخول' : 'Last Login'}: $lastLoginText',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  // status label placed next to the activation switch
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: statusColor.withValues(alpha: 0.16),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      statusLabel,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(color: statusColor),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Transform.scale(
                                    scale: 0.9,
                                    child: Switch(
                                      value: user.isActive,
                                      onChanged: (_) => _toggleUser(user),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  PopupMenuButton<String>(
                                    onSelected: (value) {
                                      if (value == 'edit') {
                                        _openUserForm(user: user);
                                      } else if (value == 'delete') {
                                        _deleteUser(user);
                                      } else if (value == 'reset') {
                                        _resetPassword(user);
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      PopupMenuItem(
                                        value: 'edit',
                                        child: Text(isAr ? 'تعديل' : 'Edit'),
                                      ),
                                      PopupMenuItem(
                                        value: 'reset',
                                        child: Text(
                                          isAr
                                              ? 'إعادة كلمة المرور'
                                              : 'Reset Password',
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text(isAr ? 'حذف' : 'Delete'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        }, childCount: _users.length),
                      ),
              ],
            ),
    );
  }
}

class UserFormDialog extends StatefulWidget {
  final bool isArabic;
  final AppUserModel? user;
  const UserFormDialog({super.key, required this.isArabic, this.user});

  @override
  State<UserFormDialog> createState() => _UserFormDialogState();
}

class _UserFormDialogState extends State<UserFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  Map<String, dynamic> _permissions = {};
  String _role = 'staff';
  bool _isActive = true;
  int? _selectedEmployeeId;
  List<EmployeeModel> _employees = [];
  bool _loadingEmployees = false;

  @override
  void initState() {
    super.initState();
    final user = widget.user;
    _usernameController = TextEditingController(text: user?.username ?? '');
    _passwordController = TextEditingController();
    _selectedEmployeeId = user?.employeeId;
    _permissions = user?.permissions != null
        ? Map<String, dynamic>.from(user!.permissions!)
        : {};
    _role = user?.role ?? 'staff';
    _isActive = user?.isActive ?? true;
    _loadEmployees();
  }

  Future<void> _loadEmployees() async {
    setState(() => _loadingEmployees = true);
    try {
      final response = await ApiService().getEmployees();
      final employeesData = response['employees'];
      List<EmployeeModel> employeesList = [];

      if (employeesData is List<EmployeeModel>) {
        employeesList = employeesData;
      } else if (employeesData is List) {
        employeesList = employeesData
            .whereType<Map>()
            .map(
              (raw) => EmployeeModel.fromJson(Map<String, dynamic>.from(raw)),
            )
            .toList();
      }

      setState(() {
        _employees = employeesList;
        _loadingEmployees = false;
      });
    } catch (e) {
      setState(() => _loadingEmployees = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ في جلب الموظفين: $e')));
      }
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    final payload = <String, dynamic>{
      'username': _usernameController.text.trim(),
      'employee_id': _selectedEmployeeId,
      'role': _role,
      'permissions': _permissions.isEmpty ? null : _permissions,
      'is_active': _isActive,
    };

    final password = _passwordController.text.trim();
    if (widget.user == null) {
      payload['password'] = password;
    } else if (password.isNotEmpty) {
      payload['password'] = password;
    }

    payload.removeWhere((key, value) => value == null);
    Navigator.of(context).pop(payload);
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    return AlertDialog(
      title: Text(
        widget.user == null
            ? (isAr ? 'مستخدم جديد' : 'New User')
            : (isAr ? 'تعديل مستخدم' : 'Edit User'),
      ),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _usernameController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'اسم المستخدم' : 'Username',
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return isAr
                          ? 'اسم المستخدم مطلوب'
                          : 'Username is required';
                    }
                    return null;
                  },
                ),
                TextFormField(
                  controller: _passwordController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'كلمة المرور' : 'Password',
                  ),
                  obscureText: true,
                  validator: (value) {
                    if (widget.user == null &&
                        (value == null || value.trim().isEmpty)) {
                      return isAr
                          ? 'كلمة المرور مطلوبة'
                          : 'Password is required';
                    }
                    return null;
                  },
                ),
                DropdownButtonFormField<String>(
                  value: _role,
                  items: const [
                    DropdownMenuItem(value: 'admin', child: Text('Admin')),
                    DropdownMenuItem(value: 'manager', child: Text('Manager')),
                    DropdownMenuItem(value: 'staff', child: Text('Staff')),
                  ],
                  onChanged: (value) =>
                      setState(() => _role = value ?? 'staff'),
                  decoration: InputDecoration(
                    labelText: isAr ? 'الدور' : 'Role',
                  ),
                ),
                const SizedBox(height: 8),
                // Employee dropdown
                _loadingEmployees
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : DropdownButtonFormField<int?>(
                        value: _selectedEmployeeId,
                        decoration: InputDecoration(
                          labelText: isAr
                              ? 'الموظف (اختياري)'
                              : 'Employee (optional)',
                          helperText: isAr
                              ? 'اختر موظفاً لربطه بهذا المستخدم'
                              : 'Select an employee to link',
                        ),
                        items: [
                          DropdownMenuItem<int?>(
                            value: null,
                            child: Text(
                              isAr ? 'بدون موظف' : 'No Employee',
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          ),
                          ..._employees.map((emp) {
                            final title = emp.name.isNotEmpty
                                ? emp.name
                                : (isAr ? 'موظف' : 'Employee');
                            final subtitle = emp.employeeCode.isNotEmpty
                                ? emp.employeeCode
                                : (emp.jobTitle ?? '');
                            final display = subtitle.isNotEmpty
                                ? '$title • $subtitle'
                                : '$title (ID: ${emp.id ?? '-'})';
                            return DropdownMenuItem<int?>(
                              value: emp.id,
                              child: Text(display),
                            );
                          }).toList(),
                        ],
                        onChanged: (value) {
                          setState(() => _selectedEmployeeId = value);
                        },
                      ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 300,
                  child: PermissionsEditor(
                    initialPermissions: _permissions,
                    isArabic: isAr,
                    onPermissionsChanged: (permissions) {
                      _permissions = permissions;
                    },
                  ),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  value: _isActive,
                  onChanged: (value) => setState(() => _isActive = value),
                  title: Text(isAr ? 'الحساب نشط' : 'Active account'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(isAr ? 'إلغاء' : 'Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(isAr ? 'حفظ' : 'Save')),
      ],
    );
  }
}
