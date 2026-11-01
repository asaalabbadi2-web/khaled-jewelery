import 'package:flutter/material.dart';

import '../widgets/date_field.dart';
import '../api_service.dart';
import '../services/payroll_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import 'account_statement_screen.dart';

/// An employee's file in one place (EMP-2): what is missing, his users, his
/// salary, his last payroll, his advances, his bonuses, his custody, his
/// accounts -- each as the server's owner of it says; nothing reckoned here.

const _roles = {
  'personal': ('الحساب الشخصي (السلف)', 'Personal (advances)'),
  'salary_payable': ('ذمة الرواتب', 'Salary payable'),
  'bonus_payable': ('ذمة المكافآت', 'Bonus payable'),
  'commission_payable': ('ذمة العمولات', 'Commission payable'),
  'eos_payable': ('ذمة نهاية الخدمة', 'End-of-service payable'),
};

const _statuses = {
  'pending': ('معلّق', 'Pending'),
  'approved': ('معتمد', 'Approved'),
  'paid': ('مصروف', 'Paid'),
  'cancelled': ('ملغى', 'Cancelled'),
};

class EmployeeFileView extends StatefulWidget {
  const EmployeeFileView({
    super.key,
    required this.api,
    required this.employeeId,
    this.isArabic = true,
    this.service,
    this.only,
    this.leading = const [],
  });
  final ApiService api;
  final int employeeId;
  final bool isArabic;

  /// The sections shown -- null: all of them (the hub's page shows a part).
  final Set<String>? only;

  /// Shown first in its list -- a part's own panel (HR-UX ط2: the salary
  /// panel, the advances panel), scrolled with the sections.
  final List<Widget> leading;

  /// For tests: a service that answers without a server.
  final PayrollService? service;

  @override
  State<EmployeeFileView> createState() => _EmployeeFileViewState();
}

class _EmployeeFileViewState extends State<EmployeeFileView> {
  late final PayrollService _service =
      widget.service ?? PayrollService(widget.api);
  Map<String, dynamic>? _file;
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
      final file = await _service.employeeFile(widget.employeeId);
      if (mounted) setState(() => _file = file);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  String _money(Object? v) => ltrIsolate(formatAmount((v as num?) ?? 0));

  List<Widget> _settlementRows(Map<String, dynamic> s) {
    final isAr = _isAr;
    final eos = s['eos'] as Map<String, dynamic>? ?? const {};
    final leave = s['leave'] as Map<String, dynamic>? ?? const {};
    final owed = s['owed_now'] as Map<String, dynamic>? ?? const {};
    return [
      _row(
        isAr ? 'مكافأة نهاية الخدمة' : 'End-of-service award',
        _money(eos['award']),
      ),
      if (((leave['amount'] as num?) ?? 0) > 0)
        _row(isAr ? 'بدل الإجازة' : 'Leave pay', _money(leave['amount'])),
      for (final role in const [
        'salary_payable',
        'bonus_payable',
        'commission_payable',
      ])
        if (((owed[role] as num?) ?? 0) != 0)
          _row(word(_roles[role], role), _money(owed[role])),
      if (((s['advance'] as num?) ?? 0) > 0)
        _row(
          isAr ? 'تُخصم السلف' : 'Advance deducted',
          '− ${_money(s['advance'])}',
        ),
      _row(isAr ? 'الصافي' : 'Net', _money(s['net'])),
    ];
  }

  String word((String, String)? pair, String fallback) =>
      pair == null ? fallback : (_isAr ? pair.$1 : pair.$2);

  /// A dialog's row sent, the file read again -- or the refusal said.
  Future<void> _edit(
    Widget dialog,
    Future<void> Function(Map<String, dynamic> row) send,
  ) async {
    final row = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => dialog,
    );
    if (row == null) return;
    try {
      await send(row);
      await _load();
      if (mounted) {
        AppFeedback.success(context, _isAr ? 'حُفظ' : 'Saved');
      }
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    }
  }

  /// Its sections shown: all, or the page's part (HR-UX ر2).
  bool _shows(String id) => widget.only == null || widget.only!.contains(id);

  Widget _section(String id, String title, List<Widget> children) =>
      !_shows(id) ? const SizedBox.shrink() : _card(title, children);

  Widget _card(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpace.xs),
          ...children,
        ],
      ),
    ),
  );

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(value, style: Theme.of(context).textTheme.bodyMedium),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final isAr = _isAr;
    final file = _file;
    if (_error != null && file == null) {
      return AppErrorView(
        title: isAr ? 'تعذّر تحميل الملف' : 'Could not load the file',
        error: _error!,
        onRetry: _load,
      );
    }
    if (file == null) return const AppLoadingView(summaryBlocks: 2, rows: 6);
    final tones = AppSemanticColors.of(context);
    final missing = (file['missing'] as List? ?? const []).cast<String>();
    final salary = file['salary'] as Map<String, dynamic>? ?? const {};
    final structure = salary['structure'] as Map<String, dynamic>?;
    final advances = file['advances'] as Map<String, dynamic>? ?? const {};
    final bonuses = file['bonuses'] as Map<String, dynamic>? ?? const {};
    final custody = file['custody'] as Map<String, dynamic>? ?? const {};
    String word((String, String)? pair, String fallback) =>
        pair == null ? fallback : (isAr ? pair.$1 : pair.$2);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppSpace.sm),
        children: [
          if (missing.isNotEmpty && _shows('missing'))
            Card(
              key: const ValueKey('employee-file-missing'),
              color: tones.warning.container,
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Text(
                  '${isAr ? 'ناقص' : 'Missing'}: ${missing.join('، ')}',
                  style: TextStyle(color: tones.warning.onContainer),
                ),
              ),
            ),
          ...widget.leading,
          _section('salary', isAr ? 'الراتب' : 'Salary', [
            if (structure == null)
              Text(isAr ? 'لا هيكل راتب' : 'No salary structure')
            else ...[
              _row(isAr ? 'الإجمالي' : 'Gross', _money(structure['gross'])),
              _row(
                isAr ? 'أساسي / سكن / نقل' : 'Basic / housing / transport',
                '${_money(structure['basic'])} / ${_money(structure['housing'])} / ${_money(structure['transport'])}',
              ),
              _row(
                isAr ? 'من تاريخ' : 'Since',
                ltrIsolate('${structure['effective_from']}'),
              ),
            ],
            _row(
              isAr ? 'خطة الاشتراك' : 'Scheme',
              '${salary['scheme'] ?? (isAr ? '—' : '—')}',
            ),
            _row(
              isAr ? 'طريقة الصرف' : 'Paid by',
              switch (salary['payment_method']) {
                'bank' => isAr ? 'تحويل بنكي' : 'Bank',
                'cash' => isAr ? 'نقد' : 'Cash',
                _ => '—',
              },
            ),
          ]),
          _section('contract', isAr ? 'العقد' : 'Contract', [
            if (file['contract'] case final Map<String, dynamic> c) ...[
              _row(
                isAr ? 'النوع' : 'Kind',
                c['kind'] == 'fixed'
                    ? (isAr ? 'محدد المدة' : 'Fixed-term')
                    : (isAr ? 'غير محدد المدة' : 'Open-ended'),
              ),
              _row(
                isAr ? 'من — إلى' : 'From — to',
                '${ltrIsolate('${c['start_date']}')} — ${c['end_date'] == null ? '—' : ltrIsolate('${c['end_date']}')}',
              ),
              if (c['probation_end'] != null)
                _row(
                  isAr ? 'نهاية التجربة' : 'Probation ends',
                  ltrIsolate('${c['probation_end']}'),
                ),
            ] else
              Text(isAr ? 'لا عقد مسجّل' : 'No contract'),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                key: const ValueKey('employee-file-add-contract'),
                onPressed: () => _edit(
                  _ContractDialog(isAr: isAr),
                  (row) => _service.addContract(widget.employeeId, row),
                ),
                icon: const Icon(Icons.add),
                label: Text(isAr ? 'عقد (أو تجديد)' : 'Contract (or renewal)'),
              ),
            ),
          ]),
          _section('documents', isAr ? 'الوثائق' : 'Documents', [
            for (final d
                in (file['documents'] as List? ?? const [])
                    .cast<Map<String, dynamic>>())
              _row(
                '${d['type']}${d['number'] == null ? '' : ' · ${ltrIsolate('${d['number']}')}'}',
                d['expires_on'] == null
                    ? '—'
                    : '${isAr ? 'تنتهي' : 'ends'} ${ltrIsolate('${d['expires_on']}')}',
              ),
            if ((file['documents'] as List? ?? const []).isEmpty)
              Text(isAr ? 'لا وثائق مسجّلة' : 'No documents'),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) =>
                        DocumentTypesDialog(service: _service, isAr: isAr),
                  ),
                  icon: const Icon(Icons.tune),
                  label: Text(
                    isAr ? 'أنواع الوثائق والتنبيه' : 'Kinds and alerts',
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('employee-file-add-document'),
                  onPressed: () async {
                    final kinds = await _service.documentTypes();
                    if (!mounted) return;
                    await _edit(
                      _DocumentDialog(
                        kinds: kinds
                            .where((k) => k['is_active'] != false)
                            .toList(),
                        isAr: isAr,
                      ),
                      (row) => _service.addDocument(widget.employeeId, row),
                    );
                  },
                  icon: const Icon(Icons.add),
                  label: Text(
                    isAr ? 'وثيقة (أو تجديد)' : 'Document (or renewal)',
                  ),
                ),
              ],
            ),
          ]),
          _section('leave', isAr ? 'الإجازات' : 'Leave', [
            for (final b
                in ((file['leave'] as Map<String, dynamic>?)?['balances']
                            as List? ??
                        const [])
                    .cast<Map<String, dynamic>>())
              _row(
                '${b['type']}',
                b['balance'] == null
                    ? (b['reason'] == 'no_hire_date'
                          ? (isAr ? 'لا تاريخ تعيين' : 'no hire date')
                          : (isAr ? 'غير مضبوط' : 'not set'))
                    : '${isAr ? 'الرصيد' : 'left'} ${ltrIsolate(formatAmount(b['balance'] as num))} ${isAr ? 'يوم' : 'days'}',
              ),
            for (final l
                in ((file['leave'] as Map<String, dynamic>?)?['recent']
                            as List? ??
                        const [])
                    .cast<Map<String, dynamic>>())
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${l['type']} · ${ltrIsolate('${l['start_date']}')} — ${ltrIsolate('${l['end_date']}')} (${l['days']})'
                      '${l['status'] == 'approved' ? '' : ' · ${_leaveStatus('${l['status']}', isAr)}'}',
                    ),
                  ),
                  // EMP-PORTAL-1: his request, the manager's to decide
                  if (l['status'] == 'requested') ...[
                    IconButton(
                      key: ValueKey('leave-approve-${l['id']}'),
                      tooltip: isAr ? 'اعتماد الطلب' : 'Approve',
                      icon: const Icon(Icons.check_circle_outline),
                      onPressed: () => _edit(
                        _ConfirmDialog(
                          text: isAr
                              ? 'اعتماد طلب الإجازة؟'
                              : 'Approve the request?',
                          isAr: isAr,
                        ),
                        (_) =>
                            _service.decideLeave(l['id'] as int, approve: true),
                      ),
                    ),
                    IconButton(
                      tooltip: isAr ? 'رفض الطلب' : 'Reject',
                      icon: const Icon(Icons.highlight_off),
                      onPressed: () => _edit(
                        _ConfirmDialog(
                          text: isAr
                              ? 'رفض طلب الإجازة؟'
                              : 'Reject the request?',
                          isAr: isAr,
                        ),
                        (_) => _service.decideLeave(
                          l['id'] as int,
                          approve: false,
                        ),
                      ),
                    ),
                  ],
                  if (l['status'] == 'approved' || l['status'] == 'requested')
                    IconButton(
                      tooltip: isAr ? 'إلغاء الإجازة' : 'Cancel leave',
                      icon: const Icon(Icons.event_busy_outlined),
                      onPressed: () => _edit(
                        _ConfirmDialog(
                          text: isAr
                              ? 'إلغاء هذه الإجازة؟'
                              : 'Cancel this leave?',
                          isAr: isAr,
                        ),
                        (_) => _service.cancelLeave(l['id'] as int),
                      ),
                    ),
                ],
              ),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) =>
                        LeaveTypesDialog(service: _service, isAr: isAr),
                  ).then((_) => _load()),
                  icon: const Icon(Icons.tune),
                  label: Text(
                    isAr ? 'أنواع الإجازات وأيامها' : 'Kinds and days',
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('employee-file-add-leave'),
                  onPressed: () async {
                    final kinds = await _service.leaveTypes();
                    if (!mounted) return;
                    await _edit(
                      _LeaveDialog(
                        kinds: kinds
                            .where((k) => k['is_active'] != false)
                            .toList(),
                        isAr: isAr,
                      ),
                      (row) => _service.recordLeave(widget.employeeId, row),
                    );
                  },
                  icon: const Icon(Icons.add),
                  label: Text(isAr ? 'تسجيل إجازة' : 'Record leave'),
                ),
              ],
            ),
          ]),
          _section('payroll', isAr ? 'آخر الرواتب' : 'Last payroll', [
            for (final p
                in (file['payroll'] as List? ?? const [])
                    .cast<Map<String, dynamic>>())
              _row(
                '${ltrIsolate('${p['month']}/${p['year']}')} · ${word(_statuses[p['status']], '${p['status']}')}',
                _money(p['net_salary']),
              ),
          ]),
          _section('advances', isAr ? 'السلف' : 'Advances', [
            _row(
              isAr ? 'رصيد حساب السلف' : 'Advance account',
              _money(advances['account_balance']),
            ),
            for (final plan
                in (advances['plans'] as List? ?? const [])
                    .cast<Map<String, dynamic>>())
              _row(
                '${isAr ? 'خطة' : 'Plan'} ${_money(plan['amount'])} · ${isAr ? 'القسط' : 'installment'} ${_money(plan['installment'])}',
                '${isAr ? 'الباقي' : 'left'} ${_money(plan['remaining'])}',
              ),
          ]),
          _section('bonuses', isAr ? 'المكافآت' : 'Bonuses', [
            _row(
              isAr ? 'معتمدة غير مصروفة' : 'Approved unpaid',
              _money(bonuses['approved_unpaid']),
            ),
            _row(
              isAr ? 'المستحق في الدفاتر' : 'Owed in the books',
              _money(bonuses['owed_in_books']),
            ),
          ]),
          _section('custody', isAr ? 'العهدة' : 'Custody', [
            if (custody.isEmpty)
              Text(isAr ? 'لا عهدة قائمة' : 'None open')
            else
              for (final row in custody.values.cast<Map<String, dynamic>>())
                _row(
                  '${row['safe']}',
                  (row['balances'] as Map<String, dynamic>).entries
                      .map(
                        (e) => e.key == 'cash'
                            ? _money(e.value)
                            : '${ltrIsolate(formatGrams(e.value as num))} ${isAr ? 'جم' : 'g'} ${e.key}',
                      )
                      .join(' · '),
                ),
          ]),
          _section('accounts', isAr ? 'الحسابات' : 'Accounts', [
            // HR-UX ط5: each opens its statement (the old screen's «كشف حساب»)
            for (final a
                in (file['accounts'] as List? ?? const [])
                    .cast<Map<String, dynamic>>())
              InkWell(
                key: ValueKey('employee-account-${a['role']}'),
                onTap: a['account_id'] is int
                    ? () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => AccountStatementScreen(
                            accountId: a['account_id'] as int,
                            accountName: '${a['name']}',
                          ),
                        ),
                      )
                    : null,
                child: Row(
                  children: [
                    Expanded(
                      child: _row(
                        word(_roles[a['role']], '${a['name']}'),
                        _money(a['cash']),
                      ),
                    ),
                    const Icon(Icons.chevron_left, size: 18),
                  ],
                ),
              ),
          ]),
          _section('end', isAr ? 'إنهاء الخدمة' : 'End of service', [
            if (file['termination'] case final Map<String, dynamic> t) ...[
              _row(
                isAr ? 'آخر يوم · السبب' : 'Last day · reason',
                '${ltrIsolate('${t['last_day']}')} · ${_reasonWord('${t['reason']}', isAr)}',
              ),
              ..._settlementRows(
                t['settlement'] as Map<String, dynamic>? ?? const {},
              ),
              _row(
                isAr ? 'الحالة' : 'Status',
                t['status'] == 'paid'
                    ? (isAr ? 'صُرفت' : 'paid')
                    : (isAr ? 'معتمدة غير مصروفة' : 'approved, unpaid'),
              ),
              if (t['status'] == 'approved')
                Wrap(
                  alignment: WrapAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () => _edit(
                        _ConfirmDialog(
                          text: isAr
                              ? 'إلغاء إنهاء الخدمة؟ يُعكس قيده ويعود الموظف نشطًا (ومستخدمه موقوف).'
                              : 'Cancel? Its entry is reversed and he is active again.',
                          isAr: isAr,
                        ),
                        (_) => _service.cancelTermination(t['id'] as int),
                      ),
                      icon: const Icon(Icons.undo),
                      label: Text(isAr ? 'إلغاء' : 'Cancel'),
                    ),
                    FilledButton.icon(
                      key: const ValueKey('employee-file-pay-termination'),
                      onPressed: () async {
                        final accounts = await _service.paymentAccounts();
                        if (!mounted) return;
                        await _edit(
                          _AccountDialog(accounts: accounts, isAr: isAr),
                          (row) => _service.payTermination(
                            t['id'] as int,
                            row['payment_account_id'] as int,
                          ),
                        );
                      },
                      icon: const Icon(Icons.payments_outlined),
                      label: Text(isAr ? 'صرف التسوية' : 'Pay'),
                    ),
                  ],
                ),
            ] else
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  key: const ValueKey('employee-file-terminate'),
                  onPressed: () async {
                    final row = await showDialog<Map<String, dynamic>>(
                      context: context,
                      builder: (_) => _TerminationDialog(
                        service: _service,
                        employeeId: widget.employeeId,
                        isAr: isAr,
                      ),
                    );
                    if (row == null || !mounted) return;
                    try {
                      final result = await _service.approveTermination(
                        widget.employeeId,
                        row,
                      );
                      await _load();
                      if (!mounted) return;
                      AppFeedback.success(
                        context,
                        isAr ? 'اعتُمد إنهاء الخدمة' : 'Approved',
                      );
                      if (result['warning'] case final String warning) {
                        AppFeedback.warning(context, warning);
                      }
                    } catch (e) {
                      if (mounted) AppFeedback.error(context, e.toString());
                    }
                  },
                  icon: const Icon(Icons.logout),
                  label: Text(isAr ? 'إنهاء الخدمة' : 'End of service'),
                ),
              ),
          ]),
          _section('access', isAr ? 'المستخدم' : 'User', [
            for (final u
                in (file['users'] as List? ?? const [])
                    .cast<Map<String, dynamic>>())
              _row(
                '${u['username']}',
                u['is_active'] == true
                    ? (isAr ? 'نشط' : 'active')
                    : (isAr ? 'موقوف' : 'stopped'),
              ),
            if ((file['users'] as List? ?? const []).isEmpty)
              Text(isAr ? 'لا حساب دخول' : 'No sign-in'),
          ]),
        ],
      ),
    );
  }
}

Widget _dateField(TextEditingController c, String label, String key) =>
    DateField(
      key: ValueKey(key),
      controller: c,
      label: label,
      pickerKey: ValueKey('$key-pick'),
    );

String? _text(TextEditingController c) =>
    c.text.trim().isEmpty ? null : c.text.trim();

class _ContractDialog extends StatefulWidget {
  const _ContractDialog({required this.isAr});
  final bool isAr;

  @override
  State<_ContractDialog> createState() => _ContractDialogState();
}

class _ContractDialogState extends State<_ContractDialog> {
  String _kind = 'fixed';
  final _start = TextEditingController();
  final _end = TextEditingController();
  final _probation = TextEditingController();

  @override
  void dispose() {
    for (final c in [_start, _end, _probation]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    return AlertDialog(
      title: Text(isAr ? 'عقد العمل' : 'Contract'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<String>(
              key: const ValueKey('contract-kind'),
              segments: [
                ButtonSegment(
                  value: 'fixed',
                  label: Text(isAr ? 'محدد المدة' : 'Fixed-term'),
                ),
                ButtonSegment(
                  value: 'indefinite',
                  label: Text(isAr ? 'غير محدد المدة' : 'Open-ended'),
                ),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
            _dateField(_start, isAr ? 'البداية' : 'Start', 'contract-start'),
            if (_kind == 'fixed')
              _dateField(_end, isAr ? 'النهاية' : 'End', 'contract-end'),
            _dateField(
              _probation,
              isAr
                  ? 'نهاية التجربة (حتى 180 يومًا)'
                  : 'Probation ends (≤ 180 days)',
              'contract-probation',
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
          key: const ValueKey('contract-save'),
          onPressed: () => Navigator.pop(context, {
            'kind': _kind,
            'start_date': _text(_start),
            'end_date': _kind == 'fixed' ? _text(_end) : null,
            'probation_end': _text(_probation),
          }),
          child: Text(isAr ? 'حفظ' : 'Save'),
        ),
      ],
    );
  }
}

class _DocumentDialog extends StatefulWidget {
  const _DocumentDialog({required this.kinds, required this.isAr});
  final List<Map<String, dynamic>> kinds;
  final bool isAr;

  @override
  State<_DocumentDialog> createState() => _DocumentDialogState();
}

class _DocumentDialogState extends State<_DocumentDialog> {
  int? _type;
  final _number = TextEditingController();
  final _issued = TextEditingController();
  final _expires = TextEditingController();

  @override
  void dispose() {
    for (final c in [_number, _issued, _expires]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    return AlertDialog(
      title: Text(isAr ? 'وثيقة' : 'Document'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<int>(
              key: const ValueKey('document-type'),
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
            TextField(
              key: const ValueKey('document-number'),
              controller: _number,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(labelText: isAr ? 'الرقم' : 'Number'),
            ),
            _dateField(_issued, isAr ? 'الإصدار' : 'Issued', 'document-issued'),
            _dateField(
              _expires,
              isAr ? 'الانتهاء' : 'Expires',
              'document-expires',
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
          key: const ValueKey('document-save'),
          onPressed: () => Navigator.pop(context, {
            'type_id': _type,
            'number': _text(_number),
            'issued_on': _text(_issued),
            'expires_on': _text(_expires),
          }),
          child: Text(isAr ? 'حفظ' : 'Save'),
        ),
      ],
    );
  }
}

/// The owner's kinds of documents and each one's alert days -- empty: no alert.
class DocumentTypesDialog extends StatefulWidget {
  const DocumentTypesDialog({
    super.key,
    required this.service,
    required this.isAr,
  });
  final PayrollService service;
  final bool isAr;

  @override
  State<DocumentTypesDialog> createState() => DocumentTypesDialogState();
}

class DocumentTypesDialogState extends State<DocumentTypesDialog> {
  List<Map<String, dynamic>>? _kinds;
  final Map<int, TextEditingController> _days = {};
  final _newName = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [..._days.values, _newName]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final kinds = await widget.service.documentTypes();
    if (!mounted) return;
    setState(() {
      _kinds = kinds;
      for (final k in kinds) {
        _days[k['id'] as int] ??= TextEditingController(
          text: k['alert_days'] == null ? '' : '${k['alert_days']}',
        );
      }
    });
  }

  Future<void> _save(Future<void> Function() send) async {
    try {
      await send();
      await _load();
      if (mounted) AppFeedback.success(context, widget.isAr ? 'حُفظ' : 'Saved');
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    final kinds = _kinds;
    return AlertDialog(
      title: Text(
        isAr ? 'أنواع الوثائق وأيام التنبيه' : 'Document kinds and alert days',
      ),
      content: SizedBox(
        width: 460,
        child: kinds == null
            ? const LinearProgressIndicator()
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isAr
                          ? 'أيام التنبيه قبل الانتهاء لكل نوع؛ الفارغ لا تنبيه له.'
                          : 'Days before the end for each kind; empty: no alert.',
                    ),
                    for (final k in kinds)
                      Row(
                        children: [
                          Expanded(child: Text('${k['name']}')),
                          SizedBox(
                            width: 90,
                            child: TextField(
                              key: ValueKey('document-type-days-${k['id']}'),
                              controller: _days[k['id'] as int],
                              textDirection: TextDirection.ltr,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                hintText: isAr ? 'أيام' : 'days',
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: isAr ? 'حفظ' : 'Save',
                            icon: const Icon(Icons.check),
                            onPressed: () => _save(
                              () => widget.service.saveDocumentType({
                                'alert_days':
                                    _days[k['id'] as int]!.text.trim().isEmpty
                                    ? null
                                    : _days[k['id'] as int]!.text.trim(),
                              }, id: k['id'] as int),
                            ),
                          ),
                        ],
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _newName,
                            decoration: InputDecoration(
                              labelText: isAr ? 'نوع جديد' : 'New kind',
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: isAr ? 'إضافة' : 'Add',
                          icon: const Icon(Icons.add),
                          onPressed: () => _save(() async {
                            await widget.service.saveDocumentType({
                              'name': _newName.text.trim(),
                            });
                            _newName.clear();
                          }),
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
          child: Text(isAr ? 'إغلاق' : 'Close'),
        ),
      ],
    );
  }
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({required this.text, required this.isAr});
  final String text;
  final bool isAr;

  @override
  Widget build(BuildContext context) => AlertDialog(
    content: Text(text),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(isAr ? 'رجوع' : 'Back'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, const <String, dynamic>{}),
        child: Text(isAr ? 'تأكيد' : 'Confirm'),
      ),
    ],
  );
}

class _LeaveDialog extends StatefulWidget {
  const _LeaveDialog({required this.kinds, required this.isAr});
  final List<Map<String, dynamic>> kinds;
  final bool isAr;

  @override
  State<_LeaveDialog> createState() => _LeaveDialogState();
}

class _LeaveDialogState extends State<_LeaveDialog> {
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
      title: Text(isAr ? 'تسجيل إجازة' : 'Record leave'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<int>(
              key: const ValueKey('leave-type'),
              initialValue: _type,
              decoration: InputDecoration(labelText: isAr ? 'النوع' : 'Kind'),
              items: [
                for (final k in widget.kinds)
                  DropdownMenuItem(
                    value: k['id'] as int,
                    child: Text(
                      '${k['name']}${k['paid'] == false ? (isAr ? ' (بدون أجر)' : ' (unpaid)') : ''}',
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _type = v),
            ),
            _dateField(_start, isAr ? 'من' : 'From', 'leave-start'),
            _dateField(_end, isAr ? 'إلى' : 'To', 'leave-end'),
            TextField(
              controller: _notes,
              decoration: InputDecoration(labelText: isAr ? 'ملاحظة' : 'Note'),
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
          key: const ValueKey('leave-save'),
          onPressed: () => Navigator.pop(context, {
            'type_id': _type,
            'start_date': _text(_start),
            'end_date': _text(_end),
            'notes': _text(_notes),
          }),
          child: Text(isAr ? 'سجّل' : 'Record'),
        ),
      ],
    );
  }
}

/// The owner's kinds of leave and their days -- empty: no balance held.
class LeaveTypesDialog extends StatefulWidget {
  const LeaveTypesDialog({
    super.key,
    required this.service,
    required this.isAr,
  });
  final PayrollService service;
  final bool isAr;

  @override
  State<LeaveTypesDialog> createState() => LeaveTypesDialogState();
}

class LeaveTypesDialogState extends State<LeaveTypesDialog> {
  List<Map<String, dynamic>>? _kinds;
  final Map<String, TextEditingController> _fields = {};

  static const _numbers = [
    'days_per_year',
    'longer_after_years',
    'longer_days_per_year',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _field(Map<String, dynamic> k, String name) =>
      _fields.putIfAbsent(
        '${k['id']}-$name',
        () => TextEditingController(text: k[name] == null ? '' : '${k[name]}'),
      );

  Future<void> _load() async {
    final kinds = await widget.service.leaveTypes();
    if (mounted) setState(() => _kinds = kinds);
  }

  Future<void> _save(Map<String, dynamic> k) async {
    try {
      await widget.service.saveLeaveType({
        for (final n in _numbers)
          n: _field(k, n).text.trim().isEmpty ? null : _field(k, n).text.trim(),
      }, id: k['id'] as int);
      await _load();
      if (mounted) AppFeedback.success(context, widget.isAr ? 'حُفظ' : 'Saved');
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    }
  }

  Widget _number(Map<String, dynamic> k, String name, String label) => Expanded(
    child: TextField(
      key: ValueKey('leave-type-$name-${k['id']}'),
      controller: _field(k, name),
      textDirection: TextDirection.ltr,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    final kinds = _kinds;
    return AlertDialog(
      title: Text(isAr ? 'أنواع الإجازات وأيامها' : 'Leave kinds and days'),
      content: SizedBox(
        width: 520,
        child: kinds == null
            ? const LinearProgressIndicator()
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isAr
                          ? 'الفارغ غير مضبوط فلا يُفحص رصيده. السنوية تتراكم من تاريخ التعيين؛ غيرها لكل سنة ميلادية.'
                          : 'Empty: no balance held. An accruing kind earns from the hire date; others per calendar year.',
                    ),
                    for (final k in kinds) ...[
                      const Divider(),
                      Text(
                        '${k['name']} · ${k['paid'] == true ? (isAr ? 'بأجر' : 'paid') : (isAr ? 'بدون أجر' : 'unpaid')}'
                        '${k['accrues'] == true ? (isAr ? ' · تتراكم' : ' · accrues') : ''}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Row(
                        children: [
                          _number(
                            k,
                            'days_per_year',
                            isAr ? 'أيام السنة' : 'Days a year',
                          ),
                          if (k['accrues'] == true) ...[
                            const SizedBox(width: AppSpace.sm),
                            _number(
                              k,
                              'longer_after_years',
                              isAr ? 'بعد سنوات' : 'After years',
                            ),
                            const SizedBox(width: AppSpace.sm),
                            _number(
                              k,
                              'longer_days_per_year',
                              isAr ? 'أيامها بعدها' : 'Days after',
                            ),
                          ],
                          IconButton(
                            tooltip: isAr ? 'حفظ' : 'Save',
                            icon: const Icon(Icons.check),
                            onPressed: () => _save(k),
                          ),
                        ],
                      ),
                    ],
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

const _reasons = {
  'employer_ended': ('إنهاء من صاحب العمل', 'Ended by the employer'),
  'contract_end': ('انتهاء العقد', 'Contract ended'),
  'mutual': ('بالاتفاق', 'By agreement'),
  'resignation': ('استقالة (المادة 85)', 'Resignation (art. 85)'),
  'art_80': ('فصل (المادة 80)', 'Dismissal (art. 80)'),
  'death': ('وفاة', 'Death'),
};

String _reasonWord(String reason, bool isAr) => _reasons[reason] == null
    ? reason
    : (isAr ? _reasons[reason]!.$1 : _reasons[reason]!.$2);

class _AccountDialog extends StatefulWidget {
  const _AccountDialog({required this.accounts, required this.isAr});
  final List<Map<String, dynamic>> accounts;
  final bool isAr;

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  int? _account;

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    return AlertDialog(
      title: Text(isAr ? 'صرف التسوية من' : 'Pay from'),
      content: DropdownButtonFormField<int>(
        key: const ValueKey('termination-account'),
        initialValue: _account,
        isExpanded: true,
        items: [
          for (final a in widget.accounts)
            DropdownMenuItem(
              value: a['id'] as int,
              child: Text('${a['name']}'),
            ),
        ],
        onChanged: (v) => setState(() => _account = v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isAr ? 'إلغاء' : 'Cancel'),
        ),
        FilledButton(
          onPressed: _account == null
              ? null
              : () => Navigator.pop(context, {'payment_account_id': _account}),
          child: Text(isAr ? 'اصرف' : 'Pay'),
        ),
      ],
    );
  }
}

/// The last day and the reason, the settlement shown before it is approved.
class _TerminationDialog extends StatefulWidget {
  const _TerminationDialog({
    required this.service,
    required this.employeeId,
    required this.isAr,
  });
  final PayrollService service;
  final int employeeId;
  final bool isAr;

  @override
  State<_TerminationDialog> createState() => _TerminationDialogState();
}

class _TerminationDialogState extends State<_TerminationDialog> {
  String? _reason;
  final _lastDay = TextEditingController();
  Map<String, dynamic>? _preview;
  String? _refusal;

  @override
  void dispose() {
    _lastDay.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _row => {
    'reason': _reason,
    'last_day': _text(_lastDay),
  };

  Future<void> _reckon() async {
    setState(() {
      _preview = null;
      _refusal = null;
    });
    try {
      final preview = await widget.service.previewTermination(
        widget.employeeId,
        _row,
      );
      if (mounted) setState(() => _preview = preview);
    } catch (e) {
      if (mounted) setState(() => _refusal = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    final preview = _preview;
    String money(Object? v) => ltrIsolate(formatAmount((v as num?) ?? 0));
    Widget line(String label, Object? v) => Row(
      children: [
        Expanded(child: Text(label)),
        Text(money(v)),
      ],
    );
    return AlertDialog(
      title: Text(isAr ? 'إنهاء الخدمة' : 'End of service'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                key: const ValueKey('termination-reason'),
                initialValue: _reason,
                decoration: InputDecoration(
                  labelText: isAr ? 'السبب' : 'Reason',
                ),
                items: [
                  for (final e in _reasons.entries)
                    DropdownMenuItem(
                      value: e.key,
                      child: Text(isAr ? e.value.$1 : e.value.$2),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _reason = v;
                  _preview = null;
                }),
              ),
              _dateField(
                _lastDay,
                isAr ? 'آخر يوم عمل' : 'Last day',
                'termination-last-day',
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  key: const ValueKey('termination-reckon'),
                  onPressed: _reckon,
                  child: Text(isAr ? 'احسب التسوية' : 'Reckon'),
                ),
              ),
              if (_refusal != null)
                Text(
                  _refusal!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (preview != null) ...[
                const Divider(),
                line(
                  isAr ? 'مكافأة نهاية الخدمة' : 'Award',
                  (preview['eos'] as Map<String, dynamic>)['award'],
                ),
                line(
                  isAr ? 'بدل الإجازة' : 'Leave pay',
                  (preview['leave'] as Map<String, dynamic>)['amount'],
                ),
                line(isAr ? 'تُخصم السلف' : 'Advance', preview['advance']),
                line(isAr ? 'الصافي' : 'Net', preview['net']),
                if ((preview['custody'] as Map?)?.isNotEmpty == true)
                  Text(
                    isAr
                        ? 'عهدته قائمة: تُسلَّم أو تُسوّى.'
                        : 'His custody is open.',
                    style: TextStyle(
                      color: AppSemanticColors.of(context).warning.fg,
                    ),
                  ),
                Text(
                  isAr
                      ? 'راتب الشهر الأخير يُصرف في مسيره، مجزّأً بآخر يوم.'
                      : 'His last month is paid by its run, prorated.',
                ),
              ],
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
          key: const ValueKey('termination-approve'),
          onPressed: preview == null
              ? null
              : () => Navigator.pop(context, _row),
          child: Text(isAr ? 'اعتماد' : 'Approve'),
        ),
      ],
    );
  }
}

/// A leave's state, said (EMP-PORTAL-1: a request waits for the manager).
String _leaveStatus(String status, bool isAr) => switch (status) {
  'requested' => isAr ? 'طلب ينتظر الاعتماد' : 'requested',
  'rejected' => isAr ? 'مرفوض' : 'rejected',
  'cancelled' => isAr ? 'ملغاة' : 'cancelled',
  _ => status,
};
