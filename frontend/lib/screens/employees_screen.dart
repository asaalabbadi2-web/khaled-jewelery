import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../models/app_user_model.dart';
import '../models/employee_model.dart';
import '../providers/auth_provider.dart';
import '../utils.dart';

class EmployeesScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  const EmployeesScreen({super.key, required this.api, this.isArabic = true});

  @override
  State<EmployeesScreen> createState() => _EmployeesScreenState();
}

class _EmployeesScreenState extends State<EmployeesScreen> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<EmployeeModel> _employees = [];
  bool? _activeFilter;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadEmployees();
    _searchController.addListener(_debouncedSearch);
  }

  @override
  void dispose() {
    _searchController.removeListener(_debouncedSearch);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadEmployees() async {
    setState(() => _loading = true);
    try {
      final payload = await widget.api.getEmployees(
        search: _searchController.text.trim().isEmpty
            ? null
            : _searchController.text.trim(),
        isActive: _activeFilter,
      );
      final items = payload['employees'] as List<EmployeeModel>;
      setState(() {
        _employees = items;
      });
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _debouncedSearch() {
    Future.delayed(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _loadEmployees();
    });
  }

  void _showSnack(String message, {bool isError = false}) {
    final isAr = widget.isArabic;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? Colors.red
            : Theme.of(context).colorScheme.primary,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: isAr ? 'إغلاق' : 'Close',
          textColor: Colors.white,
          onPressed: () {},
        ),
      ),
    );
  }

  Future<void> _refresh() async {
    await _loadEmployees();
  }

  Future<void> _toggleEmployee(EmployeeModel employee) async {
    try {
      final newValue = await widget.api.toggleEmployeeActive(employee.id ?? 0);
      setState(() {
        final index = _employees.indexWhere((e) => e.id == employee.id);
        if (index != -1) {
          _employees[index] = employee.copyWith(isActive: newValue);
        }
      });
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  Future<void> _showCreateUserDialog(EmployeeModel employee) async {
    final isAr = widget.isArabic;
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    final emailController = TextEditingController();
    final phoneController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final auth = context.read<AuthProvider>();
    final isSystemAdmin = auth.isSystemAdmin;
    final isManager = auth.role == 'manager';

    final allowedRoles = isSystemAdmin
        ? const ['employee', 'accountant', 'manager']
        : (isManager ? const ['employee'] : const ['employee']);
    String selectedRole = allowedRoles.first;

    emailController.text = (employee.email ?? '').trim();
    phoneController.text = (employee.phone ?? '').trim();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text(isAr ? 'إنشاء حساب مستخدم' : 'Create User Account'),
              content: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isAr
                            ? 'إنشاء حساب دخول للموظف: ${employee.name}'
                            : 'Create login account for: ${employee.name}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: usernameController,
                        decoration: InputDecoration(
                          labelText: isAr ? 'اسم المستخدم' : 'Username',
                          hintText: isAr
                              ? 'مثال: ${employee.name.split(' ').first}'
                              : 'e.g., ${employee.name.split(' ').first}',
                          border: const OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return isAr
                                ? 'يجب إدخال اسم المستخدم'
                                : 'Username is required';
                          }
                          if (value.length < 3) {
                            return isAr
                                ? 'اسم المستخدم قصير جداً'
                                : 'Username too short';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: emailController,
                        decoration: InputDecoration(
                          labelText: isAr ? 'البريد الإلكتروني' : 'Email',
                          border: const OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.emailAddress,
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return isAr
                                ? 'يجب إدخال البريد الإلكتروني'
                                : 'Email is required';
                          }
                          if (!value.contains('@')) {
                            return isAr
                                ? 'صيغة البريد غير صحيحة'
                                : 'Invalid email format';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: phoneController,
                        decoration: InputDecoration(
                          labelText: isAr ? 'رقم الجوال' : 'Mobile',
                          border: const OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.phone,
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return isAr
                                ? 'يجب إدخال رقم الجوال'
                                : 'Mobile is required';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: passwordController,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: isAr ? 'كلمة المرور' : 'Password',
                          border: const OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return isAr
                                ? 'يجب إدخال كلمة المرور'
                                : 'Password is required';
                          }
                          if (value.length < 6) {
                            return isAr
                                ? 'كلمة المرور قصيرة جداً (6 أحرف على الأقل)'
                                : 'Password too short (min 6 characters)';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: selectedRole,
                        decoration: InputDecoration(
                          labelText: isAr ? 'الدور' : 'Role',
                          border: const OutlineInputBorder(),
                        ),
                        items: allowedRoles
                            .map(
                              (r) => DropdownMenuItem(
                                value: r,
                                child: Text(
                                  isAr
                                      ? {
                                              'employee': 'بائع',
                                              'accountant': 'محاسب',
                                              'manager': 'مدير فرع',
                                            }[r] ??
                                            r
                                      : {
                                              'employee': 'Seller',
                                              'accountant': 'Accountant',
                                              'manager': 'Branch Manager',
                                            }[r] ??
                                            r,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              selectedRole = value;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(isAr ? 'إلغاء' : 'Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    if (formKey.currentState!.validate()) {
                      Navigator.of(context).pop(true);
                    }
                  },
                  child: Text(isAr ? 'إنشاء' : 'Create'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != true) return;

    try {
      await widget.api.createUserFromEmployee(
        employeeId: employee.id!,
        username: usernameController.text.trim(),
        password: passwordController.text,
        email: emailController.text.trim(),
        phone: phoneController.text.trim(),
        role: selectedRole,
      );

      _showSnack(
        isAr
            ? 'تم إنشاء حساب المستخدم بنجاح'
            : 'User account created successfully',
      );
      await _loadEmployees();
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    } finally {
      usernameController.dispose();
      passwordController.dispose();
      emailController.dispose();
      phoneController.dispose();
    }
  }

  Future<void> _promptResetAppUserPassword(AppUserModel appUser) async {
    final isAr = widget.isArabic;
    final controller = TextEditingController();

    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(isAr ? 'إعادة تعيين كلمة المرور' : 'Reset Password'),
          content: TextField(
            controller: controller,
            obscureText: true,
            decoration: InputDecoration(
              labelText: isAr ? 'كلمة مرور جديدة' : 'New password',
              hintText: isAr ? '6 أحرف على الأقل' : 'Min 6 characters',
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(isAr ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(isAr ? 'تأكيد' : 'Confirm'),
            ),
          ],
        ),
      );

      if (ok != true) return;

      final newPassword = controller.text.trim();
      if (newPassword.length < 6) {
        _showSnack(
          isAr
              ? 'كلمة المرور يجب أن تكون 6 أحرف على الأقل'
              : 'Password too short',
          isError: true,
        );
        return;
      }

      await widget.api.resetUserPassword(appUser.id ?? 0, newPassword);
      _showSnack(isAr ? 'تم تحديث كلمة المرور' : 'Password updated');
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    } finally {
      controller.dispose();
    }
  }

  Future<void> _openEmployeeForm({EmployeeModel? employee}) async {
    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (context) {
        return EmployeeFormDialog(
          isArabic: widget.isArabic,
          employee: employee,
        );
      },
    );

    if (result == null) return;

    try {
      if (employee == null) {
        final created = await widget.api.createEmployee(result);
        setState(() => _employees.insert(0, created));
        _showSnack(widget.isArabic ? 'تم إضافة الموظف' : 'Employee created');
      } else {
        final updated = await widget.api.updateEmployee(
          employee.id ?? 0,
          result,
        );
        setState(() {
          final index = _employees.indexWhere((e) => e.id == employee.id);
          if (index != -1) {
            _employees[index] = updated;
          }
        });
        _showSnack(widget.isArabic ? 'تم تحديث الموظف' : 'Employee updated');
      }
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  void _showEmployeeDetails(EmployeeModel employee) {
    final isAr = widget.isArabic;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        final theme = Theme.of(context);
        final textTheme = theme.textTheme;
        final colorScheme = theme.colorScheme;

        final auth = context.read<AuthProvider>();
        final canManageAccounts = auth.isSystemAdmin || auth.role == 'manager';

        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: SingleChildScrollView(
                controller: _scrollController,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.badge, color: colorScheme.primary),
                        const SizedBox(width: 8),
                        Text(
                          employee.name,
                          style: textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: employee.isActive
                                ? Colors.green.withValues(alpha: 0.1)
                                : Colors.red.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            employee.isActive
                                ? (isAr ? 'نشط' : 'Active')
                                : (isAr ? 'غير نشط' : 'Inactive'),
                            style: textTheme.bodyMedium?.copyWith(
                              color: employee.isActive
                                  ? Colors.green
                                  : Colors.red,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _InfoRow(
                      label: isAr ? 'الرقم الوظيفي' : 'Employee Code',
                      value: employee.employeeCode,
                    ),
                    _InfoRow(
                      label: isAr ? 'القسم' : 'Department',
                      value: employee.department ?? '-',
                    ),
                    _InfoRow(
                      label: isAr ? 'المسمى' : 'Job Title',
                      value: employee.jobTitle ?? '-',
                    ),
                    _InfoRow(
                      label: isAr ? 'الراتب' : 'Salary',
                      value: employee.salary.toStringAsFixed(2),
                    ),
                    _InfoRow(
                      label: isAr ? 'الهاتف' : 'Phone',
                      value: employee.phone ?? '-',
                    ),
                    _InfoRow(
                      label: isAr ? 'البريد' : 'Email',
                      value: employee.email ?? '-',
                    ),
                    _InfoRow(
                      label: isAr ? 'ملاحظات' : 'Notes',
                      value: employee.notes ?? '-',
                    ),
                    if (employee.account != null)
                      _InfoRow(
                        label: isAr ? 'الحساب المحاسبي' : 'Account',
                        value:
                            '${employee.account!.accountNumber} - ${employee.account!.name}',
                      ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _StatChip(
                          icon: Icons.payments_outlined,
                          label: isAr ? 'سجلات الرواتب' : 'Payroll Entries',
                          value: employee.payrollCount.toString(),
                        ),
                        _StatChip(
                          icon: Icons.timer_outlined,
                          label: isAr ? 'سجلات الحضور' : 'Attendance Records',
                          value: employee.attendanceCount.toString(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (canManageAccounts && employee.id != null) ...[
                      Text(
                        isAr ? 'حساب الدخول' : 'Login Account',
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      FutureBuilder<AppUserModel?>(
                        future: widget.api.getUserByEmployeeId(employee.id!),
                        builder: (context, snap) {
                          if (snap.connectionState == ConnectionState.waiting) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }

                          if (snap.hasError) {
                            return Text(
                              isAr
                                  ? 'تعذر تحميل حساب الدخول'
                                  : 'Failed to load login account',
                              style: textTheme.bodyMedium,
                            );
                          }

                          final linked = snap.data;
                          if (linked == null) {
                            return Text(
                              isAr
                                  ? 'لا يوجد حساب دخول مرتبط'
                                  : 'No linked login account',
                              style: textTheme.bodyMedium,
                            );
                          }

                          final roleLabelAr = {
                            'employee': 'بائع',
                            'accountant': 'محاسب',
                            'manager': 'مدير فرع',
                            'system_admin': 'مسؤول النظام',
                          }[linked.role];
                          final roleLabelEn = {
                            'employee': 'Seller',
                            'accountant': 'Accountant',
                            'manager': 'Branch Manager',
                            'system_admin': 'System Admin',
                          }[linked.role];

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _InfoRow(
                                label: isAr ? 'اسم المستخدم' : 'Username',
                                value: linked.username,
                              ),
                              _InfoRow(
                                label: isAr ? 'الدور' : 'Role',
                                value: isAr
                                    ? (roleLabelAr ?? linked.role)
                                    : (roleLabelEn ?? linked.role),
                              ),
                              _InfoRow(
                                label: isAr ? 'الحالة' : 'Status',
                                value: linked.isActive
                                    ? (isAr ? 'مفعل' : 'Enabled')
                                    : (isAr ? 'معطل' : 'Disabled'),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  TextButton.icon(
                                    icon: Icon(
                                      linked.isActive
                                          ? Icons.lock_outline
                                          : Icons.lock_open,
                                    ),
                                    label: Text(
                                      linked.isActive
                                          ? (isAr
                                                ? 'تعطيل الحساب'
                                                : 'Disable account')
                                          : (isAr
                                                ? 'تفعيل الحساب'
                                                : 'Enable account'),
                                    ),
                                    onPressed: () async {
                                      try {
                                        final isActive = await widget.api
                                            .toggleUserActive(linked.id ?? 0);
                                        _showSnack(
                                          isActive
                                              ? (isAr
                                                    ? 'تم تفعيل الحساب'
                                                    : 'Account enabled')
                                              : (isAr
                                                    ? 'تم تعطيل الحساب'
                                                    : 'Account disabled'),
                                        );
                                        // Reopen to refresh linked account snapshot.
                                        Navigator.of(context).pop();
                                        _showEmployeeDetails(employee);
                                      } catch (e) {
                                        _showSnack(e.toString(), isError: true);
                                      }
                                    },
                                  ),
                                  TextButton.icon(
                                    icon: const Icon(Icons.key_outlined),
                                    label: Text(
                                      isAr
                                          ? 'إعادة التعيين الإداري'
                                          : 'Admin password reset',
                                    ),
                                    onPressed: () {
                                      Navigator.of(context).pop();
                                      _promptResetAppUserPassword(linked);
                                    },
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                    ],
                    Row(
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.edit),
                          label: Text(
                            isAr ? 'تعديل البيانات' : 'Edit Employee',
                          ),
                          onPressed: () {
                            Navigator.of(context).pop();
                            _openEmployeeForm(employee: employee);
                          },
                        ),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          icon: const Icon(Icons.person_add),
                          label: Text(
                            isAr ? 'إنشاء حساب مستخدم' : 'Create User Account',
                          ),
                          onPressed: () {
                            Navigator.of(context).pop();
                            _showCreateUserDialog(employee);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final isAr = widget.isArabic;

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'الموظفون' : 'Employees'),
        actions: [
          IconButton(
            tooltip: isAr ? 'تحديث' : 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<bool?>(
            icon: const Icon(Icons.filter_list),
            onSelected: (value) {
              setState(() => _activeFilter = value);
              _loadEmployees();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: null,
                child: Text(isAr ? 'جميع الحالات' : 'All statuses'),
              ),
              PopupMenuItem(
                value: true,
                child: Text(isAr ? 'نشط فقط' : 'Active only'),
              ),
              PopupMenuItem(
                value: false,
                child: Text(isAr ? 'غير نشط فقط' : 'Inactive only'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEmployeeForm(),
        icon: const Icon(Icons.person_add_alt_1),
        label: Text(isAr ? 'موظف جديد' : 'New Employee'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: isAr
                      ? 'بحث باسم الموظف أو الهاتف...'
                      : 'Search by name or phone...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _employees.isEmpty
                  ? Center(
                      child: Text(
                        isAr ? 'لا يوجد موظفون' : 'No employees found',
                        style: textTheme.titleMedium?.copyWith(
                          color: colorScheme.primary,
                        ),
                      ),
                    )
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _employees.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final employee = _employees[index];
                        return Card(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          child: ListTile(
                            onTap: () => _showEmployeeDetails(employee),
                            leading: CircleAvatar(
                              backgroundColor: colorScheme.primary,
                              child: Icon(
                                Icons.person_outline,
                                color: colorScheme.onPrimary,
                              ),
                            ),
                            title: Text(
                              employee.name,
                              style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(employee.employeeCode),
                                if (employee.department != null &&
                                    employee.department!.isNotEmpty)
                                  Text(employee.department!),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: employee.isActive,
                                  onChanged: (_) => _toggleEmployee(employee),
                                ),
                                PopupMenuButton<String>(
                                  onSelected: (value) {
                                    if (value == 'edit') {
                                      _openEmployeeForm(employee: employee);
                                    }
                                  },
                                  itemBuilder: (context) => [
                                    PopupMenuItem(
                                      value: 'edit',
                                      child: Text(isAr ? 'تعديل' : 'Edit'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class EmployeeFormDialog extends StatefulWidget {
  final bool isArabic;
  final EmployeeModel? employee;
  const EmployeeFormDialog({super.key, required this.isArabic, this.employee});

  @override
  State<EmployeeFormDialog> createState() => _EmployeeFormDialogState();
}

class _EmployeeFormDialogState extends State<EmployeeFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _jobTitleController;
  late final TextEditingController _departmentController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;
  late final TextEditingController _salaryController;
  late final TextEditingController _notesController;
  late final TextEditingController _nationalIdController;
  DateTime? _hireDate;
  DateTime? _terminationDate;
  bool _isActive = true;

  @override
  void initState() {
    super.initState();
    final employee = widget.employee;
    _nameController = TextEditingController(text: employee?.name ?? '');
    _jobTitleController = TextEditingController(text: employee?.jobTitle ?? '');
    _departmentController = TextEditingController(
      text: employee?.department ?? '',
    );
    _phoneController = TextEditingController(text: employee?.phone ?? '');
    _emailController = TextEditingController(text: employee?.email ?? '');
    _salaryController = TextEditingController(
      text: employee != null ? employee.salary.toStringAsFixed(2) : '',
    );
    _notesController = TextEditingController(text: employee?.notes ?? '');
    _nationalIdController = TextEditingController(
      text: employee?.nationalId ?? '',
    );
    _isActive = employee?.isActive ?? true;

    // ✅ تحميل التواريخ من الموظف الحالي
    _hireDate = employee?.hireDate;
    _terminationDate = employee?.terminationDate;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _jobTitleController.dispose();
    _departmentController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _salaryController.dispose();
    _notesController.dispose();
    _nationalIdController.dispose();
    super.dispose();
  }

  Future<void> _pickDate(BuildContext context, bool isHireDate) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: isHireDate ? (_hireDate ?? now) : (_terminationDate ?? now),
      firstDate: DateTime(1950),
      lastDate: DateTime(2100),
    );

    if (picked != null) {
      setState(() {
        if (isHireDate) {
          _hireDate = picked;
        } else {
          _terminationDate = picked;
        }
      });
    }
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    final salary =
        double.tryParse(_salaryController.text.trim().replaceAll(',', '.')) ??
        0.0;

    final payload = <String, dynamic>{
      'name': _nameController.text.trim(),
      'job_title': _jobTitleController.text.trim().isEmpty
          ? null
          : _jobTitleController.text.trim(),
      'department': _departmentController.text.trim().isEmpty
          ? null
          : _departmentController.text.trim(),
      'phone': _phoneController.text.trim().isEmpty
          ? null
          : _phoneController.text.trim(),
      'email': _emailController.text.trim().isEmpty
          ? null
          : _emailController.text.trim(),
      'salary': salary,
      'notes': _notesController.text.trim().isEmpty
          ? null
          : _notesController.text.trim(),
      'national_id': _nationalIdController.text.trim().isEmpty
          ? null
          : _nationalIdController.text.trim(),
      'hire_date': _hireDate?.toIso8601String().split('T').first,
      'termination_date': _terminationDate?.toIso8601String().split('T').first,
      'is_active': _isActive,
    }..removeWhere((key, value) => value == null);

    Navigator.of(context).pop(payload);
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    return AlertDialog(
      title: Text(
        widget.employee == null
            ? (isAr ? 'موظف جديد' : 'New Employee')
            : (isAr ? 'تعديل موظف' : 'Edit Employee'),
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'الاسم الكامل' : 'Full Name',
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return isAr ? 'الاسم مطلوب' : 'Name is required';
                    }
                    return null;
                  },
                ),
                TextFormField(
                  controller: _jobTitleController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'المسمى الوظيفي' : 'Job Title',
                  ),
                ),
                TextFormField(
                  controller: _departmentController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'القسم' : 'Department',
                  ),
                ),
                TextFormField(
                  controller: _salaryController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'الراتب الأساسي' : 'Basic Salary',
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [NormalizeNumberFormatter()],
                ),
                TextFormField(
                  controller: _phoneController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'الهاتف' : 'Phone',
                  ),
                ),
                TextFormField(
                  controller: _emailController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'البريد الإلكتروني' : 'Email',
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                TextFormField(
                  controller: _nationalIdController,
                  decoration: InputDecoration(
                    labelText: isAr
                        ? 'الرقم الوطني / الإقامة'
                        : 'National ID / Iqama',
                    prefixIcon: const Icon(Icons.badge),
                  ),
                ),
                const SizedBox(height: 12),
                // ✅ تاريخ التعيين
                ListTile(
                  leading: const Icon(Icons.event),
                  title: Text(isAr ? 'تاريخ التعيين' : 'Hire Date'),
                  subtitle: Text(
                    _hireDate != null
                        ? '${_hireDate!.year}-${_hireDate!.month.toString().padLeft(2, '0')}-${_hireDate!.day.toString().padLeft(2, '0')}'
                        : (isAr ? 'غير محدد' : 'Not set'),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_hireDate != null)
                        IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: () => setState(() => _hireDate = null),
                        ),
                      IconButton(
                        icon: const Icon(Icons.calendar_today),
                        onPressed: () => _pickDate(context, true),
                      ),
                    ],
                  ),
                ),
                // ✅ تاريخ الإنهاء
                ListTile(
                  leading: const Icon(Icons.event_busy),
                  title: Text(isAr ? 'تاريخ الإنهاء' : 'Termination Date'),
                  subtitle: Text(
                    _terminationDate != null
                        ? '${_terminationDate!.year}-${_terminationDate!.month.toString().padLeft(2, '0')}-${_terminationDate!.day.toString().padLeft(2, '0')}'
                        : (isAr ? 'غير محدد' : 'Not set'),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_terminationDate != null)
                        IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: () =>
                              setState(() => _terminationDate = null),
                        ),
                      IconButton(
                        icon: const Icon(Icons.calendar_today),
                        onPressed: () => _pickDate(context, false),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _notesController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'ملاحظات' : 'Notes',
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  value: _isActive,
                  onChanged: (value) => setState(() => _isActive = value),
                  title: Text(isAr ? 'الحالة نشطة' : 'Active Status'),
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

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(flex: 3, child: Text(value, style: textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StatChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Chip(
      avatar: Icon(icon, color: colorScheme.primary),
      label: Text('$label: $value'),
      backgroundColor: colorScheme.primary.withValues(alpha: 0.1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
}
