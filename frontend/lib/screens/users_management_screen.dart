import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api_service.dart';

/// شاشة إدارة المستخدمين (مع JWT)
class UsersManagementScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const UsersManagementScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<UsersManagementScreen> createState() => _UsersManagementScreenState();
}

class _UsersManagementScreenState extends State<UsersManagementScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _roles = [];
  bool _loading = false;
  bool? _activeFilter;
  String? _token;

  @override
  void initState() {
    super.initState();
    _loadToken();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('auth_token');
    if (_token != null) {
      _loadUsers();
      _loadRoles();
    } else {
      _showSnack('الرجاء تسجيل الدخول أولاً', isError: true);
    }
  }

  Future<void> _loadUsers() async {
    if (_token == null) return;

    setState(() => _loading = true);
    try {
      final response = await widget.api.listUsersWithAuth(
        _token!,
        search: _searchController.text.trim().isEmpty
            ? null
            : _searchController.text.trim(),
        isActive: _activeFilter,
        page: 1,
        perPage: 100,
      );

      if (response['success'] == true) {
        setState(() {
          _users = List<Map<String, dynamic>>.from(response['users'] ?? []);
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

  Future<void> _loadRoles() async {
    if (_token == null) return;

    try {
      final response = await widget.api.getRoles(_token!, includeUsers: false);
      if (response['success'] == true) {
        setState(() {
          _roles = List<Map<String, dynamic>>.from(response['roles'] ?? []);
        });
      }
    } catch (e) {
      debugPrint('Error loading roles: $e');
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

  Widget _buildStatisticsRow(ThemeData theme, ColorScheme colorScheme) {
    if (_users.isEmpty) {
      return const SizedBox.shrink();
    }

    final total = _users.length;
    final active = _users.where((u) => u['is_active'] == true).length;
    final admins = _users.where((u) => u['is_admin'] == true).length;

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
            'إجمالي المستخدمين',
            'Total Users',
            total,
            Icons.people_alt_outlined,
            const Color(0xFFFFD700),
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
            Icons.admin_panel_settings_outlined,
            Colors.deepPurple.shade700,
          ),
        ],
      ),
    );
  }

  Widget _buildUserCard(Map<String, dynamic> user, ThemeData theme) {
    final username = user['username'] ?? '';
    final fullName = user['full_name'] ?? '';
    final isActive = user['is_active'] == true;
    final isAdmin = user['is_admin'] == true;
    final roles = user['roles'] as List<dynamic>? ?? [];

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      elevation: 1,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: isActive
              ? const Color(0xFFFFD700).withValues(alpha: 0.2)
              : Colors.grey.shade300,
          child: Icon(
            isAdmin ? Icons.admin_panel_settings : Icons.person,
            color: isActive ? const Color(0xFFB8860B) : Colors.grey,
          ),
        ),
        title: Text(
          fullName.isNotEmpty ? fullName : username,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              '@$username',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.grey[600],
              ),
            ),
            if (roles.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: roles.map((role) {
                  final roleName = widget.isArabic
                      ? (role['name_ar'] ?? role['name'] ?? '')
                      : (role['name'] ?? '');
                  return Chip(
                    label: Text(
                      roleName,
                      style: const TextStyle(fontSize: 11),
                    ),
                    backgroundColor: const Color(0xFFFFD700).withValues(alpha: 0.2),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  );
                }).toList(),
              ),
            ],
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Active Status Badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: isActive ? Colors.green.shade50 : Colors.red.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isActive ? Colors.green.shade300 : Colors.red.shade300,
                ),
              ),
              child: Text(
                isActive
                    ? (widget.isArabic ? 'نشط' : 'Active')
                    : (widget.isArabic ? 'معطل' : 'Inactive'),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isActive ? Colors.green.shade700 : Colors.red.shade700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Actions Menu
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                switch (value) {
                  case 'edit':
                    _showUserDialog(user: user);
                    break;
                  case 'toggle':
                    _toggleUserStatus(user);
                    break;
                  case 'roles':
                    _showRolesDialog(user);
                    break;
                  case 'delete':
                    _deleteUser(user);
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
                  value: 'toggle',
                  child: Row(
                    children: [
                      Icon(
                        isActive
                            ? Icons.block_outlined
                            : Icons.check_circle_outline,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        isActive
                            ? (widget.isArabic ? 'تعطيل' : 'Deactivate')
                            : (widget.isArabic ? 'تفعيل' : 'Activate'),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'roles',
                  child: Row(
                    children: [
                      const Icon(Icons.manage_accounts_outlined, size: 20),
                      const SizedBox(width: 12),
                      Text(widget.isArabic ? 'إدارة الأدوار' : 'Manage Roles'),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      const Icon(Icons.delete_outline, color: Colors.red, size: 20),
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
          ],
        ),
      ),
    );
  }

  Future<void> _toggleUserStatus(Map<String, dynamic> user) async {
    if (_token == null) return;

    try {
      final response = await widget.api.toggleUserActiveWithAuth(
        _token!,
        user['id'],
      );

      if (response['success'] == true) {
        _showSnack(response['message'] ?? 'تم تغيير حالة المستخدم');
        _loadUsers();
      }
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  Future<void> _deleteUser(Map<String, dynamic> user) async {
    if (_token == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.isArabic ? 'حذف مستخدم' : 'Delete User'),
        content: Text(
          widget.isArabic
              ? 'هل تريد حذف المستخدم ${user['username']}؟'
              : 'Delete user ${user['username']}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: Text(widget.isArabic ? 'حذف' : 'Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final response = await widget.api.deleteUserWithAuth(_token!, user['id']);

      if (response['success'] == true) {
        _showSnack(response['message'] ?? 'تم حذف المستخدم');
        _loadUsers();
      }
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  Future<void> _showUserDialog({Map<String, dynamic>? user}) async {
    final isEdit = user != null;
    final usernameController = TextEditingController(text: user?['username']);
    final fullNameController = TextEditingController(text: user?['full_name']);
    final passwordController = TextEditingController();
    bool isAdmin = user?['is_admin'] == true;
    bool isActive = user?['is_active'] ?? true;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(
            isEdit
                ? (widget.isArabic ? 'تعديل مستخدم' : 'Edit User')
                : (widget.isArabic ? 'إضافة مستخدم' : 'Add User'),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: usernameController,
                  enabled: !isEdit,
                  decoration: InputDecoration(
                    labelText: widget.isArabic ? 'اسم المستخدم' : 'Username',
                    prefixIcon: const Icon(Icons.person_outline),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: fullNameController,
                  decoration: InputDecoration(
                    labelText: widget.isArabic ? 'الاسم الكامل' : 'Full Name',
                    prefixIcon: const Icon(Icons.badge_outlined),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: isEdit
                        ? (widget.isArabic
                            ? 'كلمة مرور جديدة (اختياري)'
                            : 'New Password (optional)')
                        : (widget.isArabic ? 'كلمة المرور' : 'Password'),
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  title: Text(widget.isArabic ? 'نشط' : 'Active'),
                  value: isActive,
                  onChanged: (value) => setState(() => isActive = value),
                ),
                SwitchListTile(
                  title: Text(widget.isArabic ? 'مدير' : 'Administrator'),
                  value: isAdmin,
                  onChanged: (value) => setState(() => isAdmin = value),
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
                final username = usernameController.text.trim();
                final fullName = fullNameController.text.trim();
                final password = passwordController.text.trim();

                if (!isEdit && username.isEmpty) {
                  _showSnack(
                    widget.isArabic
                        ? 'اسم المستخدم مطلوب'
                        : 'Username is required',
                    isError: true,
                  );
                  return;
                }

                if (!isEdit && password.isEmpty) {
                  _showSnack(
                    widget.isArabic
                        ? 'كلمة المرور مطلوبة'
                        : 'Password is required',
                    isError: true,
                  );
                  return;
                }

                try {
                  if (isEdit) {
                    // Update
                    await widget.api.updateUserWithAuth(
                      _token!,
                      user['id'],
                      fullName: fullName.isEmpty ? null : fullName,
                      isAdmin: isAdmin,
                      isActive: isActive,
                      password: password.isEmpty ? null : password,
                    );
                  } else {
                    // Create
                    await widget.api.createUserWithAuth(
                      _token!,
                      username: username,
                      password: password,
                      fullName: fullName,
                      isAdmin: isAdmin,
                      isActive: isActive,
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
      ),
    );

    if (result == true) {
      _loadUsers();
    }
  }

  Future<void> _showRolesDialog(Map<String, dynamic> user) async {
    final userRoles = (user['roles'] as List?)?.map((r) => r['id'] as int).toList() ?? [];
    final selectedRoles = Set<int>.from(userRoles);

    final result = await showDialog<Set<int>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(widget.isArabic ? 'إدارة الأدوار' : 'Manage Roles'),
          content: SizedBox(
            width: double.maxFinite,
            child: _roles.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _roles.length,
                    itemBuilder: (context, index) {
                      final role = _roles[index];
                      final roleId = role['id'] as int;
                      final roleName = widget.isArabic
                          ? (role['name_ar'] ?? role['name'])
                          : role['name'];

                      return CheckboxListTile(
                        title: Text(roleName),
                        subtitle: role['description'] != null
                            ? Text(role['description'])
                            : null,
                        value: selectedRoles.contains(roleId),
                        onChanged: (checked) {
                          setState(() {
                            if (checked == true) {
                              selectedRoles.add(roleId);
                            } else {
                              selectedRoles.remove(roleId);
                            }
                          });
                        },
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(selectedRoles),
              child: Text(widget.isArabic ? 'حفظ' : 'Save'),
            ),
          ],
        ),
      ),
    );

    if (result == null || _token == null) return;

    try {
      // Determine which roles to add and remove
      final currentRoles = Set<int>.from(userRoles);
      final toAdd = result.difference(currentRoles).toList();
      final toRemove = currentRoles.difference(result).toList();

      if (toAdd.isNotEmpty) {
        await widget.api.manageUserRoles(_token!, user['id'], 'add', toAdd);
      }

      if (toRemove.isNotEmpty) {
        await widget.api.manageUserRoles(_token!, user['id'], 'remove', toRemove);
      }

      _showSnack(widget.isArabic ? 'تم تحديث الأدوار' : 'Roles updated');
      _loadUsers();
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isArabic ? 'إدارة المستخدمين' : 'Users Management'),
        backgroundColor: const Color(0xFFFFD700),
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          // Filter by Active Status
          PopupMenuButton<bool?>(
            icon: const Icon(Icons.filter_list),
            tooltip: widget.isArabic ? 'تصفية' : 'Filter',
            onSelected: (value) {
              setState(() => _activeFilter = value);
              _loadUsers();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: null,
                child: Text(widget.isArabic ? 'الكل' : 'All'),
              ),
              PopupMenuItem(
                value: true,
                child: Text(widget.isArabic ? 'نشط فقط' : 'Active Only'),
              ),
              PopupMenuItem(
                value: false,
                child: Text(widget.isArabic ? 'معطل فقط' : 'Inactive Only'),
              ),
            ],
          ),
          // Refresh
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: widget.isArabic ? 'تحديث' : 'Refresh',
            onPressed: _loadUsers,
          ),
        ],
      ),
      body: Column(
        children: [
          // Statistics Row
          _buildStatisticsRow(theme, colorScheme),

          // Search Bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: widget.isArabic ? 'بحث...' : 'Search...',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _loadUsers();
                        },
                      )
                    : null,
              ),
              onSubmitted: (_) => _loadUsers(),
            ),
          ),

          // Users List
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _users.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.people_outline,
                              size: 80,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              widget.isArabic
                                  ? 'لا يوجد مستخدمين'
                                  : 'No users found',
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadUsers,
                        child: ListView.builder(
                          itemCount: _users.length,
                          itemBuilder: (context, index) {
                            return _buildUserCard(_users[index], theme);
                          },
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showUserDialog(),
        backgroundColor: const Color(0xFFFFD700),
        foregroundColor: Colors.black87,
        icon: const Icon(Icons.person_add),
        label: Text(widget.isArabic ? 'إضافة مستخدم' : 'Add User'),
      ),
    );
  }
}
