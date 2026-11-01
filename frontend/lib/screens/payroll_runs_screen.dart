import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/date_field.dart';
import '../api_service.dart';
import 'package:printing/printing.dart';

import '../models/payroll_run_models.dart';
import '../pdf/payslip_pdf_builder.dart';
import '../services/payroll_service.dart';
import 'contribution_schemes_screen.dart';
import 'payroll_policy_screen.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils.dart' show normalizeNumber;
import '../utils/arabic_number_formatter.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';

/// A month's payroll as one document (PAYROLL-2, ADR-068): drafted from the
/// salary structures, reviewed, approved with one accrual, paid in a batch.
/// The server says every figure and every refusal; the screen shows them.

String _runStatusWord(String status, bool isAr) => switch (status) {
  'draft' => isAr ? 'مسودة' : 'Draft',
  'approved' => isAr ? 'معتمد' : 'Approved',
  'paid' => isAr ? 'مصروف' : 'Paid',
  'cancelled' => isAr ? 'ملغى' : 'Cancelled',
  _ => status,
};

SemanticTone _runTone(BuildContext context, String status) {
  final tones = AppSemanticColors.of(context);
  return switch (status) {
    'paid' => tones.ready,
    'approved' => tones.info,
    'cancelled' => tones.blocked,
    _ => tones.warning,
  };
}

String _leftOutWord(String reason, bool isAr) => switch (reason) {
  'no_structure' => isAr ? 'لا هيكل راتب له' : 'No salary structure',
  'has_an_entry' =>
    isAr ? 'له سجل راتب لهذا الشهر خارج المسير' : 'Has an entry of his own',
  'not_employed' => isAr ? 'لم يعمل في الشهر' : 'Not employed this month',
  'removed' => isAr ? 'أُزيل من المسودة' : 'Removed from the draft',
  _ => reason,
};

/// A deduction's kind, said (PAYROLL-3).
String _deductionWord(String? kind, bool isAr) => switch (kind) {
  'penalty' => isAr ? 'جزاء' : 'Penalty',
  'contribution' => isAr ? 'اشتراك' : 'Contribution',
  'advance' => isAr ? 'سلفة' : 'Advance',
  _ => isAr ? 'غياب' : 'Absence',
};

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.status, this.isAr);
  final String status;
  final bool isAr;

  @override
  Widget build(BuildContext context) {
    final tone = _runTone(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Text(
        _runStatusWord(status, isAr),
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(color: tone.onContainer),
      ),
    );
  }
}

// ── the runs ────────────────────────────────────────────────────────────────

class PayrollRunsScreen extends StatefulWidget {
  const PayrollRunsScreen({
    super.key,
    required this.api,
    this.isArabic = true,
    this.embedded = false,
    this.service,
  });
  final ApiService api;
  final bool isArabic;

  /// The hub's own, or a test's.
  final PayrollService? service;

  /// Inside the HR hub's «الرواتب» tab (HR-UX ر1): no bar of its own -- the
  /// policy and the schemes are the hub's «الإعدادات».
  final bool embedded;

  @override
  State<PayrollRunsScreen> createState() => _PayrollRunsScreenState();
}

class _PayrollRunsScreenState extends State<PayrollRunsScreen> {
  late final PayrollService _service =
      widget.service ?? PayrollService(widget.api);
  List<PayrollRunSummary>? _runs;
  Object? _error;

  bool get _isAr => widget.isArabic;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final runs = await _service.listRuns();
      if (mounted) setState(() => _runs = runs);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _newRun() async {
    final period = await showDialog<(int, int)>(
      context: context,
      builder: (_) => _MonthDialog(isAr: _isAr),
    );
    if (period == null || !mounted) return;
    try {
      final run = await _service.generate(month: period.$1, year: period.$2);
      if (!mounted) return;
      await _open(run.summary.id);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    }
  }

  Future<void> _open(int runId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            PayrollRunScreen(api: widget.api, runId: runId, isArabic: _isAr),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final isAr = _isAr;
    final runs = _runs;
    Widget body;
    if (_error != null && runs == null) {
      body = AppErrorView(
        title: isAr ? 'تعذّر تحميل المسيرات' : 'Could not load the runs',
        error: _error!,
        onRetry: _load,
      );
    } else if (runs == null) {
      body = const AppLoadingView(summaryBlocks: 0, rows: 5);
    } else if (runs.isEmpty) {
      body = AppEmptyView(
        title: isAr ? 'لا مسيرات بعد' : 'No runs yet',
        hint: isAr
            ? 'المسير يُنشأ من هياكل رواتب الموظفين لشهر واحد'
            : 'A run is drafted from the salary structures for one month',
        actionLabel: isAr ? 'مسير جديد' : 'New run',
        actionIcon: Icons.add,
        onAction: _newRun,
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          padding: const EdgeInsets.all(AppSpace.lg),
          itemCount: runs.length,
          separatorBuilder: (_, _) => const SizedBox(height: AppSpace.sm),
          itemBuilder: (_, i) {
            final run = runs[i];
            return Card(
              child: ListTile(
                key: ValueKey('payroll-run-${run.id}'),
                leading: const Icon(Icons.event_note_outlined),
                title: Text(
                  ltrIsolate('${run.month}/${run.year}'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                subtitle: Text(isAr ? 'مسير رقم ${run.id}' : 'Run #${run.id}'),
                trailing: _StatusChip(run.status, isAr),
                onTap: () => _open(run.id),
              ),
            );
          },
        ),
      );
    }
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(isAr ? 'مسيرات الرواتب' : 'Payroll runs'),
              actions: [
                IconButton(
                  key: const ValueKey('payroll-open-schemes'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ContributionSchemesScreen(
                        api: widget.api,
                        isArabic: isAr,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.health_and_safety_outlined),
                  tooltip: isAr
                      ? 'خطط الاشتراك (التأمينات)'
                      : 'Contribution schemes',
                ),
                IconButton(
                  key: const ValueKey('payroll-open-policy'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          PayrollPolicyScreen(api: widget.api, isArabic: isAr),
                    ),
                  ),
                  icon: const Icon(Icons.tune),
                  tooltip: isAr ? 'سياسة الرواتب' : 'Payroll policy',
                ),
                IconButton(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  tooltip: isAr ? 'تحديث' : 'Refresh',
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('payroll-run-new'),
        onPressed: _newRun,
        icon: const Icon(Icons.add),
        label: Text(isAr ? 'مسير جديد' : 'New run'),
      ),
      body: body,
    );
  }
}

class _MonthDialog extends StatefulWidget {
  const _MonthDialog({required this.isAr});
  final bool isAr;

  @override
  State<_MonthDialog> createState() => _MonthDialogState();
}

class _MonthDialogState extends State<_MonthDialog> {
  late int _month;
  late int _year;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    _month = today.month;
    _year = today.year;
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    final thisYear = DateTime.now().year;
    return AlertDialog(
      title: Text(isAr ? 'مسير شهر' : 'Run for a month'),
      content: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              key: const ValueKey('payroll-run-month'),
              initialValue: _month,
              decoration: InputDecoration(labelText: isAr ? 'الشهر' : 'Month'),
              items: [
                for (var m = 1; m <= 12; m++)
                  DropdownMenuItem(value: m, child: Text('$m')),
              ],
              onChanged: (v) => setState(() => _month = v ?? _month),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: DropdownButtonFormField<int>(
              key: const ValueKey('payroll-run-year'),
              initialValue: _year,
              decoration: InputDecoration(labelText: isAr ? 'السنة' : 'Year'),
              items: [
                for (var y = thisYear - 1; y <= thisYear + 1; y++)
                  DropdownMenuItem(value: y, child: Text('$y')),
              ],
              onChanged: (v) => setState(() => _year = v ?? _year),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isAr ? 'إلغاء' : 'Cancel'),
        ),
        FilledButton(
          key: const ValueKey('payroll-run-generate'),
          onPressed: () => Navigator.pop(context, (_month, _year)),
          child: Text(isAr ? 'أنشئ المسودة' : 'Draft it'),
        ),
      ],
    );
  }
}

// ── one run ─────────────────────────────────────────────────────────────────

class PayrollRunScreen extends StatefulWidget {
  const PayrollRunScreen({
    super.key,
    required this.api,
    required this.runId,
    this.isArabic = true,
    this.service,
  });
  final ApiService api;
  final int runId;
  final bool isArabic;

  /// For tests: a service that answers without a server.
  final PayrollService? service;

  @override
  State<PayrollRunScreen> createState() => _PayrollRunScreenState();
}

class _PayrollRunScreenState extends State<PayrollRunScreen> {
  late final PayrollService _service =
      widget.service ?? PayrollService(widget.api);
  PayrollRun? _run;
  Object? _error;
  bool _busy = false;

  bool get _isAr => widget.isArabic;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final run = await _service.getRun(widget.runId);
      if (mounted) setState(() => _run = run);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// The action, its run shown as the server returns it -- or its refusal said.
  Future<void> _act(Future<PayrollRun> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      final run = await action();
      if (!mounted) return;
      setState(() => _run = run);
      AppFeedback.success(context, done);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_isAr ? 'رجوع' : 'Back'),
            ),
            FilledButton(
              key: const ValueKey('payroll-run-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(_isAr ? 'تأكيد' : 'Confirm'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _approve(PayrollRun run) async {
    final net = formatAmount(run.totals['net_salary'] ?? 0);
    if (!await _confirm(
      _isAr ? 'اعتماد المسير' : 'Approve the run',
      _isAr
          ? 'يُكتب قيد استحقاق واحد بصافي $net ر.س، ولا يُعدَّل المسير بعده.'
          : 'One accrual of $net is written; the run is not edited after.',
    )) {
      return;
    }
    await _act(
      () => _service.approve(run.summary.id),
      _isAr ? 'اعتُمد المسير' : 'Approved',
    );
  }

  Future<void> _cancel(PayrollRun run) async {
    if (!await _confirm(
      _isAr ? 'إلغاء المسير' : 'Cancel the run',
      run.summary.status == 'draft'
          ? (_isAr
                ? 'تُحذف أسطر المسودة، ويمكن إنشاء مسير الشهر من جديد.'
                : 'The draft lines are removed.')
          : (_isAr
                ? 'يُعكس قيد استحقاقه، ويمكن إنشاء مسير الشهر من جديد.'
                : 'Its accrual is reversed.'),
    )) {
      return;
    }
    await _act(
      () => _service.cancel(run.summary.id),
      _isAr ? 'أُلغي المسير' : 'Cancelled',
    );
  }

  Future<void> _pay(PayrollRun run) async {
    final plan = await showDialog<(Map<int, int>, String)>(
      context: context,
      builder: (_) =>
          _PayDialog(service: _service, lines: run.lines, isAr: _isAr),
    );
    if (plan == null) return;
    await _act(
      () => _service.pay(
        run.summary.id,
        accountByLine: plan.$1,
        paidDate: plan.$2,
      ),
      _isAr ? 'صُرف المسير' : 'Paid',
    );
  }

  Future<void> _editLine(PayrollRun run, PayrollRunLine line) async {
    final edited =
        await showDialog<
          (List<PayrollLabelledAmount>, List<PayrollLabelledAmount>, List<int>)
        >(
          context: context,
          builder: (_) => _LineDialog(line: line, isAr: _isAr),
        );
    if (edited == null) return;
    await _act(
      () => _service.editLine(
        run.summary.id,
        line.id,
        additions: edited.$1,
        deductions: edited.$2,
        keptBonuses: line.bonuses.isEmpty ? null : edited.$3,
        notes: line.notes,
      ),
      _isAr ? 'حُفظ السطر' : 'Saved',
    );
  }

  Future<void> _removeLine(PayrollRun run, PayrollRunLine line) async {
    if (!await _confirm(
      _isAr ? 'إزالة من المسودة' : 'Remove from the draft',
      line.employeeName,
    )) {
      return;
    }
    await _act(
      () => _service.removeLine(run.summary.id, line.id),
      _isAr ? 'أُزيل السطر' : 'Removed',
    );
  }

  Future<void> _employeeData(int employeeId, String name) async {
    await showDialog<void>(
      context: context,
      builder: (_) => EmployeePayrollDialog(
        service: _service,
        employeeId: employeeId,
        name: name,
        isAr: _isAr,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = _isAr;
    final run = _run;
    Widget body;
    if (_error != null && run == null) {
      body = AppErrorView(
        title: isAr ? 'تعذّر تحميل المسير' : 'Could not load the run',
        error: _error!,
        onRetry: _load,
      );
    } else if (run == null) {
      body = const AppLoadingView(summaryBlocks: 4, rows: 5);
    } else {
      final status = run.summary.status;
      Widget card(PayrollRunLine line) => _LineCard(
        line: line,
        isAr: isAr,
        onEdit: status == 'draft' ? () => _editLine(run, line) : null,
        onRemove: status == 'draft' ? () => _removeLine(run, line) : null,
        onEmployee: () => _employeeData(line.employeeId, line.employeeName),
        onPayslip: () => showDialog<void>(
          context: context,
          builder: (_) =>
              _PayslipDialog(service: _service, lineId: line.id, isAr: isAr),
        ),
      );
      body = ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          _Stages(status: status, isAr: isAr),
          const SizedBox(height: AppSpace.md),
          _Totals(run: run, isAr: isAr),
          if (run.leftOut.isNotEmpty) ...[
            const SizedBox(height: AppSpace.md),
            _LeftOut(
              run: run,
              isAr: isAr,
              onAddStructure: status == 'draft' ? _employeeData : null,
            ),
          ],
          const SizedBox(height: AppSpace.md),
          // HR-UX ر3: a table on a wide screen, a line's details in its sheet;
          // cards on a narrow one
          if (run.lines.isNotEmpty)
            LayoutBuilder(
              builder: (context, box) => box.maxWidth >= 900
                  ? _LinesTable(
                      lines: run.lines,
                      isAr: isAr,
                      onOpen: (line) => showDialog<void>(
                        context: context,
                        builder: (_) => Dialog(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 560),
                            child: SingleChildScrollView(child: card(line)),
                          ),
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        for (final line in run.lines)
                          Padding(
                            padding: const EdgeInsets.only(bottom: AppSpace.sm),
                            child: card(line),
                          ),
                      ],
                    ),
            ),
          if (run.lines.isEmpty)
            AppEmptyView(
              title: isAr ? 'المسير بلا أسطر' : 'The run has no lines',
              hint: isAr
                  ? 'أضف هياكل رواتب للموظفين، ثم ألغِ المسودة وأنشئها من جديد'
                  : 'Add salary structures, then draft the month again',
            ),
        ],
      );
    }
    final status = run?.summary.status;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          run == null
              ? (isAr ? 'المسير' : 'Run')
              : '${isAr ? 'مسير' : 'Run'} ${ltrIsolate('${run.summary.month}/${run.summary.year}')}',
        ),
        actions: [
          if (status != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: AppSpace.md),
              child: Center(child: _StatusChip(status, isAr)),
            ),
        ],
      ),
      body: body,
      bottomNavigationBar:
          run == null || status == 'cancelled' || status == 'paid'
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Row(
                  children: [
                    if (status == 'draft')
                      Expanded(
                        child: FilledButton.icon(
                          key: const ValueKey('payroll-run-approve'),
                          onPressed: _busy || run.lines.isEmpty
                              ? null
                              : () => _approve(run),
                          icon: const Icon(Icons.verified_outlined),
                          label: Text(isAr ? 'اعتماد' : 'Approve'),
                        ),
                      ),
                    if (status == 'approved')
                      Expanded(
                        child: FilledButton.icon(
                          key: const ValueKey('payroll-run-pay'),
                          onPressed: _busy ? null : () => _pay(run),
                          icon: const Icon(Icons.payments_outlined),
                          label: Text(isAr ? 'صرف' : 'Pay'),
                        ),
                      ),
                    const SizedBox(width: AppSpace.md),
                    OutlinedButton.icon(
                      key: const ValueKey('payroll-run-cancel'),
                      onPressed: _busy ? null : () => _cancel(run),
                      icon: const Icon(Icons.block),
                      label: Text(isAr ? 'إلغاء المسير' : 'Cancel run'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.run, required this.isAr});
  final PayrollRun run;
  final bool isAr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget tile(String label, String key, {bool strong = false}) => Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: strong ? scheme.inverseSurface : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: strong ? scheme.onInverseSurface : null,
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            formatAmount(run.totals[key] ?? 0),
            textDirection: TextDirection.ltr,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: strong ? scheme.onInverseSurface : null,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
    final tiles = [
      tile(isAr ? 'الأساسي' : 'Basic', 'basic_salary'),
      tile(isAr ? 'البدلات والمكافآت' : 'Allowances & bonuses', 'allowances'),
      tile(isAr ? 'الخصومات' : 'Deductions', 'deductions'),
      tile(isAr ? 'الصافي للصرف' : 'Net to pay', 'net_salary', strong: true),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 700 ? 4 : 2;
        final width = (box.maxWidth - AppSpace.sm * (columns - 1)) / columns;
        return Wrap(
          key: const ValueKey('payroll-run-totals'),
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: [for (final t in tiles) SizedBox(width: width, child: t)],
        );
      },
    );
  }
}

/// The run's four stages: drafted, reviewed, approved (one accrual), paid.
class _Stages extends StatelessWidget {
  const _Stages({required this.status, required this.isAr});
  final String status;
  final bool isAr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final reached = switch (status) {
      'draft' => 1,
      'approved' => 3,
      'paid' => 4,
      _ => -1,
    };
    final stages = [
      (
        isAr ? 'أُنشئت المسودة' : 'Drafted',
        isAr ? 'من هياكل الرواتب' : 'from the structures',
      ),
      (
        isAr ? 'المراجعة' : 'Review',
        isAr ? 'إضافات وخصومات' : 'additions, deductions',
      ),
      (
        isAr ? 'الاعتماد' : 'Approval',
        isAr ? 'قيد استحقاق واحد' : 'one accrual',
      ),
      (isAr ? 'الصرف' : 'Payment', isAr ? 'تحويل ونقد معًا' : 'bank and cash'),
    ];
    if (reached < 0) {
      return Card(
        color: tones.blocked.container,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Text(
            isAr ? 'المسير ملغى' : 'The run is cancelled',
            style: theme.textTheme.titleSmall?.copyWith(
              color: tones.blocked.onContainer,
            ),
          ),
        ),
      );
    }
    Widget stage(int index) {
      final done = index < reached;
      final current = index == reached;
      final tone = done ? tones.ready : (current ? tones.gold : null);
      return Container(
        key: ValueKey('payroll-stage-$index'),
        padding: const EdgeInsets.all(AppSpace.sm),
        decoration: BoxDecoration(
          color: tone?.container ?? theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: current ? Border.all(color: tones.gold.fg, width: 2) : null,
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: tone?.fg ?? theme.colorScheme.outlineVariant,
              foregroundColor: theme.colorScheme.surface,
              child: done
                  ? const Icon(Icons.check, size: 16)
                  : Text(ltrIsolate('${index + 1}')),
            ),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stages[index].$1,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: tone?.onContainer,
                    ),
                  ),
                  Text(
                    stages[index].$2,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: tone?.onContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 700 ? 4 : 2;
        final width = (box.maxWidth - AppSpace.sm * (columns - 1)) / columns;
        return Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: [
            for (var i = 0; i < stages.length; i++)
              SizedBox(width: width, child: stage(i)),
          ],
        );
      },
    );
  }
}

/// The lines as a table: a wide screen's (HR-UX ر3). A row opens its line.
class _LinesTable extends StatelessWidget {
  const _LinesTable({
    required this.lines,
    required this.isAr,
    required this.onOpen,
  });
  final List<PayrollRunLine> lines;
  final bool isAr;
  final void Function(PayrollRunLine line) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final tabular = theme.textTheme.bodyMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget money(double v, {bool strong = false}) => Text(
      formatAmount(v),
      textDirection: TextDirection.ltr,
      style: strong ? tabular?.copyWith(fontWeight: FontWeight.w800) : tabular,
    );
    String? note(PayrollRunLine l) {
      if (l.bonusesHeld != null) {
        return isAr ? 'مكافآت محجوزة: الدفاتر تقول أقل' : 'bonuses held';
      }
      if (l.bonusBooksCap != null) {
        return isAr ? 'مكافأته بما تقوله الدفاتر' : 'bonus at the books';
      }
      if (!l.wholeMonth) {
        return isAr
            ? '${ltrIsolate('${l.days}')} يومًا من الشهر'
            : '${l.days} days';
      }
      return null;
    }

    return Card(
      key: const ValueKey('payroll-lines-table'),
      clipBehavior: Clip.antiAlias,
      child: Table(
        columnWidths: const {0: FlexColumnWidth(2.4)},
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
            ),
            children: [
              for (final h in [
                isAr ? 'الموظف' : 'Employee',
                isAr ? 'الأساسي' : 'Basic',
                isAr ? 'البدلات والمكافآت' : 'Allowances',
                isAr ? 'الخصومات' : 'Deductions',
                isAr ? 'الصافي' : 'Net',
                isAr ? 'السند' : 'Voucher',
              ])
                Padding(
                  padding: const EdgeInsets.all(AppSpace.md),
                  child: Text(h, style: theme.textTheme.labelMedium),
                ),
            ],
          ),
          for (final l in lines)
            TableRow(
              key: ValueKey('payroll-row-${l.employeeId}'),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              children: [
                for (final cell in [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.employeeName, style: theme.textTheme.titleSmall),
                      if (note(l) case final String n)
                        Text(
                          n,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: l.bonusesHeld != null
                                ? tones.warning.fg
                                : null,
                          ),
                        ),
                    ],
                  ),
                  money(l.basic),
                  money(l.allowances),
                  l.deductions > 0 ? money(l.deductions) : const Text('—'),
                  money(l.net, strong: true),
                  Text(
                    l.voucherNumber == null
                        ? '—'
                        : ltrIsolate(l.voucherNumber!),
                    style: theme.textTheme.bodySmall,
                  ),
                ])
                  TableRowInkWell(
                    onTap: () => onOpen(l),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpace.md),
                      child: cell,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _LeftOut extends StatelessWidget {
  const _LeftOut({
    required this.run,
    required this.isAr,
    required this.onAddStructure,
  });
  final PayrollRun run;
  final bool isAr;
  final Future<void> Function(int employeeId, String name)? onAddStructure;

  @override
  Widget build(BuildContext context) {
    final tone = AppSemanticColors.of(context).warning;
    final theme = Theme.of(context);
    return Card(
      color: tone.container,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isAr ? 'خارج المسير' : 'Left out',
              style: theme.textTheme.titleSmall?.copyWith(
                color: tone.onContainer,
              ),
            ),
            for (final row in run.leftOut)
              Row(
                key: ValueKey('payroll-left-out-${row.employeeId}'),
                children: [
                  Expanded(
                    child: Text(
                      '${row.name} — ${_leftOutWord(row.reason, isAr)}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: tone.onContainer,
                      ),
                    ),
                  ),
                  if (row.reason == 'no_structure' && onAddStructure != null)
                    TextButton(
                      onPressed: () =>
                          onAddStructure!(row.employeeId, row.name),
                      child: Text(isAr ? 'هيكل الراتب' : 'Structure'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({
    required this.line,
    required this.isAr,
    required this.onEdit,
    required this.onRemove,
    required this.onEmployee,
    required this.onPayslip,
  });
  final PayrollRunLine line;
  final bool isAr;
  final VoidCallback? onEdit;
  final VoidCallback? onRemove;
  final VoidCallback onEmployee;
  final VoidCallback onPayslip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tabular = theme.textTheme.bodyMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    String money(double v) => formatAmount(v);
    return Card(
      key: ValueKey('payroll-line-${line.employeeId}'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    line.employeeName,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  money(line.net),
                  textDirection: TextDirection.ltr,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Wrap(
              spacing: AppSpace.lg,
              children: [
                Text(
                  '${isAr ? 'أساسي' : 'Basic'} ${ltrIsolate(money(line.basic))}',
                  style: tabular,
                ),
                Text(
                  '${isAr ? 'بدلات' : 'Allowances'} ${ltrIsolate(money(line.allowances))}',
                  style: tabular,
                ),
                if (line.deductions > 0)
                  Text(
                    '${isAr ? 'خصومات' : 'Deductions'} ${ltrIsolate(money(line.deductions))}',
                    style: tabular,
                  ),
                if (!line.wholeMonth)
                  Text(
                    isAr
                        ? '${ltrIsolate('${line.days}')} يومًا من الشهر'
                        : '${line.days} days',
                    style: tabular,
                  ),
                if (line.voucherNumber != null)
                  Text(ltrIsolate(line.voucherNumber!), style: tabular),
              ],
            ),
            for (final a in line.additions)
              Text(
                '+ ${a.label} ${ltrIsolate(money(a.amount))}',
                style: theme.textTheme.bodySmall,
              ),
            for (final d in line.deductionLines)
              Text(
                '− ${d.label} (${_deductionWord(d.kind, isAr)}) ${ltrIsolate(money(d.amount))}',
                style: theme.textTheme.bodySmall,
              ),
            for (final b in line.bonuses)
              Text(
                '+ ${b['label']} (${isAr ? 'مكافأة' : 'bonus'}) ${ltrIsolate(money(((b['amount'] as num?) ?? 0).toDouble()))}',
                style: theme.textTheme.bodySmall,
              ),
            if (line.bonusBooksCap case final cap?)
              Text(
                isAr
                    ? 'المكافأة المعتمدة ${ltrIsolate(money(cap['approved_unpaid'] ?? 0))} تُصرف بما تقوله الدفاتر ${ltrIsolate(money(cap['owed_in_books'] ?? 0))}: صُرف باقيها من قبل'
                    : 'Bonus ${money(cap['approved_unpaid'] ?? 0)} paid at what the books owe, ${money(cap['owed_in_books'] ?? 0)}',
                style: theme.textTheme.bodySmall,
              ),
            if (line.bonusesHeld case final held?)
              Text(
                isAr
                    ? 'مكافآت معتمدة ${ltrIsolate(money(held['approved_unpaid'] ?? 0))} لم تدخل: الدفاتر تقول المستحق ${ltrIsolate(money(held['owed_in_books'] ?? 0))}'
                    : 'Approved bonuses ${money(held['approved_unpaid'] ?? 0)} held: the books owe ${money(held['owed_in_books'] ?? 0)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppSemanticColors.of(context).warning.fg,
                ),
              ),
            if (line.eosProvision != 0)
              Text(
                '${isAr ? 'مخصص نهاية الخدمة للشهر' : 'End-of-service provision'} '
                '${ltrIsolate(money(line.eosProvision))}',
                style: theme.textTheme.bodySmall,
              )
            else if (line.eosPolicyNotSet)
              Text(
                isAr
                    ? 'سياسة نهاية الخدمة غير مضبوطة: لا يُحسب المخصص'
                    : 'End-of-service policy not set: no provision',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppSemanticColors.of(context).warning.fg,
                ),
              )
            else if (line.eosWithoutHireDate)
              Text(
                isAr
                    ? 'لا تاريخ تعيين: لا يُحسب مخصص نهاية الخدمة'
                    : 'No hire date: no end-of-service provision',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppSemanticColors.of(context).warning.fg,
                ),
              ),
            if (line.employerContributions > 0)
              Text(
                '${isAr ? 'حصة المنشأة من الاشتراكات' : 'Employer contributions'} '
                '${ltrIsolate(money(line.employerContributions))}',
                style: theme.textTheme.bodySmall,
              ),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: onEmployee,
                  icon: const Icon(Icons.badge_outlined),
                  label: Text(isAr ? 'بيانات الراتب' : 'Payroll data'),
                ),
                TextButton.icon(
                  onPressed: onPayslip,
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: Text(isAr ? 'القسيمة' : 'Payslip'),
                ),
                if (onEdit != null)
                  TextButton.icon(
                    key: ValueKey('payroll-line-edit-${line.employeeId}'),
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(isAr ? 'إضافة وخصم' : 'Adjust'),
                  ),
                if (onRemove != null)
                  TextButton.icon(
                    onPressed: onRemove,
                    icon: const Icon(Icons.remove_circle_outline),
                    label: Text(isAr ? 'إزالة' : 'Remove'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── the line's additions and deductions ─────────────────────────────────────

class _Row {
  _Row(String label, double? amount, {this.kind})
    : label = TextEditingController(text: label),
      amount = TextEditingController(
        text: amount == null ? '' : formatAmount(amount).replaceAll(',', ''),
      );
  final TextEditingController label;
  final TextEditingController amount;

  /// A deduction's: 'absence' or 'penalty'; an addition has none.
  String? kind;
}

class _LineDialog extends StatefulWidget {
  const _LineDialog({required this.line, required this.isAr});
  final PayrollRunLine line;
  final bool isAr;

  @override
  State<_LineDialog> createState() => _LineDialogState();
}

class _LineDialogState extends State<_LineDialog> {
  /// The bonuses kept on the line; one unticked is let go (PAYROLL-4).
  late final Set<int> _kept = {
    for (final b in widget.line.bonuses) b['bonus_id'] as int,
  };

  late final List<_Row> _additions = [
    for (final a in widget.line.additions) _Row(a.label, a.amount),
  ];

  /// The keyed ones -- absence and penalties; the reckoned are the server's.
  late final List<_Row> _deductions = [
    for (final d in widget.line.deductionLines.where((d) => d.isKeyed))
      _Row(d.label, d.amount, kind: d.kind ?? 'absence'),
  ];

  List<PayrollLabelledAmount> _read(List<_Row> rows) => [
    for (final r in rows)
      if (r.label.text.trim().isNotEmpty || r.amount.text.trim().isNotEmpty)
        PayrollLabelledAmount(
          r.label.text.trim(),
          double.tryParse(normalizeNumber(r.amount.text)) ?? 0,
          kind: r.kind,
        ),
  ];

  Widget _side(
    String title,
    List<_Row> rows,
    String keyPrefix, {
    bool kinds = false,
  }) {
    final isAr = widget.isAr;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        for (var i = 0; i < rows.length; i++)
          Row(
            children: [
              if (kinds)
                DropdownButton<String>(
                  key: ValueKey('$keyPrefix-kind-$i'),
                  value: rows[i].kind,
                  items: [
                    for (final k in const ['absence', 'penalty'])
                      DropdownMenuItem(
                        value: k,
                        child: Text(_deductionWord(k, isAr)),
                      ),
                  ],
                  onChanged: (v) => setState(() => rows[i].kind = v),
                ),
              if (kinds) const SizedBox(width: AppSpace.sm),
              Expanded(
                flex: 3,
                child: TextField(
                  key: ValueKey('$keyPrefix-label-$i'),
                  controller: rows[i].label,
                  decoration: InputDecoration(
                    labelText: isAr ? 'السبب' : 'Reason',
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                flex: 2,
                child: TextField(
                  key: ValueKey('$keyPrefix-amount-$i'),
                  controller: rows[i].amount,
                  textDirection: TextDirection.ltr,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    ArabicNumberTextInputFormatter(),
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: InputDecoration(
                    labelText: isAr ? 'المبلغ' : 'Amount',
                  ),
                ),
              ),
              IconButton(
                onPressed: () => setState(() => rows.removeAt(i)),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        TextButton.icon(
          key: ValueKey('$keyPrefix-add'),
          onPressed: () => setState(
            () => rows.add(_Row('', null, kind: kinds ? 'absence' : null)),
          ),
          icon: const Icon(Icons.add),
          label: Text(isAr ? 'سطر' : 'Line'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    return AlertDialog(
      title: Text(widget.line.employeeName),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _side(isAr ? 'الإضافات' : 'Additions', _additions, 'addition'),
              for (final b in widget.line.bonuses)
                CheckboxListTile(
                  key: ValueKey('payroll-line-bonus-${b['bonus_id']}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _kept.contains(b['bonus_id']),
                  onChanged: (v) => setState(
                    () => v == true
                        ? _kept.add(b['bonus_id'] as int)
                        : _kept.remove(b['bonus_id'] as int),
                  ),
                  title: Text(
                    '${b['label']} (${isAr ? 'مكافأة معتمدة' : 'approved bonus'})',
                  ),
                  secondary: Text(
                    formatAmount((b['amount'] as num?) ?? 0),
                    textDirection: TextDirection.ltr,
                  ),
                ),
              const SizedBox(height: AppSpace.md),
              _side(
                isAr ? 'الخصومات' : 'Deductions',
                _deductions,
                'deduction',
                kinds: true,
              ),
              for (final d in widget.line.deductionLines.where(
                (d) => !d.isKeyed,
              ))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${d.label} (${_deductionWord(d.kind, isAr)})'),
                  subtitle: Text(
                    isAr ? 'يحسبه النظام' : 'Reckoned by the system',
                  ),
                  trailing: Text(
                    formatAmount(d.amount),
                    textDirection: TextDirection.ltr,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isAr ? 'إلغاء' : 'Cancel'),
        ),
        FilledButton(
          key: const ValueKey('payroll-line-save'),
          onPressed: () => Navigator.pop(context, (
            _read(_additions),
            _read(_deductions),
            _kept.toList(),
          )),
          child: Text(isAr ? 'حفظ' : 'Save'),
        ),
      ],
    );
  }
}

// ── paid in a batch ─────────────────────────────────────────────────────────

class _PayDialog extends StatefulWidget {
  const _PayDialog({
    required this.service,
    required this.lines,
    required this.isAr,
  });
  final PayrollService service;
  final List<PayrollRunLine> lines;
  final bool isAr;

  @override
  State<_PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<_PayDialog> {
  List<Map<String, dynamic>>? _accounts;
  Object? _error;
  int? _bank;
  int? _cash;
  late final Map<int, String?> _method = {
    for (final l in widget.lines.where((l) => l.voucherNumber == null))
      l.id: l.paymentMethod,
  };

  @override
  void initState() {
    super.initState();
    widget.service
        .paymentAccounts()
        .then((a) {
          if (mounted) setState(() => _accounts = a);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e);
        });
  }

  Map<int, int>? get _plan {
    final plan = <int, int>{};
    for (final e in _method.entries) {
      final account = switch (e.value) {
        'bank' => _bank,
        'cash' => _cash,
        _ => null,
      };
      if (account == null) return null;
      plan[e.key] = account;
    }
    return plan;
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    final accounts = _accounts;
    final names = {for (final l in widget.lines) l.id: l.employeeName};
    Widget accountField(
      String label,
      int? value,
      ValueChanged<int?> set,
      String key,
    ) => DropdownButtonFormField<int>(
      key: ValueKey(key),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final a in accounts ?? const <Map<String, dynamic>>[])
          DropdownMenuItem(
            value: a['id'] as int,
            child: Text(a['name']?.toString() ?? ''),
          ),
      ],
      onChanged: set,
    );
    final plan = _plan;
    return AlertDialog(
      title: Text(isAr ? 'صرف المسير' : 'Pay the run'),
      content: SizedBox(
        width: 480,
        child: _error != null
            ? Text(_error.toString())
            : accounts == null
            ? const LinearProgressIndicator()
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    accountField(
                      isAr ? 'حساب التحويل البنكي' : 'Bank account',
                      _bank,
                      (v) => setState(() => _bank = v),
                      'payroll-pay-bank',
                    ),
                    const SizedBox(height: AppSpace.sm),
                    accountField(
                      isAr ? 'حساب النقد' : 'Cash account',
                      _cash,
                      (v) => setState(() => _cash = v),
                      'payroll-pay-cash',
                    ),
                    const SizedBox(height: AppSpace.md),
                    for (final e in _method.entries)
                      Row(
                        children: [
                          Expanded(child: Text(names[e.key] ?? '')),
                          SegmentedButton<String>(
                            key: ValueKey('payroll-pay-method-${e.key}'),
                            emptySelectionAllowed: true,
                            segments: [
                              ButtonSegment(
                                value: 'bank',
                                label: Text(isAr ? 'تحويل' : 'Bank'),
                              ),
                              ButtonSegment(
                                value: 'cash',
                                label: Text(isAr ? 'نقد' : 'Cash'),
                              ),
                            ],
                            selected: {?e.value},
                            onSelectionChanged: (s) => setState(
                              () => _method[e.key] = s.isEmpty ? null : s.first,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isAr ? 'إلغاء' : 'Cancel'),
        ),
        FilledButton(
          key: const ValueKey('payroll-pay-confirm'),
          onPressed: plan == null
              ? null
              : () {
                  final today = DateTime.now();
                  final day =
                      '${today.year}-${'${today.month}'.padLeft(2, '0')}-${'${today.day}'.padLeft(2, '0')}';
                  Navigator.pop(context, (plan, day));
                },
          child: Text(isAr ? 'اصرف' : 'Pay'),
        ),
      ],
    );
  }
}

// ── the payslip ─────────────────────────────────────────────────────────────

class _PayslipDialog extends StatelessWidget {
  const _PayslipDialog({
    required this.service,
    required this.lineId,
    required this.isAr,
  });
  final PayrollService service;
  final int lineId;
  final bool isAr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(isAr ? 'قسيمة الراتب' : 'Payslip'),
      content: SizedBox(
        width: 420,
        child: FutureBuilder<Map<String, dynamic>>(
          future: service.payslip(lineId),
          builder: (context, snap) {
            if (snap.hasError) return Text(snap.error.toString());
            if (!snap.hasData) return const LinearProgressIndicator();
            final slip = snap.data!;
            final entry = slip['entry'] as Map<String, dynamic>;
            final employee = slip['employee'] as Map<String, dynamic>;
            final breakdown = slip['breakdown'] as Map<String, dynamic>?;
            final earned =
                breakdown?['earned'] as Map<String, dynamic>? ?? const {};
            Widget row(String label, Object? value, {bool strong = false}) =>
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                  child: Row(
                    children: [
                      Expanded(child: Text(label)),
                      Text(
                        formatAmount((value as num?) ?? 0),
                        textDirection: TextDirection.ltr,
                        style:
                            (strong
                                    ? theme.textTheme.titleMedium
                                    : theme.textTheme.bodyMedium)
                                ?.copyWith(
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                      ),
                    ],
                  ),
                );
            List<Map<String, dynamic>> lines(String key) =>
                ((breakdown?[key] as List?) ?? const [])
                    .cast<Map<String, dynamic>>();
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    employee['name']?.toString() ?? '',
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(
                    '${isAr ? 'شهر' : 'Month'} ${ltrIsolate('${entry['month']}/${entry['year']}')}',
                  ),
                  if (breakdown != null && breakdown['whole_month'] == false)
                    Text(
                      isAr
                          ? '${ltrIsolate('${breakdown['days']}')} يومًا من ${ltrIsolate('${breakdown['divisor']}')}'
                          : '${breakdown['days']} of ${breakdown['divisor']} days',
                    ),
                  const Divider(),
                  row(
                    isAr ? 'الأساسي' : 'Basic',
                    earned['basic'] ?? entry['basic_salary'],
                  ),
                  if (earned.isNotEmpty) ...[
                    row(isAr ? 'السكن' : 'Housing', earned['housing']),
                    row(isAr ? 'النقل' : 'Transport', earned['transport']),
                    if (((earned['other_allowances'] as num?) ?? 0) > 0)
                      row(
                        isAr ? 'بدلات أخرى' : 'Other',
                        earned['other_allowances'],
                      ),
                  ] else
                    row(isAr ? 'البدلات' : 'Allowances', entry['allowances']),
                  for (final a in lines('additions'))
                    row('+ ${a['label']}', a['amount']),
                  for (final b in lines('bonuses'))
                    row(
                      '+ ${b['label']} (${isAr ? 'مكافأة' : 'bonus'})',
                      b['amount'],
                    ),
                  for (final d in lines('deductions'))
                    row('− ${d['label']}', d['amount']),
                  const Divider(),
                  row(
                    isAr ? 'الصافي' : 'Net',
                    entry['net_salary'],
                    strong: true,
                  ),
                  if (entry['voucher'] != null)
                    Text(
                      '${isAr ? 'سند الصرف' : 'Voucher'} ${ltrIsolate('${(entry['voucher'] as Map)['voucher_number']}')}',
                    ),
                  if (employee['payment_method'] == 'bank' &&
                      employee['iban'] != null)
                    Text(ltrIsolate('${employee['iban']}')),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        // HR-UX ر3: the payslip on paper
        TextButton.icon(
          key: const ValueKey('payslip-print'),
          onPressed: () async {
            try {
              final slip = await service.payslip(lineId);
              await Printing.layoutPdf(
                name: 'payslip-$lineId',
                onLayout: (_) => buildPayslipPdf(slip),
              );
            } catch (e) {
              if (context.mounted) AppFeedback.error(context, e.toString());
            }
          },
          icon: const Icon(Icons.print_outlined),
          label: Text(isAr ? 'طباعة' : 'Print'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isAr ? 'إغلاق' : 'Close'),
        ),
      ],
    );
  }
}

// ── an employee's payroll data: structures and how he is paid ───────────────

class EmployeePayrollDialog extends StatefulWidget {
  const EmployeePayrollDialog({
    super.key,
    required this.service,
    required this.employeeId,
    required this.name,
    required this.isAr,
  });
  final PayrollService service;
  final int employeeId;
  final String name;
  final bool isAr;

  @override
  State<EmployeePayrollDialog> createState() => _EmployeePayrollDialogState();
}

class _EmployeePayrollDialogState extends State<EmployeePayrollDialog> {
  List<SalaryStructureModel>? _structures;
  final _from = TextEditingController();
  final _gross = TextEditingController();
  final _basic = TextEditingController();
  final _housing = TextEditingController();
  final _transport = TextEditingController();
  final _other = TextEditingController(text: '0');
  final _iban = TextEditingController();
  final _bankName = TextEditingController();
  final _wage = TextEditingController();
  final _advance = TextEditingController();
  final _installment = TextEditingController();
  final _consentNote = TextEditingController();
  String? _method;
  int? _schemeId;
  bool _consent = false;
  List<Map<String, dynamic>> _schemes = const [];
  (List<AdvancePlanModel>, double, double)? _advances;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    _from.text = '${today.year}-${'${today.month}'.padLeft(2, '0')}-01';
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _from,
      _gross,
      _basic,
      _housing,
      _transport,
      _other,
      _iban,
      _bankName,
      _wage,
      _advance,
      _installment,
      _consentNote,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await widget.service.structures(widget.employeeId);
      final payment = await widget.service.payment(widget.employeeId);
      final schemes = await widget.service.schemes();
      final advances = await widget.service.advancePlans(widget.employeeId);
      if (mounted) {
        setState(() {
          _structures = rows;
          _schemes = schemes;
          _advances = advances;
          _schemeId ??= payment['contribution_scheme_id'] as int?;
          final wage = payment['contribution_wage'] as num?;
          if (_wage.text.isEmpty && wage != null) {
            _wage.text = _plain(wage.toDouble());
          }
          _method ??= payment['payment_method'] as String?;
          if (_iban.text.isEmpty) _iban.text = '${payment['iban'] ?? ''}';
          if (_bankName.text.isEmpty) {
            _bankName.text = '${payment['bank_name'] ?? ''}';
          }
        });
      }
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    }
  }

  double _read(TextEditingController c) =>
      double.tryParse(normalizeNumber(c.text)) ?? 0;

  String _plain(double v) => formatAmount(v).replaceAll(',', '');

  Future<void> _suggest() async {
    try {
      final split = await widget.service.suggest(_read(_gross));
      setState(() {
        _basic.text = _plain(split['basic'] ?? 0);
        _housing.text = _plain(split['housing'] ?? 0);
        _transport.text = _plain(split['transport'] ?? 0);
      });
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.service.addStructure(
        widget.employeeId,
        effectiveFrom: _from.text.trim(),
        basic: _read(_basic),
        housing: _read(_housing),
        transport: _read(_transport),
        otherAllowances: _read(_other),
      );
      await _load();
      if (mounted) {
        AppFeedback.success(
          context,
          widget.isAr ? 'حُفظ هيكل الراتب' : 'Structure saved',
        );
      }
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _savePayment() async {
    setState(() => _busy = true);
    try {
      await widget.service.savePayment(
        widget.employeeId,
        method: _method,
        iban: _iban.text.trim().isEmpty ? null : _iban.text.trim(),
        bankName: _bankName.text.trim().isEmpty ? null : _bankName.text.trim(),
        schemeId: _schemeId,
        contributionWage: _wage.text.trim().isEmpty ? null : _read(_wage),
      );
      if (mounted) {
        AppFeedback.success(
          context,
          widget.isAr ? 'حُفظت طريقة الصرف' : 'Payment saved',
        );
      }
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addAdvance() async {
    setState(() => _busy = true);
    try {
      final today = DateTime.now();
      await widget.service.addAdvancePlan(
        widget.employeeId,
        amount: _read(_advance),
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
      _advance.clear();
      _installment.clear();
      await _load();
      if (mounted) {
        AppFeedback.success(
          context,
          widget.isAr ? 'جُدولت السلفة' : 'Advance planned',
        );
      }
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
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
    final isAr = widget.isAr;
    final theme = Theme.of(context);
    final rows = _structures;
    return AlertDialog(
      title: Text('${isAr ? 'بيانات راتب' : 'Payroll data:'} ${widget.name}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isAr ? 'هياكل الراتب' : 'Salary structures',
                style: theme.textTheme.titleSmall,
              ),
              if (rows == null)
                const LinearProgressIndicator()
              else if (rows.isEmpty)
                Text(isAr ? 'لا هيكل بعد' : 'None yet')
              else
                for (final s in rows)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${isAr ? 'من' : 'From'} ${ltrIsolate(s.effectiveFrom)} — ${ltrIsolate(formatAmount(s.gross))}',
                    ),
                    subtitle: Text(
                      '${isAr ? 'أساسي' : 'Basic'} ${ltrIsolate(formatAmount(s.basic))} · '
                      '${isAr ? 'سكن' : 'Housing'} ${ltrIsolate(formatAmount(s.housing))} · '
                      '${isAr ? 'نقل' : 'Transport'} ${ltrIsolate(formatAmount(s.transport))}',
                    ),
                    trailing: IconButton(
                      tooltip: isAr ? 'حذف' : 'Delete',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        try {
                          await widget.service.deleteStructure(s.id);
                          await _load();
                        } catch (e) {
                          if (context.mounted) {
                            AppFeedback.error(context, e.toString());
                          }
                        }
                      },
                    ),
                  ),
              const Divider(),
              Text(
                isAr ? 'هيكل جديد' : 'New structure',
                style: theme.textTheme.titleSmall,
              ),
              DateField(
                key: const ValueKey('structure-from'),
                controller: _from,
                label: isAr ? 'يبدأ من' : 'From',
              ),
              Row(
                children: [
                  Expanded(
                    child: _field(
                      _gross,
                      isAr ? 'إجمالي الراتب' : 'Gross',
                      'structure-gross',
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('structure-suggest'),
                    onPressed: _suggest,
                    child: Text(isAr ? 'قسّم بالنسب' : 'Split'),
                  ),
                ],
              ),
              _field(_basic, isAr ? 'الأساسي' : 'Basic', 'structure-basic'),
              _field(_housing, isAr ? 'السكن' : 'Housing', 'structure-housing'),
              _field(
                _transport,
                isAr ? 'النقل' : 'Transport',
                'structure-transport',
              ),
              _field(_other, isAr ? 'بدلات أخرى' : 'Other', 'structure-other'),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton(
                  key: const ValueKey('structure-save'),
                  onPressed: _busy ? null : _save,
                  child: Text(isAr ? 'احفظ الهيكل' : 'Save structure'),
                ),
              ),
              const Divider(),
              Text(
                isAr ? 'طريقة الصرف' : 'Paid by',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: AppSpace.sm),
              SegmentedButton<String>(
                key: const ValueKey('employee-payment-method'),
                emptySelectionAllowed: true,
                segments: [
                  ButtonSegment(
                    value: 'bank',
                    label: Text(isAr ? 'تحويل بنكي' : 'Bank'),
                  ),
                  ButtonSegment(
                    value: 'cash',
                    label: Text(isAr ? 'نقد' : 'Cash'),
                  ),
                ],
                selected: {?_method},
                onSelectionChanged: (s) =>
                    setState(() => _method = s.isEmpty ? null : s.first),
              ),
              if (_method == 'bank') ...[
                TextField(
                  key: const ValueKey('employee-iban'),
                  controller: _iban,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: isAr ? 'الآيبان (SA…)' : 'IBAN (SA…)',
                  ),
                ),
                TextField(
                  controller: _bankName,
                  decoration: InputDecoration(
                    labelText: isAr ? 'البنك' : 'Bank',
                  ),
                ),
              ],
              const SizedBox(height: AppSpace.sm),
              DropdownButtonFormField<int?>(
                key: const ValueKey('employee-scheme'),
                initialValue: _schemeId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: isAr
                      ? 'خطة الاشتراك (التأمينات)'
                      : 'Contribution scheme',
                ),
                items: [
                  DropdownMenuItem<int?>(
                    value: null,
                    child: Text(isAr ? 'بلا اشتراك' : 'None'),
                  ),
                  for (final scheme in _schemes)
                    DropdownMenuItem<int?>(
                      value: scheme['id'] as int,
                      child: Text('${scheme['name']}'),
                    ),
                ],
                onChanged: (v) => setState(() => _schemeId = v),
              ),
              if (_schemeId != null)
                _field(
                  _wage,
                  isAr
                      ? 'الأجر المسجّل في التأمينات (فارغ: الأساسي والسكن)'
                      : 'Registered wage (empty: basic + housing)',
                  'employee-contribution-wage',
                ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  key: const ValueKey('employee-payment-save'),
                  onPressed: _busy ? null : _savePayment,
                  child: Text(isAr ? 'احفظ الصرف والاشتراك' : 'Save'),
                ),
              ),
              const Divider(),
              Text(
                isAr ? 'السلف' : 'Advances',
                style: theme.textTheme.titleSmall,
              ),
              if (_advances case final advances?) ...[
                Text(
                  isAr
                      ? 'رصيد حساب السلف ${ltrIsolate(formatAmount(advances.$2))} — غير مجدول ${ltrIsolate(formatAmount(advances.$3))}'
                      : 'Advance account ${formatAmount(advances.$2)} — unplanned ${formatAmount(advances.$3)}',
                ),
                for (final plan in advances.$1)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${ltrIsolate(formatAmount(plan.amount))} — '
                      '${isAr ? 'القسط' : 'installment'} ${ltrIsolate(formatAmount(plan.installment))}',
                    ),
                    subtitle: Text(
                      '${isAr ? 'الباقي' : 'Left'} ${ltrIsolate(formatAmount(plan.remaining))} · '
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
                            onPressed: () async {
                              try {
                                await widget.service.cancelAdvancePlan(plan.id);
                                await _load();
                              } catch (e) {
                                if (context.mounted) {
                                  AppFeedback.error(context, e.toString());
                                }
                              }
                            },
                          )
                        : null,
                  ),
              ],
              Row(
                children: [
                  Expanded(
                    child: _field(
                      _advance,
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
                child: TextButton(
                  key: const ValueKey('advance-save'),
                  onPressed: _busy ? null : _addAdvance,
                  child: Text(isAr ? 'جدول السلفة' : 'Plan the advance'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isAr ? 'إغلاق' : 'Close'),
        ),
      ],
    );
  }
}
