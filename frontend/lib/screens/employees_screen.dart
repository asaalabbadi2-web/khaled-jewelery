import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/employee_model.dart';

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

  Future<void> _deleteEmployee(EmployeeModel employee) async {
    final isAr = widget.isArabic;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(isAr ? 'حذف الموظف' : 'Delete Employee'),
          content: Text(
            isAr
                ? 'هل أنت متأكد من حذف ${employee.name}؟'
                : 'Are you sure you want to delete ${employee.name}?',
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
        );
      },
    );

    if (confirm != true) return;

    try {
      await widget.api.deleteEmployee(employee.id ?? 0);
      setState(() {
        _employees.removeWhere((e) => e.id == employee.id);
      });
      _showSnack(isAr ? 'تم حذف الموظف' : 'Employee deleted');
    } catch (e) {
      _showSnack(e.toString(), isError: true);
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
                          color: employee.isActive ? Colors.green : Colors.red,
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
                TextButton.icon(
                  icon: const Icon(Icons.edit),
                  label: Text(isAr ? 'تعديل البيانات' : 'Edit Employee'),
                  onPressed: () {
                    Navigator.of(context).pop();
                    _openEmployeeForm(employee: employee);
                  },
                ),
              ],
            ),
          ),
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
                                    } else if (value == 'delete') {
                                      _deleteEmployee(employee);
                                    }
                                  },
                                  itemBuilder: (context) => [
                                    PopupMenuItem(
                                      value: 'edit',
                                      child: Text(isAr ? 'تعديل' : 'Edit'),
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
