import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../models/app_user_model.dart';
import '../models/employee_model.dart';
import '../models/safe_box_model.dart';
import '../providers/auth_provider.dart';
import '../utils.dart';
import '../widgets/user_avatar_widget.dart';
import 'account_statement_screen.dart';

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
        showAll: _activeFilter == null,
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

  Map<String, dynamic>? _pickEmployeeSalaryAccount(
    List<dynamic> accounts,
    EmployeeModel employee,
  ) {
    final empName = employee.name.trim().toLowerCase();
    if (empName.isEmpty) return null;

    String normalizeName(String input) {
      final s = input.toLowerCase().trim();
      // Collapse all whitespace + remove common separators to be resilient
      // to formatting differences (e.g. spaces around '-')
      return s
          .replaceAll(RegExp(r'\s+'), '')
          .replaceAll('-', '')
          .replaceAll('–', '')
          .replaceAll('—', '')
          .replaceAll('/', '')
          .replaceAll('\\', '')
          .replaceAll('_', '')
          .replaceAll('|', '')
          .replaceAll(':', '')
          .replaceAll('،', '')
          .replaceAll(',', '')
          .replaceAll('.', '')
          .replaceAll('(', '')
          .replaceAll(')', '');
    }

    final expectedSalaryAccountName =
        'ح/ذمم الموظف ${employee.name.trim()} - رواتب';
    final expectedNormalized = normalizeName(expectedSalaryAccountName);

    final nameTokens = empName
        .split(RegExp(r'\s+'))
        .map((t) => t.trim())
        .where((t) => t.length >= 2)
        .toList(growable: false);

    final flat = <Map<String, dynamic>>[];

    void visit(dynamic node) {
      if (node is! Map) return;
      final map = node.cast<String, dynamic>();
      flat.add(map);
      final children = map['sub_accounts'];
      if (children is List) {
        for (final ch in children) {
          visit(ch);
        }
      }
    }

    for (final root in accounts) {
      visit(root);
    }

    // 1) Prefer an exact match by name + 2400 prefix to avoid collisions
    // when employee names overlap (e.g. "محمد" vs "محمد علي").
    for (final acc in flat) {
      final number = (acc['account_number'] ?? '').toString().toLowerCase();
      if (!number.startsWith('2400')) continue;
      final name = (acc['name'] ?? '').toString();
      if (name.isEmpty) continue;
      if (normalizeName(name) == expectedNormalized) {
        return acc;
      }
    }

    bool looksLikeSalaryName(String name) {
      final n = name.toLowerCase();
      return n.contains('رواتب') ||
          n.contains('راتب') ||
          n.contains('salary') ||
          n.contains('payroll');
    }

    int scoreAccount(Map<String, dynamic> acc) {
      final name = (acc['name'] ?? '').toString().toLowerCase();
      final number = (acc['account_number'] ?? '').toString().toLowerCase();

      final normalizedName = normalizeName(name);

      var score = 0;
      if (number.startsWith('2400')) score += 50;
      if (looksLikeSalaryName(name)) score += 30;

      // Strong signal: close to the canonical naming.
      if (normalizedName == expectedNormalized) {
        score += 80;
      }

      if (name.contains(empName)) {
        score += 20;
      } else if (nameTokens.isNotEmpty && nameTokens.any(name.contains)) {
        score += 10;
      }

      // Prefer detail accounts (usually no children)
      final children = acc['sub_accounts'];
      final hasChildren = children is List && children.isNotEmpty;
      if (!hasChildren) score += 5;

      return score;
    }

    Map<String, dynamic>? best;
    var bestScore = 0;
    for (final acc in flat) {
      final name = (acc['name'] ?? '').toString();
      if (name.isEmpty) continue;
      final sc = scoreAccount(acc);
      if (sc > bestScore) {
        bestScore = sc;
        best = acc;
      }
    }

    // Require a minimum confidence.
    if (bestScore < 50) return null;
    return best;
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
        ? const ['employee', 'storekeeper', 'accountant', 'manager']
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
          api: widget.api,
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
    var currentEmployee = employee;
    var openingSalaryStatement = false;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        final theme = Theme.of(context);
        final textTheme = theme.textTheme;
        final colorScheme = theme.colorScheme;

        final auth = context.read<AuthProvider>();
        final canManageAccounts = auth.isSystemAdmin || auth.role == 'manager';

        return StatefulBuilder(
          builder: (context, setModalState) {
            final employee = currentEmployee;
            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680, maxHeight: 900),
                child: Padding(
              padding: const EdgeInsets.all(16),
              child: SingleChildScrollView(
                controller: _scrollController,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // رأس الديالوج
                    Row(
                      children: [
                        Icon(Icons.badge, color: colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            employee.name,
                            style: textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
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
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context).pop(),
                          tooltip: isAr ? 'إغلاق' : 'Close',
                        ),
                      ],
                    ),
                    const Divider(height: 20),
                    DefaultTabController(
                      length: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TabBar(
                            labelColor: colorScheme.primary,
                            unselectedLabelColor: textTheme.bodyMedium?.color?.withValues(alpha: 0.65),
                            indicatorColor: colorScheme.primary,
                            tabs: [
                              Tab(text: isAr ? 'بيانات الموظف' : 'Employee Data'),
                              Tab(text: isAr ? 'الهدف الشخصي' : 'Personal Goal'),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 660,
                            child: TabBarView(
                              children: [
                                SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (canManageAccounts) ...[
                                        FilledButton.icon(
                                          onPressed: () async {
                                            try {
                                              final updated = await widget.api
                                                  .ensureEmployeeSetup(
                                                    employee.id ?? 0,
                                                    ensurePersonalAccount: true,
                                                    ensurePayablesAccounts: true,
                                                    ensureCashSafe: true,
                                                    ensureGoldSafe: true,
                                                  );

                                              setState(() {
                                                final index = _employees.indexWhere(
                                                  (e) => e.id == updated.id,
                                                );
                                                if (index != -1) {
                                                  _employees[index] = updated;
                                                }
                                              });

                                              setModalState(() {
                                                currentEmployee = updated;
                                              });

                                              _showSnack(
                                                widget.isArabic
                                                    ? 'تم إنشاء/ربط حسابات وخزائن الموظف'
                                                    : 'Employee setup ensured',
                                              );
                                            } catch (e) {
                                              _showSnack(e.toString(), isError: true);
                                            }
                                          },
                                          icon: const Icon(Icons.build_circle),
                                          label: Text(
                                            widget.isArabic
                                                ? 'إصلاح حسابات وخزائن الموظف'
                                                : 'Fix employee accounts & safes',
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                      ],
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
                                      if (employee.account != null)
                                        Align(
                                          alignment: AlignmentDirectional.centerStart,
                                          child: TextButton.icon(
                                            onPressed: () {
                                              final acc = employee.account!;
                                              Navigator.of(context).push(
                                                MaterialPageRoute(
                                                  builder: (_) => AccountStatementScreen(
                                                    accountId: acc.id,
                                                    accountName: acc.name,
                                                  ),
                                                ),
                                              );
                                            },
                                            icon: const Icon(Icons.receipt_long, size: 18),
                                            label: Text(isAr ? 'كشف حساب' : 'Account Statement'),
                                          ),
                                        ),
                                      Align(
                                        alignment: AlignmentDirectional.centerStart,
                                        child: TextButton.icon(
                                          onPressed: openingSalaryStatement
                                              ? null
                                              : () async {
                                                  setModalState(() {
                                                    openingSalaryStatement = true;
                                                  });

                                                  try {
                                                    final accounts = await widget.api
                                                        .getAccounts();
                                                    final salaryAccount =
                                                        _pickEmployeeSalaryAccount(
                                                          accounts,
                                                          employee,
                                                        );

                                                    if (salaryAccount == null) {
                                                      _showSnack(
                                                        isAr
                                                            ? 'تعذر العثور على حساب رواتب الموظف. ابحث في كشف الحساب عن: رواتب ${employee.name}'
                                                            : 'Could not find salary account. Search statements for: Salary ${employee.name}',
                                                        isError: true,
                                                      );
                                                      return;
                                                    }

                                                    final id = salaryAccount['id'];
                                                    final accountId = id is int
                                                        ? id
                                                        : int.tryParse('$id');
                                                    if (accountId == null) {
                                                      _showSnack(
                                                        isAr
                                                            ? 'تعذر فتح كشف الرواتب (معرّف الحساب غير صالح)'
                                                            : 'Failed to open salary statement (invalid account id)',
                                                        isError: true,
                                                      );
                                                      return;
                                                    }

                                                    final accountName =
                                                        (salaryAccount['name'] ?? '').toString();
                                                    if (!mounted) return;
                                                    await Navigator.of(context).push(
                                                      MaterialPageRoute(
                                                        builder: (_) => AccountStatementScreen(
                                                          accountId: accountId,
                                                          accountName: accountName.isEmpty
                                                              ? (isAr
                                                                    ? 'رواتب الموظف'
                                                                    : 'Employee Salary')
                                                              : accountName,
                                                        ),
                                                      ),
                                                    );
                                                  } catch (e) {
                                                    _showSnack(e.toString(), isError: true);
                                                  } finally {
                                                    setModalState(() {
                                                      openingSalaryStatement = false;
                                                    });
                                                  }
                                                },
                                          icon: openingSalaryStatement
                                              ? const SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child: CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                  ),
                                                )
                                              : const Icon(Icons.payments_outlined, size: 18),
                                          label: Text(
                                            isAr
                                                ? 'كشف حساب الرواتب (2400)'
                                                : 'Salary Statement (2400)',
                                          ),
                                        ),
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
                                SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (employee.id != null)
                                        _GoalSettingsTile(
                                          employee: employee,
                                          isArabic: isAr,
                                          api: widget.api,
                                          onSaved: (updated) {
                                            setModalState(() => currentEmployee = updated);
                                            setState(() {
                                              final idx = _employees.indexWhere((e) => e.id == updated.id);
                                              if (idx != -1) _employees[idx] = updated;
                                            });
                                          },
                                        )
                                      else
                                        Padding(
                                          padding: const EdgeInsets.symmetric(vertical: 12),
                                          child: Text(
                                            isAr
                                                ? 'احفظ الموظف أولاً لتفعيل الهدف الشخصي.'
                                                : 'Save employee first to enable personal goal.',
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
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
          IconButton(
            tooltip: isAr ? 'إصلاح حسابات جميع الموظفين' : 'Fix all employee accounts',
            icon: const Icon(Icons.build_circle_outlined),
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(isAr ? 'إصلاح حسابات جميع الموظفين' : 'Fix All Employee Accounts'),
                  content: Text(isAr
                      ? 'سيتم إنشاء الحسابات المحاسبية والخزائن الناقصة لجميع الموظفين النشطين.\nهذه العملية آمنة ولا تُكرر الحسابات الموجودة.'
                      : 'This will create missing accounts and safes for all active employees. Safe to re-run.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(isAr ? 'إلغاء' : 'Cancel')),
                    ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(isAr ? 'تأكيد' : 'Confirm')),
                  ],
                ),
              );
              if (confirmed != true) return;
              try {
                final result = await ApiService().bulkEnsureAllEmployeesSetup();
                final updated = (result['updated'] as List?)?.length ?? 0;
                final errors = (result['errors'] as List?)?.length ?? 0;
                _showSnack(isAr
                    ? 'تم إصلاح $updated موظف${errors > 0 ? " — $errors أخطاء" : ""}'
                    : 'Fixed $updated employees${errors > 0 ? " — $errors errors" : ""}');
                _refresh();
              } catch (e) {
                _showSnack(e.toString(), isError: true);
              }
            },
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
                            leading: UserAvatarWidget(
                              displayName: employee.name,
                              photoBase64: employee.photo,
                              radius: 20,
                              editable: true,
                              onUpload: (base64) async {
                                if (employee.id == null) return;
                                await widget.api.updateEmployeePhoto(employee.id!, base64);
                                _loadEmployees();
                              },
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
  final ApiService api;
  final bool isArabic;
  final EmployeeModel? employee;
  const EmployeeFormDialog({
    super.key,
    required this.api,
    required this.isArabic,
    this.employee,
  });

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

  List<SafeBoxModel> _goldSafes = const [];
  bool _loadingGoldSafes = false;
  int _selectedGoldSafeBoxId = 0; // 0 => main

  List<SafeBoxModel> _cashSafes = const [];
  bool _loadingCashSafes = false;
  int _selectedCashSafeBoxId = 0; // 0 => main

  bool _autoCreateGoldSafe = false;
  bool _autoCreateCashSafe = false;

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

    _selectedGoldSafeBoxId = employee?.goldSafeBoxId ?? 0;
    _selectedCashSafeBoxId = employee?.cashSafeBoxId ?? 0;

    // ✅ تحميل التواريخ من الموظف الحالي
    _hireDate = employee?.hireDate;
    _terminationDate = employee?.terminationDate;

    _loadGoldSafes();
    _loadCashSafes();
  }

  Future<void> _loadGoldSafes() async {
    setState(() => _loadingGoldSafes = true);
    try {
      final safes = await widget.api.getSafeBoxes(
        safeType: 'gold',
        isActive: true,
      );
      if (!mounted) return;
      setState(() {
        _goldSafes = safes;
      });
    } catch (_) {
      // Keep the form usable even if safes couldn't load.
    } finally {
      if (mounted) setState(() => _loadingGoldSafes = false);
    }
  }

  Future<void> _loadCashSafes() async {
    setState(() => _loadingCashSafes = true);
    try {
      final safes = await widget.api.getSafeBoxes(
        safeType: 'cash',
        isActive: true,
      );
      if (!mounted) return;
      setState(() {
        _cashSafes = safes;
      });
    } catch (_) {
      // Keep the form usable even if safes couldn't load.
    } finally {
      if (mounted) setState(() => _loadingCashSafes = false);
    }
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
      'gold_safe_box_id': _selectedGoldSafeBoxId,
      'cash_safe_box_id': _selectedCashSafeBoxId,
    }..removeWhere((key, value) => value == null);

    // Auto-create flags are only supported on create (POST /employees).
    if (widget.employee == null) {
      payload['auto_create_gold_safe_box'] = _autoCreateGoldSafe;
      payload['auto_create_cash_safe_box'] = _autoCreateCashSafe;
    }

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

                // Cash safe selection + optional auto-create (create only)
                if (widget.employee == null) ...[
                  SwitchListTile(
                    value: _autoCreateCashSafe,
                    onChanged: (value) {
                      setState(() {
                        _autoCreateCashSafe = value;
                        if (value) {
                          _selectedCashSafeBoxId =
                              0; // main (treated as NULL server-side)
                        }
                      });
                    },
                    title: Text(
                      isAr
                          ? 'إنشاء خزنة نقدية خاصة للموظف تلقائياً'
                          : 'Auto-create dedicated cash safe',
                    ),
                  ),
                ],
                DropdownButtonFormField<int>(
                  value: _selectedCashSafeBoxId,
                  decoration: InputDecoration(
                    labelText: isAr ? 'خزنة النقد' : 'Cash Safe',
                    prefixIcon: const Icon(Icons.point_of_sale),
                  ),
                  items: <DropdownMenuItem<int>>[
                    DropdownMenuItem(
                      value: 0,
                      child: Text(
                        isAr ? 'الخزنة الرئيسية (افتراضي)' : 'Main (default)',
                      ),
                    ),
                    ..._cashSafes
                        .where((s) => (s.id ?? 0) > 0)
                        .map(
                          (s) => DropdownMenuItem(
                            value: s.id!,
                            child: Text(s.name),
                          ),
                        ),
                  ],
                  onChanged:
                      (_loadingCashSafes ||
                          (widget.employee == null && _autoCreateCashSafe))
                      ? null
                      : (value) {
                          setState(() {
                            _selectedCashSafeBoxId = value ?? 0;
                            if ((value ?? 0) > 0) {
                              _autoCreateCashSafe = false;
                            }
                          });
                        },
                ),
                const SizedBox(height: 12),

                // Gold safe selection + optional auto-create (create only)
                if (widget.employee == null) ...[
                  SwitchListTile(
                    value: _autoCreateGoldSafe,
                    onChanged: (value) {
                      setState(() {
                        _autoCreateGoldSafe = value;
                        if (value) {
                          _selectedGoldSafeBoxId =
                              0; // main (treated as NULL server-side)
                        }
                      });
                    },
                    title: Text(
                      isAr
                          ? 'إنشاء خزنة ذهب خاصة للموظف تلقائياً'
                          : 'Auto-create dedicated gold safe',
                    ),
                  ),
                ],
                DropdownButtonFormField<int>(
                  value: _selectedGoldSafeBoxId,
                  decoration: InputDecoration(
                    labelText: isAr ? 'خزنة الذهب' : 'Gold Safe',
                    prefixIcon: const Icon(Icons.diamond),
                  ),
                  items: <DropdownMenuItem<int>>[
                    DropdownMenuItem(
                      value: 0,
                      child: Text(
                        isAr ? 'الخزنة الرئيسية (افتراضي)' : 'Main (default)',
                      ),
                    ),
                    ..._goldSafes
                        .where((s) => (s.id ?? 0) > 0)
                        .map(
                          (s) => DropdownMenuItem(
                            value: s.id!,
                            child: Text(s.name),
                          ),
                        ),
                  ],
                  onChanged:
                      (_loadingGoldSafes ||
                          (widget.employee == null && _autoCreateGoldSafe))
                      ? null
                      : (value) {
                          setState(() {
                            _selectedGoldSafeBoxId = value ?? 0;
                            if ((value ?? 0) > 0) {
                              _autoCreateGoldSafe = false;
                            }
                          });
                        },
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

// ═══════════════════════════════════════════════════════════════
// 🎯 بطاقة أهداف الأداء الشخصية
// ═══════════════════════════════════════════════════════════════
class _GoalSettingsTile extends StatefulWidget {
  final EmployeeModel employee;
  final bool isArabic;
  final ApiService api;
  final ValueChanged<EmployeeModel> onSaved;
  const _GoalSettingsTile({
    required this.employee,
    required this.isArabic,
    required this.api,
    required this.onSaved,
  });
  @override
  State<_GoalSettingsTile> createState() => _GoalSettingsTileState();
}

class _GoalSettingsTileState extends State<_GoalSettingsTile> {
  bool _editing = false;
  bool _saving  = false;

  late String _metric;
  late TextEditingController _nameCtrl;
  // Monthly
  late TextEditingController _monthlyCtrl;
  late TextEditingController _bonusMonthlyCtrl;
  String _rewardTypeMonthly = 'fixed';
  int? _bonusRuleIdMonthly;
  bool _monthlyEnabled = true;
  // Weekly
  late TextEditingController _weeklyCtrl;
  late TextEditingController _bonusWeeklyCtrl;
  String _rewardTypeWeekly = 'fixed';
  int? _bonusRuleIdWeekly;
  bool _weeklyEnabled = true;
  // Daily
  late TextEditingController _dailyCtrl;
  late TextEditingController _bonusDailyCtrl;
  String _rewardTypeDaily = 'fixed';
  int? _bonusRuleIdDaily;
  bool _dailyEnabled = false;

  List<Map<String, dynamic>> _bonusRules = [];

  static const _gold = Color(0xFFD4AF37);

  @override
  void initState() { super.initState(); _init(); }

  void _init() {
    final e = widget.employee;
    _metric              = e.goalMetric ?? 'weight';
    _nameCtrl            = TextEditingController(text: e.goalName ?? '');
    _monthlyCtrl         = TextEditingController(text: _monthly(e)?.toString() ?? '');
    _weeklyCtrl          = TextEditingController(text: _weekly(e)?.toString() ?? '');
    _dailyCtrl           = TextEditingController(text: _daily(e)?.toString() ?? '');
    _bonusMonthlyCtrl    = TextEditingController(text: e.goalBonusMonthly?.toString() ?? '');
    _bonusWeeklyCtrl     = TextEditingController(text: e.goalBonusWeekly?.toString() ?? '');
    _bonusDailyCtrl      = TextEditingController(text: e.goalBonusDaily?.toString() ?? '');
    _monthlyEnabled      = e.goalMonthlyEnabled;
    _weeklyEnabled       = e.goalWeeklyEnabled;
    _dailyEnabled        = e.goalDailyEnabled;
    _rewardTypeMonthly   = e.goalRewardTypeMonthly;
    _rewardTypeWeekly    = e.goalRewardTypeWeekly;
    _rewardTypeDaily     = e.goalRewardTypeDaily;
    _bonusRuleIdMonthly  = e.goalBonusRuleIdMonthly;
    _bonusRuleIdWeekly   = e.goalBonusRuleIdWeekly;
    _bonusRuleIdDaily    = e.goalBonusRuleIdDaily;
  }

  Future<void> _loadBonusRules() async {
    try {
      final rules = await widget.api.getBonusRules(isActive: true);
      if (mounted) {
        setState(() {
          _bonusRules = rules.whereType<Map<String, dynamic>>().toList();
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.isArabic
              ? 'تعذّر تحميل قواعد المكافآت: $e'
              : 'Failed to load bonus rules: $e'),
          backgroundColor: Colors.red.shade700,
        ));
      }
    }
  }

  num? _monthly(EmployeeModel e) => switch (e.goalMetric ?? 'weight') {
    'points'   => e.goalPointsMonthly,
    'invoices' => e.goalInvoicesMonthly,
    _          => e.goalWeightMonthly,
  };
  num? _weekly(EmployeeModel e) => switch (e.goalMetric ?? 'weight') {
    'points'   => e.goalPointsWeekly,
    'invoices' => e.goalInvoicesWeekly,
    _          => e.goalWeightWeekly,
  };
  num? _daily(EmployeeModel e) => switch (e.goalMetric ?? 'weight') {
    'points'   => e.goalPointsDaily,
    'invoices' => e.goalInvoicesDaily,
    _          => e.goalWeightDaily,
  };

  @override
  void dispose() {
    _nameCtrl.dispose(); _monthlyCtrl.dispose(); _weeklyCtrl.dispose();
    _dailyCtrl.dispose(); _bonusMonthlyCtrl.dispose();
    _bonusWeeklyCtrl.dispose(); _bonusDailyCtrl.dispose();
    super.dispose();
  }

  String _metricLabel(String m) => switch (m) {
    'points'   => widget.isArabic ? 'نقاط' : 'Points',
    'invoices' => widget.isArabic ? 'فواتير' : 'Invoices',
    _          => widget.isArabic ? 'وزن (جم)' : 'Weight (g)',
  };
  String _unit(String m) => switch (m) {
    'points'   => widget.isArabic ? 'نقطة' : 'pts',
    'invoices' => widget.isArabic ? 'فاتورة' : 'inv',
    _          => 'g',
  };

  Future<void> _save() async {
    if (widget.employee.id == null) return;
    setState(() => _saving = true);
    try {
      final monthly = double.tryParse(_monthlyCtrl.text.trim());
      final weekly  = double.tryParse(_weeklyCtrl.text.trim());
      final daily   = double.tryParse(_dailyCtrl.text.trim());
      final payload = <String, dynamic>{
        'goal_metric': _metric,
        'goal_name': _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text.trim(),
        // Targets
        if (_metric == 'weight') ...{
          'goal_weight_monthly': monthly,
          'goal_weight_weekly':  weekly,
          'goal_weight_daily':   daily,
        } else if (_metric == 'points') ...{
          'goal_points_monthly': monthly,
          'goal_points_weekly':  weekly,
          'goal_points_daily':   daily,
        } else ...{
          'goal_invoices_monthly': monthly?.toInt(),
          'goal_invoices_weekly':  weekly?.toInt(),
          'goal_invoices_daily':   daily?.toInt(),
        },
        // Enable/disable per period
        'goal_monthly_enabled': _monthlyEnabled,
        'goal_weekly_enabled':  _weeklyEnabled,
        'goal_daily_enabled':   _dailyEnabled,
        // Bonus amount (fixed)
        'goal_bonus_monthly': double.tryParse(_bonusMonthlyCtrl.text.trim()),
        'goal_bonus_weekly':  double.tryParse(_bonusWeeklyCtrl.text.trim()),
        'goal_bonus_daily':   double.tryParse(_bonusDailyCtrl.text.trim()),
        // Reward type
        'goal_reward_type_monthly': _rewardTypeMonthly,
        'goal_reward_type_weekly':  _rewardTypeWeekly,
        'goal_reward_type_daily':   _rewardTypeDaily,
        // Bonus rule IDs
        'goal_bonus_rule_id_monthly': _bonusRuleIdMonthly,
        'goal_bonus_rule_id_weekly':  _bonusRuleIdWeekly,
        'goal_bonus_rule_id_daily':   _bonusRuleIdDaily,
      };
      final res = await widget.api.updateEmployeeGoals(widget.employee.id!, payload);
      final updated = EmployeeModel.fromJson(res['employee'] as Map<String, dynamic>);
      widget.onSaved(updated);
      setState(() => _editing = false);
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(widget.isArabic ? 'خطأ في الحفظ' : 'Save Error'),
            content: Text(e.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final e    = widget.employee;
    final hasGoal = e.goalMetric != null && (_monthly(e) != null || _weekly(e) != null || _daily(e) != null);

    return Card(
      elevation: 0,
      color: _gold.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: _gold.withValues(alpha: 0.35)),
      ),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── رأس البطاقة ──
          Row(children: [
            const Icon(Icons.flag_rounded, color: _gold, size: 18),
            const SizedBox(width: 8),
            Text(
              isAr ? 'الهدف الشخصي' : 'Personal Goal',
              style: const TextStyle(fontWeight: FontWeight.w700, color: _gold, fontSize: 13.5),
            ),
            const Spacer(),
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () {
                if (_editing) {
                  // إلغاء
                  _nameCtrl.dispose(); _monthlyCtrl.dispose(); _weeklyCtrl.dispose();
                  _dailyCtrl.dispose(); _bonusMonthlyCtrl.dispose();
                  _bonusWeeklyCtrl.dispose(); _bonusDailyCtrl.dispose();
                  _init();
                } else {
                  _loadBonusRules();
                }
                setState(() => _editing = !_editing);
              },
              child: Text(_editing ? (isAr ? 'إلغاء' : 'Cancel') : (isAr ? 'تعديل' : 'Edit')),
            ),
          ]),
          // ── عرض الهدف ──
          if (!_editing) ...[
            const SizedBox(height: 8),
            if (!hasGoal)
              Text(isAr ? 'لم يُحدَّد هدف. اضغط تعديل.' : 'No goal set. Tap Edit.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600))
            else ...[
              Text('${_metricLabel(e.goalMetric!)}${e.goalName != null ? "  ·  ${e.goalName}" : ""}',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 4, children: [
                if (e.goalDailyEnabled && _daily(e) != null)   _chip(isAr ? 'يومي' : 'Daily',     '${_daily(e)} ${_unit(e.goalMetric!)}'),
                if (e.goalWeeklyEnabled && _weekly(e) != null)  _chip(isAr ? 'أسبوعي' : 'Weekly',  '${_weekly(e)} ${_unit(e.goalMetric!)}'),
                if (e.goalMonthlyEnabled && _monthly(e) != null) _chip(isAr ? 'شهري' : 'Monthly',   '${_monthly(e)} ${_unit(e.goalMetric!)}'),
                if ((e.goalBonusDaily ?? 0) > 0 && e.goalDailyEnabled)     _chip(isAr ? 'مكافأة/يوم' : 'Bonus/Day', '${e.goalBonusDaily} ر.س'),
                if ((e.goalBonusWeekly ?? 0) > 0 && e.goalWeeklyEnabled)   _chip(isAr ? 'مكافأة/أسبوع' : 'Bonus/Wk', '${e.goalBonusWeekly} ر.س'),
                if ((e.goalBonusMonthly ?? 0) > 0 && e.goalMonthlyEnabled) _chip(isAr ? 'مكافأة/شهر' : 'Bonus/Mo', '${e.goalBonusMonthly} ر.س'),
              ]),
            ],
          ],
          // ── نموذج التعديل ──
          if (_editing) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _metric,
              decoration: InputDecoration(
                labelText: isAr ? 'نوع الهدف' : 'Goal Type',
                border: const OutlineInputBorder(), isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              items: [
                DropdownMenuItem(value: 'weight',   child: Text(isAr ? 'وزن مبيعات (جم)' : 'Sales Weight (g)')),
                DropdownMenuItem(value: 'points',   child: Text(isAr ? 'نقاط الأداء' : 'Performance Points')),
                DropdownMenuItem(value: 'invoices', child: Text(isAr ? 'عدد الفواتير' : 'Invoice Count')),
              ],
              onChanged: (v) => setState(() => _metric = v ?? 'weight'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: isAr ? 'عنوان الهدف (يظهر في الاحتفالية)' : 'Goal title (shown in celebration)',
                border: const OutlineInputBorder(), isDense: true,
              ),
            ),
            const SizedBox(height: 14),
            // ── الأهداف لكل فترة ──
            ..._buildPeriodSection(isAr, 'monthly', isAr ? 'الهدف الشهري' : 'Monthly Goal', _monthlyCtrl, _bonusMonthlyCtrl,
              _monthlyEnabled, (v) => setState(() => _monthlyEnabled = v),
              _rewardTypeMonthly, (v) {
                setState(() => _rewardTypeMonthly = v);
                if (v == 'rule' && _bonusRules.isEmpty) _loadBonusRules();
              },
              _bonusRuleIdMonthly, (v) => setState(() => _bonusRuleIdMonthly = v),
            ),
            ..._buildPeriodSection(isAr, 'weekly', isAr ? 'الهدف الأسبوعي' : 'Weekly Goal', _weeklyCtrl, _bonusWeeklyCtrl,
              _weeklyEnabled, (v) => setState(() => _weeklyEnabled = v),
              _rewardTypeWeekly, (v) {
                setState(() => _rewardTypeWeekly = v);
                if (v == 'rule' && _bonusRules.isEmpty) _loadBonusRules();
              },
              _bonusRuleIdWeekly, (v) => setState(() => _bonusRuleIdWeekly = v),
            ),
            ..._buildPeriodSection(isAr, 'daily', isAr ? 'الهدف اليومي' : 'Daily Goal', _dailyCtrl, _bonusDailyCtrl,
              _dailyEnabled, (v) => setState(() => _dailyEnabled = v),
              _rewardTypeDaily, (v) {
                setState(() => _rewardTypeDaily = v);
                if (v == 'rule' && _bonusRules.isEmpty) _loadBonusRules();
              },
              _bonusRuleIdDaily, (v) => setState(() => _bonusRuleIdDaily = v),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save_rounded, size: 18),
                label: Text(isAr ? 'حفظ الهدف' : 'Save Goal'),
                style: FilledButton.styleFrom(backgroundColor: _gold),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  List<Widget> _buildPeriodSection(
    bool isAr,
    String period,
    String title,
    TextEditingController targetCtrl,
    TextEditingController bonusCtrl,
    bool enabled,
    ValueChanged<bool> onEnabledChanged,
    String rewardType,
    ValueChanged<String> onRewardTypeChanged,
    int? bonusRuleId,
    ValueChanged<int?> onRuleIdChanged,
  ) {
    return [
      SwitchListTile.adaptive(
        value: enabled,
        onChanged: onEnabledChanged,
        activeColor: _gold,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        contentPadding: EdgeInsets.zero,
        dense: true,
      ),
      if (enabled) ...[
        TextField(
          controller: targetCtrl,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: isAr ? 'قيمة الهدف' : 'Target Value',
            suffixText: _unit(_metric),
            border: const OutlineInputBorder(), isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Text(isAr ? 'المكافأة:' : 'Reward:', style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(width: 8),
          _rewardTypeBtn(isAr ? 'مبلغ ثابت' : 'Fixed', 'fixed', rewardType, onRewardTypeChanged),
          const SizedBox(width: 6),
          _rewardTypeBtn(isAr ? 'قاعدة مكافأة' : 'Bonus Rule', 'rule', rewardType, onRewardTypeChanged),
        ]),
        const SizedBox(height: 8),
        if (rewardType == 'fixed')
          TextField(
            controller: bonusCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: isAr ? 'مبلغ المكافأة (ر.س)' : 'Bonus Amount (SAR)',
              prefixIcon: const Icon(Icons.monetization_on_outlined, size: 18),
              border: const OutlineInputBorder(), isDense: true,
            ),
          )
        else
          DropdownButtonFormField<int?>(
            value: _bonusRules.any((r) => r['id'] == bonusRuleId) ? bonusRuleId : null,
            decoration: InputDecoration(
              labelText: isAr ? 'اختر قاعدة المكافأة' : 'Select Bonus Rule',
              border: const OutlineInputBorder(), isDense: true,
            ),
            items: [
              DropdownMenuItem<int?>(value: null, child: Text(isAr ? '— لا شيء —' : '— None —')),
              ..._bonusRules.map((r) => DropdownMenuItem<int?>(
                value: r['id'] as int?,
                child: Text(r['name']?.toString() ?? ''),
              )),
            ],
            onChanged: onRuleIdChanged,
          ),
        const SizedBox(height: 10),
      ],
    ];
  }

  Widget _rewardTypeBtn(String label, String value, String current, ValueChanged<String> onChange) {
    final selected = current == value;
    return GestureDetector(
      onTap: () => onChange(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? _gold : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? _gold : Colors.grey.shade400),
        ),
        child: Text(label, style: TextStyle(
          fontSize: 11.5, fontWeight: FontWeight.w600,
          color: selected ? Colors.white : Colors.grey.shade700,
        )),
      ),
    );
  }

  Widget _chip(String label, String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: _gold.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _gold.withValues(alpha: 0.3)),
    ),
    child: Text('$label: $value',
        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFF8B6914))),
  );
}
