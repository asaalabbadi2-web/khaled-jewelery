import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../models/opening_models.dart';
import '../providers/auth_provider.dart';
import '../services/opening_service.dart';
import '../theme/app_theme.dart';
import '../utils/currency_utils.dart' show formatAmount, formatGrams;
import '../utils/two_places.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/confirm_financial_action.dart';

/// TR-2 (ADR-044): a new year's opening figures beside the closing books.
///
/// The owner, 6 Nov 2026: a row for each asset or liability holding a balance,
/// by its group; each figure empty until entered («فارغة حتى تُؤكَّد») with its
/// source; a party's cash opens as gold at the closing price of the count day
/// or stays cash waiting to be closed («الاثنين معا»). The manager enters, the
/// owner approves («المدير يُدخل، والمالك يعتمد»), once every row has its
/// figure; then nothing changes. What equity takes is the server's. A
/// supplier's cash stays cash (7 Nov): the server says whose cash asks.
///
/// TR-3: approved, it says what the approval froze -- the count day's closing
/// price, the riyals carried waiting into the year at it, and each customer
/// opening as gold in grams.
class OpeningScreen extends StatefulWidget {
  const OpeningScreen({super.key, required this.year});
  final int year;

  @override
  State<OpeningScreen> createState() => _OpeningScreenState();
}

class _OpeningScreenState extends State<OpeningScreen> {
  final _svc = OpeningService(ApiService());
  Opening? _opening;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final opening = await _svc.load(widget.year);
      if (mounted) setState(() => _opening = opening);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _edit(OpeningRow row) async {
    final opening = _opening!;
    if (opening.approved) return;
    final updated = await showModalBottomSheet<Opening>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FigureSheet(
        year: widget.year,
        row: row,
        sources: opening.sources,
        treatments: opening.treatments,
        service: _svc,
      ),
    );
    if (updated != null && mounted) {
      setState(() => _opening = updated);
      AppFeedback.success(context, 'حُفظ رقم ${row.name}');
    }
  }

  Future<void> _approve() async {
    final opening = _opening!;
    final ok = await confirmFinancialAction(
      context,
      title: 'اعتماد افتتاح ${widget.year}',
      effect: 'تُقفل الأرقام كلها، ولا يُغيَّر رقم بعد الاعتماد.',
      confirmLabel: 'اعتماد الافتتاح',
      destructive: false,
      facts: [
        ('الحسابات', '${opening.total}'),
        ('إلى حقوق الملكية', '${formatAmount(opening.differenceCash)} ريال'),
        ('وزنًا', '${formatGrams(opening.differenceGrams)} جم'),
      ],
    );
    if (ok == null || !mounted) return;
    try {
      final approved = await _svc.approve(widget.year);
      if (!mounted) return;
      setState(() => _opening = approved);
      AppFeedback.success(context, 'اعتُمد افتتاح ${widget.year}');
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final opening = _opening;
    final canApprove = context.watch<AuthProvider>().hasPermission('opening.approve');
    return Scaffold(
      appBar: AppBar(
        title: Text('افتتاح ${widget.year}'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: opening == null
          ? (_error == null
                ? const AppLoadingView(summaryBlocks: 2)
                : AppErrorView(title: 'تعذّر تحميل الافتتاح', error: _error, onRetry: _load))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(AppSpace.lg),
                children: [
                  _Header(opening: opening, canApprove: canApprove, onApprove: _approve),
                  const SizedBox(height: AppSpace.lg),
                  for (final section in _sections(opening.rows).entries)
                    _Section(
                      title: section.key,
                      rows: section.value,
                      sources: opening.sources,
                      locked: opening.approved,
                      onTap: _edit,
                    ),
                ],
              ),
            ),
    );
  }

  static Map<String, List<OpeningRow>> _sections(List<OpeningRow> rows) {
    final out = <String, List<OpeningRow>>{};
    for (final r in rows) {
      out.putIfAbsent(r.section, () => []).add(r);
    }
    return out;
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.opening, required this.canApprove, required this.onApprove});
  final Opening opening;
  final bool canApprove;
  final VoidCallback onApprove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final complete = opening.entered == opening.total;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('مُدخَل ${opening.entered} من ${opening.total}', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpace.sm),
            LinearProgressIndicator(
              value: opening.total == 0 ? 1 : opening.entered / opening.total,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            const SizedBox(height: AppSpace.md),
            Text('إلى حقوق الملكية', style: muted),
            Text(
              '${formatAmount(opening.differenceCash)} ريال · '
              '${formatGrams(opening.differenceGrams)} جم بالعيار الرئيسي',
              style: theme.textTheme.titleSmall,
              textDirection: TextDirection.rtl,
            ),
            Text('الأرقام الفعلية ناقص الدفاتر، لما أُدخل منها', style: muted),
            const SizedBox(height: AppSpace.md),
            if (opening.approved)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpace.md),
                decoration: BoxDecoration(
                  color: tones.ready.container,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'معتمد: ${opening.approvedBy}'
                      '${opening.approvedAt == null ? '' : ' · ${_day(opening.approvedAt!)}'}'
                      ' — لا يُغيَّر رقم فيه',
                      style: TextStyle(color: tones.ready.onContainer),
                    ),
                    if (opening.closingPrice != null) ...[
                      const SizedBox(height: AppSpace.xs),
                      Text(
                        'سعر التسكير يوم الجرد ${opening.countDay ?? ''}: '
                        '${formatAmount(opening.closingPrice!)} ريال للجرام',
                        style: TextStyle(color: tones.ready.onContainer),
                      ),
                      Text(
                        'تنتقل إلى ${opening.year} منتظرةً بسعره: '
                        '${formatAmount(opening.carriedCash ?? 0)} ريال',
                        style: TextStyle(color: tones.ready.onContainer),
                      ),
                      Text(
                        opening.reconciliationEntry == null
                            ? 'لا فروق: أُقفلت ${opening.year - 1} على الأرقام كما هي'
                            : 'فروق المطابقة قُيّدت في ${opening.year - 1} بالقيد ${opening.reconciliationEntry}',
                        style: TextStyle(color: tones.ready.onContainer),
                      ),
                      if (opening.marketPrice != null)
                        Text(
                          'قُيّم المخزون بسعر السوق يوم الجرد ${formatAmount(opening.marketPrice!)} ريال للجرام'
                          '${opening.revaluationEntry == null ? '' : ' بالقيد ${opening.revaluationEntry}'}',
                          style: TextStyle(color: tones.ready.onContainer),
                        ),
                      if ((opening.toGoldCash ?? 0).abs() >= 0.005)
                        Text(
                          'منها ذهبًا على العملاء: ${formatAmount(opening.toGoldCash!)} ريال',
                          style: TextStyle(color: tones.ready.onContainer),
                        ),
                    ],
                  ],
                ),
              )
            else if (canApprove)
              Wrap(
                spacing: AppSpace.md,
                runSpacing: AppSpace.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton(
                    onPressed: complete ? onApprove : null,
                    child: const Text('اعتماد الافتتاح'),
                  ),
                  if (!complete)
                    Text('يُعتمد حين يُؤكَّد كل رقم', style: muted),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// "cash · 18 · 21 ..." -- only the figures that are not zero.
String _figuresText(Map<String, double> f) {
  final parts = <String>[
    if ((f['cash'] ?? 0).abs() >= 0.005) '${formatAmount(f['cash']!)} ريال',
    for (final k in openingKarats)
      if ((f[k] ?? 0).abs() >= 0.0005) '${formatGrams(f[k]!)} جم $k',
  ];
  return parts.isEmpty ? 'صفر' : parts.join(' · ');
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.rows,
    required this.sources,
    required this.locked,
    required this.onTap,
  });
  final String title;
  final List<OpeningRow> rows;
  final Map<String, String> sources;
  final bool locked;
  final ValueChanged<OpeningRow> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entered = rows.where((r) => r.entered).length;
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: true,
        title: Text(title, style: theme.textTheme.titleSmall),
        subtitle: Text('$entered من ${rows.length}'),
        children: [
          for (final r in rows) _RowTile(row: r, sources: sources, locked: locked, onTap: () => onTap(r)),
        ],
      ),
    );
  }
}

class _RowTile extends StatelessWidget {
  const _RowTile({required this.row, required this.sources, required this.locked, required this.onTap});
  final OpeningRow row;
  final Map<String, String> sources;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final tone = row.entered ? tones.ready : tones.warning;
    return InkWell(
      onTap: locked ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.name, style: theme.textTheme.bodyLarge),
                  Text(row.number, style: muted, textDirection: TextDirection.ltr),
                  const SizedBox(height: AppSpace.xs),
                  Text('الدفاتر: ${_figuresText(row.books)}', style: muted),
                  if (row.entered)
                    Text(
                      'المصدر: ${sources[row.source] ?? row.source ?? ''}'
                      '${row.enteredBy == null ? '' : ' · ${row.enteredBy}'}',
                      style: muted,
                    ),
                  if (row.goldGrams != null)
                    Text('ذهبًا عليه: ${formatGrams(row.goldGrams!)} جم بسعر الجرد', style: muted),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
                decoration: BoxDecoration(
                  color: tone.container,
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                ),
                child: Text(
                  row.entered ? _figuresText(row.actual!) : 'لم يُدخل',
                  style: theme.textTheme.bodySmall?.copyWith(color: tone.onContainer),
                  textAlign: TextAlign.end,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One account's figure: cash and the four karats at two places, its source,
/// and -- a party with cash -- whether it opens as gold or waits.
class _FigureSheet extends StatefulWidget {
  const _FigureSheet({
    required this.year,
    required this.row,
    required this.sources,
    required this.treatments,
    required this.service,
  });
  final int year;
  final OpeningRow row;
  final Map<String, String> sources;
  final Map<String, String> treatments;
  final OpeningService service;

  @override
  State<_FigureSheet> createState() => _FigureSheetState();
}

class _FigureSheetState extends State<_FigureSheet> {
  late final Map<String, TextEditingController> _fields;
  late final TextEditingController _note;
  String? _source;
  String? _treatment;
  String? _refused;
  bool _saving = false;

  static const _keys = ['cash', ...openingKarats];

  /// A field holds a figure at two places, and nothing for zero.
  static bool _blank(double? v) => v == null || v.abs() < 0.005;

  @override
  void initState() {
    super.initState();
    final actual = widget.row.actual;
    _fields = {
      for (final k in _keys)
        k: TextEditingController(text: _blank(actual?[k]) ? '' : actual![k]!.toStringAsFixed(2)),
    };
    _fields['cash']!.addListener(() => setState(() {}));
    _note = TextEditingController(text: widget.row.note ?? '');
    _source = widget.row.source;
    _treatment = widget.row.treatment;
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    _note.dispose();
    super.dispose();
  }

  double _value(String k) => double.tryParse(_fields[k]!.text) ?? 0.0;

  /// A party whose books or figure hold cash is asked how it opens.
  bool get _asksTreatment =>
      widget.row.party && ((widget.row.books['cash'] ?? 0).abs() >= 0.005 || _value('cash').abs() >= 0.005);

  void _matchBooks() {
    for (final k in _keys) {
      final v = widget.row.books[k];
      _fields[k]!.text = _blank(v) ? '' : v!.toStringAsFixed(2);
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _refused = null;
    });
    try {
      final updated = await widget.service.enter(
        widget.year,
        widget.row.accountId,
        cash: _value('cash'),
        karats: {for (final k in openingKarats) k: _value(k)},
        source: _source ?? '',
        treatment: _asksTreatment ? _treatment : null,
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(updated);
    } catch (e) {
      if (mounted) setState(() => _refused = AppFeedback.messageOf(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final row = widget.row;
    Widget field(String k, String label) => TextField(
      controller: _fields[k],
      decoration: InputDecoration(
        labelText: label,
        helperText: 'الدفاتر: ${k == 'cash' ? formatAmount(row.books[k] ?? 0) : formatGrams(row.books[k] ?? 0)}',
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
      inputFormatters: [twoPlaces(signed: true)],
      textDirection: TextDirection.ltr,
    );
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpace.lg,
        right: AppSpace.lg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpace.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(row.name, style: theme.textTheme.titleMedium),
            Text('${row.number} · ${row.section}', style: muted),
            const SizedBox(height: AppSpace.md),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: _matchBooks,
                icon: const Icon(Icons.done_all),
                label: const Text('مطابق للدفاتر'),
              ),
            ),
            const SizedBox(height: AppSpace.md),
            field('cash', 'النقد (ريال)'),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.md,
              runSpacing: AppSpace.sm,
              children: [
                for (final k in openingKarats)
                  SizedBox(width: 160, child: field(k, 'عيار $k (جم)')),
              ],
            ),
            const SizedBox(height: AppSpace.lg),
            Text('المصدر', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpace.xs),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: [
                for (final s in widget.sources.entries)
                  ChoiceChip(
                    label: Text(s.value),
                    selected: _source == s.key,
                    onSelected: (_) => setState(() => _source = s.key),
                  ),
              ],
            ),
            if (_asksTreatment) ...[
              const SizedBox(height: AppSpace.lg),
              Text('رصيد الطرف النقدي', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpace.xs),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                children: [
                  for (final t in widget.treatments.entries)
                    ChoiceChip(
                      label: Text(t.value),
                      selected: _treatment == t.key,
                      onSelected: (_) => setState(() => _treatment = t.key),
                    ),
                ],
              ),
            ],
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'ملاحظة'),
              maxLength: 300,
            ),
            if (_refused != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(_refused!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: AppSpace.md),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'يُحفظ…' : 'حفظ الرقم'),
            ),
          ],
        ),
      ),
    );
  }
}
