import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/payroll_run_models.dart';
import '../services/payroll_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils.dart' show normalizeNumber;
import '../utils/arabic_number_formatter.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import 'app_feedback.dart';
import 'app_state_views.dart';

/// An employee's advances beside their balance (HR-UX ط2: they were the
/// third form of the salary dialog): the advance account's balance and what
/// is not yet planned, each plan and its stop, and a new plan -- its
/// installment the policy's when left empty, one above the cap only with his
/// consent (Labour Law art. 92). Every figure is the server's.
class EmployeeAdvancesPanel extends StatefulWidget {
  const EmployeeAdvancesPanel({
    super.key,
    required this.service,
    required this.employeeId,
    required this.isAr,
    this.unsaved,
    this.onSaved,
  });

  final PayrollService service;
  final int employeeId;
  final bool isAr;

  /// What was typed and not saved, for the holder to ask before it leaves.
  final ValueNotifier<List<String>>? unsaved;
  final VoidCallback? onSaved;

  @override
  State<EmployeeAdvancesPanel> createState() => _EmployeeAdvancesPanelState();
}

class _EmployeeAdvancesPanelState extends State<EmployeeAdvancesPanel> {
  (List<AdvancePlanModel>, double, double)? _advances;
  Object? _error;
  bool _busy = false;
  bool _consent = false;
  final _amount = TextEditingController();
  final _installment = TextEditingController();
  final _consentNote = TextEditingController();

  bool get _isAr => widget.isAr;

  @override
  void initState() {
    super.initState();
    _amount.addListener(_typed);
    _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    _installment.dispose();
    _consentNote.dispose();
    super.dispose();
  }

  void _typed() {
    final unsaved = [
      if (_amount.text.trim().isNotEmpty) _isAr ? 'السلفة' : 'the advance',
    ];
    final told = widget.unsaved;
    if (told != null && told.value.length != unsaved.length) {
      told.value = unsaved;
    }
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final advances = await widget.service.advancePlans(widget.employeeId);
      if (mounted) {
        setState(() {
          _error = null;
          _advances = advances;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  double _read(TextEditingController c) =>
      double.tryParse(normalizeNumber(c.text)) ?? 0;

  String _money(double v) => ltrIsolate(formatAmount(v));

  Future<void> _plan() async {
    setState(() => _busy = true);
    try {
      final today = DateTime.now();
      await widget.service.addAdvancePlan(
        widget.employeeId,
        amount: _read(_amount),
        installment: _installment.text.trim().isEmpty
            ? null
            : _read(_installment),
        startMonth: today.month,
        startYear: today.year,
        consent: _consent,
        consentNote: _consentNote.text.trim().isEmpty
            ? null
            : _consentNote.text.trim(),
      );
      _amount.clear();
      _installment.clear();
      await _load();
      widget.onSaved?.call();
      if (mounted) {
        AppFeedback.success(
          context,
          _isAr ? 'جُدولت السلفة' : 'Advance planned',
        );
      }
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop(AdvancePlanModel plan) async {
    try {
      await widget.service.cancelAdvancePlan(plan.id);
      await _load();
      widget.onSaved?.call();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Widget _field(TextEditingController c, String label, String key) => TextField(
    key: ValueKey(key),
    controller: c,
    textDirection: TextDirection.ltr,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: [
      ArabicNumberTextInputFormatter(),
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
    ],
    decoration: InputDecoration(labelText: label),
  );

  @override
  Widget build(BuildContext context) {
    final isAr = _isAr;
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final advances = _advances;
    if (_error != null && advances == null) {
      return AppErrorView(
        title: isAr ? 'تعذّر تحميل السلف' : 'Could not load the advances',
        error: _error!,
        onRetry: _load,
      );
    }
    if (advances == null) {
      return const AppLoadingView(summaryBlocks: 0, rows: 3);
    }
    final (plans, balance, unplanned) = advances;
    return Card(
      key: const ValueKey('employee-advances'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isAr ? 'السلف' : 'Advances',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              isAr
                  ? 'رصيد حساب السلف ${_money(balance)} — غير مجدول ${_money(unplanned)}'
                  : 'Advance account ${_money(balance)} — unplanned ${_money(unplanned)}',
              style: unplanned > 0
                  ? theme.textTheme.bodyMedium?.copyWith(
                      color: tones.warning.fg,
                    )
                  : theme.textTheme.bodyMedium,
            ),
            for (final plan in plans)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${_money(plan.amount)} — ${isAr ? 'القسط' : 'installment'} ${_money(plan.installment)}',
                ),
                subtitle: Text(
                  '${isAr ? 'الباقي' : 'Left'} ${_money(plan.remaining)} · '
                  '${switch (plan.status) {
                    'settled' => isAr ? 'سُدّدت' : 'settled',
                    'cancelled' => isAr ? 'أُوقفت' : 'stopped',
                    _ => isAr ? 'قائمة' : 'active',
                  }}',
                ),
                trailing: plan.status == 'active'
                    ? IconButton(
                        tooltip: isAr ? 'أوقف الأقساط' : 'Stop',
                        icon: const Icon(Icons.pause_circle_outline),
                        onPressed: _busy ? null : () => _stop(plan),
                      )
                    : null,
              ),
            const SizedBox(height: AppSpace.sm),
            Row(
              children: [
                Expanded(
                  child: _field(
                    _amount,
                    isAr ? 'مبلغ يُجدول' : 'Amount',
                    'advance-amount',
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: _field(
                    _installment,
                    isAr ? 'القسط (فارغ: بالسياسة)' : 'Installment',
                    'advance-installment',
                  ),
                ),
              ],
            ),
            CheckboxListTile(
              key: const ValueKey('advance-consent'),
              contentPadding: EdgeInsets.zero,
              value: _consent,
              onChanged: (v) => setState(() => _consent = v ?? false),
              title: Text(
                isAr
                    ? 'بموافقة الموظف على قسط فوق الحد (المادة 92)'
                    : 'Employee consented above the cap',
              ),
            ),
            if (_consent)
              TextField(
                controller: _consentNote,
                decoration: InputDecoration(
                  labelText: isAr ? 'مرجع الموافقة' : 'Consent reference',
                ),
              ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton(
                key: const ValueKey('advance-save'),
                onPressed: _busy || _read(_amount) <= 0 ? null : _plan,
                child: Text(isAr ? 'جدول السلفة' : 'Plan the advance'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
