import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../models/employee_bonus_model.dart';
import '../widgets/user_avatar_widget.dart';
import '../models/safe_box_model.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../utils/currency_utils.dart' as cu;
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/confirm_financial_action.dart';
import '../widgets/tiered_rule_editor.dart' show tierMeasures;
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
      if (!mounted) return;
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
      if (mounted) AppFeedback.error(context, e, title: 'تعذّر تحميل المكافآت');
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
  // Each act says what it does to the books before it does it, and how it
  // went in the server's words (bonus study م3ب).

  String get _currency => context.read<SettingsProvider>().currencySymbolText;

  String _money(num v) => '${cu.formatAmount(v)} $_currency';

  static final _day = DateFormat('yyyy-MM-dd');

  List<(String, String)> _factsOf(EmployeeBonusModel b) => [
        ('الموظف', b.employee?.fullName ?? '—'),
        ('المبلغ', _money(b.amount)),
        ('الفترة', '${_day.format(b.periodStart)} → ${_day.format(b.periodEnd)}'),
      ];

  Future<void> _approve(EmployeeBonusModel b) async {
    if (b.id == null) return;
    final why = bonusWhy(b, _currency);
    final go = await confirmFinancialAction(
      context,
      title: 'اعتماد مكافأة',
      facts: _factsOf(b),
      effect: '${why == null ? '' : '$why.\n'}'
          'يُسجَّل قيد اعتمادها: مصروف المكافآت مدين، ومكافآت '
          '${b.employee?.fullName ?? 'الموظف'} المستحقة دائنة بـ ${_money(b.amount)}.',
      confirmLabel: 'اعتماد',
      destructive: false,
    );
    if (go == null || !mounted) return;
    try {
      final answer = await widget.api.approveBonus(b.id!);
      final number = (answer['voucher'] as Map?)?['voucher_number'];
      if (mounted) {
        AppFeedback.success(
            context, number == null ? 'اعتُمدت' : 'اعتُمدت، وقيدها $number');
      }
      _loadBonuses();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'لم تُعتمد');
    }
  }

  /// A pending bonus has no entry yet, so rejecting one makes or undoes none;
  /// a reason, if one is written, is kept in its note. Null: the user went back.
  Future<String?> _askRejection(String title) => showDialog<String>(
        context: context,
        builder: (_) => _RejectDialog(title: title),
      );

  Future<void> _reject(EmployeeBonusModel b) async {
    if (b.id == null) return;
    final reason = await _askRejection(
        'رفض مكافأة ${b.employee?.fullName ?? ''} (${_money(b.amount)})');
    if (reason == null || !mounted) return;
    try {
      await widget.api
          .rejectBonus(b.id!, reason: reason.isEmpty ? null : reason);
      if (mounted) AppFeedback.success(context, 'رُفضت');
      _loadBonuses();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'لم تُرفض');
    }
  }

  Future<void> _pay(EmployeeBonusModel bonus) async {
    if (bonus.id == null) return;
    List<SafeBoxModel> safes;
    try {
      final all = await widget.api.getSafeBoxes(
          isActive: true, includeBalance: true, includeAccount: false);
      safes = all
          .where((s) => s.safeType == 'cash' || s.safeType == 'bank')
          .toList();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'تعذّر تحميل الخزائن');
      return;
    }
    if (!mounted) return;
    if (safes.isEmpty) {
      AppFeedback.warning(context, 'لا خزينة نقد أو بنك نشطة يُصرف منها');
      return;
    }
    final safe = await showDialog<SafeBoxModel>(
      context: context,
      builder: (_) => _PayDialog(bonus: bonus, safes: safes, money: _money),
    );
    if (safe?.id == null || !mounted) return;
    try {
      await widget.api.payBonus(
        bonus.id!,
        safeBoxId: safe!.id!,
        paymentMethod: safe.safeType == 'bank' ? 'transfer' : 'cash',
      );
      if (mounted) AppFeedback.success(context, 'صُرفت من ${safe.name}');
      _loadBonuses();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'لم تُصرف');
    }
  }

  Future<void> _edit(EmployeeBonusModel bonus) async {
    if (bonus.id == null || bonus.status != 'pending') return;
    final changes = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _EditBonusDialog(bonus: bonus),
    );
    if (changes == null || !mounted) return;
    try {
      await widget.api.updateBonus(bonus.id!, changes);
      if (mounted) AppFeedback.success(context, 'حُفظ التعديل');
      _loadBonuses();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'لم يُحفظ التعديل');
    }
  }

  Future<void> _bulkApprove(List<EmployeeBonusModel> pending) async {
    if (pending.isEmpty) return;
    final total = pending.fold<double>(0, (s, b) => s + b.amount);
    final names = {for (final b in pending) b.employee?.fullName ?? '—'}.toList();
    final who = names.length <= 4
        ? names.join('، ')
        : '${names.take(4).join('، ')} و${names.length - 4} غيرهم';
    final go = await confirmFinancialAction(
      context,
      title: 'اعتماد المكافآت المعلّقة',
      facts: [('العدد', '${pending.length}'), ('الإجمالي', _money(total))],
      effect: 'لـ $who.\n'
          'يُسجَّل لكل مكافأة قيد اعتمادها: مصروف المكافآت مدين، '
          'ومكافآت موظفها المستحقة دائنة.',
      confirmLabel: 'اعتماد الكل',
      destructive: false,
    );
    if (go == null || !mounted) return;
    setState(() => _bulkLoading = true);
    try {
      final res = await widget.api
          .bulkApproveBonuses([for (final b in pending) b.id!]);
      if (!mounted) return;
      final failed =
          ((res['failed'] as List?) ?? const []).whereType<Map>().toList();
      final done = res['approved_count'] ?? res['count'] ?? 0;
      if (failed.isEmpty) {
        AppFeedback.success(context, 'اعتُمدت $done');
      } else {
        // Each bonus is approved on its own; one refused does not stop the
        // rest, and the first refusal is said in the server's words.
        AppFeedback.warning(context,
            'اعتُمدت $done، ولم تُعتمد ${failed.length}: ${failed.first['error'] ?? ''}');
      }
      _loadBonuses();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'لم تُعتمد');
    } finally {
      if (mounted) setState(() => _bulkLoading = false);
    }
  }

  Future<void> _bulkReject(List<EmployeeBonusModel> pending) async {
    if (pending.isEmpty) return;
    final reason =
        await _askRejection('رفض المكافآت المعلّقة (${pending.length})');
    if (reason == null || !mounted) return;
    setState(() => _bulkLoading = true);
    try {
      final res = await widget.api.bulkRejectBonuses(
          [for (final b in pending) b.id!],
          reason: reason.isEmpty ? null : reason);
      if (mounted) AppFeedback.success(context, 'رُفضت ${res['count'] ?? 0}');
      _loadBonuses();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'لم تُرفض');
    } finally {
      if (mounted) setState(() => _bulkLoading = false);
    }
  }

  // ─────────────────────────────── Bottom Sheet: تفاصيل المكافأة ───────────────────────────────

  void _showDetails(EmployeeBonusModel b) {
    final isAr = widget.isArabic;
    final fmt = DateFormat('yyyy-MM-dd');
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final why = bonusWhy(b, _currency);
    void then(BuildContext ctx, void Function(EmployeeBonusModel) act) {
      Navigator.pop(ctx);
      act(b);
    }

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
            color: theme.scaffoldBackgroundColor,
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
                    color: cs.outlineVariant,
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
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          if (b.employee?.position != null)
                            Text(b.employee!.position!,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: cs.onSurfaceVariant)),
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
                      padding: const EdgeInsets.all(AppSpace.lg),
                      decoration: BoxDecoration(
                        color: tones.gold.container,
                        borderRadius: BorderRadius.circular(AppRadius.control),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.monetization_on_rounded,
                              color: tones.gold.fg, size: 28),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(isAr ? 'المبلغ' : 'Amount',
                                    style: theme.textTheme.labelMedium?.copyWith(
                                        color: tones.gold.onContainer)),
                                Text(
                                  _money(b.amount),
                                  style: theme.textTheme.headlineSmall?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: tones.gold.onContainer),
                                ),
                                if (why != null)
                                  Text(why,
                                      key: const Key('bonus-why'),
                                      style: theme.textTheme.bodyMedium?.copyWith(
                                          color: tones.gold.onContainer)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Info grid
                    _DetailRow(
                        label: isAr ? 'القاعدة' : 'Rule',
                        value: b.bonusRule?.name ?? (isAr ? 'يدوية' : 'Manual'),
                        icon: Icons.rule_rounded),
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
                          label: isAr ? 'مرجع القيد' : 'Entry ref',
                          value: b.paymentReference!,
                          icon: Icons.receipt_long_outlined),
                    if (b.notes != null && b.notes!.isNotEmpty)
                      _DetailRow(
                          label: isAr ? 'ملاحظات' : 'Notes',
                          value: b.notes!,
                          icon: Icons.notes_rounded),

                    // What its rule recorded, all of it, folded: the line
                    // above says it; this keeps every input in reach.
                    if (b.calculationData != null &&
                        b.calculationData!.isNotEmpty)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text(isAr ? 'كل مدخلات الاحتساب' : 'All calculation inputs',
                            style: theme.textTheme.labelLarge
                                ?.copyWith(color: cs.onSurfaceVariant)),
                        children: [
                          for (final e in b.calculationData!.entries
                              .where((e) => e.value != null))
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Row(children: [
                                Text('${e.key}:',
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(color: cs.onSurfaceVariant)),
                                const SizedBox(width: 8),
                                Expanded(
                                    child: Text('${e.value}',
                                        style: theme.textTheme.bodySmall)),
                              ]),
                            ),
                        ],
                      ),

                    // Actions: the next step strong, the rest soft (UI-3).
                    if (b.canApprove() || b.canReject() || b.canPay()) ...[
                      const SizedBox(height: 24),
                      if (b.canApprove())
                        _ActionButton(
                          label: isAr ? 'اعتماد' : 'Approve',
                          icon: Icons.check_circle_outline,
                          tone: tones.ready,
                          onTap: () => then(ctx, _approve),
                        ),
                      if (b.canPay())
                        _ActionButton(
                          label: isAr ? 'صرف' : 'Pay',
                          icon: Icons.payments_outlined,
                          tone: tones.info,
                          onTap: () => then(ctx, _pay),
                        ),
                      if (b.status == 'pending') ...[
                        const SizedBox(height: 8),
                        _ActionButton(
                          label: isAr ? 'تعديل' : 'Edit',
                          icon: Icons.edit_outlined,
                          outlined: true,
                          onTap: () => then(ctx, _edit),
                        ),
                      ],
                      if (b.canReject()) ...[
                        const SizedBox(height: 8),
                        _ActionButton(
                          label: isAr ? 'رفض' : 'Reject',
                          icon: Icons.cancel_outlined,
                          tone: tones.blocked,
                          outlined: true,
                          onTap: () => then(ctx, _reject),
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
                              color: Theme.of(context).colorScheme.outlineVariant,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            isAr ? 'تصفية متقدمة' : 'Advanced Filters',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _clearFilters();
                          },
                          child: Text(isAr ? 'مسح' : 'Clear'),
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
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
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
                            child: Text(isAr ? 'تطبيق الفلاتر' : 'Apply Filters'),
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
    final pending = filtered
        .where((b) => b.status == 'pending' && b.id != null)
        .toList();

    // ── المحتوى المشترك بين المضمّن والمستقل ──
    Widget body = _loading
        ? const AppLoadingView(summaryBlocks: 4, rows: 6)
        : RefreshIndicator(
            onRefresh: _loadBonuses,
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
                if (pending.isNotEmpty)
                  SliverToBoxAdapter(child: _buildBulkBar(isAr, pending)),
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
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            isAr
                                ? 'ابدأ بـ "احتساب" لإنشاء أول مجموعة'
                                : 'Start with "Calculate" to create your first batch',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                    decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle),
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
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle),
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
        icon: const Icon(Icons.calculate_rounded),
        label: Text(isAr ? 'احتساب' : 'Calculate'),
      ),
      body: body,
    );
  }

  Widget _buildSummary(bool isAr) {
    final tones = AppSemanticColors.of(context);
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
          value: '${cu.formatAmount(total, decimals: 0)} $_currency',
          tone: tones.info,
          icon: Icons.payments_outlined,
          trend: pctChange,
          trendLabel: isAr ? 'عن الفترة السابقة' : 'vs last period',
        )),
        const SizedBox(width: 8),
        Expanded(child: _SmartMetricTile(
          label: isAr ? 'معلّقة' : 'Pending',
          value: '$pending',
          tone: tones.warning,
          icon: Icons.pending_actions_outlined,
          subtitle: pending > 0 ? (isAr ? 'يحتاج اعتماد' : 'needs review') : (isAr ? 'لا شيء معلق' : 'all clear'),
        )),
        const SizedBox(width: 8),
        Expanded(child: _SmartMetricTile(
          label: isAr ? 'معتمدة' : 'Approved',
          value: '$approved',
          tone: tones.ready,
          icon: Icons.check_circle_outline,
          subtitle: isAr ? 'جاهزة للدفع' : 'ready to pay',
        )),
        const SizedBox(width: 8),
        Expanded(child: _SmartMetricTile(
          label: isAr ? 'مدفوعة' : 'Paid',
          value: '$paid',
          tone: tones.gold,
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
            label: Text(label),
            selected: selected,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
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

  Widget _buildBulkBar(bool isAr, List<EmployeeBonusModel> pending) {
    final tone = AppSemanticColors.of(context).warning;
    final total = pending.fold<double>(0, (s, b) => s + b.amount);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(children: [
        Icon(Icons.pending_actions_rounded, color: tone.fg, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${pending.length} ${isAr ? 'معلّقة' : 'pending'} · ${_money(total)}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: tone.onContainer, fontWeight: FontWeight.w600),
          ),
        ),
        TextButton.icon(
          onPressed: _bulkLoading ? null : () => _bulkApprove(pending),
          icon: _bulkLoading
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.check_circle_outline, size: 16),
          label: Text(isAr ? 'اعتماد الكل' : 'Approve all'),
          style: TextButton.styleFrom(foregroundColor: tone.onContainer),
        ),
        TextButton.icon(
          onPressed: _bulkLoading ? null : () => _bulkReject(pending),
          icon: const Icon(Icons.cancel_outlined, size: 16),
          label: Text(isAr ? 'رفض الكل' : 'Reject all'),
          style: TextButton.styleFrom(foregroundColor: tone.onContainer),
        ),
      ]),
    );
  }
}

// ─────────────────────────────── Sub-widgets ───────────────────────────────

/// A bonus's status in its tone: waiting (pending), ready to pay (approved),
/// done (paid), stopped (rejected).
SemanticTone _statusTone(BuildContext context, String status) {
  final tones = AppSemanticColors.of(context);
  return switch (status) {
    'pending' => tones.warning,
    'approved' => tones.ready,
    'paid' => tones.info,
    'rejected' => tones.blocked,
    _ => tones.sectionSlate,
  };
}

class _BonusTile extends StatelessWidget {
  final EmployeeBonusModel bonus;
  final VoidCallback onTap;

  const _BonusTile({required this.bonus, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('d MMM yyyy', 'ar');
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final currency = context.read<SettingsProvider>().currencySymbolText;
    final why = bonusWhy(bonus, currency);
    final muted = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);

    return Material(
      color: cs.surface,
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
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${bonus.bonusRule?.name ?? 'يدوية'} · '
                    '${fmt.format(bonus.periodStart)} → ${fmt.format(bonus.periodEnd)}',
                    style: muted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (why != null) ...[
                    const SizedBox(height: 2),
                    Text(why, style: muted, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${cu.formatAmount(bonus.amount)} $currency',
                  style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold, color: tones.gold.fg),
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
    final tone = _statusTone(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        EmployeeBonusModel.getStatusNameAr(status),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: tone.onContainer, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _SmartMetricTile extends StatelessWidget {
  final String label;
  final String value;
  final SemanticTone tone;
  final IconData icon;
  final double? trend;
  final String? trendLabel;
  final String? subtitle;

  const _SmartMetricTile({
    required this.label,
    required this.value,
    required this.tone,
    required this.icon,
    this.trend,
    this.trendLabel,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final small = text.labelSmall?.copyWith(color: tone.onContainer);
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Icon(icon, size: 13, color: tone.fg),
            const SizedBox(width: 5),
            Flexible(
              child: Text(label,
                  style: small?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(value,
                style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800, color: tone.onContainer)),
          ),
          const SizedBox(height: 2),
          if (trend != null) ...[
            Row(children: [
              Icon(
                trend! >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded,
                size: 11,
                color: tone.onContainer,
              ),
              const SizedBox(width: 2),
              Flexible(
                child: Text(
                  '${cu.formatAmount(trend!.abs(), decimals: 1)}% ${trendLabel ?? ""}',
                  style: small,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          ] else if (subtitle != null)
            Text(subtitle!, style: small, overflow: TextOverflow.ellipsis),
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
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: muted),
        const SizedBox(width: 10),
        SizedBox(
          width: 100,
          child: Text(label,
              style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ),
        Expanded(
          child: Text(value,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w500)),
        ),
      ]),
    );
  }
}

/// The sheet's next step (approve, pay) strong in its [tone]; the rest
/// [outlined] -- reject in its tone, edit plain (UI-3).
class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final SemanticTone? tone;
  final VoidCallback onTap;
  final bool outlined;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.tone,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    const padding = EdgeInsets.symmetric(vertical: 12);
    final Widget button;
    if (tone == null || outlined) {
      button = OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: tone?.fg,
          side: tone == null ? null : BorderSide(color: tone!.fg),
          padding: padding,
        ),
      );
    } else {
      button = FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: AppButtonStyles.primary(context, tone!)
            .merge(FilledButton.styleFrom(padding: padding)),
      );
    }
    return SizedBox(width: double.infinity, child: button);
  }
}

class _FilterSection extends StatelessWidget {
  final String label;
  final Widget child;

  const _FilterSection({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant)),
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
      onSelected: (_) => onTap(),
    );
  }
}

/// Why a bonus is its amount, from what its rule recorded when it computed it
/// (calculation_data): the measure, its value, the tier it reached. Null when
/// nothing was recorded to say it by -- a manual bonus, an old rule type.
String? bonusWhy(EmployeeBonusModel b, String currency) {
  final data = b.calculationData;
  if (data == null) return null;
  String n(Object? v) => v is num
      ? cu.formatAmount(v, decimals: v == v.truncate() ? 0 : 2)
      : '${v ?? '—'}';
  final tier = data['tier'];
  if (data['measure'] != null && tier is Map) {
    final measure = tierMeasures[data['measure']] ?? '${data['measure']}';
    final rate = tier['per_unit'] != null
        ? 'بـ ${n(tier['per_unit'])} لكل وحدة'
        : '${n(tier['amount'])} $currency';
    return '$measure ${n(data['value'])} · شريحة من ${n(tier['from'])} $rate';
  }
  if (data['employee_points'] != null) {
    final least = data['min_points'];
    return 'النقاط ${n(data['employee_points'])}'
        '${least is num && least > 0 ? ' · الحد الأدنى ${n(least)}' : ''}';
  }
  if (data['sales_target'] != null) {
    return 'المبيعات ${n(data['sales_amount'])} $currency '
        'من هدف ${n(data['sales_target'])}';
  }
  return null;
}

class _RejectDialog extends StatefulWidget {
  const _RejectDialog({required this.title});

  final String title;

  @override
  State<_RejectDialog> createState() => _RejectDialogState();
}

class _RejectDialogState extends State<_RejectDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'لم تُعتمد بعد، فلا قيد لها يُعكس. السبب يُحفظ في ملاحظتها.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpace.md),
            TextField(
              key: const Key('reject-reason'),
              controller: _reason,
              maxLines: 2,
              decoration:
                  const InputDecoration(labelText: 'سبب الرفض (اختياري)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('تراجع')),
        FilledButton(
          key: const Key('reject-confirm'),
          style: AppButtonStyles.danger(context),
          onPressed: () => Navigator.pop(context, _reason.text.trim()),
          child: const Text('رفض'),
        ),
      ],
    );
  }
}

/// The safe to pay a bonus from, its balance beside it, and the voucher the
/// payment makes. The server reads the balance from the books and refuses a
/// safe short of the bonus; the dialog only says so first.
class _PayDialog extends StatefulWidget {
  const _PayDialog(
      {required this.bonus, required this.safes, required this.money});

  final EmployeeBonusModel bonus;
  final List<SafeBoxModel> safes;
  final String Function(num) money;

  @override
  State<_PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<_PayDialog> {
  late SafeBoxModel _safe = widget.safes.first;

  double _balanceOf(SafeBoxModel s) => s.balance?.cash ?? 0.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final b = widget.bonus;
    final name = b.employee?.fullName ?? 'الموظف';
    final short = _balanceOf(_safe) < b.amount;
    final tone = short ? tones.warning : tones.info;
    return AlertDialog(
      title: Text('صرف مكافأة $name'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('المبلغ ${widget.money(b.amount)}',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpace.md),
            DropdownButtonFormField<SafeBoxModel>(
              key: const Key('pay-safe'),
              value: _safe,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'من خزينة'),
              items: [
                for (final s in widget.safes)
                  DropdownMenuItem(
                    value: s,
                    child: Row(
                      children: [
                        Expanded(
                            child:
                                Text(s.name, overflow: TextOverflow.ellipsis)),
                        Text(
                          widget.money(_balanceOf(s)),
                          textDirection: TextDirection.ltr,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: _balanceOf(s) >= b.amount
                                ? tones.ready.fg
                                : tones.blocked.fg,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _safe = v ?? _safe),
            ),
            const SizedBox(height: AppSpace.md),
            Container(
              key: const Key('pay-effect'),
              padding: const EdgeInsets.all(AppSpace.md),
              decoration: BoxDecoration(
                color: tone.container,
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: Text(
                short
                    ? 'رصيد ${_safe.name} ${widget.money(_balanceOf(_safe))} '
                        'أقل من المكافأة، ويرفض الخادم الصرف منها.'
                    : 'يُسجَّل سند صرف: مكافآت $name المستحقة مدينة، '
                        'و${_safe.name} دائنة بـ ${widget.money(b.amount)}.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: tone.onContainer),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('تراجع')),
        FilledButton(
          key: const Key('pay-confirm'),
          onPressed: () => Navigator.pop(context, _safe),
          child: const Text('صرف'),
        ),
      ],
    );
  }
}

/// A pending bonus's edit. A bonus its rule computed keeps its rule's amount
/// and period -- the next run recomputes them, and the server refuses a typed
/// one (computed_by_rule) -- so only its note is offered, and why is said.
/// A manual bonus is the manager's: amount, note and period.
class _EditBonusDialog extends StatefulWidget {
  const _EditBonusDialog({required this.bonus});

  final EmployeeBonusModel bonus;

  @override
  State<_EditBonusDialog> createState() => _EditBonusDialogState();
}

class _EditBonusDialogState extends State<_EditBonusDialog> {
  late final _amount = TextEditingController(text: _typed(widget.bonus.amount));
  late final _note = TextEditingController(text: widget.bonus.notes ?? '');
  late DateTime _start = widget.bonus.periodStart;
  late DateTime _end = widget.bonus.periodEnd;
  String? _amountError;

  static final _day = DateFormat('yyyy-MM-dd');

  static String _typed(double v) =>
      v == v.truncateToDouble() ? '${v.toInt()}' : '$v';

  bool get _byRule => widget.bonus.bonusRuleId != null;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();
    if (_byRule) {
      Navigator.pop(context, <String, dynamic>{'notes': note});
      return;
    }
    final amount = double.tryParse(_amount.text.trim());
    if (amount == null || amount < 0) {
      setState(() => _amountError = 'مبلغ غير صحيح');
      return;
    }
    Navigator.pop(context, <String, dynamic>{
      'amount': amount,
      'notes': note,
      'period_start': _day.format(_start),
      'period_end': _day.format(_end),
    });
  }

  Future<void> _pick(bool start) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: start ? _start : _end,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => start ? _start = picked : _end = picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final rule = widget.bonus.bonusRule?.name;
    Widget date(String label, DateTime value, bool start) => Expanded(
          child: InkWell(
            onTap: () => _pick(start),
            child: InputDecorator(
              decoration: InputDecoration(labelText: label),
              child: Text(_day.format(value)),
            ),
          ),
        );
    return AlertDialog(
      title: const Text('تعديل المكافأة'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_byRule) ...[
              Container(
                key: const Key('edit-by-rule'),
                padding: const EdgeInsets.all(AppSpace.md),
                decoration: BoxDecoration(
                  color: tones.info.container,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: Text(
                  'مبلغها وفترتها تحسبهما قاعدتها${rule == null ? '' : ' «$rule»'}، '
                  'ويعيد التشغيل التالي حسابهما. لمبلغ آخر: ارفضها، وأضف مكافأة '
                  'يدوية بسببها.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: tones.info.onContainer),
                ),
              ),
              const SizedBox(height: AppSpace.md),
            ] else ...[
              TextField(
                key: const Key('edit-amount'),
                controller: _amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: 'المبلغ', errorText: _amountError),
                onChanged: (_) {
                  if (_amountError != null) setState(() => _amountError = null);
                },
              ),
              const SizedBox(height: AppSpace.md),
            ],
            TextField(
              key: const Key('edit-note'),
              controller: _note,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'ملاحظات'),
            ),
            if (!_byRule) ...[
              const SizedBox(height: AppSpace.md),
              Row(children: [
                date('من', _start, true),
                const SizedBox(width: AppSpace.sm),
                date('إلى', _end, false),
              ]),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('تراجع')),
        FilledButton(
            key: const Key('edit-save'),
            onPressed: _save,
            child: const Text('حفظ')),
      ],
    );
  }
}
