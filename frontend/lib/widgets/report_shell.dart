import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../models/report_contract.dart';
import '../pdf/report_pdf_builder.dart';
import '../providers/settings_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils/bidi.dart';
import '../utils/report_export.dart';
import 'app_feedback.dart';
import 'app_period_picker.dart';
import 'app_state_views.dart';

/// One screen for any report (REPORTS ت1, ADR-083): the period (the ready ones
/// a tap away, UI-4) and the report's own switches above; its four states --
/// loading as the page's shape, an error to retry, nothing in the period (and
/// what to do), the report; the checks it makes of itself, its table with the
/// totals, each row opening what it sums; where its figures come from and
/// when they were read; Excel, PDF and print, as the screen shows it. What it
/// shows is the server's contract (models/report_contract.dart): nothing is
/// reckoned here.

/// A switch of a report's own (the trial balance's karat by karat).
@immutable
class ReportToggle {
  const ReportToggle(this.key, this.label);

  final String key;
  final String label;
}

/// One choice of a report's own (the sales analysis's «حسب»): its options,
/// the first chosen at the start.
@immutable
class ReportChoice {
  const ReportChoice(this.key, this.label, this.options);

  final String key;
  final String label;
  final List<(String, String)> options;
}

typedef ReportLoader =
    Future<ReportData> Function(
      DateTimeRange? range,
      Set<String> on,
      Map<String, String> chosen,
    );
typedef ReportSaver =
    Future<void> Function(String fileName, List<int> bytes, String mimeType);

class ReportShell extends StatefulWidget {
  const ReportShell({
    super.key,
    required this.title,
    required this.load,
    this.subtitle,
    this.toggles = const [],
    this.choices = const [],
    this.initialRange,
    this.singleDay = false,
    this.onDrill,
    this.emptyTitle = 'لا شيء في هذه الفترة',
    this.now,
    this.saver,
    this.printer,
  });

  final String title;
  final String? subtitle;
  final ReportLoader load;
  final List<ReportToggle> toggles;
  final List<ReportChoice> choices;

  /// The period it opens on; null: all periods.
  final DateTimeRange? initialRange;

  /// A report of one day (the balance sheet): a day, not a period -- the
  /// loader's range is that day (today at the start).
  final bool singleDay;

  /// What a row's figure opens -- its account, its document; the report it
  /// is read from (its period, its day) beside.
  final void Function(
    BuildContext context,
    ReportDrill drill,
    ReportRow row,
    ReportData report,
  )?
  onDrill;
  final String emptyTitle;

  /// Today, for tests; the device's clock otherwise.
  final DateTime Function()? now;

  /// Where a file goes; tests pass a fake (the platform's otherwise).
  final ReportSaver? saver;

  /// The print dialog; tests pass a fake.
  final Future<void> Function(Future<List<int>> Function() pdf)? printer;

  @override
  State<ReportShell> createState() => _ReportShellState();
}

class _ReportShellState extends State<ReportShell> {
  late DateTimeRange? _range =
      widget.initialRange ??
      (widget.singleDay ? _dayRange((widget.now ?? DateTime.now)()) : null);

  static DateTimeRange _dayRange(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    return DateTimeRange(start: day, end: day);
  }

  Future<void> _pickDay() async {
    final today = (widget.now ?? DateTime.now)();
    final picked = await showDatePicker(
      context: context,
      initialDate: _range?.end ?? today,
      firstDate: DateTime(today.year - 5),
      lastDate: DateTime(today.year + 1, 12, 31),
    );
    if (picked == null) return;
    setState(() => _range = _dayRange(picked));
    _load();
  }

  final Set<String> _on = {};
  late final Map<String, String> _chosen = {
    for (final c in widget.choices) c.key: c.options.first.$1,
  };
  ReportData? _report;
  Object? _error;
  bool _loading = true;
  int _ask = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ask = ++_ask;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final report = await widget.load(_range, Set.of(_on), Map.of(_chosen));
      if (!mounted || ask != _ask) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || ask != _ask) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  String get _period => periodLabel(_range);

  String _companyName() {
    try {
      return context.read<SettingsProvider>().companyName;
    } catch (_) {
      return '';
    }
  }

  Future<List<int>> _pdf(ReportData report) => buildReportPdf(
    report,
    companyName: _companyName(),
    period: _range == null
        ? 'كل الفترات'
        : widget.singleDay
        ? 'في ${DateFormat('yyyy-MM-dd').format(_range!.end)}'
        : _period,
  );

  Future<void> _export(String kind) async {
    final report = _report;
    if (report == null) return;
    final save = widget.saver ?? saveReportFile;
    try {
      switch (kind) {
        case 'excel':
          await save(
            reportFileName(report, 'xlsx'),
            reportXlsx(report),
            xlsxMime,
          );
        case 'pdf':
          await save(
            reportFileName(report, 'pdf'),
            await _pdf(report),
            pdfMime,
          );
        case 'print':
          final print =
              widget.printer ??
              (pdf) => Printing.layoutPdf(
                name: reportFileName(report, 'pdf'),
                onLayout: (_) async => Uint8List.fromList(await pdf()),
              );
          await print(() => _pdf(report));
      }
    } catch (e) {
      if (mounted) AppFeedback.error(context, AppFeedback.messageOf(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final ready = !_loading && _error == null && report != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            key: const ValueKey('report-refresh'),
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
          IconButton(
            key: const ValueKey('report-excel'),
            tooltip: 'تصدير Excel',
            icon: const Icon(Icons.table_view_outlined),
            onPressed: ready ? () => _export('excel') : null,
          ),
          IconButton(
            key: const ValueKey('report-pdf'),
            tooltip: 'PDF',
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: ready ? () => _export('pdf') : null,
          ),
          IconButton(
            key: const ValueKey('report-print'),
            tooltip: 'طباعة',
            icon: const Icon(Icons.print_outlined),
            onPressed: ready ? () => _export('print') : null,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.md,
              AppSpace.lg,
              AppSpace.sm,
            ),
            child: Wrap(
              spacing: AppSpace.md,
              runSpacing: AppSpace.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.subtitle != null)
                  Text(
                    widget.subtitle!,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                if (widget.singleDay)
                  OutlinedButton.icon(
                    key: const ValueKey('report-day'),
                    onPressed: _pickDay,
                    icon: const Icon(Icons.event, size: 18),
                    label: Text(
                      'في ${ltrIsolate(DateFormat('yyyy-MM-dd').format(_range!.end))}',
                    ),
                  )
                else
                  AppPeriodPicker(
                    key: const ValueKey('report-period'),
                    range: _range,
                    now: widget.now,
                    onChanged: (range) {
                      setState(() => _range = range);
                      _load();
                    },
                  ),
                for (final c in widget.choices)
                  // many options scroll sideways on a narrow screen, never overflow
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<String>(
                      key: ValueKey('report-choice-${c.key}'),
                      showSelectedIcon: false,
                      segments: [
                        for (final (value, label) in c.options)
                          ButtonSegment(value: value, label: Text(label)),
                      ],
                      selected: {_chosen[c.key]!},
                      onSelectionChanged: (s) {
                        setState(() => _chosen[c.key] = s.first);
                        _load();
                      },
                    ),
                  ),
                for (final t in widget.toggles)
                  FilterChip(
                    key: ValueKey('report-toggle-${t.key}'),
                    label: Text(t.label),
                    selected: _on.contains(t.key),
                    onSelected: (on) {
                      setState(() => on ? _on.add(t.key) : _on.remove(t.key));
                      _load();
                    },
                  ),
              ],
            ),
          ),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading && _report == null) return const AppLoadingView();
    if (_error != null) {
      return AppErrorView(
        title: 'تعذّر تحميل ${widget.title}',
        error: _error,
        onRetry: _load,
      );
    }
    final report = _report!;
    if (report.rows.isEmpty) {
      return AppEmptyView(
        title: widget.emptyTitle,
        hint: _range == null ? null : 'الفترة: $_period',
        icon: Icons.event_busy_outlined,
        actionLabel: _range == null ? null : 'كل الفترات',
        actionIcon: _range == null ? null : Icons.all_inclusive,
        onAction: _range == null
            ? null
            : () {
                setState(() => _range = null);
                _load();
              },
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          0,
          AppSpace.lg,
          AppSpace.xl,
        ),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (report.checks.isNotEmpty) ...[
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [for (final c in report.checks) _check(context, c)],
            ),
            const SizedBox(height: AppSpace.md),
          ],
          ReportTable(
            report: report,
            onDrill: widget.onDrill == null
                ? null
                : (drill, row) => widget.onDrill!(context, drill, row, report),
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            [
              report.basisLabel,
              if (report.readAt != null)
                'قُرئ ${ltrIsolate(DateFormat('yyyy-MM-dd HH:mm').format(report.readAt!))}',
            ].join(' · '),
            key: const ValueKey('report-source'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _check(BuildContext context, ReportCheck check) {
    final tones = AppSemanticColors.of(context);
    final tone = check.ok ? tones.ready : tones.blocked;
    return Container(
      key: ValueKey('report-check-${check.key}'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.sm,
      ),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            check.ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 18,
            color: tone.onContainer,
          ),
          const SizedBox(width: AppSpace.xs),
          Text(
            check.label,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: tone.onContainer),
          ),
        ],
      ),
    );
  }
}

/// A report's table: its columns' titles, its rows, its totals. A figure and
/// its title keep to the column's right edge, in tabular figures, so the
/// decimals line up (the payroll's lesson, 2 Nov 2026); a signed column says
/// a negative in the error tone; a row with something behind it opens it.
class ReportTable extends StatelessWidget {
  const ReportTable({super.key, required this.report, this.onDrill});

  final ReportData report;
  final void Function(ReportDrill drill, ReportRow row)? onDrill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final tabular = theme.textTheme.bodyMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget cell(
      ReportColumn c,
      Object? value, {
      bool strong = false,
      bool note = false,
    }) {
      final text = reportCell(c, value);
      final negative = c.signed && value is num && value < 0 && text.isNotEmpty;
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.sm,
        ),
        child: Align(
          alignment: c.isFigure
              ? Alignment.centerRight
              : AlignmentDirectional.centerStart,
          child: Text(
            text,
            textDirection: c.isFigure ? TextDirection.ltr : null,
            style: (c.isFigure ? tabular : theme.textTheme.bodyMedium)
                ?.copyWith(
                  fontWeight: strong ? FontWeight.w700 : null,
                  fontStyle: note ? FontStyle.italic : null,
                  color: negative
                      ? theme.colorScheme.error
                      : note
                      ? theme.colorScheme.onSurfaceVariant
                      : null,
                ),
          ),
        ),
      );
    }

    final columns = report.columns;
    // the last text column -- the description -- takes the room
    final wide = columns.lastIndexWhere((c) => !c.isFigure);
    // The table fills its card; on a narrow screen it keeps its columns
    // and slides sideways.
    return Card(
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // A text column takes the room the figures leave and wraps (a long
          // note pushed the grams off the screen); a figure keeps its width.
          child: SizedBox(
            width: box.maxWidth.isFinite && box.maxWidth > 720
                ? box.maxWidth
                : 720,
            child: Table(
              columnWidths: {
                for (var i = 0; i < columns.length; i++)
                  i: i == wide
                      ? const FlexColumnWidth()
                      : const IntrinsicColumnWidth(),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                  ),
                  children: [
                    for (final c in columns)
                      Padding(
                        padding: const EdgeInsets.all(AppSpace.md),
                        child: Align(
                          alignment: c.isFigure
                              ? Alignment.centerRight
                              : AlignmentDirectional.centerStart,
                          child: Text(
                            c.label,
                            key: ValueKey('report-head-${c.key}'),
                            style: theme.textTheme.labelMedium,
                          ),
                        ),
                      ),
                  ],
                ),
                // a statement's lines: a section's heading, its total, a
                // line said apart (a finding)
                for (final (i, row) in report.rows.indexed)
                  TableRow(
                    key: ValueKey('report-row-$i'),
                    decoration: BoxDecoration(
                      color: switch (row.style) {
                        ReportRowStyle.heading =>
                          theme.colorScheme.surfaceContainerLow,
                        ReportRowStyle.finding => tones.warning.container,
                        _ => null,
                      },
                      border: Border(
                        top: BorderSide(
                          color: row.style == ReportRowStyle.subtotal
                              ? theme.colorScheme.outline
                              : theme.colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                    children: [
                      for (final c in columns)
                        row.drill != null && onDrill != null
                            ? TableRowInkWell(
                                onTap: () => onDrill!(row.drill!, row),
                                child: cell(c, row[c.key]),
                              )
                            : cell(
                                c,
                                row[c.key],
                                strong:
                                    row.style == ReportRowStyle.heading ||
                                    row.style == ReportRowStyle.subtotal,
                                note: row.style == ReportRowStyle.note,
                              ),
                    ],
                  ),
                if (report.totals.isNotEmpty)
                  TableRow(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      border: Border(
                        top: BorderSide(color: theme.colorScheme.outline),
                      ),
                    ),
                    children: [
                      for (final (i, c) in columns.indexed)
                        c.isFigure
                            ? cell(c, report.totals[c.key], strong: true)
                            : i == 0
                            ? KeyedSubtree(
                                key: const ValueKey('report-totals'),
                                child: cell(c, 'المجموع', strong: true),
                              )
                            : cell(c, '', strong: true),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
