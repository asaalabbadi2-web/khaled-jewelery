import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/employee_model.dart';
import '../theme/app_semantic_colors.dart';
import 'app_feedback.dart';

/// An employee's personal goal (moved whole from the employees screen, HR-UX;
/// the owner, 1 Nov 2026: «نفّذ التوصية»): its metric, its daily, weekly and
/// monthly targets, its reward -- in use by the five on the 1 Nov copy (999.9
/// points a month, 27 achievements). The employee page's «الأداء» shows it;
/// the earlier screen too.
// ═══════════════════════════════════════════════════════════════
// 🎯 بطاقة أهداف الأداء الشخصية
// ═══════════════════════════════════════════════════════════════
class GoalSettingsTile extends StatefulWidget {
  final EmployeeModel employee;
  final bool isArabic;
  final ApiService api;
  final ValueChanged<EmployeeModel> onSaved;
  const GoalSettingsTile({
    super.key,
    required this.employee,
    required this.isArabic,
    required this.api,
    required this.onSaved,
  });
  @override
  State<GoalSettingsTile> createState() => _GoalSettingsTileState();
}

class _GoalSettingsTileState extends State<GoalSettingsTile> {
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

  // the theme's gold, not a colour of its own (the raw-colour ratchet)
  SemanticTone get _tone => AppSemanticColors.of(context).gold;
  Color get _gold => _tone.fg;
  TextTheme get _text => Theme.of(context).textTheme;
  ColorScheme get _scheme => Theme.of(context).colorScheme;

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
        AppFeedback.error(
          context,
          e,
          title: widget.isArabic ? 'تعذّر تحميل قواعد المكافآت' : 'Failed to load bonus rules',
        );
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
        AppFeedback.error(context, e, title: widget.isArabic ? 'خطأ في الحفظ' : 'Save Error');
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
            Icon(Icons.flag_rounded, color: _gold, size: 18),
            const SizedBox(width: 8),
            Text(
              isAr ? 'الهدف الشخصي' : 'Personal Goal',
              style: _text.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: _gold),
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
                  style: _text.bodySmall?.copyWith(color: _scheme.onSurfaceVariant))
            else ...[
              Text('${_metricLabel(e.goalMetric!)}${e.goalName != null ? "  ·  ${e.goalName}" : ""}',
                  style: _text.titleSmall),
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
                    ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: _scheme.onPrimary))
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
        title: Text(title, style: _text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
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
          Text(isAr ? 'المكافأة:' : 'Reward:', style: _text.bodySmall?.copyWith(color: _scheme.onSurfaceVariant)),
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
          color: selected ? _gold : null,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? _gold : _scheme.outline),
        ),
        child: Text(label, style: _text.labelMedium?.copyWith(
          color: selected ? _scheme.onPrimary : _scheme.onSurfaceVariant,
        )),
      ),
    );
  }

  Widget _chip(String label, String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: _tone.container, borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _gold.withValues(alpha: 0.3)),
    ),
    child: Text('$label: $value',
        style: _text.labelMedium?.copyWith(color: _tone.onContainer)),
  );
}
