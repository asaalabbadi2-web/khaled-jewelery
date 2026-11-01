import 'package:flutter/material.dart';

import '../api_service.dart';
import '../services/payroll_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';

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
  });
  final ApiService api;
  final int employeeId;
  final bool isArabic;

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

  Widget _section(String title, List<Widget> children) => Card(
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
          if (missing.isNotEmpty)
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
          _section(isAr ? 'الراتب' : 'Salary', [
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
          _section(isAr ? 'العقد' : 'Contract', [
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
          _section(isAr ? 'الوثائق' : 'Documents', [
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
                        _DocumentTypesDialog(service: _service, isAr: isAr),
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
          _section(isAr ? 'آخر الرواتب' : 'Last payroll', [
            for (final p
                in (file['payroll'] as List? ?? const [])
                    .cast<Map<String, dynamic>>())
              _row(
                '${ltrIsolate('${p['month']}/${p['year']}')} · ${word(_statuses[p['status']], '${p['status']}')}',
                _money(p['net_salary']),
              ),
          ]),
          _section(isAr ? 'السلف' : 'Advances', [
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
          _section(isAr ? 'المكافآت' : 'Bonuses', [
            _row(
              isAr ? 'معتمدة غير مصروفة' : 'Approved unpaid',
              _money(bonuses['approved_unpaid']),
            ),
            _row(
              isAr ? 'المستحق في الدفاتر' : 'Owed in the books',
              _money(bonuses['owed_in_books']),
            ),
          ]),
          _section(isAr ? 'العهدة' : 'Custody', [
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
          _section(isAr ? 'الحسابات' : 'Accounts', [
            for (final a
                in (file['accounts'] as List? ?? const [])
                    .cast<Map<String, dynamic>>())
              _row(word(_roles[a['role']], '${a['name']}'), _money(a['cash'])),
          ]),
          _section(isAr ? 'المستخدم' : 'User', [
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
    TextField(
      key: ValueKey(key),
      controller: c,
      textDirection: TextDirection.ltr,
      decoration: InputDecoration(labelText: label, hintText: 'YYYY-MM-DD'),
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
class _DocumentTypesDialog extends StatefulWidget {
  const _DocumentTypesDialog({required this.service, required this.isAr});
  final PayrollService service;
  final bool isAr;

  @override
  State<_DocumentTypesDialog> createState() => _DocumentTypesDialogState();
}

class _DocumentTypesDialogState extends State<_DocumentTypesDialog> {
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
