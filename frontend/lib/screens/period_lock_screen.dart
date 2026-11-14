import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../api_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/record_card.dart';

/// «إقفال الفترات» (ADR-090, law 9): the books closed through a month's last
/// day -- no entry written, changed or deleted in it, by any path. Closing a
/// month shows first what still waits in it (a voucher pending, an entry
/// unposted, an invoice unposted, a period expense's months not posted):
/// each would be refused there once closed. It is handled, or accepted by
/// name and kept with the move. Opening a month again, to correct it, is a
/// move like any, with its reason. Every move is in the log, never changed.
/// Moving the lock is the owner's ([canMove]); reading it is anyone's who
/// reads the journal.
class PeriodLockScreen extends StatefulWidget {
  final ApiService api;
  final bool canMove;

  const PeriodLockScreen({super.key, required this.api, this.canMove = false});

  @override
  State<PeriodLockScreen> createState() => _PeriodLockScreenState();
}

final _day = DateFormat('yyyy-MM-dd');

/// The month ends after [after] (none: from a year back) up to the last one over by [today].
List<DateTime> monthEndsToClose(DateTime? after, DateTime today) {
  final last = DateTime(today.year, today.month, 0);
  var month = after == null
      ? DateTime(last.year - 1, last.month + 1, 1)
      : DateTime(after.year, after.month + 1, 1);
  final out = <DateTime>[];
  while (true) {
    final end = DateTime(month.year, month.month + 1, 0);
    if (end.isAfter(last)) break;
    out.add(end);
    month = DateTime(month.year, month.month + 1, 1);
  }
  return out;
}

class _PeriodLockScreenState extends State<PeriodLockScreen> {
  late Future<Map<String, dynamic>> _lock = widget.api.getPeriodLock();
  bool _busy = false;

  void _reload() => setState(() {
    _lock = widget.api.getPeriodLock();
  });

  void _say(String message) => AppFeedback.success(context, message);

  static const _kinds = {
    'vouchers': 'سندات معلّقة',
    'entries': 'قيود غير مرحَّلة أو مسودات',
    'invoices': 'فواتير غير مرحَّلة',
    'period_expenses': 'أشهر مصروفات فترة لم تُقيَّد',
  };

  String _itemLabel(String kind, Map item) => switch (kind) {
    'vouchers' => '${item['number']} — ${item['date']}',
    'entries' =>
      '${item['number']} — ${item['date']}${item['draft'] == true ? ' (مسودة)' : ''}',
    'invoices' => '${item['type'] ?? ''} ${item['number']} — ${item['date']}',
    _ => '${item['description']} — حتى ${item['through']}',
  };

  Future<void> _close(DateTime? current) async {
    final choices = monthEndsToClose(current, DateTime.now());
    if (choices.isEmpty) {
      _say('لا شهر انتهى بعد القفل الحالي');
      return;
    }
    var through = choices.last;
    Map<String, dynamic>? waiting;
    DateTime? asked; // asked once for each month chosen
    Future<void> look(StateSetter set) async {
      final month = through;
      asked = month;
      final w = await widget.api.getPeriodLockPending(_day.format(month));
      if (month == through) set(() => waiting = w);
    }

    final reason = TextEditingController();
    var accept = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) {
          if (waiting == null && asked != through) look(set);
          final total = (waiting?['total'] as num?) ?? 0;
          final ready =
              waiting != null &&
              reason.text.trim().isNotEmpty &&
              (total == 0 || accept);
          return Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('إقفال الفترة'),
              content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DropdownButtonFormField<DateTime>(
                        key: const Key('period-lock-through'),
                        initialValue: through,
                        decoration: const InputDecoration(
                          labelText: 'مقفلة حتى',
                        ),
                        items: [
                          for (final d in choices)
                            DropdownMenuItem(
                              value: d,
                              child: Text(_day.format(d)),
                            ),
                        ],
                        onChanged: (d) {
                          if (d == null) return;
                          set(
                            () => (through = d, waiting = null, accept = false),
                          );
                        },
                      ),
                      const SizedBox(height: AppSpace.md),
                      if (waiting == null)
                        const LinearProgressIndicator()
                      else if (total == 0)
                        const Text(
                          'لا شيء ينتظر في هذه الأشهر.',
                          key: Key('period-lock-nothing-waits'),
                        )
                      else ...[
                        Text(
                          'ينتظر في هذه الأشهر ($total): كلٌّ منها يُرفض فيها بعد الإقفال.',
                          key: const Key('period-lock-waiting'),
                          style: TextStyle(
                            color: AppSemanticColors.of(context).warning.fg,
                          ),
                        ),
                        for (final kind in _kinds.keys)
                          if (((waiting![kind] as Map?)?['count'] as num? ??
                                  0) >
                              0)
                            RecordCard(
                              style: RecordStyle.finding,
                              title:
                                  '${_kinds[kind]} (${(waiting![kind] as Map)['count']})',
                              subtitle: [
                                for (final item
                                    in ((waiting![kind] as Map)['items']
                                            as List)
                                        .cast<Map>()
                                        .take(5))
                                  _itemLabel(kind, item),
                              ].join('\n'),
                            ),
                        CheckboxListTile(
                          key: const Key('period-lock-accept'),
                          value: accept,
                          onChanged: (v) => set(() => accept = v ?? false),
                          title: const Text('أقبل ما ينتظر، فيُحفظ مع القفل'),
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ],
                      TextField(
                        key: const Key('period-lock-reason'),
                        controller: reason,
                        decoration: const InputDecoration(
                          labelText: 'السبب',
                          helperText: 'يُحفظ في سجلّ القفل',
                        ),
                        onChanged: (_) => set(() {}),
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
                FilledButton(
                  key: const Key('period-lock-confirm'),
                  onPressed: ready ? () => Navigator.pop(context, true) : null,
                  child: const Text('أقفل'),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (confirmed != true || !mounted) return;
    await _move(
      _day.format(through),
      reason.text.trim(),
      acceptPending: accept,
    );
  }

  /// Opened back to a month's end before [current] -- the last month by
  /// default, as far back as the correction needs -- or all of it (null).
  Future<void> _reopen(DateTime current) async {
    final reason = TextEditingController();
    final choices = <DateTime?>[
      for (var i = 0; i < 24; i++) DateTime(current.year, current.month - i, 0),
      null,
    ];
    DateTime? earlier = choices.first;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('فتح شهر للتصحيح'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<DateTime?>(
                  key: const Key('period-lock-reopen-to'),
                  initialValue: earlier,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'يصير القفل حتى'),
                  items: [
                    for (final d in choices)
                      DropdownMenuItem<DateTime?>(
                        value: d,
                        child: Text(d == null ? 'لا شيء مقفل (يُفتح كله)' : _day.format(d)),
                      ),
                  ],
                  onChanged: (d) => set(() => earlier = d),
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  earlier == null
                      ? 'تُفتح الدفاتر كلها. أعد إقفالها بعد التصحيح.'
                      : 'تُفتح الأشهر بعد ${_day.format(earlier!)} حتى ${DateFormat('yyyy-MM').format(current)}. '
                          'أعد إقفالها بعد التصحيح.',
                ),
                TextField(
                  key: const Key('period-lock-reopen-reason'),
                  controller: reason,
                  decoration: const InputDecoration(
                    labelText: 'السبب',
                    helperText: 'يُحفظ في سجلّ القفل',
                  ),
                  onChanged: (_) => set(() {}),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                key: const Key('period-lock-reopen-confirm'),
                onPressed: reason.text.trim().isEmpty
                    ? null
                    : () => Navigator.pop(context, true),
                child: const Text('افتح'),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    await _move(earlier == null ? null : _day.format(earlier!), reason.text.trim());
  }

  Future<void> _move(
    String? through,
    String reason, {
    bool acceptPending = false,
  }) async {
    setState(() => _busy = true);
    try {
      await widget.api.movePeriodLock(
        closedThrough: through,
        reason: reason,
        acceptPending: acceptPending,
      );
      if (!mounted) return;
      _say(through == null ? 'فُتحت الدفاتر كلها' : 'الدفاتر مقفلة حتى $through');
      _reload();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('إقفال الفترات')),
        body: FutureBuilder<Map<String, dynamic>>(
          future: _lock,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const AppLoadingView(summaryBlocks: 1, rows: 4);
            }
            if (snap.hasError) {
              return AppErrorView(
                title: 'تعذّر تحميل القفل',
                error: snap.error!,
                onRetry: _reload,
              );
            }
            final lock = snap.data!;
            final closed = lock['closed_through'] == null
                ? null
                : DateTime.parse('${lock['closed_through']}');
            final history = (lock['history'] as List? ?? const []).cast<Map>();
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.all(AppSpace.lg),
                  children: [
                    RecordCard(
                      key: const Key('period-lock-now'),
                      style: RecordStyle.heading,
                      title: closed == null
                          ? 'لا شيء مقفل'
                          : 'الدفاتر مقفلة حتى ${_day.format(closed)}',
                      subtitle: closed == null
                          ? 'كل شهر مفتوح للكتابة.'
                          : 'لا قيد يُكتب أو يُعدَّل أو يُحذف في شهر مقفل، من أي مسار. التصحيح في أول شهر مفتوح.',
                    ),
                    if (widget.canMove) ...[
                      const SizedBox(height: AppSpace.md),
                      Wrap(
                        spacing: AppSpace.sm,
                        runSpacing: AppSpace.sm,
                        children: [
                          FilledButton.icon(
                            key: const Key('period-lock-close'),
                            onPressed: _busy ? null : () => _close(closed),
                            icon: const Icon(Icons.lock_outline),
                            label: const Text('إقفال شهر'),
                          ),
                          if (closed != null)
                            OutlinedButton.icon(
                              key: const Key('period-lock-reopen'),
                              onPressed: _busy ? null : () => _reopen(closed),
                              icon: const Icon(Icons.lock_open),
                              label: const Text('فتح آخر شهر للتصحيح'),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: AppSpace.lg),
                    Text('السجل', style: theme.textTheme.titleMedium),
                    if (history.isEmpty) const Text('لم يُحرَّك القفل بعد.'),
                    for (final h in history)
                      RecordCard(
                        title: h['closed_through'] == null
                            ? 'فُتح كله'
                            : 'حتى ${h['closed_through']}',
                        subtitle:
                            '${h['reason']}\n${h['changed_by']} · ${'${h['changed_at']}'.substring(0, 16)}',
                        fields: [
                          if (h['accepted_pending'] != null)
                            RecordField(
                              'قُبل ما ينتظر',
                              '${(h['accepted_pending'] as Map)['total']}',
                            ),
                        ],
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
