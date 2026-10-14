import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_service.dart';
import '../models/bonus_rule_model.dart';
import '../models/employee_model.dart';
import '../theme/app_theme.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';

class CalculateBonusesScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  final bool embedded;

  const CalculateBonusesScreen({
    super.key,
    required this.api,
    this.isArabic = true,
    this.embedded = false,
  });

  @override
  State<CalculateBonusesScreen> createState() => _CalculateBonusesScreenState();
}

class _CalculateBonusesScreenState extends State<CalculateBonusesScreen> {
  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);

    final body = ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        // ── Section 1: الاحتساب التلقائي ──
        _SectionHeader(
          icon: Icons.calculate_rounded,
          title: isAr ? 'الاحتساب التلقائي' : 'Auto Calculate',
          subtitle: isAr
              ? 'احتساب المكافآت من القواعد المفعّلة'
              : 'Compute bonuses from active rules',
          color: AppColors.primaryGold,
        ),
        const SizedBox(height: 12),
        _AutoCalculateContent(api: widget.api, isArabic: isAr),

        const SizedBox(height: 28),
        // ── فاصل ──
        Row(children: [
          Expanded(child: Divider(color: theme.dividerColor)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(isAr ? 'أو' : 'OR',
                style: TextStyle(fontSize: 11, color: theme.hintColor, fontWeight: FontWeight.w700)),
          ),
          Expanded(child: Divider(color: theme.dividerColor)),
        ]),
        const SizedBox(height: 28),

        // ── Section 2: مكافأة الفائزين ──
        _SectionHeader(
          icon: Icons.emoji_events_rounded,
          title: isAr ? 'مكافأة الفائزين' : 'Winners Bonus',
          subtitle: isAr
              ? 'منح مكافآت للأوائل في سباق الأداء'
              : 'Reward top performers from leaderboard',
          color: AppColors.invoicePurchaseNew,
        ),
        const SizedBox(height: 12),
        _WinnersBonusContent(api: widget.api, isArabic: isAr),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'احتساب المكافآت' : 'Calculate Bonuses'),
        centerTitle: true,
      ),
      body: body,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color color;

  const _SectionHeader({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: color, size: 19),
      ),
      const SizedBox(width: 10),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: color)),
          if (subtitle != null) ...[
            const SizedBox(height: 1),
            Text(subtitle!, style: TextStyle(fontSize: 11, color: theme.hintColor)),
          ],
        ],
      )),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────
// Tab 1: الاحتساب التلقائي
// ─────────────────────────────────────────────────────────────

class _AutoCalculateContent extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  const _AutoCalculateContent({required this.api, required this.isArabic});

  @override
  State<_AutoCalculateContent> createState() => _AutoCalculateContentState();
}

class _AutoCalculateContentState extends State<_AutoCalculateContent> {
  DateTime _periodStart = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _periodEnd = DateTime.now();
  List<Map<String, dynamic>>? _results;
  bool _loading = false;
  bool _saving = false;

  Future<void> _calculatePreview() async {
    setState(() {
      _loading = true;
      _results = null;
    });
    try {
      final result = await widget.api.calculateBonuses(
        dateFrom: _periodStart.toIso8601String().split('T').first,
        dateTo: _periodEnd.toIso8601String().split('T').first,
      );
      final isSuccess = result['success'] == null || result['success'] == true;
      if (!isSuccess) throw Exception(result['message'] ?? 'فشل الاحتساب');

      final raw = result['bonuses'];
      final bonuses = raw is List ? raw : (raw as Map?)?.values.toList() ?? [];

      setState(() {
        _results = bonuses.map((b) {
          String emp = 'غير محدد';
          if (b['employee'] is Map) {
            emp = b['employee']['name'] ?? emp;
          } else if (b['employee_name'] != null) {
            emp = b['employee_name'];
          }

          String rule = '';
          if (b['rule'] is Map) {
            rule = b['rule']['name'] ?? '';
          } else if (b['rule_name'] != null) {
            rule = b['rule_name'];
          }

          return {
            'employee_name': emp,
            'bonus_type': b['bonus_type'] ?? '',
            'amount': (b['amount'] as num?)?.toDouble() ?? 0.0,
            'rule_name': rule,
            'status': b['status'] ?? 'pending',
          };
        }).toList();
      });
      _snack('${widget.isArabic ? 'تم احتساب' : 'Calculated'} ${_results!.length}');
    } catch (e) {
      _snack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final isAr = widget.isArabic;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isAr ? 'تأكيد الحفظ' : 'Confirm Save'),
        content: Text(isAr
            ? 'حفظ ${_results?.length ?? 0} مكافأة؟'
            : 'Save ${_results?.length ?? 0} bonuses?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(isAr ? 'إلغاء' : 'Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(isAr ? 'حفظ' : 'Save')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      await widget.api.calculateBonuses(
        dateFrom: _periodStart.toIso8601String().split('T').first,
        dateTo: _periodEnd.toIso8601String().split('T').first,
      );
      _snack(isAr ? 'تم الحفظ' : 'Saved');
      if (mounted) setState(() => _results = null);
    } catch (e) {
      _snack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : Colors.green.shade700,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final fmt = DateFormat('yyyy-MM-dd');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── اختيار الفترة ──
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: _datePicker(
                    context: context,
                    label: isAr ? 'من تاريخ' : 'From',
                    date: _periodStart,
                    onPicked: (d) => setState(() => _periodStart = d),
                    fmt: fmt,
                  )),
                  const SizedBox(width: 12),
                  Expanded(child: _datePicker(
                    context: context,
                    label: isAr ? 'إلى تاريخ' : 'To',
                    date: _periodEnd,
                    onPicked: (d) => setState(() => _periodEnd = d),
                    fmt: fmt,
                  )),
                ]),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _loading ? null : _calculatePreview,
                    icon: _loading
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.calculate_rounded, size: 20),
                    label: Text(isAr ? 'معاينة النتائج' : 'Preview Results'),
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── النتائج ──
        if (_results != null) ...[
          const SizedBox(height: 12),
          Row(children: [
            Text(
              '${isAr ? 'النتائج' : 'Results'} (${_results!.length})',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const Spacer(),
            if (_results!.isNotEmpty)
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save_rounded, size: 18),
                label: Text(isAr ? 'حفظ الكل' : 'Save All'),
                style: FilledButton.styleFrom(backgroundColor: AppColors.success),
              ),
          ]),
          const SizedBox(height: 8),
          if (_results!.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(child: Text(
                isAr ? 'لا توجد مكافآت للفترة المحددة' : 'No bonuses for this period',
                style: TextStyle(color: Colors.grey.shade500),
              )),
            )
          else
            ..._results!.map((r) => _ResultTile(result: r)),
        ],
      ],
    );
  }

  Widget _datePicker({
    required BuildContext context,
    required String label,
    required DateTime date,
    required ValueChanged<DateTime> onPicked,
    required DateFormat fmt,
  }) {
    return InkWell(
      onTap: () async {
        final p = await showDatePicker(
          context: context,
          initialDate: date,
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
        );
        if (p != null) onPicked(p);
      },
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.calendar_today_rounded, size: 18),
          isDense: true,
        ),
        child: Text(fmt.format(date)),
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  final Map<String, dynamic> result;
  const _ResultTile({required this.result});

  @override
  Widget build(BuildContext context) {
    final status = result['status'] as String? ?? 'pending';
    final statusColors = {
      'approved': Colors.blue,
      'paid': Colors.green,
      'rejected': Colors.red,
      'pending': Colors.orange,
    };
    final color = statusColors[status] ?? Colors.orange;
    final statusLabels = {
      'approved': 'معتمدة',
      'paid': 'مدفوعة',
      'rejected': 'مرفوضة',
      'pending': 'معلقة',
    };

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Colors.grey.shade100),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: const Color(0xFFD4AF37).withValues(alpha: 0.15),
          child: Text(
            (result['employee_name'] as String).characters.first,
            style: const TextStyle(color: Color(0xFF8B6914), fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(result['employee_name'] as String,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        subtitle: Text(
          result['rule_name'] as String? ?? result['bonus_type'] as String,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${(result['amount'] as double).toStringAsFixed(0)} ${context.read<SettingsProvider>().currencySymbolText}',
              style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF8B6914)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(statusLabels[status] ?? status,
                  style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Tab 2: مكافأة الفائزين
// ─────────────────────────────────────────────────────────────

class _WinnerEntry {
  final String leaderboardName;
  final double score;
  final int rank;
  EmployeeModel? selectedEmployee;
  final TextEditingController amountController;

  _WinnerEntry({
    required this.leaderboardName,
    required this.score,
    required this.rank,
    this.selectedEmployee,
    required double amount,
  }) : amountController = TextEditingController(text: amount.toStringAsFixed(0));

  void dispose() => amountController.dispose();
}

class _WinnersBonusContent extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  const _WinnersBonusContent({required this.api, required this.isArabic});

  @override
  State<_WinnersBonusContent> createState() => _WinnersBonusContentState();
}

class _WinnersBonusContentState extends State<_WinnersBonusContent> {
  String _period = 'month';
  String _metric = 'points';
  List<_WinnerEntry> _winners = [];
  List<EmployeeModel> _employees = [];
  List<BonusRuleModel> _pointsRules = [];
  BonusRuleModel? _selectedRule;
  bool _loadingLeaderboard = false;
  bool _loadingData = false;
  bool _granting = false;
  bool _fetchedOnce = false;
  final _notesCtrl = TextEditingController();


  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    for (final w in _winners) {
      w.dispose();
    }
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _loadingData = true);
    try {
      final empRes = await widget.api.getEmployees(isActive: true, perPage: 200);
      final empData = empRes['employees'];
      final employees = empData is List<EmployeeModel>
          ? empData
          : (empData as List).map((j) => EmployeeModel.fromJson(j as Map<String, dynamic>)).toList();

      final rulesData = await widget.api.getBonusRules(isActive: true);
      final rules = rulesData
          .map((j) => BonusRuleModel.fromJson(j as Map<String, dynamic>))
          .where((r) => r.ruleType == 'points_based')
          .toList();

      setState(() {
        _employees = employees;
        _pointsRules = rules;
        if (rules.isNotEmpty) _selectedRule = rules.first;
      });
    } catch (e) {
      _snack('خطأ: $e', error: true);
    } finally {
      if (mounted) setState(() => _loadingData = false);
    }
  }

  Future<void> _fetchWinners() async {
    setState(() { _loadingLeaderboard = true; _winners = []; });
    try {
      final data = await widget.api.getHomeLeaderboard(period: _period, metric: _metric);
      // Only employees who reached their goal (goal_progress >= 1.0).
      // If goal_progress is null the employee has no target set — exclude them too.
      final allRanking = (data['ranking'] as List?) ?? [];
      final qualified = allRanking.where((r) {
        final gp = (r as Map)['goal_progress'];
        return gp != null && (gp as num) >= 1.0;
      }).take(3).toList();
      for (final w in _winners) {
        w.dispose();
      }
      final entries = <_WinnerEntry>[];
      for (var i = 0; i < qualified.length; i++) {
        final row = qualified[i] as Map;
        final name = (row['name'] ?? '').toString();
        final score = (row['score'] as num?)?.toDouble() ?? 0.0;
        EmployeeModel? matched;
        try {
          final nl = name.toLowerCase();
          matched = _employees.firstWhere(
            (e) => e.name.toLowerCase().contains(nl) || nl.contains(e.name.toLowerCase()),
          );
        } catch (_) {}
        entries.add(_WinnerEntry(
          leaderboardName: name, score: score, rank: i + 1,
          selectedEmployee: matched,
          amount: _calcAmount(score, _selectedRule),
        ));
      }
      setState(() { _winners = entries; _fetchedOnce = true; });
    } catch (e) {
      _snack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loadingLeaderboard = false);
    }
  }

  double _calcAmount(double score, BonusRuleModel? rule) {
    if (rule == null) return 0;
    if (rule.bonusType == 'points_per_unit') {
      double a = score * rule.bonusValue;
      if (rule.maxBonus != null) a = a.clamp(rule.minBonus, rule.maxBonus!);
      return a;
    }
    if (rule.bonusType == 'fixed') return rule.bonusValue;
    return 0;
  }

  void _recalc() {
    for (final w in _winners) {
      final a = _calcAmount(w.score, _selectedRule);
      w.amountController.text = a.toStringAsFixed(0);
    }
    setState(() {});
  }

  Future<void> _grant() async {
    final isAr = widget.isArabic;
    final valid = _winners.where((w) => w.selectedEmployee != null).toList();
    if (valid.isEmpty) { _snack(isAr ? 'اربط كل فائز بموظف' : 'Link each winner to an employee', error: true); return; }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(isAr ? 'منح مكافأة لـ ${valid.length} فائز؟' : 'Grant bonus to ${valid.length} winner(s)?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(isAr ? 'إلغاء' : 'Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text(isAr ? 'منح' : 'Grant')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _granting = true);
    final now = DateTime.now();
    final start = _period == 'today'
        ? DateTime(now.year, now.month, now.day)
        : _period == 'week'
            ? now.subtract(Duration(days: now.weekday - 1))
            : DateTime(now.year, now.month, 1);

    int success = 0;
    for (final w in valid) {
      try {
        await widget.api.createBonus({
          'employee_id': w.selectedEmployee!.id,
          'bonus_rule_id': _selectedRule?.id,
          'bonus_type': _selectedRule?.bonusType ?? 'fixed',
          'amount': double.tryParse(w.amountController.text) ?? 0,
          'period_start': start.toIso8601String().split('T').first,
          'period_end': now.toIso8601String().split('T').first,
          'status': 'pending',
          'notes': _notesCtrl.text.trim().isEmpty
              ? 'مكافأة سباق — المرتبة ${w.rank} (${BonusRuleModel.getPointsPeriodNameAr(_period)})'
              : _notesCtrl.text.trim(),
          'calculation_data': {'source': 'leaderboard', 'period': _period, 'metric': _metric, 'score': w.score, 'rank': w.rank},
        });
        success++;
      } catch (_) {}
    }
    if (mounted) setState(() { _granting = false; _winners = []; });
    _snack(isAr ? 'تم منح $success مكافأة' : 'Granted $success bonus(es)');
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : Colors.green.shade700,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;

    if (_loadingData) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── إعدادات ──
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.emoji_events_rounded, color: Color(0xFFD4AF37), size: 20),
                const SizedBox(width: 8),
                Text(isAr ? 'إعدادات السباق' : 'Race Settings',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(child: DropdownButtonFormField<String>(
                  value: _period,
                  decoration: InputDecoration(
                    labelText: isAr ? 'الفترة' : 'Period',
                    border: const OutlineInputBorder(), isDense: true),
                  items: [
                    DropdownMenuItem(value: 'today', child: Text(isAr ? 'اليوم' : 'Today')),
                    DropdownMenuItem(value: 'week', child: Text(isAr ? 'الأسبوع' : 'Week')),
                    DropdownMenuItem(value: 'month', child: Text(isAr ? 'الشهر' : 'Month')),
                  ],
                  onChanged: (v) => setState(() => _period = v!),
                )),
                const SizedBox(width: 12),
                Expanded(child: DropdownButtonFormField<String>(
                  value: _metric,
                  decoration: InputDecoration(
                    labelText: isAr ? 'المقياس' : 'Metric',
                    border: const OutlineInputBorder(), isDense: true),
                  items: [
                    DropdownMenuItem(value: 'points', child: Text(isAr ? 'النقاط' : 'Points')),
                    DropdownMenuItem(value: 'weight', child: Text(isAr ? 'الوزن' : 'Weight')),
                    DropdownMenuItem(value: 'count', child: Text(isAr ? 'الفواتير' : 'Invoices')),
                  ],
                  onChanged: (v) => setState(() => _metric = v!),
                )),
              ]),
              if (_pointsRules.isNotEmpty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<BonusRuleModel>(
                  value: _selectedRule,
                  decoration: InputDecoration(
                    labelText: isAr ? 'قاعدة المكافأة' : 'Bonus Rule',
                    border: const OutlineInputBorder(), isDense: true),
                  items: _pointsRules.map((r) => DropdownMenuItem(
                    value: r,
                    child: Text('${r.name} — ${r.bonusValue} ${isAr ? 'لكل نقطة' : '/pt'}'),
                  )).toList(),
                  onChanged: (v) { setState(() => _selectedRule = v); _recalc(); },
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Row(children: [
                      const Icon(Icons.info_outline, color: Colors.orange, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(
                        isAr ? 'أضف قاعدة من نوع "على أساس النقاط" من تبويب القواعد' : 'Add a points_based rule from the Rules tab',
                        style: const TextStyle(fontSize: 12),
                      )),
                    ]),
                  ),
                ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _loadingLeaderboard ? null : _fetchWinners,
                  icon: _loadingLeaderboard
                      ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.leaderboard_rounded, size: 20),
                  label: Text(isAr ? 'جلب الفائزين من السباق' : 'Fetch Winners'),
                ),
              ),
            ]),
          ),
        ),

        // ── الفائزون ──
        if (_fetchedOnce && _winners.isEmpty && !_loadingLeaderboard) ...[
          const SizedBox(height: 16),
          Center(
            child: Text(
              isAr ? 'لا يوجد موظفون بلغوا هدفهم بعد' : 'No employees have reached their goal yet',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
          ),
        ],
        if (_winners.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(isAr ? 'الفائزون' : 'Winners',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 10),
          ..._winners.map((w) => _WinnerCard(
            winner: w,
            employees: _employees,
            isArabic: isAr,
            metric: _metric,
            onChanged: () => setState(() {}),
          )),
          const SizedBox(height: 8),
          TextField(
            controller: _notesCtrl,
            decoration: InputDecoration(
              labelText: isAr ? 'ملاحظة (اختياري)' : 'Notes (optional)',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.notes_rounded),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _granting ? null : _grant,
            icon: _granting
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.card_giftcard_rounded, size: 20),
            label: Text(isAr ? 'منح المكافآت للفائزين' : 'Grant Bonuses'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD4AF37),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ],
      ],
    );
  }
}

class _WinnerCard extends StatelessWidget {
  final _WinnerEntry winner;
  final List<EmployeeModel> employees;
  final bool isArabic;
  final String metric;
  final VoidCallback onChanged;

  const _WinnerCard({
    required this.winner, required this.employees,
    required this.isArabic, required this.metric, required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isAr = isArabic;
    final medal = winner.rank <= 3 ? ['🥇', '🥈', '🥉'][winner.rank - 1] : '#${winner.rank}';
    final color = winner.rank <= 3
        ? [const Color(0xFFB88913), const Color(0xFF8F99A7), const Color(0xFFA56A36)][winner.rank - 1]
        : Colors.grey;
    final unit = metric == 'points' ? (isAr ? 'نقطة' : 'pts')
        : metric == 'weight' ? 'g' : (isAr ? 'فاتورة' : 'inv');

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(medal, style: const TextStyle(fontSize: 26)),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(winner.leaderboardName,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: color)),
              Text('${winner.score.toStringAsFixed(0)} $unit',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ])),
          ]),
          const SizedBox(height: 12),
          DropdownButtonFormField<EmployeeModel>(
            value: winner.selectedEmployee,
            decoration: InputDecoration(
              labelText: isAr ? 'الموظف المقابل' : 'Linked Employee',
              border: const OutlineInputBorder(), isDense: true,
              prefixIcon: const Icon(Icons.person_search_rounded, size: 18),
            ),
            items: [
              DropdownMenuItem<EmployeeModel>(
                value: null,
                child: Text(isAr ? '— اختر موظفاً —' : '— Select employee —',
                    style: const TextStyle(color: Colors.grey))),
              ...employees.map((e) => DropdownMenuItem(
                value: e,
                child: Text('${e.name} (${e.employeeCode})', overflow: TextOverflow.ellipsis),
              )),
            ],
            onChanged: (v) { winner.selectedEmployee = v; onChanged(); },
          ),
          const SizedBox(height: 10),
          TextField(
            controller: winner.amountController,
            decoration: InputDecoration(
              labelText: isAr ? 'المبلغ' : 'Amount',
              border: const OutlineInputBorder(), isDense: true,
              prefixIcon: const Icon(Icons.monetization_on_outlined, size: 18),
            ),
            keyboardType: TextInputType.number,
          ),
        ]),
      ),
    );
  }
}
