import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_service.dart';
import '../models/bonus_rule_model.dart';
import '../models/employee_model.dart';
import '../models/invoice_type_model.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';

class BonusRulesScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  final bool embedded;

  const BonusRulesScreen({
    super.key,
    required this.api,
    this.isArabic = true,
    this.embedded = false,
  });

  @override
  State<BonusRulesScreen> createState() => _BonusRulesScreenState();
}

class _BonusRulesScreenState extends State<BonusRulesScreen> {
  List<BonusRuleModel> _rules = [];
  bool _loading = false;
  bool? _activeFilter;

  @override
  void initState() {
    super.initState();
    _loadRules();
  }

  Future<void> _loadRules() async {
    setState(() => _loading = true);
    try {
      final data = await widget.api.getBonusRules(isActive: _activeFilter);
      if (!mounted) return;
      final rules = data
          .map((json) => BonusRuleModel.fromJson(json as Map<String, dynamic>))
          .toList();
      setState(() => _rules = rules);
    } catch (e) {
      if (mounted) _showSnack(e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
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

  void _showRuleDialog({BonusRuleModel? rule}) {
    showDialog(
      context: context,
      builder: (ctx) => _BonusRuleDialog(
        api: widget.api,
        isArabic: widget.isArabic,
        rule: rule,
        onSaved: () {
          _loadRules();
          Navigator.of(ctx).pop();
        },
      ),
    );
  }

  Future<void> _deleteRule(BonusRuleModel rule) async {
    final isAr = widget.isArabic;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isAr ? 'تأكيد الحذف' : 'Confirm Delete'),
        content: Text(
          isAr
              ? 'هل أنت متأكد من حذف قاعدة "${rule.name}"؟'
              : 'Are you sure you want to delete rule "${rule.name}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isAr ? 'حذف' : 'Delete'),
          ),
        ],
      ),
    );

    if (confirm == true && rule.id != null) {
      try {
        await widget.api.deleteBonusRule(rule.id!);
        if (!mounted) return;
        _showSnack(isAr ? 'تم الحذف بنجاح' : 'Deleted successfully');
        _loadRules();
      } catch (e) {
        if (mounted) _showSnack(e.toString(), isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final content = _loading
        ? const Center(child: CircularProgressIndicator())
        : _rules.isEmpty
        ? Center(
            child: Text(
              isAr ? 'لا توجد قواعد مكافآت' : 'No bonus rules',
              style: const TextStyle(fontSize: 18, color: Colors.grey),
            ),
          )
        : ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _rules.length,
            itemBuilder: (ctx, i) => _buildRuleCard(_rules[i]),
          );

    final body = widget.embedded
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildEmbeddedHeader(isAr),
              Expanded(child: content),
            ],
          )
        : content;

    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(isAr ? 'قواعد المكافآت' : 'Bonus Rules'),
              centerTitle: true,
              actions: _buildAppBarActions(isAr),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showRuleDialog(),
        icon: const Icon(Icons.add),
        label: Text(isAr ? 'إضافة قاعدة' : 'Add Rule'),
      ),
      body: SafeArea(top: widget.embedded, bottom: false, child: body),
    );
  }

  List<Widget> _buildAppBarActions(bool isAr) {
    return [
      IconButton(icon: const Icon(Icons.refresh), onPressed: _loadRules),
      PopupMenuButton<bool?>(
        icon: const Icon(Icons.filter_list),
        onSelected: (value) {
          setState(() => _activeFilter = value);
          _loadRules();
        },
        itemBuilder: (ctx) => [
          PopupMenuItem(value: null, child: Text(isAr ? 'الكل' : 'All')),
          PopupMenuItem(
            value: true,
            child: Text(isAr ? 'نشطة فقط' : 'Active Only'),
          ),
          PopupMenuItem(
            value: false,
            child: Text(isAr ? 'غير نشطة فقط' : 'Inactive Only'),
          ),
        ],
      ),
    ];
  }

  Widget _buildEmbeddedHeader(bool isAr) {
    if (!widget.embedded) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Text(
            isAr ? 'قواعد المكافآت' : 'Bonus Rules',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          ..._buildAppBarActions(isAr),
        ],
      ),
    );
  }

  Widget _buildRuleCard(BonusRuleModel rule) {
    final isAr = widget.isArabic;
    final dateFormat = DateFormat('yyyy-MM-dd');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      child: ExpansionTile(
        leading: Icon(
          rule.isActive ? Icons.check_circle : Icons.cancel,
          color: rule.isActive ? Colors.green : Colors.grey,
        ),
        title: Text(
          rule.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${BonusRuleModel.getRuleTypeNameAr(rule.ruleType)} - ${BonusRuleModel.getBonusTypeNameAr(rule.bonusType)}',
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (rule.description != null) ...[
                  Text(
                    isAr ? 'الوصف:' : 'Description:',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(rule.description!),
                  const SizedBox(height: 12),
                ],
                _buildInfoRow(
                  isAr ? 'القيمة:' : 'Value:',
                  '${rule.bonusValue}',
                ),
                _buildInfoRow(
                  isAr ? 'الحد الأدنى:' : 'Min:',
                  '${rule.minBonus}',
                ),
                if (rule.maxBonus != null)
                  _buildInfoRow(
                    isAr ? 'الحد الأقصى:' : 'Max:',
                    '${rule.maxBonus}',
                  ),
                if (rule.validFrom != null)
                  _buildInfoRow(
                    isAr ? 'من تاريخ:' : 'From:',
                    dateFormat.format(rule.validFrom!),
                  ),
                if (rule.validTo != null)
                  _buildInfoRow(
                    isAr ? 'إلى تاريخ:' : 'To:',
                    dateFormat.format(rule.validTo!),
                  ),
                if (rule.targetDepartments != null &&
                    rule.targetDepartments!.isNotEmpty)
                  _buildInfoRow(
                    isAr ? 'الأقسام:' : 'Departments:',
                    rule.targetDepartments!.join(', '),
                  ),
                if (rule.targetPositions != null &&
                    rule.targetPositions!.isNotEmpty)
                  _buildInfoRow(
                    isAr ? 'الوظائف:' : 'Positions:',
                    rule.targetPositions!.join(', '),
                  ),
                if (rule.isPointsBased) ...[
                  _buildInfoRow(
                    isAr ? 'فترة النقاط:' : 'Points period:',
                    BonusRuleModel.getPointsPeriodNameAr(
                      (rule.conditions?['points_period'] as String?) ?? 'month',
                    ),
                  ),
                  if (rule.conditions?['min_points'] != null)
                    _buildInfoRow(
                      isAr ? 'حد أدنى نقاط:' : 'Min points:',
                      '${rule.conditions!['min_points']}',
                    ),
                ],
                if (rule.targetEmployeeIds != null &&
                    rule.targetEmployeeIds!.isNotEmpty)
                  _buildInfoRow(
                    isAr ? 'الموظفين:' : 'Employees:',
                    rule.targetEmployeeIds!.map((id) => '#$id').join(', '),
                  ),
                if (rule.applicableInvoiceTypes != null &&
                    rule.applicableInvoiceTypes!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isAr ? 'أنواع الفواتير:' : 'Invoice Types:',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: rule.applicableInvoiceTypes!
                              .map(
                                (type) => Chip(
                                  label: Text(
                                    type,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  backgroundColor: const Color(
                                    0xFFD4AF37,
                                  ).withValues(alpha: 0.2),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () => _showRuleDialog(rule: rule),
                      icon: const Icon(Icons.edit, size: 18),
                      label: Text(isAr ? 'تعديل' : 'Edit'),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: () => _deleteRule(rule),
                      icon: const Icon(
                        Icons.delete,
                        size: 18,
                        color: Colors.red,
                      ),
                      label: Text(
                        isAr ? 'حذف' : 'Delete',
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

// Dialog for adding/editing bonus rules
class _BonusRuleDialog extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  final BonusRuleModel? rule;
  final VoidCallback onSaved;

  const _BonusRuleDialog({
    required this.api,
    required this.isArabic,
    this.rule,
    required this.onSaved,
  });

  @override
  State<_BonusRuleDialog> createState() => _BonusRuleDialogState();
}

class _BonusRuleDialogState extends State<_BonusRuleDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _descController;
  late TextEditingController _valueController;
  late TextEditingController _minController;
  late TextEditingController _maxController;
  late TextEditingController _minSalesController;
  late TextEditingController _minProfitController;
  late TextEditingController _minAttendanceController;
  late TextEditingController _profitPercentInvoiceController;
  late TextEditingController _minPointsController;

  String _selectedRuleType = 'sales_target';
  String _selectedBonusType = 'percentage';
  String _selectedPointsPeriod = 'month';
  bool _isActive = true;
  DateTime? _validFrom;
  DateTime? _validTo;
  bool _saving = false;

  // 🆕 للموظفين وأنواع الفواتير
  List<EmployeeModel> _allEmployees = [];
  List<int> _selectedEmployeeIds = [];
  List<InvoiceTypeModel> _availableInvoiceTypes = [];
  List<String> _selectedInvoiceTypes = [];
  bool _loadingData = false;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _nameController = TextEditingController(text: rule?.name ?? '');
    _descController = TextEditingController(text: rule?.description ?? '');
    _valueController = TextEditingController(
      text: rule?.bonusValue.toString() ?? '0',
    );
    _minController = TextEditingController(
      text: rule?.minBonus.toString() ?? '0',
    );
    _maxController = TextEditingController(
      text: rule?.maxBonus?.toString() ?? '',
    );
    _minSalesController = TextEditingController(
      text: rule?.conditions != null && rule!.conditions!['min_sales'] != null
          ? rule.conditions!['min_sales'].toString()
          : '',
    );
    _minProfitController = TextEditingController(
      text: rule?.conditions != null && rule!.conditions!['min_profit'] != null
          ? rule.conditions!['min_profit'].toString()
          : '',
    );
    _minAttendanceController = TextEditingController(
      text:
          rule?.conditions != null &&
              rule!.conditions!['min_attendance_rate'] != null
          ? rule.conditions!['min_attendance_rate'].toString()
          : '',
    );
    _profitPercentInvoiceController = TextEditingController(
      text:
          rule?.conditions != null &&
              rule!.conditions!['min_profit_percent_of_invoice'] != null
          ? rule.conditions!['min_profit_percent_of_invoice'].toString()
          : '',
    );
    _minPointsController = TextEditingController(
      text:
          rule?.conditions != null &&
              rule!.conditions!['min_points'] != null
          ? rule.conditions!['min_points'].toString()
          : '',
    );
    _selectedRuleType = rule?.ruleType ?? 'sales_target';
    _selectedBonusType = rule?.bonusType ?? 'percentage';
    _selectedPointsPeriod =
        (rule?.conditions?['points_period'] as String?) ?? 'month';
    _isActive = rule?.isActive ?? true;
    _validFrom = rule?.validFrom;
    _validTo = rule?.validTo;

    // 🆕 تحميل الموظفين المحددين وأنواع الفواتير
    _selectedEmployeeIds = rule?.targetEmployeeIds ?? [];
    _selectedInvoiceTypes = rule?.applicableInvoiceTypes ?? [];
    _loadInitialData();
  }

  /// 🆕 تحميل البيانات الأولية (الموظفين وأنواع الفواتير)
  Future<void> _loadInitialData() async {
    setState(() => _loadingData = true);
    try {
      // تحميل الموظفين
      final employeesResponse = await widget.api.getEmployees(
        isActive: true,
        perPage: 100,
      );

      // التحقق من نوع البيانات المُرجعة
      final employeesData = employeesResponse['employees'];
      List<EmployeeModel> employees;
      if (employeesData is List<EmployeeModel>) {
        employees = employeesData;
      } else if (employeesData is List) {
        employees = employeesData
            .map((json) => EmployeeModel.fromJson(json as Map<String, dynamic>))
            .toList();
      } else {
        throw Exception(
          'Unexpected employees data type: ${employeesData.runtimeType}',
        );
      }

      // تحميل أنواع الفواتير (قد تكون قائمة نصوص أو كائنات)
      final invoiceTypesData = await widget.api.getInvoiceTypes();
      late final List<InvoiceTypeModel> invoiceTypes;
      if (invoiceTypesData.isNotEmpty && invoiceTypesData.first is Map) {
        invoiceTypes = invoiceTypesData
            .map(
              (json) => InvoiceTypeModel.fromJson(json as Map<String, dynamic>),
            )
            .toList();
      } else {
        invoiceTypes = invoiceTypesData
            .map((val) => val.toString())
            .map(
              (label) => InvoiceTypeModel(
                value: label,
                label: label,
                description: label,
              ),
            )
            .toList();
      }

      setState(() {
        _allEmployees = employees;
        _availableInvoiceTypes = invoiceTypes;
      });

      // 🔍 Debug: طباعة البيانات المحملة
      if (kDebugMode) {
        debugPrint('✅ Loaded ${employees.length} employees');
        debugPrint('✅ Loaded ${invoiceTypes.length} invoice types');
        debugPrint(
          '📋 Invoice types: ${invoiceTypes.map((t) => t.label).join(", ")}',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ Error loading data: $e');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('خطأ في تحميل البيانات: $e'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingData = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _valueController.dispose();
    _minController.dispose();
    _maxController.dispose();
    _minSalesController.dispose();
    _minProfitController.dispose();
    _minAttendanceController.dispose();
    _profitPercentInvoiceController.dispose();
    _minPointsController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      final payload = {
        'name': _nameController.text.trim(),
        'description': _descController.text.trim().isEmpty
            ? null
            : _descController.text.trim(),
        'rule_type': _selectedRuleType,
        'bonus_type': _selectedBonusType,
        'bonus_value': double.parse(_valueController.text),
        'min_bonus': double.parse(_minController.text),
        'max_bonus': _maxController.text.isEmpty
            ? null
            : double.parse(_maxController.text),
        'conditions': {},
        'target_employee_ids': _selectedEmployeeIds.isEmpty
            ? null
            : _selectedEmployeeIds, // 🆕
        'applicable_invoice_types': _selectedInvoiceTypes.isEmpty
            ? null
            : _selectedInvoiceTypes, // 🆕
        'is_active': _isActive,
        'valid_from': _validFrom?.toIso8601String().split('T').first,
        'valid_to': _validTo?.toIso8601String().split('T').first,
      };

      // تعبئة الشروط الاختيارية
      double? tryParse(String v) =>
          v.trim().isEmpty ? null : double.tryParse(v.trim());
      final minSales = tryParse(_minSalesController.text);
      final minProfit = tryParse(_minProfitController.text);
      final minAttendance = tryParse(_minAttendanceController.text);
      final minProfitPercentInvoice = tryParse(
        _profitPercentInvoiceController.text,
      );

      final conditions = <String, dynamic>{};
      if (minSales != null) conditions['min_sales'] = minSales;
      if (minProfit != null) conditions['min_profit'] = minProfit;
      if (minAttendance != null) {
        conditions['min_attendance_rate'] = minAttendance;
      }
      if (minProfitPercentInvoice != null) {
        conditions['min_profit_percent_of_invoice'] = minProfitPercentInvoice;
      }
      if (_selectedRuleType == 'points_based') {
        final minPts = tryParse(_minPointsController.text);
        if (minPts != null) conditions['min_points'] = minPts;
        conditions['points_period'] = _selectedPointsPeriod;
      }
      if (conditions.isNotEmpty) {
        payload['conditions'] = conditions;
      }

      // 🔍 Debug: طباعة البيانات المرسلة
      if (kDebugMode) {
        debugPrint('📤 Sending bonus rule payload:');
        debugPrint('   Target Employees: $_selectedEmployeeIds');
        debugPrint('   Invoice Types: $_selectedInvoiceTypes');
        debugPrint('   Full payload: $payload');
      }

      if (widget.rule?.id != null) {
        await widget.api.updateBonusRule(widget.rule!.id!, payload);
      } else {
        await widget.api.createBonusRule(payload);
      }

      widget.onSaved();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final dateFormat = DateFormat('yyyy-MM-dd');

    return AlertDialog(
      title: Text(
        widget.rule == null
            ? (isAr ? 'إضافة قاعدة مكافأة' : 'Add Bonus Rule')
            : (isAr ? 'تعديل قاعدة المكافأة' : 'Edit Bonus Rule'),
      ),
      content: SizedBox(
        width: 500,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'الاسم' : 'Name',
                    border: const OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'مطلوب' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'الوصف' : 'Description',
                    border: const OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _selectedRuleType,
                  decoration: InputDecoration(
                    labelText: isAr ? 'نوع القاعدة' : 'Rule Type',
                    border: const OutlineInputBorder(),
                  ),
                  items: BonusRuleModel.ruleTypes
                      .map(
                        (t) => DropdownMenuItem(
                          value: t,
                          child: Text(BonusRuleModel.getRuleTypeNameAr(t)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() {
                    _selectedRuleType = v!;
                    // عند اختيار النقاط، القيمة الافتراضية لنوع المكافأة هي مبلغ لكل نقطة
                    if (_selectedRuleType == 'points_based' &&
                        _selectedBonusType != 'points_per_unit' &&
                        _selectedBonusType != 'fixed') {
                      _selectedBonusType = 'points_per_unit';
                    }
                  }),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _selectedBonusType,
                  decoration: InputDecoration(
                    labelText: isAr ? 'نوع المكافأة' : 'Bonus Type',
                    border: const OutlineInputBorder(),
                  ),
                  items: BonusRuleModel.bonusTypes
                      .map(
                        (t) => DropdownMenuItem(
                          value: t,
                          child: Text(BonusRuleModel.getBonusTypeNameAr(t)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => _selectedBonusType = v!),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _valueController,
                  decoration: InputDecoration(
                    labelText: _selectedRuleType == 'points_based' &&
                            _selectedBonusType == 'points_per_unit'
                        ? (isAr ? 'المبلغ لكل نقطة' : 'Amount per point')
                        : (isAr ? 'القيمة' : 'Value'),
                    helperText: _selectedRuleType == 'points_based' &&
                            _selectedBonusType == 'points_per_unit'
                        ? (isAr
                            ? 'مثال: 0.5 يعني 0.5 ${context.read<SettingsProvider>().currencySymbolText} لكل نقطة'
                            : 'e.g. 0.5 = 0.5 ${context.read<SettingsProvider>().currencySymbolText} per point')
                        : null,
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  validator: (v) => v == null || double.tryParse(v) == null
                      ? 'رقم مطلوب'
                      : null,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _minController,
                        decoration: InputDecoration(
                          labelText: isAr ? 'الحد الأدنى' : 'Min',
                          border: const OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _maxController,
                        decoration: InputDecoration(
                          labelText: isAr ? 'الحد الأقصى' : 'Max',
                          border: const OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // قسم إعدادات النقاط — يظهر فقط لنوع points_based
                if (_selectedRuleType == 'points_based') ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFD700).withValues(alpha: 0.08),
                      border: Border.all(
                        color: const Color(0xFFD4AF37).withValues(alpha: 0.5),
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.stars_rounded,
                              color: Color(0xFFD4AF37),
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              isAr
                                  ? 'إعدادات سباق النقاط'
                                  : 'Points Race Settings',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF8B6914),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          value: _selectedPointsPeriod,
                          decoration: InputDecoration(
                            labelText:
                                isAr ? 'فترة احتساب النقاط' : 'Points Period',
                            helperText: isAr
                                ? 'الفترة التي تُحسب منها نقاط الموظف'
                                : 'Period from which employee points are counted',
                            border: const OutlineInputBorder(),
                          ),
                          items: BonusRuleModel.pointsPeriods
                              .map(
                                (p) => DropdownMenuItem(
                                  value: p,
                                  child: Text(
                                    BonusRuleModel.getPointsPeriodNameAr(p),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) =>
                              setState(() => _selectedPointsPeriod = v!),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _minPointsController,
                          decoration: InputDecoration(
                            labelText: isAr
                                ? 'حد أدنى للنقاط (اختياري)'
                                : 'Min points (optional)',
                            helperText: isAr
                                ? 'لا تُمنح المكافأة إلا إذا تجاوز الموظف هذا العدد'
                                : 'Bonus only granted if employee exceeds this threshold',
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.star_border),
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // الشروط الاختيارية — مخفية لـ points_based
                if (_selectedRuleType != 'points_based') ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      isAr
                          ? 'شروط الاستحقاق (اختياري)'
                          : 'Eligibility (optional)',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _minSalesController,
                          decoration: InputDecoration(
                            labelText:
                                isAr ? 'حد أدنى للمبيعات' : 'Min sales',
                            helperText: isAr
                                ? 'بالريال أو الوزن حسب الفاتورة'
                                : 'In currency/weight per invoice',
                            border: const OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _minProfitController,
                          decoration: InputDecoration(
                            labelText:
                                isAr ? 'حد أدنى للربح' : 'Min profit',
                            helperText:
                                isAr ? 'قيمة ثابتة' : 'Fixed value',
                            border: const OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _profitPercentInvoiceController,
                          decoration: InputDecoration(
                            labelText: isAr
                                ? 'ربح % من الفاتورة'
                                : 'Profit % of invoice',
                            helperText: isAr
                                ? 'مثال: 5 يعني ربح ≥5% من إجمالي الفاتورة'
                                : 'e.g. 5 means profit ≥5% of invoice total',
                            border: const OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _minAttendanceController,
                          decoration: InputDecoration(
                            labelText:
                                isAr ? 'نسبة حضور %' : 'Attendance %',
                            border: const OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _validFrom ?? DateTime.now(),
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null) {
                            setState(() => _validFrom = picked);
                          }
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: isAr ? 'من تاريخ' : 'From Date',
                            border: const OutlineInputBorder(),
                          ),
                          child: Text(
                            _validFrom != null
                                ? dateFormat.format(_validFrom!)
                                : (isAr ? 'اختر تاريخ' : 'Select Date'),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _validTo ?? DateTime.now(),
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null) {
                            setState(() => _validTo = picked);
                          }
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: isAr ? 'إلى تاريخ' : 'To Date',
                            border: const OutlineInputBorder(),
                          ),
                          child: Text(
                            _validTo != null
                                ? dateFormat.format(_validTo!)
                                : (isAr ? 'اختر تاريخ' : 'Select Date'),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: Text(isAr ? 'نشطة' : 'Active'),
                  value: _isActive,
                  onChanged: (v) => setState(() => _isActive = v),
                ),
                const Divider(height: 32),

                // 🆕 قسم تخصيص الموظفين
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      isAr ? '🎯 تخصيص الموظفين' : '🎯 Target Employees',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFFD4AF37),
                      ),
                    ),
                    if (_selectedEmployeeIds.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD4AF37),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_selectedEmployeeIds.length} ${isAr ? 'محدد' : 'selected'}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        isAr
                            ? 'اختر الموظفين الذين تنطبق عليهم هذه القاعدة (اترك فارغاً للجميع)'
                            : 'Select employees for this rule (leave empty for all)',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (_selectedEmployeeIds.isNotEmpty)
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _selectedEmployeeIds.clear();
                          });
                        },
                        icon: const Icon(Icons.clear, size: 16),
                        label: Text(isAr ? 'مسح الكل' : 'Clear All'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_loadingData)
                  const Center(child: CircularProgressIndicator())
                else
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: _allEmployees.isEmpty
                        ? Text(
                            isAr ? 'لا يوجد موظفين' : 'No employees',
                            style: TextStyle(color: Colors.grey.shade600),
                          )
                        : Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _allEmployees.map((emp) {
                              final isSelected = _selectedEmployeeIds.contains(
                                emp.id,
                              );
                              return ChoiceChip(
                                label: Text(emp.name),
                                selected: isSelected,
                                onSelected: (selected) {
                                  setState(() {
                                    if (selected) {
                                      _selectedEmployeeIds.add(emp.id!);
                                    } else {
                                      _selectedEmployeeIds.remove(emp.id);
                                    }
                                  });
                                },
                                selectedColor: const Color(
                                  0xFFD4AF37,
                                ).withValues(alpha: 0.3),
                                checkmarkColor: const Color(0xFF8B6914),
                                backgroundColor: Colors.grey.shade100,
                                labelStyle: TextStyle(
                                  color: isSelected
                                      ? const Color(0xFF8B6914)
                                      : Colors.black87,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              );
                            }).toList(),
                          ),
                  ),

                const Divider(height: 32),

                // 🆕 قسم تحديد أنواع الفواتير
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      isAr
                          ? '📋 أنواع الفواتير المستهدفة'
                          : '📋 Target Invoice Types',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFFD4AF37),
                      ),
                    ),
                    if (_selectedInvoiceTypes.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD4AF37),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_selectedInvoiceTypes.length} ${isAr ? 'محدد' : 'selected'}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        isAr
                            ? 'اختر أنواع الفواتير التي تنطبق عليها هذه القاعدة (اترك فارغاً للجميع)'
                            : 'Select invoice types for this rule (leave empty for all)',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (_selectedInvoiceTypes.isNotEmpty)
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _selectedInvoiceTypes.clear();
                          });
                        },
                        icon: const Icon(Icons.clear, size: 16),
                        label: Text(isAr ? 'مسح الكل' : 'Clear All'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_loadingData)
                  const Center(child: CircularProgressIndicator())
                else
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: _availableInvoiceTypes.isEmpty
                        ? Text(
                            isAr ? 'لا توجد أنواع فواتير' : 'No invoice types',
                            style: TextStyle(color: Colors.grey.shade600),
                          )
                        : Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _availableInvoiceTypes.map((type) {
                              final isSelected = _selectedInvoiceTypes.contains(
                                type.value,
                              );
                              return ChoiceChip(
                                label: Text(type.label),
                                tooltip: type.description,
                                selected: isSelected,
                                onSelected: (selected) {
                                  setState(() {
                                    if (selected) {
                                      _selectedInvoiceTypes.add(type.value);
                                    } else {
                                      _selectedInvoiceTypes.remove(type.value);
                                    }
                                  });
                                },
                                selectedColor: const Color(
                                  0xFFD4AF37,
                                ).withValues(alpha: 0.3),
                                checkmarkColor: const Color(0xFF8B6914),
                                backgroundColor: Colors.grey.shade100,
                                labelStyle: TextStyle(
                                  color: isSelected
                                      ? const Color(0xFF8B6914)
                                      : Colors.black87,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                              );
                            }).toList(),
                          ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(isAr ? 'إلغاء' : 'Cancel'),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(isAr ? 'حفظ' : 'Save'),
        ),
      ],
    );
  }
}
