import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../models/employee_bonus_model.dart';
import '../widgets/user_avatar_widget.dart';
import '../models/safe_box_model.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'bonus_management_screen.dart';
import 'calculate_bonuses_screen.dart';
import '../widgets/bonus_owed_from_books_card.dart';

class BonusesScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  final bool embedded;

  const BonusesScreen({
    super.key,
    required this.api,
    this.isArabic = true,
    this.embedded = false,
  });

  @override
  State<BonusesScreen> createState() => _BonusesScreenState();
}

class _BonusesScreenState extends State<BonusesScreen>
    with SingleTickerProviderStateMixin {
  List<EmployeeBonusModel> _bonuses = [];
  // What each employee is owed in the books (BONUS-BOOKS-1): the books are
  // right -- a voucher outside this screen moves them, not a bonus's status.
  List<Map<String, dynamic>> _owed = [];
  bool _loading = false;
  bool _bulkLoading = false;

  // فلتر الحالة — الفلتر الأكثر استخداماً
  String? _statusFilter;

  // فلاتر متقدمة
  String? _ruleTypeFilter;
  String? _bonusTypeFilter;
  String? _departmentFilter;
  double? _minAmount;
  double? _maxAmount;
  DateTime? _periodStart;
  DateTime? _periodEnd;

  String _searchQuery = '';
  String _sortOption = 'newest';

  final _searchController = TextEditingController();

  static const _gold = Color(0xFFD4AF37);
  static const _goldDark = Color(0xFF8B6914);

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

  // ─────────────────────────────── Data ───────────────────────────────

  Future<void> _loadBonuses() async {
    setState(() => _loading = true);
    try {
      final data = await widget.api.getBonuses(
        status: _statusFilter,
        dateFrom: _periodStart?.toIso8601String().split('T').first,
        dateTo: _periodEnd?.toIso8601String().split('T').first,
      );
      final owed = await widget.api.getBonusesOwed();
      setState(() {
        _bonuses = data
            .map((j) => EmployeeBonusModel.fromJson(j as Map<String, dynamic>))
            .toList();
        _owed = ((owed['employees'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
      });
    } catch (e) {
      _snack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<EmployeeBonusModel> get _filtered {
    Iterable<EmployeeBonusModel> list = _bonuses;

    if (_ruleTypeFilter != null) {
      list = list.where((b) => b.bonusRule?.ruleType == _ruleTypeFilter);
    }
    if (_bonusTypeFilter != null) {
      list = list.where((b) => b.bonusType == _bonusTypeFilter);
    }
    if (_departmentFilter != null) {
      final d = _departmentFilter!.toLowerCase();
      list = list.where((b) =>
          b.employee?.department != null &&
          b.employee!.department!.toLowerCase() == d);
    }
    if (_minAmount != null) list = list.where((b) => b.amount >= _minAmount!);
    if (_maxAmount != null) list = list.where((b) => b.amount <= _maxAmount!);

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((b) {
        return [
          b.employee?.fullName,
          b.employee?.employeeCode,
          b.employee?.department,
          b.employee?.position,
          b.bonusRule?.name,
          b.bonusType,
          b.notes,
        ].any((f) => f != null && f.toLowerCase().contains(q));
      });
    }

    final sorted = list.toList();
    switch (_sortOption) {
      case 'amount_desc':
        sorted.sort((a, b) => b.amount.compareTo(a.amount));
      case 'amount_asc':
        sorted.sort((a, b) => a.amount.compareTo(b.amount));
      case 'oldest':
        sorted.sort((a, b) => a.periodStart.compareTo(b.periodStart));
      case 'status':
        sorted.sort((a, b) => a.status.compareTo(b.status));
      default:
        sorted.sort((a, b) => b.periodStart.compareTo(a.periodStart));
    }
    return sorted;
  }

  bool get _hasActiveFilters =>
      _ruleTypeFilter != null ||
      _bonusTypeFilter != null ||
      _departmentFilter != null ||
      _minAmount != null ||
      _maxAmount != null ||
      _periodStart != null ||
      _periodEnd != null;

  void _clearFilters() {
    setState(() {
      _ruleTypeFilter = null;
      _bonusTypeFilter = null;
      _departmentFilter = null;
      _minAmount = null;
      _maxAmount = null;
      _periodStart = null;
      _periodEnd = null;
    });
    _loadBonuses();
  }

  // ─────────────────────────────── Actions ───────────────────────────────

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : _goldDark,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _approve(EmployeeBonusModel b) async {
    if (b.id == null) return;
    try {
      await widget.api.approveBonus(b.id!);
      _snack(widget.isArabic ? 'تم الاعتماد' : 'Approved');
      _loadBonuses();
    } catch (e) {
      _snack(e.toString(), error: true);
    }
  }

  Future<void> _reject(EmployeeBonusModel b) async {
    if (b.id == null) return;
    try {
      await widget.api.rejectBonus(b.id!);
      _snack(widget.isArabic ? 'تم الرفض' : 'Rejected');
      _loadBonuses();
    } catch (e) {
      _snack(e.toString(), error: true);
    }
  }

  Future<void> _pay(EmployeeBonusModel bonus) async {
    final isAr = widget.isArabic;
    List<SafeBoxModel> safeBoxes = [];
    try {
      final all = await widget.api.getSafeBoxes(
          isActive: true, includeBalance: true, includeAccount: false);
      safeBoxes = all
          .where((s) => s.safeType == 'cash' || s.safeType == 'bank')
          .toList();
    } catch (e) {
      _snack('${isAr ? 'فشل تحميل الخزائن' : 'Failed to load safes'}: $e',
          error: true);
      return;
    }

    if (safeBoxes.isEmpty) {
      _snack(isAr ? 'لا توجد خزائن متاحة' : 'No safe boxes available',
          error: true);
      return;
    }

    final selected = await showDialog<SafeBoxModel>(
      context: context,
      builder: (ctx) {
        SafeBoxModel? choice = safeBoxes.first;
        return StatefulBuilder(
          builder: (ctx, ss) => AlertDialog(
            title: Text(isAr ? 'اختر خزينة الدفع' : 'Select Payment Safe'),
            content: DropdownButtonFormField<SafeBoxModel>(
              value: choice,
              isExpanded: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: safeBoxes.map((sb) {
                final bal = sb.balance?.cash ?? 0.0;
                final ok = bal >= bonus.amount;
                return DropdownMenuItem(
                  value: sb,
                  child: Row(
                    children: [
                      Expanded(
                          child: Text(sb.name, overflow: TextOverflow.ellipsis)),
                      Text(
                        bal.toStringAsFixed(0),
                        style: TextStyle(
                            fontSize: 12,
                            color: ok ? Colors.green : Colors.red),
                      ),
                    ],
                  ),
                );
              }).toList(),
              onChanged: (v) => ss(() => choice = v),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(isAr ? 'إلغاء' : 'Cancel')),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, choice),
                  child: Text(isAr ? 'دفع' : 'Pay')),
            ],
          ),
        );
      },
    );

    if (selected?.id != null && bonus.id != null) {
      try {
        await widget.api.payBonus(
          bonus.id!,
          safeBoxId: selected!.id!,
          paymentMethod: selected.safeType == 'bank' ? 'transfer' : 'cash',
        );
        _snack(isAr ? 'تم تسجيل الدفع' : 'Payment recorded');
        _loadBonuses();
      } catch (e) {
        _snack(e.toString(), error: true);
      }
    }
  }

  Future<void> _edit(EmployeeBonusModel bonus) async {
    final isAr = widget.isArabic;
    if (bonus.status != 'pending') {
      _snack(isAr ? 'يمكن تعديل المعلقة فقط' : 'Only pending can be edited',
          error: true);
      return;
    }
    final amtCtrl = TextEditingController(text: bonus.amount.toStringAsFixed(2));
    final noteCtrl = TextEditingController(text: bonus.notes ?? '');
    DateTime start = bonus.periodStart;
    DateTime end = bonus.periodEnd;
    final fmt = DateFormat('yyyy-MM-dd');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, ss) => AlertDialog(
          title: Text(isAr ? 'تعديل المكافأة' : 'Edit Bonus'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: amtCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: isAr ? 'المبلغ' : 'Amount',
                  prefixIcon: const Icon(Icons.attach_money),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: isAr ? 'ملاحظات' : 'Notes',
                  prefixIcon: const Icon(Icons.notes),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final p = await showDatePicker(
                          context: ctx,
                          initialDate: start,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100));
                      if (p != null) ss(() => start = p);
                    },
                    child: InputDecorator(
                      decoration: InputDecoration(
                          labelText: isAr ? 'من' : 'From',
                          border: const OutlineInputBorder()),
                      child: Text(fmt.format(start)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final p = await showDatePicker(
                          context: ctx,
                          initialDate: end,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100));
                      if (p != null) ss(() => end = p);
                    },
                    child: InputDecorator(
                      decoration: InputDecoration(
                          labelText: isAr ? 'إلى' : 'To',
                          border: const OutlineInputBorder()),
                      child: Text(fmt.format(end)),
                    ),
                  ),
                ),
              ]),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(isAr ? 'إلغاء' : 'Cancel')),
            ElevatedButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.save, size: 18),
                label: Text(isAr ? 'حفظ' : 'Save')),
          ],
        ),
      ),
    );

    if (ok == true && bonus.id != null) {
      final amount = double.tryParse(amtCtrl.text.trim());
      if (amount == null) {
        _snack(isAr ? 'مبلغ غير صحيح' : 'Invalid amount', error: true);
        return;
      }
      try {
        await widget.api.updateBonus(bonus.id!, {
          'amount': amount,
          'notes':
              noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
          'period_start': fmt.format(start),
          'period_end': fmt.format(end),
        });
        _snack(isAr ? 'تم التحديث' : 'Updated');
        _loadBonuses();
      } catch (e) {
        _snack(e.toString(), error: true);
      }
    }
  }

  Future<void> _bulkApprove(List<int> ids) async {
    final isAr = widget.isArabic;
    if (ids.isEmpty) {
      _snack(isAr ? 'لا توجد مكافآت معلقة' : 'No pending bonuses', error: true);
      return;
    }
    final ok = await _confirm(
      isAr ? 'اعتماد ${ids.length} مكافأة معلقة؟' : 'Approve ${ids.length} pending bonuses?',
    );
    if (!ok) return;
    setState(() => _bulkLoading = true);
    try {
      final res = await widget.api.bulkApproveBonuses(ids);
      _snack(isAr ? 'تم اعتماد ${res['count'] ?? 0}' : 'Approved ${res['count'] ?? 0}');
      _loadBonuses();
    } catch (e) {
      _snack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _bulkLoading = false);
    }
  }

  Future<void> _bulkReject(List<int> ids) async {
    final isAr = widget.isArabic;
    if (ids.isEmpty) {
      _snack(isAr ? 'لا توجد مكافآت معلقة' : 'No pending bonuses', error: true);
      return;
    }
    String? reason;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: Text(isAr ? 'رفض ${ids.length} مكافأة' : 'Reject ${ids.length} bonuses'),
          content: TextField(
            controller: ctrl,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: isAr ? 'سبب الرفض (اختياري)' : 'Reason (optional)',
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(isAr ? 'إلغاء' : 'Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () {
                reason = ctrl.text.trim().isEmpty ? null : ctrl.text.trim();
                Navigator.pop(ctx, true);
              },
              child: Text(isAr ? 'رفض' : 'Reject'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    setState(() => _bulkLoading = true);
    try {
      final res = await widget.api.bulkRejectBonuses(ids, reason: reason);
      _snack(isAr ? 'تم رفض ${res['count'] ?? 0}' : 'Rejected ${res['count'] ?? 0}');
      _loadBonuses();
    } catch (e) {
      _snack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _bulkLoading = false);
    }
  }

  Future<bool> _confirm(String message) async {
    final isAr = widget.isArabic;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: Text(message),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(isAr ? 'إلغاء' : 'Cancel')),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(isAr ? 'تأكيد' : 'Confirm')),
            ],
          ),
        ) ??
        false;
  }

  // ─────────────────────────────── Bottom Sheet: تفاصيل المكافأة ───────────────────────────────

  void _showDetails(EmployeeBonusModel b) {
    final isAr = widget.isArabic;
    final fmt = DateFormat('yyyy-MM-dd');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (_, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // Handle
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    _Avatar(name: b.employee?.fullName ?? '?', size: 48, photo: b.employee?.photo),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            b.employee?.fullName ?? (isAr ? 'غير محدد' : 'Unknown'),
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.bold),
                          ),
                          if (b.employee?.position != null)
                            Text(b.employee!.position!,
                                style: TextStyle(
                                    color: Colors.grey.shade600, fontSize: 13)),
                        ],
                      ),
                    ),
                    _StatusBadge(status: b.status),
                  ],
                ),
              ),
              const Divider(height: 28, indent: 20, endIndent: 20),

              // Details list
              Expanded(
                child: ListView(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  children: [
                    // Amount — بارز
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: _gold.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.monetization_on_rounded,
                              color: _gold, size: 28),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(isAr ? 'المبلغ' : 'Amount',
                                  style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 12)),
                              Text(
                                '${b.amount.toStringAsFixed(2)} ${context.read<SettingsProvider>().currencySymbolText}',
                                style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                    color: _goldDark),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Info grid
                    _DetailRow(
                        label: isAr ? 'القاعدة' : 'Rule',
                        value: b.bonusRule?.name ?? '—',
                        icon: Icons.rule_rounded),
                    _DetailRow(
                        label: isAr ? 'نوع المكافأة' : 'Bonus type',
                        value: b.bonusType,
                        icon: Icons.category_outlined),
                    _DetailRow(
                        label: isAr ? 'الفترة' : 'Period',
                        value:
                            '${fmt.format(b.periodStart)}  →  ${fmt.format(b.periodEnd)}',
                        icon: Icons.date_range_rounded),
                    if (b.approvedAt != null)
                      _DetailRow(
                          label: isAr ? 'تاريخ الاعتماد' : 'Approved',
                          value: fmt.format(b.approvedAt!),
                          icon: Icons.check_circle_outline),
                    if (b.approvedBy != null)
                      _DetailRow(
                          label: isAr ? 'اعتمد بواسطة' : 'Approved by',
                          value: b.approvedBy!,
                          icon: Icons.person_outline),
                    if (b.paidAt != null)
                      _DetailRow(
                          label: isAr ? 'تاريخ الدفع' : 'Paid',
                          value: fmt.format(b.paidAt!),
                          icon: Icons.payments_outlined),
                    if (b.paymentReference != null &&
                        b.paymentReference!.isNotEmpty)
                      _DetailRow(
                          label: isAr ? 'مرجع الدفع' : 'Payment ref',
                          value: b.paymentReference!,
                          icon: Icons.receipt_long_outlined),
                    if (b.notes != null && b.notes!.isNotEmpty)
                      _DetailRow(
                          label: isAr ? 'ملاحظات' : 'Notes',
                          value: b.notes!,
                          icon: Icons.notes_rounded),

                    // Calculation data
                    if (b.calculationData != null &&
                        b.calculationData!.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(isAr ? 'تفاصيل الاحتساب' : 'Calculation details',
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade500,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      ...b.calculationData!.entries
                          .where((e) => e.value != null)
                          .map((e) => Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 3),
                                child: Row(children: [
                                  Text('${e.key}:',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade600)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                      child: Text('${e.value}',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500))),
                                ]),
                              )),
                    ],

                    // Actions
                    if (b.canApprove() || b.canReject() || b.canPay()) ...[
                      const SizedBox(height: 24),
                      if (b.status == 'pending')
                        _ActionButton(
                          label: isAr ? 'تعديل' : 'Edit',
                          icon: Icons.edit_outlined,
                          color: Colors.blueGrey,
                          onTap: () {
                            Navigator.pop(ctx);
                            _edit(b);
                          },
                        ),
                      if (b.canApprove()) ...[
                        const SizedBox(height: 8),
                        _ActionButton(
                          label: isAr ? 'اعتماد' : 'Approve',
                          icon: Icons.check_circle_outline,
                          color: Colors.green,
                          onTap: () {
                            Navigator.pop(ctx);
                            _approve(b);
                          },
                        ),
                      ],
                      if (b.canReject()) ...[
                        const SizedBox(height: 8),
                        _ActionButton(
                          label: isAr ? 'رفض' : 'Reject',
                          icon: Icons.cancel_outlined,
                          color: Colors.red,
                          outlined: true,
                          onTap: () {
                            Navigator.pop(ctx);
                            _reject(b);
                          },
                        ),
                      ],
                      if (b.canPay()) ...[
                        const SizedBox(height: 8),
                        _ActionButton(
                          label: isAr ? 'دفع' : 'Pay',
                          icon: Icons.payments_outlined,
                          color: Colors.blue,
                          onTap: () {
                            Navigator.pop(ctx);
                            _pay(b);
                          },
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────── Filter Bottom Sheet ───────────────────────────────

  void _showFilters() {
    final isAr = widget.isArabic;
    final fmt = DateFormat('yyyy-MM-dd');

    final ruleTypes = _bonuses
        .map((b) => b.bonusRule?.ruleType)
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();
    final departments = _bonuses
        .map((b) => b.employee?.department)
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        String? tStatus = _statusFilter;
        String? tRule = _ruleTypeFilter;
        String? tBonus = _bonusTypeFilter;
        String? tDept = _departmentFilter;
        String tMin = _minAmount?.toString() ?? '';
        String tMax = _maxAmount?.toString() ?? '';
        DateTime? tStart = _periodStart;
        DateTime? tEnd = _periodEnd;

        return StatefulBuilder(
          builder: (ctx, ss) => DraggableScrollableSheet(
            initialChildSize: 0.75,
            minChildSize: 0.5,
            maxChildSize: 0.92,
            builder: (_, sc) => Container(
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  // Handle + title
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 8, left: 8),
                          child: Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            isAr ? 'تصفية متقدمة' : 'Advanced Filters',
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _clearFilters();
                          },
                          child: Text(isAr ? 'مسح' : 'Clear',
                              style: const TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                  ),
                  const Divider(),
                  Expanded(
                    child: ListView(
                      controller: sc,
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      children: [
                        _FilterSection(
                          label: isAr ? 'الحالة' : 'Status',
                          child: DropdownButtonFormField<String?>(
                            value: tStatus,
                            decoration: const InputDecoration(
                                border: OutlineInputBorder(), isDense: true),
                            items: [
                              DropdownMenuItem(
                                  value: null,
                                  child: Text(isAr ? 'الكل' : 'All')),
                              ...EmployeeBonusModel.statuses.map((s) =>
                                  DropdownMenuItem(
                                      value: s,
                                      child: Text(
                                          EmployeeBonusModel.getStatusNameAr(
                                              s)))),
                            ],
                            onChanged: (v) => ss(() => tStatus = v),
                          ),
                        ),
                        if (ruleTypes.isNotEmpty)
                          _FilterSection(
                            label: isAr ? 'نوع القاعدة' : 'Rule type',
                            child: DropdownButtonFormField<String?>(
                              value: tRule,
                              decoration: const InputDecoration(
                                  border: OutlineInputBorder(), isDense: true),
                              items: [
                                DropdownMenuItem(
                                    value: null,
                                    child: Text(isAr ? 'الكل' : 'All')),
                                ...ruleTypes.map((r) => DropdownMenuItem(
                                    value: r, child: Text(r))),
                              ],
                              onChanged: (v) => ss(() => tRule = v),
                            ),
                          ),
                        if (departments.isNotEmpty)
                          _FilterSection(
                            label: isAr ? 'القسم' : 'Department',
                            child: DropdownButtonFormField<String?>(
                              value: tDept,
                              decoration: const InputDecoration(
                                  border: OutlineInputBorder(), isDense: true),
                              items: [
                                DropdownMenuItem(
                                    value: null,
                                    child: Text(isAr ? 'الكل' : 'All')),
                                ...departments.map((d) => DropdownMenuItem(
                                    value: d, child: Text(d))),
                              ],
                              onChanged: (v) => ss(() => tDept = v),
                            ),
                          ),
                        _FilterSection(
                          label: isAr ? 'نطاق المبلغ' : 'Amount range',
                          child: Row(children: [
                            Expanded(
                              child: TextFormField(
                                initialValue: tMin,
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                    labelText: isAr ? 'من' : 'Min',
                                    border: const OutlineInputBorder(),
                                    isDense: true),
                                onChanged: (v) => tMin = v,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                initialValue: tMax,
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                    labelText: isAr ? 'إلى' : 'Max',
                                    border: const OutlineInputBorder(),
                                    isDense: true),
                                onChanged: (v) => tMax = v,
                              ),
                            ),
                          ]),
                        ),
                        _FilterSection(
                          label: isAr ? 'الفترة الزمنية' : 'Period',
                          child: Column(children: [
                            // Period presets
                            Wrap(spacing: 8, runSpacing: 8, children: [
                              _PeriodChip(
                                  label: isAr ? 'هذا الشهر' : 'This month',
                                  selected: tStart != null &&
                                      tStart!.day == 1 &&
                                      tStart!.month == DateTime.now().month,
                                  onTap: () {
                                    final n = DateTime.now();
                                    ss(() {
                                      tStart = DateTime(n.year, n.month, 1);
                                      tEnd = DateTime(n.year, n.month + 1, 0);
                                    });
                                  }),
                              _PeriodChip(
                                  label: isAr ? 'الشهر الماضي' : 'Last month',
                                  selected: false,
                                  onTap: () {
                                    final n = DateTime.now();
                                    ss(() {
                                      tStart = DateTime(n.year, n.month - 1, 1);
                                      tEnd = DateTime(n.year, n.month, 0);
                                    });
                                  }),
                              _PeriodChip(
                                  label: isAr ? 'الربع الحالي' : 'Quarter',
                                  selected: false,
                                  onTap: () {
                                    final n = DateTime.now();
                                    final q = ((n.month - 1) ~/ 3) * 3 + 1;
                                    ss(() {
                                      tStart = DateTime(n.year, q, 1);
                                      tEnd = DateTime(n.year, q + 3, 0);
                                    });
                                  }),
                            ]),
                            const SizedBox(height: 12),
                            Row(children: [
                              Expanded(
                                child: InkWell(
                                  onTap: () async {
                                    final p = await showDatePicker(
                                        context: context,
                                        initialDate: tStart ?? DateTime.now(),
                                        firstDate: DateTime(2020),
                                        lastDate: DateTime(2100));
                                    if (p != null) ss(() => tStart = p);
                                  },
                                  child: InputDecorator(
                                    decoration: InputDecoration(
                                        labelText: isAr ? 'من تاريخ' : 'From',
                                        border: const OutlineInputBorder(),
                                        isDense: true),
                                    child: Text(tStart != null
                                        ? fmt.format(tStart!)
                                        : '—'),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: InkWell(
                                  onTap: () async {
                                    final p = await showDatePicker(
                                        context: context,
                                        initialDate: tEnd ?? DateTime.now(),
                                        firstDate: DateTime(2020),
                                        lastDate: DateTime(2100));
                                    if (p != null) ss(() => tEnd = p);
                                  },
                                  child: InputDecorator(
                                    decoration: InputDecoration(
                                        labelText: isAr ? 'إلى تاريخ' : 'To',
                                        border: const OutlineInputBorder(),
                                        isDense: true),
                                    child: Text(
                                        tEnd != null ? fmt.format(tEnd!) : '—'),
                                  ),
                                ),
                              ),
                            ]),
                          ]),
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _gold,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: () {
                              setState(() {
                                _statusFilter = tStatus;
                                _ruleTypeFilter = tRule;
                                _bonusTypeFilter = tBonus;
                                _departmentFilter = tDept;
                                _minAmount = tMin.trim().isEmpty
                                    ? null
                                    : double.tryParse(tMin.trim());
                                _maxAmount = tMax.trim().isEmpty
                                    ? null
                                    : double.tryParse(tMax.trim());
                                _periodStart = tStart;
                                _periodEnd = tEnd;
                              });
                              Navigator.pop(ctx);
                              _loadBonuses();
                            },
                            child: Text(isAr ? 'تطبيق الفلاتر' : 'Apply Filters',
                                style: const TextStyle(fontSize: 15)),
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
      },
    );
  }

  // ─────────────────────────────── Build ───────────────────────────────

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsProvider>();
    final isAr = widget.isArabic;
    final filtered = _filtered;
    final pendingIds = filtered
        .where((b) => b.status == 'pending' && b.id != null)
        .map((b) => b.id!)
        .toList();

    // ── المحتوى المشترك بين المضمّن والمستقل ──
    Widget body = _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _loadBonuses,
            color: _gold,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _buildSummary(isAr)),
                if (_owed.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: BonusOwedFromBooksCard(rows: _owed, isArabic: isAr),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                })
                            : null,
                        hintText: isAr
                            ? 'ابحث باسم الموظف، القاعدة، الملاحظات'
                            : 'Search by name, rule, notes',
                        filled: true,
                        fillColor: Theme.of(context).colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.45),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: Theme.of(context)
                                .dividerColor
                                .withValues(alpha: 0.3),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: Theme.of(context)
                                .dividerColor
                                .withValues(alpha: 0.3),
                          ),
                        ),
                      ),
                      onChanged: (v) => setState(() => _searchQuery = v.trim()),
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: _buildStatusTabs(isAr)),
                if (pendingIds.isNotEmpty)
                  SliverToBoxAdapter(child: _buildBulkBar(isAr, pendingIds)),
                if (filtered.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.inbox_rounded, size: 48,
                              color: Theme.of(context).hintColor.withValues(alpha: 0.35)),
                          const SizedBox(height: 12),
                          Text(
                            isAr ? 'لا توجد مكافآت' : 'No bonuses',
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            isAr
                                ? 'ابدأ بـ "احتساب" لإنشاء أول مجموعة'
                                : 'Start with "Calculate" to create your first batch',
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).hintColor),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: () {
                              final mgmt = context
                                  .findAncestorStateOfType<BonusManagementScreenState>();
                              mgmt?.switchTab(2);
                            },
                            icon: const Icon(Icons.calculate_rounded, size: 16),
                            label: Text(isAr ? 'احتساب الآن' : 'Calculate now'),
                            style: FilledButton.styleFrom(
                                backgroundColor: AppColors.primaryGold),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, widget.embedded ? 16 : 100),
                    sliver: SliverList.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (context, index) => const SizedBox(height: 8),
                      itemBuilder: (_, i) =>
                          _BonusTile(bonus: filtered[i], onTap: () => _showDetails(filtered[i])),
                    ),
                  ),
              ],
            ),
          );

    // ── وضع التضمين: بدون Scaffold ──
    if (widget.embedded) {
      return Column(children: [
        // شريط أدوات مضغوط
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 4, 0),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 20),
              onPressed: _loading ? null : _loadBonuses,
              tooltip: isAr ? 'تحديث' : 'Refresh',
            ),
            Stack(alignment: Alignment.center, children: [
              IconButton(
                icon: const Icon(Icons.tune_rounded, size: 20),
                onPressed: _showFilters,
                tooltip: isAr ? 'فلاتر' : 'Filters',
              ),
              if (_hasActiveFilters)
                Positioned(
                  top: 8, right: 8,
                  child: Container(
                    width: 7, height: 7,
                    decoration: const BoxDecoration(color: _gold, shape: BoxShape.circle),
                  ),
                ),
            ]),
            PopupMenuButton<String>(
              icon: const Icon(Icons.sort_rounded, size: 20),
              onSelected: (v) => setState(() => _sortOption = v),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'newest', child: Text(isAr ? 'الأحدث' : 'Newest')),
                PopupMenuItem(value: 'oldest', child: Text(isAr ? 'الأقدم' : 'Oldest')),
                PopupMenuItem(value: 'amount_desc', child: Text(isAr ? 'الأعلى مبلغاً' : 'Highest')),
                PopupMenuItem(value: 'amount_asc', child: Text(isAr ? 'الأقل مبلغاً' : 'Lowest')),
                PopupMenuItem(value: 'status', child: Text(isAr ? 'حسب الحالة' : 'By status')),
              ],
            ),
          ]),
        ),
        Expanded(child: body),
      ]);
    }

    // ── وضع مستقل: Scaffold كامل ──
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: Text(isAr ? 'المكافآت' : 'Bonuses'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _loadBonuses,
          ),
          Stack(alignment: Alignment.center, children: [
            IconButton(icon: const Icon(Icons.tune_rounded), onPressed: _showFilters),
            if (_hasActiveFilters)
              Positioned(
                top: 8, right: 8,
                child: Container(
                  width: 8, height: 8,
                  decoration: const BoxDecoration(color: _gold, shape: BoxShape.circle),
                ),
              ),
          ]),
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort_rounded),
            onSelected: (v) => setState(() => _sortOption = v),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'newest', child: Text(isAr ? 'الأحدث' : 'Newest')),
              PopupMenuItem(value: 'oldest', child: Text(isAr ? 'الأقدم' : 'Oldest')),
              PopupMenuItem(value: 'amount_desc', child: Text(isAr ? 'الأعلى مبلغاً' : 'Highest')),
              PopupMenuItem(value: 'amount_asc', child: Text(isAr ? 'الأقل مبلغاً' : 'Lowest')),
              PopupMenuItem(value: 'status', child: Text(isAr ? 'حسب الحالة' : 'By status')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CalculateBonusesScreen(api: widget.api, isArabic: widget.isArabic),
          ),
        ).then((_) => _loadBonuses()),
        backgroundColor: _gold,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.calculate_rounded),
        label: Text(isAr ? 'احتساب' : 'Calculate'),
      ),
      body: body,
    );
  }

  Widget _buildSummary(bool isAr) {
    final total = _bonuses.fold<double>(0, (s, b) => s + b.amount);
    final pending = _bonuses.where((b) => b.status == 'pending').length;
    final approved = _bonuses.where((b) => b.status == 'approved').length;
    final paid = _bonuses.where((b) => b.status == 'paid').length;

    // trend: مقارنة آخر 30 يوم بالفترة السابقة
    final now = DateTime.now();
    final prevEnd = now.subtract(const Duration(days: 30));
    final prevStart = now.subtract(const Duration(days: 60));
    final thisTotal = _bonuses
        .where((b) => b.periodStart.isAfter(prevEnd))
        .fold<double>(0, (s, b) => s + b.amount);
    final lastTotal = _bonuses
        .where((b) => b.periodStart.isAfter(prevStart) && b.periodStart.isBefore(prevEnd))
        .fold<double>(0, (s, b) => s + b.amount);
    final pctChange = lastTotal > 0 ? ((thisTotal - lastTotal) / lastTotal * 100) : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Row(children: [
        Expanded(child: _SmartMetricTile(
          label: isAr ? 'الإجمالي' : 'Total',
          value: '${total.toStringAsFixed(0)} ${context.read<SettingsProvider>().currencySymbolText}',
          color: AppColors.info,
          icon: Icons.payments_outlined,
          trend: pctChange,
          trendLabel: isAr ? 'عن الفترة السابقة' : 'vs last period',
        )),
        const SizedBox(width: 8),
        Expanded(child: _SmartMetricTile(
          label: isAr ? 'معلّقة' : 'Pending',
          value: '$pending',
          color: AppColors.warning,
          icon: Icons.pending_actions_outlined,
          subtitle: pending > 0 ? (isAr ? 'يحتاج اعتماد' : 'needs review') : (isAr ? 'لا شيء معلق' : 'all clear'),
        )),
        const SizedBox(width: 8),
        Expanded(child: _SmartMetricTile(
          label: isAr ? 'معتمدة' : 'Approved',
          value: '$approved',
          color: AppColors.success,
          icon: Icons.check_circle_outline,
          subtitle: isAr ? 'جاهزة للدفع' : 'ready to pay',
        )),
        const SizedBox(width: 8),
        Expanded(child: _SmartMetricTile(
          label: isAr ? 'مدفوعة' : 'Paid',
          value: '$paid',
          color: AppColors.primaryGold,
          icon: Icons.task_alt_rounded,
          subtitle: isAr ? 'كل الفترات' : 'all periods',
        )),
      ]),
    );
  }

  Widget _buildStatusTabs(bool isAr) {
    final statuses = [null, ...EmployeeBonusModel.statuses];
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: statuses.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final s = statuses[i];
          final selected = _statusFilter == s;
          final label = s == null
              ? (isAr ? 'الكل' : 'All')
              : EmployeeBonusModel.getStatusNameAr(s);
          return ChoiceChip(
            label: Text(label, style: const TextStyle(fontSize: 11.5)),
            selected: selected,
            selectedColor: AppColors.primaryGold.withValues(alpha: 0.2),
            checkmarkColor: AppColors.darkGold,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            labelStyle: TextStyle(
              color: selected ? AppColors.darkGold : null,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
            onSelected: (_) {
              setState(() => _statusFilter = s);
              _loadBonuses();
            },
          );
        },
      ),
    );
  }

  Widget _buildBulkBar(bool isAr, List<int> pendingIds) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(children: [
        Icon(Icons.pending_actions_rounded,
            color: Colors.orange.shade700, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${pendingIds.length} ${isAr ? 'معلّقة' : 'pending'}',
            style: TextStyle(
                color: Colors.orange.shade800, fontWeight: FontWeight.w600),
          ),
        ),
        TextButton.icon(
          onPressed: _bulkLoading ? null : () => _bulkApprove(pendingIds),
          icon: _bulkLoading
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.check_circle_outline, size: 16),
          label: Text(isAr ? 'اعتماد الكل' : 'Approve all'),
          style: TextButton.styleFrom(foregroundColor: Colors.green.shade700),
        ),
        TextButton.icon(
          onPressed: _bulkLoading ? null : () => _bulkReject(pendingIds),
          icon: const Icon(Icons.cancel_outlined, size: 16),
          label: Text(isAr ? 'رفض الكل' : 'Reject all'),
          style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
        ),
      ]),
    );
  }
}

// ─────────────────────────────── Sub-widgets ───────────────────────────────

class _BonusTile extends StatelessWidget {
  final EmployeeBonusModel bonus;
  final VoidCallback onTap;

  const _BonusTile({required this.bonus, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('d MMM yyyy', 'ar');

    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            _Avatar(name: bonus.employee?.fullName ?? '?', size: 42, photo: bonus.employee?.photo),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bonus.employee?.fullName ?? '—',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    bonus.bonusRule?.name ?? bonus.bonusType,
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${fmt.format(bonus.periodStart)} → ${fmt.format(bonus.periodEnd)}',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${bonus.amount.toStringAsFixed(0)} ${context.read<SettingsProvider>().currencySymbolText}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Color(0xFF8B6914)),
                ),
                const SizedBox(height: 4),
                _StatusBadge(status: bonus.status),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String name;
  final double size;
  final String? photo;

  const _Avatar({required this.name, required this.size, this.photo});

  @override
  Widget build(BuildContext context) {
    return EmployeeAvatarWidget(
      name: name,
      photoBase64: photo,
      radius: size / 2,
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = Color(EmployeeBonusModel.getStatusColor(status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        EmployeeBonusModel.getStatusNameAr(status),
        style: TextStyle(
            fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _SmartMetricTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;
  final double? trend;
  final String? trendLabel;
  final String? subtitle;

  const _SmartMetricTile({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
    this.trend,
    this.trendLabel,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
            Flexible(
              child: Text(label,
                  style: TextStyle(fontSize: 10.5, color: theme.hintColor, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(value,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: color, letterSpacing: -0.3)),
          ),
          const SizedBox(height: 2),
          if (trend != null) ...[
            Row(children: [
              Icon(
                trend! >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded,
                size: 11,
                color: trend! >= 0 ? AppColors.success : AppColors.error,
              ),
              const SizedBox(width: 2),
              Flexible(
                child: Text(
                  '${trend!.abs().toStringAsFixed(1)}% ${trendLabel ?? ""}',
                  style: TextStyle(fontSize: 9.5,
                      color: trend! >= 0 ? AppColors.success : AppColors.error,
                      fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          ] else if (subtitle != null)
            Text(subtitle!,
                style: TextStyle(fontSize: 9.5, color: theme.hintColor),
                overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _DetailRow(
      {required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: Colors.grey.shade400),
        const SizedBox(width: 10),
        SizedBox(
          width: 100,
          child: Text(label,
              style:
                  TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500)),
        ),
      ]),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool outlined;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    if (outlined) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: color,
            side: BorderSide(color: color),
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }
}

class _FilterSection extends StatelessWidget {
  final String label;
  final Widget child;

  const _FilterSection({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey)),
        const SizedBox(height: 6),
        child,
      ]),
    );
  }
}

class _PeriodChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PeriodChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      selectedColor: const Color(0xFFD4AF37).withValues(alpha: 0.2),
      checkmarkColor: const Color(0xFF8B6914),
      onSelected: (_) => onTap(),
    );
  }
}
