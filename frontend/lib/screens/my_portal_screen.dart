import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../api_service.dart';
import '../pdf/payslip_pdf_builder.dart';
import '../services/payroll_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/date_field.dart';

/// «بوابتي», the employee's own (EMP-PORTAL-1; the owner, 1 Nov 2026): his
/// payslips (and their print), his leave and its balance -- and his request
/// for one, approved by the manager -- his advance, his bonuses, his goals.
/// The server reads him from his session alone; nothing here names him.
class MyPortalScreen extends StatefulWidget {
  const MyPortalScreen({
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
  State<MyPortalScreen> createState() => _MyPortalScreenState();
}

class _MyPortalScreenState extends State<MyPortalScreen> {
  late final PayrollService _service =
      widget.service ?? PayrollService(widget.api);
  Map<String, dynamic>? _portal;
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
      final portal = await _service.myPortal();
      if (mounted) setState(() => _portal = portal);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _printPayslip(int id) async {
    try {
      final slip = await _service.myPayslip(id);
      await Printing.layoutPdf(
        name: 'payslip-$id',
        onLayout: (_) => buildPayslipPdf(slip),
      );
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    }
  }

  Future<void> _requestLeave(List<Map<String, dynamic>> kinds) async {
    final row = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _LeaveRequestDialog(kinds: kinds, isAr: _isAr),
    );
    if (row == null) return;
    try {
      await _service.requestMyLeave(row);
      await _load();
      if (mounted) {
        AppFeedback.success(
          context,
          _isAr ? 'أُرسل طلبك، وينتظر اعتماد المدير' : 'Sent for approval',
        );
      }
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    }
  }

  Future<void> _cancel(int id) async {
    try {
      await _service.cancelMyLeave(id);
      await _load();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    }
  }

  Widget _card(String title, IconData icon, List<Widget> children, {Key? key}) {
    final theme = Theme.of(context);
    return Card(
      key: key,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: AppSemanticColors.of(context).gold.fg),
                const SizedBox(width: AppSpace.sm),
                Text(title, style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(value),
        ?trailing,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final isAr = _isAr;
    final portal = _portal;
    Widget body;
    if (_error != null && portal == null) {
      body = AppErrorView(
        title: isAr ? 'تعذّر تحميل بوابتك' : 'Could not load your portal',
        error: _error!,
        onRetry: _load,
      );
    } else if (portal == null) {
      body = const AppLoadingView(summaryBlocks: 2, rows: 6);
    } else {
      final employee = portal['employee'] as Map<String, dynamic>? ?? const {};
      final payslips = (portal['payslips'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      final leave = portal['leave'] as Map<String, dynamic>? ?? const {};
      final balances = (leave['balances'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      final mine = (leave['mine'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      final kinds = (leave['kinds'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      final advance = portal['advance'] as Map<String, dynamic>? ?? const {};
      final bonuses = (portal['bonuses'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      final goals = (portal['goals'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(
              '${isAr ? 'أهلًا' : 'Hello'} ${employee['name'] ?? ''}',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: AppSpace.md),
            _card(
              isAr ? 'قسائم راتبي' : 'My payslips',
              Icons.receipt_long_outlined,
              [
                if (payslips.isEmpty)
                  Text(isAr ? 'لا قسائم بعد' : 'None yet')
                else
                  for (final p in payslips)
                    _row(
                      ltrIsolate('${p['month']}/${p['year']}'),
                      ltrIsolate(formatAmount((p['net_salary'] as num?) ?? 0)),
                      trailing: IconButton(
                        key: ValueKey('my-payslip-print-${p['id']}'),
                        tooltip: isAr ? 'طباعة القسيمة' : 'Print',
                        icon: const Icon(Icons.print_outlined),
                        onPressed: () => _printPayslip(p['id'] as int),
                      ),
                    ),
              ],
              key: const ValueKey('my-payslips'),
            ),
            _card(isAr ? 'إجازتي' : 'My leave', Icons.beach_access_outlined, [
              for (final b in balances)
                _row(
                  '${b['type']}',
                  b['balance'] == null
                      ? (isAr ? 'لا رصيد مضبوط' : 'no balance held')
                      : '${ltrIsolate(formatAmount(b['balance'] as num))} ${isAr ? 'يوم' : 'days'}',
                ),
              for (final l in mine)
                _row(
                  '${l['type']} · ${ltrIsolate('${l['start_date']}')} — ${ltrIsolate('${l['end_date']}')}',
                  switch (l['status']) {
                    'requested' => isAr ? 'ينتظر الاعتماد' : 'waiting',
                    'approved' => isAr ? 'معتمدة' : 'approved',
                    'rejected' => isAr ? 'مرفوض' : 'rejected',
                    _ => isAr ? 'ملغاة' : 'cancelled',
                  },
                  trailing: l['status'] == 'requested'
                      ? IconButton(
                          key: ValueKey('my-leave-cancel-${l['id']}'),
                          tooltip: isAr ? 'إلغاء الطلب' : 'Cancel request',
                          icon: const Icon(Icons.close),
                          onPressed: () => _cancel(l['id'] as int),
                        )
                      : null,
                ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton.icon(
                  key: const ValueKey('my-leave-request'),
                  onPressed: kinds.isEmpty ? null : () => _requestLeave(kinds),
                  icon: const Icon(Icons.add),
                  label: Text(isAr ? 'طلب إجازة' : 'Ask for leave'),
                ),
              ),
            ]),
            _card(
              isAr ? 'سلفتي' : 'My advance',
              Icons.account_balance_wallet_outlined,
              [
                _row(
                  isAr ? 'المتبقي عليّ' : 'What I owe',
                  ltrIsolate(formatAmount((advance['balance'] as num?) ?? 0)),
                ),
                for (final plan
                    in (advance['plans'] as List? ?? const [])
                        .cast<Map<String, dynamic>>())
                  _row(
                    '${isAr ? 'قسط شهري' : 'monthly'} ${ltrIsolate(formatAmount((plan['installment'] as num?) ?? 0))}',
                    '${isAr ? 'الباقي' : 'left'} ${ltrIsolate(formatAmount((plan['remaining'] as num?) ?? 0))}',
                  ),
              ],
            ),
            _card(
              isAr ? 'مكافآتي وهدفي' : 'My bonuses and goals',
              Icons.emoji_events_outlined,
              [
                for (final g in goals)
                  _row(
                    '${g['period_label'] ?? g['period']}',
                    '${ltrIsolate(formatAmount((g['value'] as num?) ?? 0))} / ${ltrIsolate(formatAmount((g['target'] as num?) ?? 0))}',
                  ),
                for (final b in bonuses)
                  _row(
                    '${isAr ? 'مكافأة' : 'Bonus'} ${ltrIsolate('${b['period_end'] ?? ''}')}',
                    '${ltrIsolate(formatAmount((b['amount'] as num?) ?? 0))} · ${b['status'] == 'paid' ? (isAr ? 'صُرفت' : 'paid') : (isAr ? 'معتمدة' : 'approved')}',
                  ),
                if (goals.isEmpty && bonuses.isEmpty)
                  Text(isAr ? 'لا شيء بعد' : 'Nothing yet'),
              ],
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(isAr ? 'بوابتي' : 'My portal')),
      body: body,
    );
  }
}

class _LeaveRequestDialog extends StatefulWidget {
  const _LeaveRequestDialog({required this.kinds, required this.isAr});
  final List<Map<String, dynamic>> kinds;
  final bool isAr;

  @override
  State<_LeaveRequestDialog> createState() => _LeaveRequestDialogState();
}

class _LeaveRequestDialogState extends State<_LeaveRequestDialog> {
  int? _type;
  final _start = TextEditingController();
  final _end = TextEditingController();
  final _notes = TextEditingController();

  @override
  void dispose() {
    for (final c in [_start, _end, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    return AlertDialog(
      title: Text(isAr ? 'طلب إجازة' : 'Ask for leave'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<int>(
              key: const ValueKey('my-leave-type'),
              initialValue: _type,
              decoration: InputDecoration(labelText: isAr ? 'النوع' : 'Kind'),
              items: [
                for (final k in widget.kinds)
                  DropdownMenuItem(
                    value: k['id'] as int,
                    child: Text('${k['name']}'),
                  ),
              ],
              onChanged: (v) => setState(() => _type = v),
            ),
            DateField(
              key: const ValueKey('my-leave-start'),
              controller: _start,
              label: isAr ? 'من' : 'From',
            ),
            DateField(
              key: const ValueKey('my-leave-end'),
              controller: _end,
              label: isAr ? 'إلى' : 'To',
            ),
            TextField(
              controller: _notes,
              decoration: InputDecoration(labelText: isAr ? 'ملاحظة' : 'Note'),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              isAr
                  ? 'يصل الطلب إلى المدير لاعتماده.'
                  : 'The manager approves it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isAr ? 'إلغاء' : 'Cancel'),
        ),
        FilledButton(
          key: const ValueKey('my-leave-send'),
          onPressed: () => Navigator.pop(context, {
            'type_id': _type,
            'start_date': _start.text.trim(),
            'end_date': _end.text.trim(),
            if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
          }),
          child: Text(isAr ? 'أرسل الطلب' : 'Send'),
        ),
      ],
    );
  }
}
