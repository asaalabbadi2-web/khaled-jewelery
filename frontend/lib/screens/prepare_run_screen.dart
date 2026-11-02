import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/payroll_run_models.dart';
import '../services/payroll_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../utils/month_names.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import 'payroll_runs_screen.dart';

/// A month's run prepared before it is made (HR-UX ط4; the owner, 2 Nov 2026,
/// «اعتمد»): the month by its name, the first without a run offered (the
/// number picked before defaulted to this month -- November, with October
/// still to draft); then the run as it would be drafted, the server's and
/// nothing kept: who is in, who is left out and why, who would stop the batch
/// pay, each put right in place; then its draft.
class PrepareRunScreen extends StatefulWidget {
  const PrepareRunScreen({
    super.key,
    required this.api,
    this.isArabic = true,
    this.service,
  });

  final ApiService api;
  final bool isArabic;

  /// For tests: a service that answers without a server.
  final PayrollService? service;

  @override
  State<PrepareRunScreen> createState() => _PrepareRunScreenState();
}

class _PrepareRunScreenState extends State<PrepareRunScreen> {
  late final PayrollService _service =
      widget.service ?? PayrollService(widget.api);
  List<PayrollRunMonth>? _months;
  ({int month, int year})? _picked;
  PayrollRunPreview? _preview;
  Object? _error;
  bool _busy = false;

  bool get _isAr => widget.isArabic;

  @override
  void initState() {
    super.initState();
    _loadMonths();
  }

  Future<void> _loadMonths() async {
    try {
      final (months, offered) = await _service.runMonths();
      if (!mounted) return;
      setState(() {
        _error = null;
        _months = months;
        _picked = offered;
      });
      if (offered != null) await _see();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _see() async {
    final picked = _picked;
    if (picked == null) return;
    setState(() => _preview = null);
    try {
      final preview = await _service.previewRun(
        month: picked.month,
        year: picked.year,
      );
      if (mounted && _picked == picked) setState(() => _preview = preview);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _pick(PayrollRunMonth m) async {
    if (m.runId != null) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PayrollRunScreen(
            api: widget.api,
            runId: m.runId!,
            isArabic: _isAr,
            service: widget.service,
          ),
        ),
      );
      return;
    }
    if (m.state != 'open') return;
    setState(() => _picked = (month: m.month, year: m.year));
    await _see();
  }

  Future<void> _putRight(int employeeId, String name) async {
    await showDialog<void>(
      context: context,
      builder: (_) => EmployeePayrollDialog(
        service: _service,
        employeeId: employeeId,
        name: name,
        isAr: _isAr,
      ),
    );
    await _see();
  }

  Future<void> _draft() async {
    final picked = _picked!;
    setState(() => _busy = true);
    try {
      final run = await _service.generate(
        month: picked.month,
        year: picked.year,
      );
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PayrollRunScreen(
            api: widget.api,
            runId: run.summary.id,
            isArabic: _isAr,
            service: widget.service,
          ),
        ),
      );
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _monthLabel(int month, int year) =>
      '${monthName(month, isAr: _isAr)} ${ltrIsolate('$year')}';

  String _stateWord(PayrollRunMonth m, bool offered) => switch (m.state) {
    'paid' => _isAr ? 'مسيره مصروف' : 'Paid',
    'approved' => _isAr ? 'مسيره معتمد' : 'Approved',
    'draft' => _isAr ? 'مسودته قائمة' : 'Drafted',
    'entries' => _isAr ? 'سجلات قبل المسيرات' : 'Entered before the runs',
    _ =>
      offered
          ? (_isAr ? 'أول شهر بلا مسير' : 'The first without a run')
          : m.current
          ? (_isAr ? 'الشهر الجاري' : 'This month')
          : (_isAr ? 'بلا مسير' : 'No run'),
  };

  Widget _monthsCard() {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final months = _months!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isAr ? 'الشهر' : 'The month',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                for (final m in months)
                  Builder(
                    builder: (context) {
                      final picked =
                          _picked?.month == m.month && _picked?.year == m.year;
                      final open = m.state == 'open';
                      return InkWell(
                        key: ValueKey('prepare-month-${m.year}-${m.month}'),
                        borderRadius: BorderRadius.circular(AppRadius.control),
                        onTap: open || m.runId != null ? () => _pick(m) : null,
                        child: Container(
                          constraints: const BoxConstraints(
                            minWidth: 150,
                            minHeight: 48,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpace.lg,
                            vertical: AppSpace.sm,
                          ),
                          decoration: BoxDecoration(
                            color: picked
                                ? tones.gold.container
                                : open
                                ? null
                                : theme.colorScheme.surfaceContainerLow,
                            border: Border.all(
                              color: picked
                                  ? tones.gold.fg
                                  : theme.colorScheme.outlineVariant,
                              width: picked ? 2 : 1,
                            ),
                            borderRadius: BorderRadius.circular(
                              AppRadius.control,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _monthLabel(m.month, m.year),
                                style: theme.textTheme.titleSmall,
                              ),
                              Text(
                                _stateWord(m, picked && open),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(String label, String value, {bool strong = false}) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 180),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: strong
            ? theme.colorScheme.inverseSurface
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: strong ? theme.colorScheme.onInverseSurface : null,
            ),
          ),
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              color: strong ? theme.colorScheme.onInverseSurface : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _attention(PayrollRunPreview p) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final rows = [
      for (final r in p.run.leftOut)
        if (r.reason != 'removed') (r, true),
      for (final r in p.wontPay) (r, false),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Card(
      key: const ValueKey('prepare-attention'),
      color: tones.warning.container,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _isAr
                  ? 'قبل الإنشاء: ${ltrIsolate('${rows.length}')} يحتاج نظرة'
                  : 'Before it is made: ${rows.length} to look at',
              style: theme.textTheme.titleSmall?.copyWith(
                color: tones.warning.onContainer,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            for (final (r, out) in rows)
              Card(
                key: ValueKey(
                  'prepare-${out ? 'out' : 'wont-pay'}-${r.employeeId}',
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.md),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: AppSpace.md,
                    runSpacing: AppSpace.sm,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: AppSpace.sm,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(r.name, style: theme.textTheme.titleSmall),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpace.sm,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: (out ? tones.warning : tones.blocked)
                                        .container,
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.pill,
                                    ),
                                  ),
                                  child: Text(
                                    out
                                        ? (_isAr ? 'خارج المسير' : 'Left out')
                                        : (_isAr
                                              ? 'سيوقف الصرف'
                                              : 'Stops the pay'),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color:
                                          (out ? tones.warning : tones.blocked)
                                              .onContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Text(leftOutWord(r.reason, _isAr)),
                          ],
                        ),
                      ),
                      if (r.reason == 'no_structure' ||
                          r.reason == 'no_payment_method')
                        OutlinedButton(
                          key: ValueKey('prepare-fix-${r.employeeId}'),
                          onPressed: () => _putRight(r.employeeId, r.name),
                          child: Text(
                            r.reason == 'no_structure'
                                ? (_isAr ? 'أضف راتبه' : 'Add his salary')
                                : (_isAr
                                      ? 'حدّد طريقة صرفه'
                                      : 'Set how he is paid'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _lines(PayrollRunPreview p) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final wontPay = {for (final r in p.wontPay) r.employeeId};
    String money(double v) => ltrIsolate(formatAmount(v));
    final cells = [
      for (final l in p.run.lines)
        (
          l,
          l.bonuses.fold<double>(
            0,
            (s, b) => s + ((b['amount'] as num?) ?? 0).toDouble(),
          ),
        ),
    ];
    return Card(
      key: const ValueKey('prepare-lines'),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Text(
              _isAr ? 'يدخلون' : 'In the run',
              style: theme.textTheme.titleSmall,
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              // figures keep to their column's right edge under their titles,
              // as in the run's table: numeric's end edge is the left in Arabic
              columns: [
                DataColumn(label: Text(_isAr ? 'الموظف' : 'Employee')),
                DataColumn(label: Text(_isAr ? 'الراتب' : 'Salary')),
                DataColumn(label: Text(_isAr ? 'المكافآت' : 'Bonuses')),
                DataColumn(label: Text(_isAr ? 'الخصومات' : 'Deductions')),
                DataColumn(label: Text(_isAr ? 'الصافي' : 'Net')),
              ],
              rows: [
                for (final (l, bonuses) in cells)
                  DataRow(
                    cells: [
                      DataCell(
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l.employeeName),
                            if (wontPay.contains(l.employeeId))
                              Text(
                                _isAr ? 'لا طريقة صرف' : 'No way to be paid',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: tones.blocked.fg,
                                ),
                              ),
                          ],
                        ),
                      ),
                      DataCell(Text(money(l.basic + l.allowances))),
                      DataCell(Text(bonuses == 0 ? '—' : money(bonuses))),
                      DataCell(
                        Text(l.deductions == 0 ? '—' : money(l.deductions)),
                      ),
                      DataCell(
                        Text(money(l.net), style: theme.textTheme.titleSmall),
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

  @override
  Widget build(BuildContext context) {
    final isAr = _isAr;
    final theme = Theme.of(context);
    Widget body;
    if (_error != null && _months == null) {
      body = AppErrorView(
        title: isAr ? 'تعذّر تحميل الأشهر' : 'Could not load the months',
        error: _error!,
        onRetry: _loadMonths,
      );
    } else if (_months == null) {
      body = const AppLoadingView(summaryBlocks: 4, rows: 4);
    } else {
      final picked = _picked;
      final p = _preview;
      body = ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          _monthsCard(),
          if (picked == null)
            AppEmptyView(
              title: isAr ? 'لا شهر بلا مسير' : 'No month to draft',
              hint: isAr
                  ? 'كل شهر إلى اليوم له مسيره'
                  : 'Every month to now has its run',
            )
          else if (p == null)
            const AppLoadingView(summaryBlocks: 4, rows: 4)
          else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.lg),
                child: Wrap(
                  spacing: AppSpace.md,
                  runSpacing: AppSpace.md,
                  children: [
                    _tile(
                      isAr ? 'يدخلون المسير' : 'In the run',
                      isAr
                          ? '${ltrIsolate('${p.run.lines.length}')} من ${ltrIsolate('${p.run.lines.length + p.run.leftOut.length}')}'
                          : '${p.run.lines.length} of ${p.run.lines.length + p.run.leftOut.length}',
                    ),
                    _tile(
                      isAr ? 'الرواتب' : 'Salaries',
                      ltrIsolate(
                        formatAmount(
                          (p.run.totals['basic_salary'] ?? 0) +
                              (p.run.totals['allowances'] ?? 0),
                        ),
                      ),
                    ),
                    _tile(
                      isAr
                          ? 'المكافآت بما في الدفاتر'
                          : 'Bonuses, as the books owe',
                      ltrIsolate(formatAmount(p.run.totals['bonuses'] ?? 0)),
                    ),
                    _tile(
                      isAr ? 'الصافي التقديري' : 'Net, as drafted now',
                      ltrIsolate(formatAmount(p.run.totals['net_salary'] ?? 0)),
                      strong: true,
                    ),
                  ],
                ),
              ),
            ),
            _attention(p),
            if (p.run.lines.isNotEmpty) _lines(p),
            const SizedBox(height: AppSpace.md),
            Text(
              isAr
                  ? 'تُراجَع المسودة وتُعدَّل قبل الاعتماد. ومن يُصلَح وضعه بعد إنشائها يُضاف إليها بـ«أضف إلى المسودة».'
                  : 'The draft is reviewed before it is approved; one put right after is added to it.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      );
    }
    final picked = _picked;
    return Scaffold(
      appBar: AppBar(title: Text(isAr ? 'مسير جديد' : 'New run')),
      body: body,
      bottomNavigationBar: picked == null || _preview == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: FilledButton(
                  key: const ValueKey('prepare-draft'),
                  onPressed: _busy || _preview!.run.lines.isEmpty
                      ? null
                      : _draft,
                  child: Text(
                    isAr
                        ? 'أنشئ مسودة ${monthName(picked.month)}'
                        : 'Draft ${monthName(picked.month, isAr: false)}',
                  ),
                ),
              ),
            ),
    );
  }
}
