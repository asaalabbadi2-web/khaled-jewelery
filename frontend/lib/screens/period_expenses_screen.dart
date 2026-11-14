import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/inline_number_cell.dart' show readTypedNumber;
import '../utils/bidi.dart' show ltrIsolate;
import '../utils/currency_utils.dart' show formatAmount;
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/account_picker_sheet.dart'
    show AccountPickerFormField, isLeafAccount, parentAccountIdsOf;
import '../widgets/record_card.dart';
import '../widgets/summary_strip.dart';

/// «مصروفات الفترات» (ADR-090): an expense of a period -- rent, a licence, a
/// subscription -- accrued month by month, its vouchers its payments. Each
/// says what the server derives: accrued by today, paid by today, and the
/// balance -- prepaid above zero, accrued below. The screen computes none of
/// it. From here: a new one, its schedule and its edits, an edit or a
/// cancellation with its reason, and the month-end action -- previewed, then
/// applied.
class PeriodExpensesScreen extends StatefulWidget {
  final ApiService api;

  const PeriodExpensesScreen({super.key, required this.api});

  @override
  State<PeriodExpensesScreen> createState() => _PeriodExpensesScreenState();
}

final _day = DateFormat('yyyy-MM-dd');

/// The last day of the month before [today]: what the month-end action accrues through.
DateTime lastMonthEnd(DateTime today) => DateTime(today.year, today.month, 0);

class _PeriodExpensesScreenState extends State<PeriodExpensesScreen> {
  late Future<List<Map<String, dynamic>>> _expenses = widget.api
      .getPeriodExpenses();
  bool _busy = false;

  void _reload() => setState(() {
    _expenses = widget.api.getPeriodExpenses();
  });

  void _say(String message) => AppFeedback.success(context, message);

  String _riyals(dynamic v) =>
      '${formatAmount(v is num ? v : 0)} ${context.read<SettingsProvider>().currencySymbolText}';

  static String _standing(String? s) => switch (s) {
    'prepaid' => 'مقدَّم',
    'accrued' => 'مستحق',
    _ => 'مسدَّد',
  };

  Future<void> _guarded(Future<void> Function() act) async {
    setState(() => _busy = true);
    try {
      await act();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── a new one ──────────────────────────────────────────────────────────────

  Future<void> _create() async {
    final accounts = (await widget.api.getAccounts(
      skipBalances: true,
    )).whereType<Map>().map((a) => Map<String, dynamic>.from(a)).toList();
    if (!mounted) return;
    final parents = parentAccountIdsOf(accounts);
    final made = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ExpenseForm(
        accounts: accounts
            .where(
              (a) =>
                  '${a['type']}'.toLowerCase() == 'expense' &&
                  a['tracks_weight'] != true,
            )
            .where((a) => isLeafAccount(a, parents))
            .toList(),
      ),
    );
    if (made == null || !mounted) return;
    await _guarded(() async {
      await widget.api.createPeriodExpense(
        description: made['description'],
        expenseAccountId: made['account_id'],
        amount: made['amount'],
        periodStart: made['start'],
        periodEnd: made['end'],
      );
      _say('أُضيف المصروف');
      _reload();
    });
  }

  // ── one expense: its schedule, its edits ───────────────────────────────────

  Future<void> _open(Map<String, dynamic> pe) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          _ExpenseSheet(api: widget.api, id: pe['id'] as int, riyals: _riyals),
    );
    if (changed == true) _reload();
  }

  // ── the month-end action ───────────────────────────────────────────────────

  Future<void> _accrue() async {
    final through = _day.format(lastMonthEnd(DateTime.now()));
    Map<String, dynamic>? preview;
    await _guarded(
      () async => preview = await widget.api.accruePeriodExpenses(through),
    );
    if (preview == null || !mounted) return;
    final entries = (preview!['entries'] as List? ?? const []).cast<Map>();
    final reclass = (preview!['reclass'] as List? ?? const []).cast<Map>();
    final drift = (preview!['drift'] as List? ?? const []).cast<Map>();
    final apply = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('استحقاق الأشهر حتى $through'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              key: const Key('accrue-preview'),
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (entries.isEmpty && reclass.isEmpty)
                  const Text('لا قيد مستحق: الأشهر المنتهية كلها مقيَّدة.'),
                for (final e in entries)
                  RecordCard(
                    title: '${e['month']}',
                    subtitle:
                        'مصروف رقم ${e['period_expense_id']}'
                        '${e['amount'] != e['scheduled'] ? ' — تسوية تراكمية، المجدول ${_riyals(e['scheduled'])}' : ''}',
                    fields: [
                      RecordField(
                        'القيد',
                        _riyals(e['amount']),
                        negative: (e['amount'] as num) < 0,
                      ),
                    ],
                  ),
                for (final r in reclass)
                  RecordCard(
                    title: 'إعادة تصنيف ${r['month']}',
                    fields: [
                      RecordField('إلى المقدَّم', _riyals(r['to_prepaid'])),
                    ],
                  ),
                for (final d in drift)
                  RecordCard(
                    style: RecordStyle.finding,
                    title: 'لا يطابق ${d['month']}',
                    subtitle:
                        'الحسابان في الدفاتر لا يساويان أرصدة المصروفات: لا يُعاد التصنيف فوق ذلك.',
                    fields: [
                      RecordField('الدفاتر', _riyals(d['books'])),
                      RecordField('المصروفات', _riyals(d['expenses'])),
                    ],
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          if (entries.isNotEmpty || reclass.isNotEmpty)
            FilledButton(
              key: const Key('accrue-apply'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('قيّد'),
            ),
        ],
      ),
    );
    if (apply != true || !mounted) return;
    await _guarded(() async {
      final out = await widget.api.accruePeriodExpenses(through, apply: true);
      _say('قُيّد ${(out['entries'] as List? ?? const []).length} قيدًا');
      _reload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('مصروفات الفترات'),
          actions: [
            IconButton(
              key: const Key('period-expenses-accrue'),
              tooltip: 'استحقاق الشهر',
              onPressed: _busy ? null : _accrue,
              icon: const Icon(Icons.event_repeat),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const Key('period-expense-new'),
          onPressed: _busy ? null : _create,
          icon: const Icon(Icons.add),
          label: const Text('مصروف فترة'),
        ),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _expenses,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const AppLoadingView(summaryBlocks: 2, rows: 4);
            }
            if (snap.hasError) {
              return AppErrorView(
                title: 'تعذّر تحميل مصروفات الفترات',
                error: snap.error!,
                onRetry: _reload,
              );
            }
            final rows = snap.data ?? const [];
            if (rows.isEmpty) {
              return const AppEmptyView(
                title: 'لا مصروف فترة بعد',
                hint:
                    'إيجار أو رخصة أو اشتراك يُدفع عن أشهر: أضفه، ثم اربط سند صرفه به.',
                icon: Icons.event_repeat,
              );
            }
            num sum(String standing) => rows
                .where(
                  (r) => r['status'] == 'active' && r['standing'] == standing,
                )
                .fold<num>(0, (a, r) => a + ((r['balance'] as num?) ?? 0));
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                // a record's name and its figures stay close on a wide screen
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.lg,
                    AppSpace.lg,
                    AppSpace.lg,
                    96,
                  ),
                  children: [
                    SummaryStrip(
                      items: [
                        SummaryItem(
                          'مقدَّم',
                          _riyals(sum('prepaid')),
                          key: const Key('period-expenses-prepaid'),
                        ),
                        SummaryItem(
                          'مستحق',
                          _riyals(sum('accrued').abs()),
                          key: const Key('period-expenses-accrued'),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.md),
                    for (final r in rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpace.sm),
                        child: RecordCard(
                          key: ValueKey('period-expense-${r['id']}'),
                          title: '${r['description']}',
                          subtitle:
                              'من ${ltrIsolate('${r['period_start']}')} إلى ${ltrIsolate('${r['period_end']}')}'
                              '${r['status'] == 'cancelled' ? ' · ملغى' : ''}',
                          trailing: Text(
                            _standing(r['standing'] as String?),
                            style: theme.textTheme.labelLarge,
                          ),
                          style: r['status'] == 'cancelled'
                              ? RecordStyle.note
                              : RecordStyle.line,
                          onTap: () => _open(r),
                          fields: [
                            RecordField('المبلغ', _riyals(r['amount'])),
                            RecordField(
                              'المستحق حتى اليوم',
                              _riyals(r['accrued']),
                            ),
                            RecordField(
                              'المدفوع حتى اليوم',
                              _riyals(r['paid']),
                            ),
                            RecordField(
                              'الرصيد',
                              _riyals(((r['balance'] as num?) ?? 0).abs()),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A new period expense: what it is, its expense account, the amount net of
/// VAT, from and to.
class _ExpenseForm extends StatefulWidget {
  final List<Map<String, dynamic>> accounts;

  const _ExpenseForm({required this.accounts});

  @override
  State<_ExpenseForm> createState() => _ExpenseFormState();
}

class _ExpenseFormState extends State<_ExpenseForm> {
  final _description = TextEditingController();
  final _amount = TextEditingController();
  int? _account;
  DateTimeRange? _period;

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  String? get _blocker {
    if (_description.text.trim().isEmpty) return 'اكتب وصف المصروف';
    if (_account == null) return 'اختر حساب المصروف';
    if ((readTypedNumber(_amount.text) ?? 0) <= 0) {
      return 'أدخل المبلغ (بلا الضريبة)';
    }
    if (_period == null) return 'اختر الفترة';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final blocker = _blocker;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('مصروف فترة'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const Key('period-expense-description'),
                  controller: _description,
                  decoration: const InputDecoration(
                    labelText: 'الوصف',
                    hintText: 'إيجار المعرض 2026',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppSpace.md),
                AccountPickerFormField(
                  key: const Key('period-expense-account'),
                  context: context,
                  accounts: widget.accounts,
                  value: _account,
                  labelText: 'حساب المصروف',
                  showTransactionTypeFilter: false,
                  onChanged: (v) => setState(() => _account = v),
                ),
                const SizedBox(height: AppSpace.md),
                TextField(
                  key: const Key('period-expense-amount'),
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'المبلغ',
                    helperText:
                        'بلا الضريبة: ضريبة المدخلات تُقيَّد كاملة بتاريخ فاتورتها',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppSpace.md),
                OutlinedButton.icon(
                  key: const Key('period-expense-period'),
                  onPressed: () async {
                    final picked = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2035),
                      initialDateRange: _period,
                    );
                    if (picked != null) setState(() => _period = picked);
                  },
                  icon: const Icon(Icons.date_range),
                  label: Text(
                    _period == null
                        ? 'الفترة: من — إلى'
                        : 'من ${_day.format(_period!.start)} إلى ${_day.format(_period!.end)}',
                  ),
                ),
                if (blocker != null) ...[
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    blocker,
                    style: TextStyle(
                      color: AppSemanticColors.of(context).warning.fg,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            key: const Key('period-expense-save'),
            onPressed: blocker != null
                ? null
                : () => Navigator.pop(context, {
                    'description': _description.text.trim(),
                    'account_id': _account,
                    'amount': readTypedNumber(_amount.text),
                    'start': _day.format(_period!.start),
                    'end': _day.format(_period!.end),
                  }),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }
}

/// One expense: its three values, its months, its edits; an edit or a
/// cancellation, each with its reason.
class _ExpenseSheet extends StatefulWidget {
  final ApiService api;
  final int id;
  final String Function(dynamic) riyals;

  const _ExpenseSheet({
    required this.api,
    required this.id,
    required this.riyals,
  });

  @override
  State<_ExpenseSheet> createState() => _ExpenseSheetState();
}

class _ExpenseSheetState extends State<_ExpenseSheet> {
  late Future<Map<String, dynamic>> _pe = widget.api.getPeriodExpense(
    widget.id,
  );
  bool _changed = false;

  Future<String?> _reason(
    String title, {
    String? extraLabel,
    TextEditingController? extra,
  }) => showDialog<String>(
    context: context,
    builder: (context) {
      final reason = TextEditingController();
      return Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (extra != null)
                TextField(
                  key: const Key('period-expense-edit-amount'),
                  controller: extra,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(labelText: extraLabel),
                ),
              TextField(
                key: const Key('period-expense-reason'),
                controller: reason,
                decoration: const InputDecoration(
                  labelText: 'السبب',
                  helperText: 'يُحفظ في سجلّ المصروف',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('رجوع'),
            ),
            FilledButton(
              key: const Key('period-expense-reason-ok'),
              onPressed: () => Navigator.pop(context, reason.text.trim()),
              child: const Text('تأكيد'),
            ),
          ],
        ),
      );
    },
  );

  Future<void> _act(
    Future<Map<String, dynamic>> Function(String reason) call,
    String title, {
    TextEditingController? amount,
  }) async {
    final reason = await _reason(
      title,
      extraLabel: amount == null ? null : 'المبلغ الجديد',
      extra: amount,
    );
    if (reason == null || reason.isEmpty || !mounted) return;
    try {
      await call(reason);
      if (!mounted) return;
      setState(() {
        _changed = true;
        _pe = widget.api.getPeriodExpense(widget.id);
      });
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) Navigator.pop(context, _changed);
        },
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          builder: (context, scroll) => FutureBuilder<Map<String, dynamic>>(
            future: _pe,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const AppLoadingView(summaryBlocks: 1, rows: 4);
              }
              final pe = snap.data!;
              final active = pe['status'] == 'active';
              final months = (pe['schedule'] as List? ?? const []).cast<Map>();
              final revisions = (pe['revisions'] as List? ?? const [])
                  .cast<Map>();
              return ListView(
                controller: scroll,
                padding: const EdgeInsets.all(AppSpace.lg),
                children: [
                  Text(
                    '${pe['description']}',
                    style: theme.textTheme.titleLarge,
                  ),
                  Text(
                    'من ${ltrIsolate('${pe['period_start']}')} إلى ${ltrIsolate('${pe['period_end']}')}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppSpace.md),
                  RecordCard(
                    key: const Key('period-expense-values'),
                    title: 'حتى ${pe['as_of']}',
                    fields: [
                      RecordField('المبلغ', widget.riyals(pe['amount'])),
                      RecordField(
                        'المستحق بالجدول',
                        widget.riyals(pe['accrued']),
                      ),
                      RecordField(
                        'المقيَّد في الدفاتر',
                        widget.riyals(pe['posted_accrued']),
                      ),
                      RecordField('المدفوع', widget.riyals(pe['paid'])),
                      RecordField(
                        'الباقي للدفع',
                        widget.riyals(pe['remaining_to_pay']),
                      ),
                    ],
                  ),
                  if (active)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpace.sm,
                      ),
                      child: Wrap(
                        spacing: AppSpace.sm,
                        children: [
                          OutlinedButton.icon(
                            key: const Key('period-expense-edit'),
                            onPressed: () {
                              final amount = TextEditingController(
                                text: '${pe['amount']}',
                              );
                              _act(
                                (r) => widget.api.editPeriodExpense(
                                  widget.id,
                                  reason: r,
                                  amount: readTypedNumber(amount.text),
                                ),
                                'تعديل المبلغ',
                                amount: amount,
                              );
                            },
                            icon: const Icon(Icons.edit),
                            label: const Text('تعديل المبلغ'),
                          ),
                          OutlinedButton.icon(
                            key: const Key('period-expense-cancel'),
                            onPressed: () => _act(
                              (r) => widget.api.cancelPeriodExpense(
                                widget.id,
                                reason: r,
                              ),
                              'إلغاء المصروف',
                            ),
                            icon: const Icon(Icons.block),
                            label: const Text('إلغاء'),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: AppSpace.sm),
                  Text('الأشهر', style: theme.textTheme.titleMedium),
                  for (final m in months)
                    RecordCard(
                      title: '${m['month']}',
                      fields: [
                        RecordField('القسط', widget.riyals(m['amount'])),
                      ],
                    ),
                  if (revisions.isNotEmpty) ...[
                    const SizedBox(height: AppSpace.md),
                    Text('التعديلات', style: theme.textTheme.titleMedium),
                    for (final r in revisions)
                      RecordCard(
                        style: RecordStyle.note,
                        title: '${r['reason']}',
                        subtitle:
                            '${r['changed_by']} · ${'${r['changed_at']}'.substring(0, 10)}',
                        fields: [
                          for (final key in (r['after'] as Map).keys)
                            RecordField(
                              '$key',
                              '${(r['before'] as Map)[key]} ← ${(r['after'] as Map)[key]}',
                              figure: false,
                            ),
                        ],
                      ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
