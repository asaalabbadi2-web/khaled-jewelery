import 'dart:async';

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
import 'confirm_financial_action.dart';
import 'date_field.dart';

/// An employee's salary, one place (HR-UX ط2; the owner, 2 Nov 2026,
/// «اعتمد»): the salary in force and its split, «تغيير الراتب» -- a new
/// structure from the server's day, split by the policy as the gross is typed,
/// its parts summed against the gross --, the structures' history, and how he
/// is paid and insured, saved at once. Every figure is the server's: the split
/// is its suggestion, the structure's gross its sum.
///
/// What was typed and not saved is said on the card and told to [unsaved],
/// for the page or the dialog that holds the panel to ask before it leaves.
class EmployeeSalaryPanel extends StatefulWidget {
  const EmployeeSalaryPanel({
    super.key,
    required this.service,
    required this.employeeId,
    required this.isAr,
    this.unsaved,
    this.onSaved,
    this.parts = SalaryPanelPart.values,
    this.startChanging = false,
  });

  final PayrollService service;
  final int employeeId;
  final bool isAr;
  final ValueNotifier<List<String>>? unsaved;
  final VoidCallback? onSaved;

  /// The cards shown -- all, or a step's (HR-UX ط3: the new employee's
  /// salary, then his payment).
  final List<SalaryPanelPart> parts;

  /// «تغيير الراتب» open from the start (a new employee has none to show).
  final bool startChanging;

  @override
  State<EmployeeSalaryPanel> createState() => _EmployeeSalaryPanelState();
}

enum SalaryPanelPart { salary, history, payment }

typedef _Payment = (String?, String, String, int?, String);

class _EmployeeSalaryPanelState extends State<EmployeeSalaryPanel> {
  SalaryStructures? _structures;
  Object? _error;
  bool _busy = false;

  // «تغيير الراتب»
  bool _changing = false;
  bool _manual = false;
  Timer? _splitting;
  final _from = TextEditingController();
  final _gross = TextEditingController();
  final _basic = TextEditingController();
  final _housing = TextEditingController();
  final _transport = TextEditingController();
  final _other = TextEditingController();

  // how he is paid and insured
  final _iban = TextEditingController();
  final _bankName = TextEditingController();
  final _wage = TextEditingController();
  String? _method;
  int? _schemeId;
  List<Map<String, dynamic>> _schemes = const [];
  _Payment? _saved;

  bool get _isAr => widget.isAr;

  List<TextEditingController> get _all => [
    _from,
    _gross,
    _basic,
    _housing,
    _transport,
    _other,
    _iban,
    _bankName,
    _wage,
  ];

  @override
  void initState() {
    super.initState();
    for (final c in _all) {
      c.addListener(_typed);
    }
    _load();
  }

  @override
  void dispose() {
    _splitting?.cancel();
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final structures = await widget.service.structures(widget.employeeId);
      final payment = await widget.service.payment(widget.employeeId);
      final schemes = await widget.service.schemes();
      if (!mounted) return;
      setState(() {
        _error = null;
        _structures = structures;
        _schemes = schemes;
        if (widget.startChanging && !_changing && _saved == null) {
          _changing = true;
          _from.text = structures.suggestedFrom ?? '';
        }
        if (_saved == null) {
          _method = payment['payment_method'] as String?;
          _iban.text = '${payment['iban'] ?? ''}';
          _bankName.text = '${payment['bank_name'] ?? ''}';
          _schemeId = payment['contribution_scheme_id'] as int?;
          final wage = payment['contribution_wage'] as num?;
          _wage.text = wage == null ? '' : _plain(wage.toDouble());
          _saved = _payment;
        }
      });
      _typed();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  _Payment get _payment => (
    _method,
    _iban.text.trim(),
    _bankName.text.trim(),
    _schemeId,
    _wage.text.trim(),
  );

  /// Each part typed and not saved, by its name.
  List<String> get _unsaved => [
    if (_changing &&
        [
          _gross,
          _basic,
          _housing,
          _transport,
        ].any((c) => c.text.trim().isNotEmpty))
      _isAr ? 'الراتب الجديد' : 'the new salary',
    if (_saved != null && _payment != _saved)
      _isAr ? 'الصرف والتأمينات' : 'payment and insurance',
  ];

  void _typed() {
    final unsaved = _unsaved;
    final told = widget.unsaved;
    if (told != null && !_sameList(told.value, unsaved)) told.value = unsaved;
    if (mounted) setState(() {});
  }

  static bool _sameList(List<String> a, List<String> b) =>
      a.length == b.length &&
      [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  double _read(TextEditingController c) =>
      double.tryParse(normalizeNumber(c.text)) ?? 0;

  String _plain(double v) => formatAmount(v).replaceAll(',', '');

  String _money(double v) => ltrIsolate(formatAmount(v));

  /// To the halala, as the server keeps it.
  static double _halala(double v) => (v * 100).round() / 100;

  double get _sum => _halala(
    _read(_basic) + _read(_housing) + _read(_transport) + _read(_other),
  );

  // ── «تغيير الراتب» ─────────────────────────────────────────────────────────

  void _open() {
    setState(() {
      _changing = true;
      _manual = false;
      _from.text = _structures?.suggestedFrom ?? '';
    });
  }

  void _close() {
    _splitting?.cancel();
    for (final c in [_gross, _basic, _housing, _transport, _other]) {
      c.clear();
    }
    setState(() => _changing = false);
    _typed();
  }

  /// The gross split by the policy -- the server's, a moment after typing.
  void _grossTyped(String _) {
    if (_manual) return;
    _splitting?.cancel();
    _splitting = Timer(const Duration(milliseconds: 350), _split);
  }

  Future<void> _split() async {
    final gross = _read(_gross);
    if (gross <= 0) return;
    try {
      final split = await widget.service.suggest(gross);
      if (!mounted || _manual || _read(_gross) != gross) return;
      _basic.text = _plain(split['basic'] ?? 0);
      _housing.text = _plain(split['housing'] ?? 0);
      _transport.text = _plain(split['transport'] ?? 0);
      _other.text = _plain(split['other_allowances'] ?? 0);
    } catch (e) {
      if (!mounted) return;
      setState(() => _manual = true);
      AppFeedback.error(context, e);
    }
  }

  bool get _ready {
    final gross = _read(_gross);
    return !_busy &&
        _from.text.trim().isNotEmpty &&
        _read(_basic) > 0 &&
        (gross == 0 || _sum == _halala(gross));
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
      _close();
      await _load();
      widget.onSaved?.call();
      if (mounted) {
        AppFeedback.success(
          context,
          _isAr ? 'حُفظ الراتب الجديد' : 'Salary saved',
        );
      }
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(SalaryStructureModel s) async {
    final sure = await confirmFinancialAction(
      context,
      title: _isAr ? 'حذف هيكل الراتب' : 'Delete the structure',
      effect: _isAr
          ? 'يُحذف هذا الهيكل، ويقرأ المسير ما قبله.'
          : 'This structure goes; the run reads the one before it.',
      confirmLabel: _isAr ? 'احذف' : 'Delete',
      facts: [
        (_isAr ? 'من' : 'From', ltrIsolate(s.effectiveFrom)),
        (_isAr ? 'الإجمالي' : 'Gross', _money(s.gross)),
      ],
    );
    if (sure == null) return;
    try {
      await widget.service.deleteStructure(s.id);
      await _load();
      widget.onSaved?.call();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  // ── how he is paid ─────────────────────────────────────────────────────────

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
      _saved = _payment;
      _typed();
      widget.onSaved?.call();
      if (mounted) {
        AppFeedback.success(
          context,
          _isAr ? 'حُفظ الصرف والتأمينات' : 'Payment saved',
        );
      }
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── the cards ──────────────────────────────────────────────────────────────

  Widget _amountField(
    TextEditingController c,
    String label,
    String key, {
    bool readOnly = false,
    ValueChanged<String>? onChanged,
  }) => TextField(
    key: ValueKey(key),
    controller: c,
    readOnly: readOnly,
    onChanged: onChanged,
    textDirection: TextDirection.ltr,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: [
      ArabicNumberTextInputFormatter(),
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
    ],
    decoration: InputDecoration(labelText: label, filled: readOnly),
  );

  Widget _card({
    Key? key,
    required List<Widget> children,
    bool marked = false,
  }) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    return Card(
      key: key,
      shape: marked
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
              side: BorderSide(color: tones.gold.fg, width: 2),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: DefaultTextStyle.merge(
          style: theme.textTheme.bodyMedium,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }

  Widget _current() {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final s = _structures?.current;
    final isAr = _isAr;
    if (s == null) {
      return _card(
        key: const ValueKey('salary-current'),
        children: [
          Text(
            isAr ? 'الراتب الحالي' : 'Salary in force',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            isAr
                ? 'لا راتب ساري: لا يدخل المسير حتى يُضاف'
                : 'None in force: not in the run until added',
            style: TextStyle(color: tones.warning.fg),
          ),
          if (!_changing) ...[
            const SizedBox(height: AppSpace.md),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                key: const ValueKey('salary-change'),
                onPressed: _open,
                icon: const Icon(Icons.add),
                label: Text(isAr ? 'أضف الراتب' : 'Add the salary'),
              ),
            ),
          ],
        ],
      );
    }
    final parts = [
      (isAr ? 'أساسي' : 'Basic', s.basic, tones.gold.fg),
      (isAr ? 'سكن' : 'Housing', s.housing, tones.gold.onContainer),
      (isAr ? 'نقل' : 'Transport', s.transport, tones.gold.container),
      (
        isAr ? 'بدلات أخرى' : 'Other',
        s.otherAllowances,
        theme.colorScheme.outlineVariant,
      ),
    ];
    return _card(
      key: const ValueKey('salary-current'),
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: AppSpace.sm,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isAr ? 'الراتب الحالي' : 'Salary in force',
                  style: theme.textTheme.titleSmall,
                ),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: _money(s.gross),
                        style: theme.textTheme.headlineMedium,
                      ),
                      TextSpan(text: isAr ? '  ر.س شهريًا' : '  SAR a month'),
                    ],
                  ),
                ),
                Text(
                  '${isAr ? 'ساري من' : 'Since'} ${ltrIsolate(s.effectiveFrom)}',
                ),
              ],
            ),
            if (!_changing)
              OutlinedButton.icon(
                key: const ValueKey('salary-change'),
                onPressed: _open,
                icon: const Icon(Icons.edit_outlined),
                label: Text(isAr ? 'تغيير الراتب' : 'Change the salary'),
              ),
          ],
        ),
        const SizedBox(height: AppSpace.md),
        Semantics(
          label: [
            for (final p in parts)
              if (p.$2 > 0) '${p.$1} ${formatAmount(p.$2)}',
          ].join('، '),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: SizedBox(
              height: 12,
              child: Row(
                children: [
                  for (final p in parts)
                    if (p.$2 > 0 && s.gross > 0)
                      Expanded(
                        flex: (p.$2 * 1000 / s.gross).round().clamp(1, 1000),
                        child: ColoredBox(color: p.$3),
                      ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Wrap(
          spacing: AppSpace.lg,
          runSpacing: AppSpace.xs,
          children: [
            for (final p in parts)
              if (p.$2 > 0 || p.$1 != parts.last.$1)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: p.$3,
                        borderRadius: BorderRadius.circular(AppRadius.chip / 2),
                      ),
                    ),
                    const SizedBox(width: AppSpace.xs),
                    Text('${p.$1} ${_money(p.$2)}'),
                  ],
                ),
          ],
        ),
      ],
    );
  }

  Widget _change() {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final isAr = _isAr;
    final gross = _read(_gross);
    final sum = _sum;
    final diff = _halala(sum - gross);
    final now = _structures?.current;
    final (tone, said) = gross == 0
        ? (
            tones.info,
            isAr
                ? 'الإجمالي ${_money(sum)}: مجموع الأجزاء'
                : 'Gross ${_money(sum)}: the parts\' sum',
          )
        : diff == 0
        ? (
            tones.ready,
            isAr
                ? 'المجموع ${_money(sum)} يساوي الإجمالي'
                : 'The parts sum to the gross',
          )
        : (
            tones.warning,
            isAr
                ? 'المجموع ${_money(sum)}: ${diff > 0 ? 'يزيد' : 'ينقص'} ${_money(diff.abs())} عن الإجمالي، فلا يُحفظ حتى يتساوى'
                : 'The parts sum to ${_money(sum)}: ${_money(diff.abs())} ${diff > 0 ? 'over' : 'under'} the gross',
          );
    return _card(
      key: const ValueKey('salary-change-form'),
      marked: true,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              isAr ? 'تغيير الراتب' : 'Change the salary',
              style: theme.textTheme.titleMedium,
            ),
            Text(
              isAr
                  ? 'يُضاف هيكل جديد، ويبقى القديم في السجل'
                  : 'A new structure; the old stays in the history',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: AppSpace.md),
        Wrap(
          spacing: AppSpace.lg,
          runSpacing: AppSpace.md,
          children: [
            SizedBox(
              width: 260,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DateField(
                    key: const ValueKey('structure-from'),
                    controller: _from,
                    label: isAr ? 'يبدأ من' : 'From',
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    isAr
                        ? 'يقترحه النظام: الشهر الذي يلي آخر راتب معتمد له'
                        : 'Offered: the month after his last approved salary',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 260,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _amountField(
                    _gross,
                    isAr ? 'الإجمالي الشهري' : 'Monthly gross',
                    'structure-gross',
                    onChanged: _grossTyped,
                  ),
                  if (now != null && gross > 0) ...[
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      isAr
                          ? 'كان ${_money(now.gross)} · ${gross >= now.gross ? 'زيادة' : 'نقص'} ${_money((gross - now.gross).abs())}'
                          : 'Was ${_money(now.gross)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.md),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: SegmentedButton<bool>(
            key: const ValueKey('structure-split-mode'),
            segments: [
              ButtonSegment(
                value: false,
                label: Text(isAr ? 'بنسب سياسة الرواتب' : 'By the policy'),
              ),
              ButtonSegment(
                value: true,
                label: Text(isAr ? 'يدويًا' : 'By hand'),
              ),
            ],
            selected: {_manual},
            onSelectionChanged: (s) {
              setState(() => _manual = s.first);
              if (!_manual) _split();
            },
          ),
        ),
        const SizedBox(height: AppSpace.md),
        Wrap(
          spacing: AppSpace.md,
          runSpacing: AppSpace.md,
          children: [
            for (final (c, label, key) in [
              (_basic, isAr ? 'الأساسي' : 'Basic', 'structure-basic'),
              (_housing, isAr ? 'السكن' : 'Housing', 'structure-housing'),
              (_transport, isAr ? 'النقل' : 'Transport', 'structure-transport'),
              (_other, isAr ? 'بدلات أخرى' : 'Other', 'structure-other'),
            ])
              SizedBox(
                width: 170,
                child: _amountField(c, label, key, readOnly: !_manual),
              ),
          ],
        ),
        const SizedBox(height: AppSpace.md),
        Container(
          key: const ValueKey('structure-sum'),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg,
            vertical: AppSpace.md,
          ),
          decoration: BoxDecoration(
            color: tone.container,
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          child: Text(said, style: TextStyle(color: tone.onContainer)),
        ),
        const SizedBox(height: AppSpace.md),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.sm,
          children: [
            OutlinedButton(
              key: const ValueKey('structure-cancel'),
              onPressed: _busy ? null : _close,
              child: Text(isAr ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton(
              key: const ValueKey('structure-save'),
              onPressed: _ready ? _save : null,
              child: Text(isAr ? 'احفظ الراتب الجديد' : 'Save the new salary'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _history() {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final isAr = _isAr;
    final structures = _structures!;
    final rows =
        structures.rows; // newest first: those before the current are ahead
    final currentAt = rows.indexWhere((s) => s.id == structures.currentId);
    Widget chip(String text, SemanticTone tone) => Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 2),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: tone.onContainer),
      ),
    );
    return _card(
      key: const ValueKey('salary-history'),
      children: [
        Text(
          isAr ? 'سجل الراتب' : 'Salary history',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: AppSpace.sm),
        if (rows.isEmpty) Text(isAr ? 'لا هيكل بعد' : 'None yet'),
        for (final (i, s) in rows.indexed)
          Padding(
            key: ValueKey('structure-row-${s.id}'),
            padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.xs),
                  child: Icon(
                    Icons.circle,
                    size: 12,
                    color: i == currentAt
                        ? tones.gold.fg
                        : theme.colorScheme.outlineVariant,
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${isAr ? 'من' : 'From'} ${ltrIsolate(s.effectiveFrom)}',
                      ),
                      Text(
                        '${isAr ? 'أساسي' : 'Basic'} ${_money(s.basic)} · ${isAr ? 'سكن' : 'Housing'} ${_money(s.housing)} · ${isAr ? 'نقل' : 'Transport'} ${_money(s.transport)}',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 2),
                      if (i == currentAt)
                        chip(isAr ? 'الساري الآن' : 'In force', tones.gold)
                      else if (currentAt == -1 || i < currentAt)
                        chip(isAr ? 'قادم' : 'Ahead', tones.info),
                      if (s.locked)
                        Text(
                          isAr
                              ? 'قرأته مسيرات معتمدة، فلا يُحذف'
                              : 'Approved salaries read it: kept',
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                Text(_money(s.gross), style: theme.textTheme.titleSmall),
                if (!s.locked)
                  IconButton(
                    key: ValueKey('structure-delete-${s.id}'),
                    tooltip: isAr ? 'حذف' : 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _busy ? null : () => _delete(s),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _paymentCard() {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final isAr = _isAr;
    final dirty = _saved != null && _payment != _saved;
    return _card(
      key: const ValueKey('salary-payment'),
      children: [
        Text(
          isAr ? 'الصرف والتأمينات' : 'Payment and insurance',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: AppSpace.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: SegmentedButton<String>(
            key: const ValueKey('employee-payment-method'),
            emptySelectionAllowed: true,
            segments: [
              ButtonSegment(
                value: 'bank',
                label: Text(isAr ? 'تحويل بنكي' : 'Bank'),
              ),
              ButtonSegment(value: 'cash', label: Text(isAr ? 'نقد' : 'Cash')),
            ],
            selected: {?_method},
            onSelectionChanged: (s) {
              _method = s.isEmpty ? null : s.first;
              _typed();
            },
          ),
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
            decoration: InputDecoration(labelText: isAr ? 'البنك' : 'Bank'),
          ),
        ],
        const SizedBox(height: AppSpace.sm),
        DropdownButtonFormField<int?>(
          key: ValueKey('employee-scheme-$_schemeId'),
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
          onChanged: (v) {
            _schemeId = v;
            _typed();
          },
        ),
        if (_schemeId != null)
          _amountField(
            _wage,
            isAr
                ? 'الأجر المسجّل في التأمينات (فارغ: الأساسي والسكن)'
                : 'Registered wage (empty: basic + housing)',
            'employee-contribution-wage',
          ),
        const SizedBox(height: AppSpace.md),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.md,
            vertical: AppSpace.sm,
          ),
          decoration: BoxDecoration(
            color: dirty ? tones.warning.container : null,
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          child: Row(
            children: [
              Expanded(
                child: dirty
                    ? Text(
                        isAr ? 'لم يُحفظ' : 'Not saved',
                        key: const ValueKey('salary-payment-unsaved'),
                        style: TextStyle(color: tones.warning.onContainer),
                      )
                    : const SizedBox.shrink(),
              ),
              FilledButton(
                key: const ValueKey('employee-payment-save'),
                onPressed: dirty && !_busy ? _savePayment : null,
                child: Text(isAr ? 'حفظ' : 'Save'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = _isAr;
    if (_error != null && _structures == null) {
      return AppErrorView(
        title: isAr ? 'تعذّر تحميل الراتب' : 'Could not load the salary',
        error: _error!,
        onRetry: _load,
      );
    }
    if (_structures == null) {
      return const AppLoadingView(summaryBlocks: 1, rows: 4);
    }
    final parts = widget.parts;
    if (!parts.contains(SalaryPanelPart.history) ||
        !parts.contains(SalaryPanelPart.payment)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (parts.contains(SalaryPanelPart.salary)) ...[
            _current(),
            if (_changing) _change(),
          ],
          if (parts.contains(SalaryPanelPart.history)) _history(),
          if (parts.contains(SalaryPanelPart.payment)) _paymentCard(),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _current(),
        if (_changing) _change(),
        LayoutBuilder(
          builder: (context, box) => box.maxWidth >= 720
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _history()),
                    Expanded(child: _paymentCard()),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [_history(), _paymentCard()],
                ),
        ),
      ],
    );
  }
}
