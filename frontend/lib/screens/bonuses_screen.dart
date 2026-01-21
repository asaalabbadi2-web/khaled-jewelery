import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_service.dart';
import '../models/employee_bonus_model.dart';
import '../models/safe_box_model.dart';
import 'calculate_bonuses_screen.dart';

class BonusesScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const BonusesScreen({super.key, required this.api, this.isArabic = true});

  @override
  State<BonusesScreen> createState() => _BonusesScreenState();
}

class _BonusesScreenState extends State<BonusesScreen> {
  List<EmployeeBonusModel> _bonuses = [];
  bool _loading = false;
  String? _statusFilter;
  String? _ruleTypeFilter;
  String? _bonusTypeFilter;
  String? _departmentFilter;
  double? _minAmount;
  double? _maxAmount;
  DateTime? _periodStart;
  DateTime? _periodEnd;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _sortOption = 'newest';
  bool _onlyActionable = false;
  String? _periodPreset;
  bool _bulkLoading = false;

  @override
  void initState() {
    super.initState();
    _loadBonuses();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadBonuses() async {
    setState(() => _loading = true);
    try {
      final data = await widget.api.getBonuses(
        status: _statusFilter,
        dateFrom: _periodStart?.toIso8601String().split('T').first,
        dateTo: _periodEnd?.toIso8601String().split('T').first,
      );
      final bonuses = data
          .map(
            (json) => EmployeeBonusModel.fromJson(json as Map<String, dynamic>),
          )
          .toList();
      setState(() => _bonuses = bonuses);
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<EmployeeBonusModel> _filteredBonuses() {
    Iterable<EmployeeBonusModel> list = _bonuses;

    if (_onlyActionable) {
      list = list.where((b) => b.canApprove() || b.canReject() || b.canPay());
    }

    if (_ruleTypeFilter != null && _ruleTypeFilter!.isNotEmpty) {
      list = list.where((b) => b.bonusRule?.ruleType == _ruleTypeFilter);
    }

    if (_bonusTypeFilter != null && _bonusTypeFilter!.isNotEmpty) {
      list = list.where((b) => b.bonusType == _bonusTypeFilter);
    }

    if (_departmentFilter != null && _departmentFilter!.isNotEmpty) {
      final dept = _departmentFilter!.toLowerCase();
      list = list.where(
        (b) =>
            b.employee?.department != null &&
            b.employee!.department!.toLowerCase() == dept,
      );
    }

    if (_minAmount != null) {
      list = list.where((b) => b.amount >= _minAmount!);
    }

    if (_maxAmount != null) {
      list = list.where((b) => b.amount <= _maxAmount!);
    }

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((b) {
        final fields = [
          b.employee?.fullName,
          b.employee?.employeeCode,
          b.employee?.department,
          b.employee?.position,
          b.bonusRule?.name,
          b.bonusType,
          b.notes,
        ];
        return fields.any((f) => f != null && f.toLowerCase().contains(q));
      });
    }

    final sorted = list.toList();
    switch (_sortOption) {
      case 'amount_desc':
        sorted.sort((a, b) => b.amount.compareTo(a.amount));
        break;
      case 'amount_asc':
        sorted.sort((a, b) => a.amount.compareTo(b.amount));
        break;
      case 'oldest':
        sorted.sort((a, b) => a.periodStart.compareTo(b.periodStart));
        break;
      case 'status':
        sorted.sort((a, b) => a.status.compareTo(b.status));
        break;
      default:
        sorted.sort((a, b) => b.periodStart.compareTo(a.periodStart));
        break;
    }

    return sorted;
  }

  void _applyPeriodPreset(String preset) {
    final now = DateTime.now();
    DateTime start = now;
    DateTime end = now;

    switch (preset) {
      case 'this_month':
        start = DateTime(now.year, now.month, 1);
        end = DateTime(now.year, now.month + 1, 0);
        break;
      case 'last_month':
        start = DateTime(now.year, now.month - 1, 1);
        end = DateTime(now.year, now.month, 0);
        break;
      case 'quarter':
        final quarter = ((now.month - 1) ~/ 3) + 1;
        final firstMonth = (quarter - 1) * 3 + 1;
        start = DateTime(now.year, firstMonth, 1);
        end = DateTime(now.year, firstMonth + 3, 0);
        break;
      default:
        start = now.subtract(const Duration(days: 30));
        end = now;
    }

    setState(() {
      _periodStart = start;
      _periodEnd = end;
      _periodPreset = preset;
    });
    _loadBonuses();
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

  Future<void> _approveBonus(EmployeeBonusModel bonus) async {
    final isAr = widget.isArabic;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isAr ? 'اعتماد المكافأة' : 'Approve Bonus'),
        content: Text(
          isAr
              ? 'هل تريد اعتماد مكافأة ${bonus.amount} للموظف ${bonus.employee?.fullName ?? ""}؟'
              : 'Approve bonus of ${bonus.amount} for ${bonus.employee?.fullName ?? ""}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isAr ? 'اعتماد' : 'Approve'),
          ),
        ],
      ),
    );

    if (confirm == true && bonus.id != null) {
      try {
        await widget.api.approveBonus(bonus.id!);
        _showSnack(isAr ? 'تم الاعتماد بنجاح' : 'Approved successfully');
        _loadBonuses();
      } catch (e) {
        _showSnack(e.toString(), isError: true);
      }
    }
  }

  Future<void> _rejectBonus(EmployeeBonusModel bonus) async {
    final isAr = widget.isArabic;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isAr ? 'رفض المكافأة' : 'Reject Bonus'),
        content: Text(
          isAr
              ? 'هل تريد رفض مكافأة ${bonus.amount} للموظف ${bonus.employee?.fullName ?? ""}؟'
              : 'Reject bonus of ${bonus.amount} for ${bonus.employee?.fullName ?? ""}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isAr ? 'رفض' : 'Reject'),
          ),
        ],
      ),
    );

    if (confirm == true && bonus.id != null) {
      try {
        await widget.api.rejectBonus(bonus.id!);
        _showSnack(isAr ? 'تم الرفض' : 'Rejected');
        _loadBonuses();
      } catch (e) {
        _showSnack(e.toString(), isError: true);
      }
    }
  }

  Future<void> _payBonus(EmployeeBonusModel bonus) async {
    final isAr = widget.isArabic;

    // Load SafeBoxes (cash/bank) first
    List<SafeBoxModel> safeBoxes = [];
    try {
      final all = await widget.api.getSafeBoxes(
        isActive: true,
        includeBalance: true,
        includeAccount: false,
      );
      safeBoxes = all
          .where(
            (sb) =>
                sb.safeType == 'cash' ||
                sb.safeType == 'bank' ||
                sb.safeType == 'clearing',
          )
          .toList();
    } catch (e) {
      _showSnack(
        isAr
            ? 'فشل تحميل الخزائن: ${e.toString()}'
            : 'Failed to load safe boxes: ${e.toString()}',
        isError: true,
      );
      return;
    }

    if (safeBoxes.isEmpty) {
      _showSnack(
        isAr
            ? 'لا توجد خزائن نقدية/بنكية متاحة'
            : 'No cash/bank safe boxes available',
        isError: true,
      );
      return;
    }

    // Show SafeBox selection dialog
    final selectedSafeBox = await showDialog<SafeBoxModel>(
      context: context,
      builder: (ctx) {
        SafeBoxModel? selected = safeBoxes.first;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: Text(isAr ? 'دفع المكافأة' : 'Pay Bonus'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isAr
                      ? 'دفع مكافأة ${bonus.amount.toStringAsFixed(2)} ريال للموظف ${bonus.employee?.fullName ?? ""}'
                      : 'Pay bonus of ${bonus.amount.toStringAsFixed(2)} SAR to ${bonus.employee?.fullName ?? ""}',
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 16),
                Text(
                  isAr ? 'اختر الخزينة:' : 'Select Safe Box:',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<SafeBoxModel>(
                  initialValue: selected,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  items: safeBoxes.map((sb) {
                    final balance = sb.balance?.cash ?? 0.0;
                    final hasEnough = balance >= bonus.amount;
                    final typeLabel = sb.safeType == 'cash'
                        ? (isAr ? 'نقدي' : 'Cash')
                        : (isAr ? 'بنكي' : 'Bank');
                    return DropdownMenuItem<SafeBoxModel>(
                      value: sb,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${sb.name} ($typeLabel)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '(${balance.toStringAsFixed(2)})',
                            style: TextStyle(
                              fontSize: 12,
                              color: hasEnough ? Colors.green : Colors.red,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (val) {
                    setState(() => selected = val);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(isAr ? 'إلغاء' : 'Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, selected),
                child: Text(isAr ? 'دفع' : 'Pay'),
              ),
            ],
          ),
        );
      },
    );

    if (selectedSafeBox?.id != null && bonus.id != null) {
      try {
        final method = selectedSafeBox!.safeType == 'bank'
            ? 'transfer'
            : 'cash';
        await widget.api.payBonus(
          bonus.id!,
          safeBoxId: selectedSafeBox.id!,
          paymentMethod: method,
        );
        _showSnack(
          isAr ? 'تم تسجيل الدفع بنجاح' : 'Payment recorded successfully',
        );
        _loadBonuses();
      } catch (e) {
        _showSnack(e.toString(), isError: true);
      }
    }
  }

  Future<void> _editBonus(EmployeeBonusModel bonus) async {
    final isAr = widget.isArabic;
    if (bonus.status != 'pending') {
      _showSnack(
        isAr
            ? 'لا يمكن تعديل مكافأة غير معلقة'
            : 'Only pending bonuses can be edited',
        isError: true,
      );
      return;
    }

    final amountController = TextEditingController(
      text: bonus.amount.toString(),
    );
    final notesController = TextEditingController(text: bonus.notes ?? '');
    DateTime start = bonus.periodStart;
    DateTime end = bonus.periodEnd;

    final dateFormat = DateFormat('yyyy-MM-dd');

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isAr ? 'تعديل مكافأة' : 'Edit bonus'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: amountController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'المبلغ' : 'Amount',
                    prefixIcon: const Icon(Icons.attach_money),
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'ملاحظات' : 'Notes',
                    prefixIcon: const Icon(Icons.notes),
                    border: const OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: ctx,
                            initialDate: start,
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null) {
                            setDialogState(() => start = picked);
                          }
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: isAr ? 'من تاريخ' : 'From',
                            border: const OutlineInputBorder(),
                          ),
                          child: Text(dateFormat.format(start)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: ctx,
                            initialDate: end,
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null) {
                            setDialogState(() => end = picked);
                          }
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: isAr ? 'إلى تاريخ' : 'To',
                            border: const OutlineInputBorder(),
                          ),
                          child: Text(dateFormat.format(end)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(isAr ? 'إلغاء' : 'Cancel'),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.save),
              label: Text(isAr ? 'حفظ' : 'Save'),
            ),
          ],
        ),
      ),
    );

    if (result == true) {
      try {
        final amount = double.tryParse(amountController.text.trim());
        if (amount == null) {
          _showSnack(
            isAr ? 'الرجاء إدخال مبلغ صحيح' : 'Enter valid amount',
            isError: true,
          );
          return;
        }

        await widget.api.updateBonus(bonus.id!, {
          'amount': amount,
          'notes': notesController.text.trim().isEmpty
              ? null
              : notesController.text.trim(),
          'period_start': dateFormat.format(start),
          'period_end': dateFormat.format(end),
        });
        _showSnack(isAr ? 'تم التحديث' : 'Updated');
        _loadBonuses();
      } catch (e) {
        _showSnack(e.toString(), isError: true);
      }
    }
  }

  void _showFilterDialog() {
    final isAr = widget.isArabic;
    final dateFormat = DateFormat('yyyy-MM-dd');
    final ruleTypes =
        _bonuses
            .map((b) => b.bonusRule?.ruleType)
            .whereType<String>()
            .toSet()
            .toList()
          ..sort();
    final bonusTypes = _bonuses.map((b) => b.bonusType).toSet().toList()
      ..sort();
    final departments =
        _bonuses
            .map((b) => b.employee?.department)
            .whereType<String>()
            .toSet()
            .toList()
          ..sort();

    showDialog(
      context: context,
      builder: (ctx) {
        String? tempStatus = _statusFilter;
        String? tempRuleType = _ruleTypeFilter;
        String? tempBonusType = _bonusTypeFilter;
        String? tempDept = _departmentFilter;
        String tempMinAmount = _minAmount?.toString() ?? '';
        String tempMaxAmount = _maxAmount?.toString() ?? '';
        DateTime? tempStart = _periodStart;
        DateTime? tempEnd = _periodEnd;

        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(isAr ? 'تصفية المكافآت' : 'Filter Bonuses'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String?>(
                    initialValue: tempStatus,
                    decoration: InputDecoration(
                      labelText: isAr ? 'الحالة' : 'Status',
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: null,
                        child: Text(isAr ? 'الكل' : 'All'),
                      ),
                      ...EmployeeBonusModel.statuses.map(
                        (s) => DropdownMenuItem(
                          value: s,
                          child: Text(EmployeeBonusModel.getStatusNameAr(s)),
                        ),
                      ),
                    ],
                    onChanged: (v) => setDialogState(() => tempStatus = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: tempRuleType,
                    decoration: InputDecoration(
                      labelText: isAr ? 'نوع القاعدة' : 'Rule type',
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: null,
                        child: Text(isAr ? 'الكل' : 'All'),
                      ),
                      ...ruleTypes.map(
                        (r) => DropdownMenuItem(value: r, child: Text(r)),
                      ),
                    ],
                    onChanged: (v) => setDialogState(() => tempRuleType = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: tempBonusType,
                    decoration: InputDecoration(
                      labelText: isAr ? 'نوع المكافأة' : 'Bonus type',
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: null,
                        child: Text(isAr ? 'الكل' : 'All'),
                      ),
                      ...bonusTypes.map(
                        (t) => DropdownMenuItem(value: t, child: Text(t)),
                      ),
                    ],
                    onChanged: (v) => setDialogState(() => tempBonusType = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: tempDept,
                    decoration: InputDecoration(
                      labelText: isAr ? 'القسم' : 'Department',
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: null,
                        child: Text(isAr ? 'الكل' : 'All'),
                      ),
                      ...departments.map(
                        (d) => DropdownMenuItem(value: d, child: Text(d)),
                      ),
                    ],
                    onChanged: (v) => setDialogState(() => tempDept = v),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: tempMinAmount,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: isAr ? 'أدنى مبلغ' : 'Min amount',
                            border: const OutlineInputBorder(),
                          ),
                          onChanged: (v) =>
                              setDialogState(() => tempMinAmount = v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          initialValue: tempMaxAmount,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: isAr ? 'أقصى مبلغ' : 'Max amount',
                            border: const OutlineInputBorder(),
                          ),
                          onChanged: (v) =>
                              setDialogState(() => tempMaxAmount = v),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: tempStart ?? DateTime.now(),
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2100),
                            );
                            if (picked != null) {
                              setDialogState(() => tempStart = picked);
                            }
                          },
                          child: InputDecorator(
                            decoration: InputDecoration(
                              labelText: isAr ? 'من تاريخ' : 'From Date',
                              border: const OutlineInputBorder(),
                            ),
                            child: Text(
                              tempStart != null
                                  ? dateFormat.format(tempStart!)
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
                              initialDate: tempEnd ?? DateTime.now(),
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2100),
                            );
                            if (picked != null) {
                              setDialogState(() => tempEnd = picked);
                            }
                          },
                          child: InputDecorator(
                            decoration: InputDecoration(
                              labelText: isAr ? 'إلى تاريخ' : 'To Date',
                              border: const OutlineInputBorder(),
                            ),
                            child: Text(
                              tempEnd != null
                                  ? dateFormat.format(tempEnd!)
                                  : (isAr ? 'اختر تاريخ' : 'Select Date'),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  setState(() {
                    _statusFilter = null;
                    _ruleTypeFilter = null;
                    _bonusTypeFilter = null;
                    _departmentFilter = null;
                    _minAmount = null;
                    _maxAmount = null;
                    _periodStart = null;
                    _periodEnd = null;
                  });
                  Navigator.pop(ctx);
                  _loadBonuses();
                },
                child: Text(isAr ? 'إعادة تعيين' : 'Reset'),
              ),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _statusFilter = tempStatus;
                    _ruleTypeFilter = tempRuleType;
                    _bonusTypeFilter = tempBonusType;
                    _departmentFilter = tempDept;
                    _minAmount = tempMinAmount.trim().isEmpty
                        ? null
                        : double.tryParse(tempMinAmount.trim());
                    _maxAmount = tempMaxAmount.trim().isEmpty
                        ? null
                        : double.tryParse(tempMaxAmount.trim());
                    _periodStart = tempStart;
                    _periodEnd = tempEnd;
                  });
                  Navigator.pop(ctx);
                  _loadBonuses();
                },
                child: Text(isAr ? 'تطبيق' : 'Apply'),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final filtered = _filteredBonuses();

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'المكافآت' : 'Bonuses'),
        centerTitle: true,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadBonuses),
          IconButton(
            icon: const Icon(Icons.filter_list),
            onPressed: _showFilterDialog,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (ctx) => CalculateBonusesScreen(
                api: widget.api,
                isArabic: widget.isArabic,
              ),
            ),
          ).then((_) => _loadBonuses());
        },
        icon: const Icon(Icons.calculate),
        label: Text(isAr ? 'احتساب مكافآت' : 'Calculate Bonuses'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadBonuses,
              child: ListView(
                padding: const EdgeInsets.all(16),
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  _buildSummaryRow(isAr),
                  const SizedBox(height: 12),
                  _buildToolbar(isAr),
                  const SizedBox(height: 12),
                  _buildStatusChips(isAr),
                  const SizedBox(height: 12),
                  _buildBulkActions(isAr, filtered),
                  const SizedBox(height: 12),
                  if (filtered.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          isAr ? 'لا توجد مكافآت' : 'No bonuses',
                          style: const TextStyle(
                            fontSize: 18,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    )
                  else
                    ...filtered.map(_buildBonusCard),
                ],
              ),
            ),
    );
  }

  Widget _buildSummaryRow(bool isAr) {
    final totalAmount = _bonuses.fold<double>(0, (sum, b) => sum + b.amount);
    final pendingCount = _bonuses.where((b) => b.status == 'pending').length;
    final approvedCount = _bonuses.where((b) => b.status == 'approved').length;
    final paidCount = _bonuses.where((b) => b.status == 'paid').length;
    final actionableCount = _bonuses
        .where((b) => b.canApprove() || b.canPay())
        .length;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _SummaryCard(
          label: isAr ? 'إجمالي المبالغ' : 'Total Amount',
          value: '${totalAmount.toStringAsFixed(2)} IQD',
          color: Colors.blue.shade50,
          icon: Icons.summarize,
        ),
        _SummaryCard(
          label: isAr ? 'معلقة' : 'Pending',
          value: '$pendingCount',
          color: Colors.orange.shade50,
          icon: Icons.hourglass_empty,
        ),
        _SummaryCard(
          label: isAr ? 'معتمدة' : 'Approved',
          value: '$approvedCount',
          color: Colors.green.shade50,
          icon: Icons.verified,
        ),
        _SummaryCard(
          label: isAr ? 'مدفوعة' : 'Paid',
          value: '$paidCount',
          color: Colors.lightBlue.shade50,
          icon: Icons.payments,
        ),
        _SummaryCard(
          label: isAr ? 'جاهزة للإجراء' : 'Actionable',
          value: '$actionableCount',
          color: Colors.purple.shade50,
          icon: Icons.bolt,
        ),
      ],
    );
  }

  Widget _buildToolbar(bool isAr) {
    return Column(
      children: [
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                  )
                : null,
            hintText: isAr
                ? 'بحث بالاسم، الكود، القسم، القاعدة'
                : 'Search by name, code, dept, rule',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onChanged: (v) => setState(() => _searchQuery = v.trim()),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    label: Text(isAr ? 'إجراءات فقط' : 'Actionable only'),
                    selected: _onlyActionable,
                    onSelected: (v) => setState(() => _onlyActionable = v),
                    avatar: const Icon(Icons.flash_on, size: 18),
                  ),
                  ChoiceChip(
                    label: Text(isAr ? 'هذا الشهر' : 'This month'),
                    selected: _periodPreset == 'this_month',
                    onSelected: (_) => _applyPeriodPreset('this_month'),
                  ),
                  ChoiceChip(
                    label: Text(isAr ? 'الشهر الماضي' : 'Last month'),
                    selected: _periodPreset == 'last_month',
                    onSelected: (_) => _applyPeriodPreset('last_month'),
                  ),
                  ChoiceChip(
                    label: Text(isAr ? 'الربع الحالي' : 'This quarter'),
                    selected: _periodPreset == 'quarter',
                    onSelected: (_) => _applyPeriodPreset('quarter'),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 170,
              child: DropdownButtonFormField<String>(
                initialValue: _sortOption,
                decoration: InputDecoration(
                  labelText: isAr ? 'ترتيب' : 'Sort',
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                items: [
                  DropdownMenuItem(
                    value: 'newest',
                    child: Text(isAr ? 'الأحدث' : 'Newest first'),
                  ),
                  DropdownMenuItem(
                    value: 'oldest',
                    child: Text(isAr ? 'الأقدم' : 'Oldest first'),
                  ),
                  DropdownMenuItem(
                    value: 'amount_desc',
                    child: Text(isAr ? 'الأعلى مبلغ' : 'Amount desc'),
                  ),
                  DropdownMenuItem(
                    value: 'amount_asc',
                    child: Text(isAr ? 'الأقل مبلغ' : 'Amount asc'),
                  ),
                  DropdownMenuItem(
                    value: 'status',
                    child: Text(isAr ? 'حسب الحالة' : 'By status'),
                  ),
                ],
                onChanged: (v) => setState(() => _sortOption = v ?? 'newest'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatusChips(bool isAr) {
    final statuses = [null, ...EmployeeBonusModel.statuses];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: statuses
            .map(
              (s) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(
                    s == null
                        ? (isAr ? 'الكل' : 'All')
                        : EmployeeBonusModel.getStatusNameAr(s),
                  ),
                  selected: _statusFilter == s,
                  onSelected: (_) {
                    setState(() => _statusFilter = s);
                    _loadBonuses();
                  },
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildBonusCard(EmployeeBonusModel bonus) {
    final isAr = widget.isArabic;
    final dateFormat = DateFormat('yyyy-MM-dd');
    final statusColor = Color(EmployeeBonusModel.getStatusColor(bonus.status));

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bonus.employee?.fullName ?? 'موظف غير محدد',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (bonus.employee?.department != null)
                        Text(
                          bonus.employee!.department!,
                          style: const TextStyle(color: Colors.grey),
                        ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: statusColor),
                  ),
                  child: Text(
                    EmployeeBonusModel.getStatusNameAr(bonus.status),
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: _buildInfoItem(
                    isAr ? 'المبلغ' : 'Amount',
                    '${bonus.amount.toStringAsFixed(2)} IQD',
                    Icons.attach_money,
                  ),
                ),
                Expanded(
                  child: _buildInfoItem(
                    isAr ? 'النوع' : 'Type',
                    bonus.bonusType,
                    Icons.category,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildInfoItem(
                    isAr ? 'من' : 'From',
                    dateFormat.format(bonus.periodStart),
                    Icons.calendar_today,
                  ),
                ),
                Expanded(
                  child: _buildInfoItem(
                    isAr ? 'إلى' : 'To',
                    dateFormat.format(bonus.periodEnd),
                    Icons.calendar_today,
                  ),
                ),
              ],
            ),
            if (bonus.bonusRule != null) ...[
              const SizedBox(height: 12),
              _buildInfoItem(
                isAr ? 'القاعدة' : 'Rule',
                bonus.bonusRule!.name,
                Icons.rule,
              ),
            ],
            if (bonus.paymentReference != null &&
                bonus.paymentReference!.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildInfoItem(
                isAr ? 'مرجع الدفع' : 'Payment Ref',
                bonus.paymentReference!,
                Icons.receipt_long,
              ),
            ],
            if (bonus.approvedAt != null || bonus.paidAt != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (bonus.approvedAt != null)
                    Expanded(
                      child: _buildInfoItem(
                        isAr ? 'تاريخ الاعتماد' : 'Approved at',
                        dateFormat.format(bonus.approvedAt!),
                        Icons.check_circle_outline,
                      ),
                    ),
                  if (bonus.paidAt != null)
                    Expanded(
                      child: _buildInfoItem(
                        isAr ? 'تاريخ الدفع' : 'Paid at',
                        dateFormat.format(bonus.paidAt!),
                        Icons.payments_outlined,
                      ),
                    ),
                ],
              ),
            ],
            if (bonus.notes != null && bonus.notes!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                isAr ? 'ملاحظات:' : 'Notes:',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(bonus.notes!, style: const TextStyle(fontSize: 12)),
            ],
            if (bonus.calculationData != null &&
                bonus.calculationData!.isNotEmpty) ...[
              const Divider(height: 24),
              Text(
                isAr ? 'تفاصيل الاحتساب' : 'Calculation details',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: bonus.calculationData!.entries
                    .map(
                      (e) => Chip(
                        label: Text('${e.key}: ${e.value}'),
                        backgroundColor: Colors.grey.shade200,
                      ),
                    )
                    .toList(),
              ),
            ],
            if (bonus.canApprove() || bonus.canReject() || bonus.canPay()) ...[
              const Divider(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (bonus.status == 'pending') ...[
                    ElevatedButton.icon(
                      onPressed: () => _editBonus(bonus),
                      icon: const Icon(Icons.edit, size: 18),
                      label: Text(isAr ? 'تعديل' : 'Edit'),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (bonus.canApprove())
                    ElevatedButton.icon(
                      onPressed: () => _approveBonus(bonus),
                      icon: const Icon(Icons.check, size: 18),
                      label: Text(isAr ? 'اعتماد' : 'Approve'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                      ),
                    ),
                  if (bonus.canReject()) ...[
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () => _rejectBonus(bonus),
                      icon: const Icon(Icons.close, size: 18),
                      label: Text(isAr ? 'رفض' : 'Reject'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                    ),
                  ],
                  if (bonus.canPay()) ...[
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () => _payBonus(bonus),
                      icon: const Icon(Icons.payment, size: 18),
                      label: Text(isAr ? 'دفع' : 'Pay'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoItem(String label, String value, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.grey),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBulkActions(bool isAr, List<EmployeeBonusModel> filtered) {
    final pendingIds = filtered
        .where((b) => b.status == 'pending' && b.id != null)
        .map((b) => b.id!)
        .toList();

    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _bulkLoading ? null : () => _bulkApprove(pendingIds),
            icon: _bulkLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.check_circle),
            label: Text(isAr ? 'اعتماد الكل (معلق)' : 'Approve all pending'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _bulkLoading ? null : () => _bulkReject(pendingIds),
            icon: const Icon(Icons.close),
            label: Text(isAr ? 'رفض الكل (معلق)' : 'Reject all pending'),
          ),
        ),
      ],
    );
  }

  Future<void> _bulkApprove(List<int> ids) async {
    final isAr = widget.isArabic;
    if (ids.isEmpty) {
      _showSnack(
        isAr ? 'لا توجد مكافآت معلقة' : 'No pending bonuses',
        isError: true,
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isAr ? 'اعتماد جميع المعلّقة' : 'Approve all pending'),
        content: Text(
          isAr
              ? 'سيتم اعتماد ${ids.length} مكافأة معلقة.'
              : 'This will approve ${ids.length} pending bonuses.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isAr ? 'اعتماد' : 'Approve'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _bulkLoading = true);
    try {
      final res = await widget.api.bulkApproveBonuses(ids);
      final count = res['count'] ?? 0;
      _showSnack(isAr ? 'تم اعتماد $count' : 'Approved $count');
      _loadBonuses();
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _bulkLoading = false);
    }
  }

  Future<void> _bulkReject(List<int> ids) async {
    final isAr = widget.isArabic;
    if (ids.isEmpty) {
      _showSnack(
        isAr ? 'لا توجد مكافآت معلقة' : 'No pending bonuses',
        isError: true,
      );
      return;
    }

    String? reason;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: Text(isAr ? 'رفض جميع المعلّقة' : 'Reject all pending'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isAr
                    ? 'سيتم رفض ${ids.length} مكافأة معلقة.'
                    : 'This will reject ${ids.length} pending bonuses.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: isAr ? 'سبب الرفض (اختياري)' : 'Reason (optional)',
                  border: const OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(isAr ? 'إلغاء' : 'Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                reason = controller.text.trim().isEmpty
                    ? null
                    : controller.text.trim();
                Navigator.pop(ctx, true);
              },
              child: Text(isAr ? 'رفض' : 'Reject'),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    setState(() => _bulkLoading = true);
    try {
      final res = await widget.api.bulkRejectBonuses(ids, reason: reason);
      final count = res['count'] ?? 0;
      _showSnack(isAr ? 'تم رفض $count' : 'Rejected $count');
      _loadBonuses();
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _bulkLoading = false);
    }
  }
}

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _SummaryCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 170,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: Colors.white,
            child: Icon(icon, color: Colors.black87, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
