import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/attendance_model.dart';

class AttendanceScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  const AttendanceScreen({super.key, required this.api, this.isArabic = true});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  List<AttendanceModel> _records = [];
  bool _loading = false;
  DateTime? _startDate;
  DateTime? _endDate;
  int? _employeeIdFilter;
  String? _statusFilter;
  final TextEditingController _employeeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadAttendance();
  }

  @override
  void dispose() {
    _employeeController.dispose();
    super.dispose();
  }

  Future<void> _loadAttendance() async {
    setState(() => _loading = true);
    try {
      final records = await widget.api.getAttendance(
        employeeId: _employeeIdFilter,
        startDate: _startDate,
        endDate: _endDate,
        status: _statusFilter,
      );
      setState(() => _records = records);
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
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

  Future<void> _openForm({AttendanceModel? record}) async {
    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (context) =>
          AttendanceFormDialog(isArabic: widget.isArabic, record: record),
    );

    if (result == null) return;

    try {
      if (record == null) {
        final created = await widget.api.createAttendance(result);
        setState(() => _records.insert(0, created));
        _showSnack(
          widget.isArabic ? 'تم إنشاء سجل الحضور' : 'Attendance created',
        );
      } else {
        final updated = await widget.api.updateAttendance(
          record.id ?? 0,
          result,
        );
        setState(() {
          final index = _records.indexWhere((r) => r.id == record.id);
          if (index != -1) {
            _records[index] = updated;
          }
        });
        _showSnack(
          widget.isArabic ? 'تم تحديث سجل الحضور' : 'Attendance updated',
        );
      }
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  Future<void> _deleteRecord(AttendanceModel record) async {
    final isAr = widget.isArabic;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isAr ? 'حذف سجل حضور' : 'Delete Attendance'),
        content: Text(
          isAr
              ? 'هل تريد حذف سجل ${record.attendanceDate.toString().split(' ').first}؟'
              : 'Delete attendance on ${record.attendanceDate.toString().split(' ').first}?',
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
      await widget.api.deleteAttendance(record.id ?? 0);
      setState(() => _records.removeWhere((r) => r.id == record.id));
      _showSnack(isAr ? 'تم حذف السجل' : 'Record deleted');
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _startDate != null && _endDate != null
          ? DateTimeRange(start: _startDate!, end: _endDate!)
          : null,
    );

    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
      _loadAttendance();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'سجلات الحضور' : 'Attendance Records'),
        actions: [
          IconButton(
            onPressed: _loadAttendance,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            onPressed: _pickDateRange,
            icon: const Icon(Icons.date_range),
          ),
          PopupMenuButton<String?>(
            icon: const Icon(Icons.filter_alt),
            onSelected: (value) {
              setState(() => _statusFilter = value);
              _loadAttendance();
            },
            itemBuilder: (context) => const [
              PopupMenuItem<String?>(value: null, child: Text('All')),
              PopupMenuItem<String?>(value: 'present', child: Text('Present')),
              PopupMenuItem<String?>(value: 'absent', child: Text('Absent')),
              PopupMenuItem<String?>(value: 'late', child: Text('Late')),
              PopupMenuItem<String?>(
                value: 'on_leave',
                child: Text('On Leave'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add_task),
        label: Text(isAr ? 'سجل جديد' : 'New Record'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _employeeController,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.person_search),
                      hintText: isAr ? 'معرّف الموظف...' : 'Employee ID...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    keyboardType: TextInputType.number,
                    onSubmitted: (_) {
                      setState(() {
                        _employeeIdFilter =
                            _employeeController.text.trim().isEmpty
                            ? null
                            : int.tryParse(_employeeController.text.trim());
                      });
                      _loadAttendance();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: () {
                    setState(() {
                      _employeeIdFilter =
                          _employeeController.text.trim().isEmpty
                          ? null
                          : int.tryParse(_employeeController.text.trim());
                    });
                    _loadAttendance();
                  },
                  icon: const Icon(Icons.search),
                  label: Text(isAr ? 'بحث' : 'Search'),
                ),
              ],
            ),
          ),
          if (_startDate != null && _endDate != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Chip(
                    label: Text(
                      '${_startDate!.toString().split(' ').first} → ${_endDate!.toString().split(' ').first}',
                    ),
                    deleteIcon: const Icon(Icons.clear),
                    onDeleted: () {
                      setState(() {
                        _startDate = null;
                        _endDate = null;
                      });
                      _loadAttendance();
                    },
                  ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _records.isEmpty
                ? Center(
                    child: Text(
                      isAr ? 'لا توجد سجلات حضور' : 'No attendance records',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colorScheme.primary,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _records.length,
                    itemBuilder: (context, index) {
                      final record = _records[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        child: ListTile(
                          onTap: () => _openForm(record: record),
                          leading: CircleAvatar(
                            backgroundColor: colorScheme.primary,
                            child: Icon(
                              Icons.today,
                              color: colorScheme.onPrimary,
                            ),
                          ),
                          title: Text(
                            '${record.attendanceDate.toString().split(' ').first} - ${record.employee?.name ?? '#${record.employeeId}'}',
                            style: theme.textTheme.titleMedium,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${isAr ? 'الحالة' : 'Status'}: ${record.status}',
                              ),
                              if (record.checkInTime != null)
                                Text(
                                  '${isAr ? 'دخول' : 'In'}: ${record.checkInTime!.toIso8601String().split('T').last.substring(0, 5)}',
                                ),
                              if (record.checkOutTime != null)
                                Text(
                                  '${isAr ? 'خروج' : 'Out'}: ${record.checkOutTime!.toIso8601String().split('T').last.substring(0, 5)}',
                                ),
                            ],
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'edit') {
                                _openForm(record: record);
                              } else if (value == 'delete') {
                                _deleteRecord(record);
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
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class AttendanceFormDialog extends StatefulWidget {
  final bool isArabic;
  final AttendanceModel? record;
  const AttendanceFormDialog({super.key, required this.isArabic, this.record});

  @override
  State<AttendanceFormDialog> createState() => _AttendanceFormDialogState();
}

class _AttendanceFormDialogState extends State<AttendanceFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _employeeIdController;
  late final TextEditingController _dateController;
  late final TextEditingController _checkInController;
  late final TextEditingController _checkOutController;
  late final TextEditingController _notesController;
  String _status = 'present';

  @override
  void initState() {
    super.initState();
    final record = widget.record;
    _employeeIdController = TextEditingController(
      text: record?.employeeId.toString() ?? '',
    );
    _dateController = TextEditingController(
      text: record != null
          ? record.attendanceDate.toIso8601String().split('T').first
          : '',
    );
    _checkInController = TextEditingController(
      text: record?.checkInTime != null
          ? record!.checkInTime!
                .toIso8601String()
                .split('T')
                .last
                .substring(0, 5)
          : '',
    );
    _checkOutController = TextEditingController(
      text: record?.checkOutTime != null
          ? record!.checkOutTime!
                .toIso8601String()
                .split('T')
                .last
                .substring(0, 5)
          : '',
    );
    _notesController = TextEditingController(text: record?.notes ?? '');
    _status = record?.status ?? 'present';
  }

  @override
  void dispose() {
    _employeeIdController.dispose();
    _dateController.dispose();
    _checkInController.dispose();
    _checkOutController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    final payload = <String, dynamic>{
      'employee_id': int.tryParse(_employeeIdController.text.trim()),
      'attendance_date': _dateController.text.trim(),
      'check_in_time': _checkInController.text.trim().isEmpty
          ? null
          : _checkInController.text.trim(),
      'check_out_time': _checkOutController.text.trim().isEmpty
          ? null
          : _checkOutController.text.trim(),
      'status': _status,
      'notes': _notesController.text.trim().isEmpty
          ? null
          : _notesController.text.trim(),
    }..removeWhere((key, value) => value == null);

    Navigator.of(context).pop(payload);
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    return AlertDialog(
      title: Text(
        widget.record == null
            ? (isAr ? 'سجل حضور جديد' : 'New Attendance Record')
            : (isAr ? 'تعديل سجل الحضور' : 'Edit Attendance Record'),
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
                  controller: _employeeIdController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'معرّف الموظف' : 'Employee ID',
                  ),
                  keyboardType: TextInputType.number,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return isAr ? 'المعرف مطلوب' : 'Employee ID required';
                    }
                    return null;
                  },
                ),
                TextFormField(
                  controller: _dateController,
                  decoration: InputDecoration(
                    labelText: isAr
                        ? 'تاريخ الحضور (YYYY-MM-DD)'
                        : 'Date (YYYY-MM-DD)',
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return isAr ? 'التاريخ مطلوب' : 'Date required';
                    }
                    return null;
                  },
                ),
                TextFormField(
                  controller: _checkInController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'وقت الدخول (HH:MM)' : 'Check-in (HH:MM)',
                  ),
                ),
                TextFormField(
                  controller: _checkOutController,
                  decoration: InputDecoration(
                    labelText: isAr
                        ? 'وقت الخروج (HH:MM)'
                        : 'Check-out (HH:MM)',
                  ),
                ),
                DropdownButtonFormField<String>(
                  value: _status,
                  items: const [
                    DropdownMenuItem(value: 'present', child: Text('Present')),
                    DropdownMenuItem(value: 'absent', child: Text('Absent')),
                    DropdownMenuItem(value: 'late', child: Text('Late')),
                    DropdownMenuItem(
                      value: 'on_leave',
                      child: Text('On Leave'),
                    ),
                  ],
                  onChanged: (value) =>
                      setState(() => _status = value ?? 'present'),
                  decoration: InputDecoration(
                    labelText: isAr ? 'الحالة' : 'Status',
                  ),
                ),
                TextFormField(
                  controller: _notesController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'ملاحظات' : 'Notes',
                  ),
                  maxLines: 2,
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
