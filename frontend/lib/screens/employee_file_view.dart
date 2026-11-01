import 'package:flutter/material.dart';

import '../api_service.dart';
import '../services/payroll_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
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
