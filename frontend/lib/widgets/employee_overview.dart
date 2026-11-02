import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../utils/month_names.dart';

/// His gold custody as the boards say it -- «11.800 جم 21» each karat, the
/// grams before their word, no mark of direction between (one place, for the
/// employees' table and his page). [balances]: the server's, '21k' -> grams.
String goldCustodyText(Map<String, dynamic> balances, {bool isAr = true}) =>
    balances.isEmpty
    ? '—'
    : balances.entries
          .map(
            (e) =>
                '${formatGrams(e.value as num)} ${isAr ? 'جم' : 'g'} ${e.key.replaceAll(RegExp(r'[^0-9]'), '')}',
          )
          .join(' · ');

/// His page's «نظرة عامة» as the approved board 2 draws it (HR-UX ط6; the
/// owner, 2 Nov 2026): what his file lacks, each a «+» to where it is filled;
/// then four cards -- his last salaries, what he owes and is owed, his leave,
/// his contract and documents. Every figure is his file's (services/
/// employee_file): nothing reckoned here.
class EmployeeOverview extends StatelessWidget {
  const EmployeeOverview({
    super.key,
    required this.file,
    required this.isAr,
    required this.onGo,
  });

  final Map<String, dynamic> file;
  final bool isAr;

  /// Another part of his page: 'data', 'salary', 'leave', 'contract', 'end'.
  final void Function(String part) onGo;

  /// Where each missing item is filled -- by its key, the server's.
  static String partOf(String key) => switch (key) {
    'structure' || 'payment_method' || 'iban' => 'salary',
    'termination_date' => 'end',
    _ => 'data',
  };

  String _money(Object? v) => ltrIsolate(formatAmount((v as num?) ?? 0));

  Widget _card(
    BuildContext context,
    String key,
    String title,
    List<Widget> children,
  ) {
    final theme = Theme.of(context);
    return Container(
      key: ValueKey(key),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          ...children,
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, Widget value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        value,
      ],
    ),
  );

  Widget _missing(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final items = (file['missing_items'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    if (items.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('employee-overview-missing'),
      padding: const EdgeInsets.all(AppSpace.lg),
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      decoration: BoxDecoration(
        color: tones.warning.container,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpace.md,
        runSpacing: AppSpace.sm,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isAr
                    ? 'يكمل ملفه بـ${ltrIsolate('${items.length}')} ${items.length == 1 ? 'خطوة' : 'خطوات'}'
                    : 'His file: ${items.length} to complete',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: tones.warning.onContainer,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                isAr
                    ? 'بدونها لا يُحسب مخصص نهاية الخدمة ولا رصيد الإجازة، ولا يدخل المسير'
                    : 'Without them no end-of-service provision, no leave balance, no run',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tones.warning.onContainer,
                ),
              ),
            ],
          ),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              for (final item in items)
                ActionChip(
                  key: ValueKey('employee-overview-add-${item['key']}'),
                  label: Text('+ ${item['label']}'),
                  onPressed: () => onGo(partOf('${item['key']}')),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// His salary in force and how he is paid (the owner, 2 Nov 2026: «لماذا
  /// أُزيل قسم بيانات الراتب؟» -- the board's overview had none, his page did).
  Widget _salary(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final salary = file['salary'] as Map<String, dynamic>? ?? const {};
    final employee = file['employee'] as Map<String, dynamic>? ?? const {};
    final s = salary['structure'] as Map<String, dynamic>?;
    String way(String? m) => switch (m) {
      'bank' => isAr ? 'تحويل بنكي' : 'bank transfer',
      'cash' => isAr ? 'نقدًا' : 'cash',
      _ => isAr ? 'لم تُحدَّد' : 'not set',
    };
    final splitMethod = employee['split_method'] as String?;
    final split = splitMethod == null
        ? null
        : isAr
        ? '${_money(employee['split_amount'])} ${splitMethod == 'bank' ? 'تحويلًا' : 'نقدًا'}، والباقي ${splitMethod == 'bank' ? 'نقدًا' : 'تحويلًا'}'
        : '${_money(employee['split_amount'])} by $splitMethod, the rest the other way';
    return _card(
      context,
      'employee-overview-salary',
      isAr ? 'الراتب' : 'Salary',
      [
        if (s == null)
          Text(
            isAr
                ? 'لا راتب ساري: لا يدخل المسير حتى يُضاف'
                : 'None in force: not in the run',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tones.warning.fg,
            ),
          )
        else ...[
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: _money(s['gross']),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                TextSpan(text: isAr ? '  ر.س شهريًا' : '  SAR a month'),
              ],
            ),
          ),
          Text(
            '${isAr ? 'ساري من' : 'Since'} ${ltrIsolate('${s['effective_from']}')}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpace.sm),
          for (final (key, label) in [
            ('basic', isAr ? 'الأساسي' : 'Basic'),
            ('housing', isAr ? 'السكن' : 'Housing'),
            ('transport', isAr ? 'النقل' : 'Transport'),
            ('other_allowances', isAr ? 'بدلات أخرى' : 'Other'),
          ])
            if (((s[key] as num?) ?? 0) != 0)
              _row(
                context,
                label,
                Text(_money(s[key]), style: theme.textTheme.bodyMedium),
              ),
        ],
        _row(
          context,
          isAr ? 'يُصرف' : 'Paid by',
          Text(
            split ?? way(salary['payment_method'] as String?),
            style: theme.textTheme.bodyMedium,
          ),
        ),
        _row(
          context,
          isAr ? 'التأمينات' : 'Contributions',
          Text(
            '${salary['scheme'] ?? (isAr ? 'بلا اشتراك' : 'none')}',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton(
            key: const ValueKey('employee-overview-salary-go'),
            onPressed: () => onGo('salary'),
            child: Text(
              s == null
                  ? (isAr ? 'أضف الراتب' : 'Add the salary')
                  : (isAr
                        ? 'تغيير الراتب والصرف'
                        : 'Change salary and payment'),
            ),
          ),
        ),
      ],
    );
  }

  /// His last six salaries: each its net above its bar, its month under it,
  /// the latest gold; a bar opens his salary part (the owner: the chart said
  /// nothing).
  Widget _salaries(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final lines =
        (file['payroll'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .toList()
          ..sort(
            (a, b) => ((a['year'] as int) * 100 + (a['month'] as int))
                .compareTo((b['year'] as int) * 100 + (b['month'] as int)),
          );
    final last = lines.length > 6 ? lines.sublist(lines.length - 6) : lines;
    double net(Map<String, dynamic> l) =>
        ((l['net_salary'] as num?) ?? 0).toDouble();
    final top = last.fold<double>(0, (m, l) => net(l) > m ? net(l) : m);
    String status(Object? s) => switch (s) {
      'paid' => isAr ? 'مصروف' : 'paid',
      'approved' => isAr ? 'معتمد' : 'approved',
      _ => isAr ? 'مسودة' : 'draft',
    };
    return _card(
      context,
      'employee-overview-salaries',
      isAr ? 'آخر الرواتب' : 'Last salaries',
      [
        if (last.isEmpty)
          Text(
            isAr ? 'لا رواتب بعد' : 'None yet',
            style: theme.textTheme.bodyMedium,
          )
        else ...[
          SizedBox(
            height: 170,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (i, l) in last.indexed) ...[
                  if (i > 0) const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Tooltip(
                      message:
                          '${monthName(l['month'] as int, isAr: isAr)} ${l['year']} · ${formatAmount(net(l))} · ${status(l['status'])}'
                          '${l['voucher_number'] == null ? '' : ' · ${l['voucher_number']}'}',
                      child: InkWell(
                        key: ValueKey('employee-overview-bar-${l['id']}'),
                        onTap: () => onGo('salary'),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                formatAmount(net(l)),
                                textDirection: TextDirection.ltr,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: i == last.length - 1
                                      ? FontWeight.w800
                                      : null,
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Container(
                              height: top <= 0 ? 4 : 4 + 96 * (net(l) / top),
                              decoration: BoxDecoration(
                                color: i == last.length - 1
                                    ? tones.gold.fg
                                    : tones.gold.container,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(AppRadius.chip),
                                ),
                              ),
                            ),
                            const SizedBox(height: AppSpace.xs),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                monthName(l['month'] as int, isAr: isAr),
                                style: theme.textTheme.labelSmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            isAr
                ? 'آخرها ${monthName(last.last['month'] as int)} ${_money(last.last['net_salary'])} · ${status(last.last['status'])}'
                      '${last.length > 1 ? ' — قبله ${monthName(last[last.length - 2]['month'] as int)} ${_money(last[last.length - 2]['net_salary'])}' : ''}'
                : 'Last: ${monthName(last.last['month'] as int, isAr: false)} ${_money(last.last['net_salary'])}',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ],
    );
  }

  Widget _owes(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final advances = file['advances'] as Map<String, dynamic>? ?? const {};
    final bonuses = file['bonuses'] as Map<String, dynamic>? ?? const {};
    final custody = file['custody'] as Map<String, dynamic>? ?? const {};
    final gold =
        (custody['gold'] as Map<String, dynamic>?)?['balances']
            as Map<String, dynamic>? ??
        const {};
    final advance = (advances['account_balance'] as num?) ?? 0;
    final goldAdvance = advances['gold'] as Map<String, dynamic>? ?? const {};
    final bold = theme.textTheme.titleSmall;
    return _card(
      context,
      'employee-overview-owes',
      isAr ? 'ما له وما عليه' : 'Owes and is owed',
      [
        _row(
          context,
          isAr ? 'سلف عليه' : 'Advances he owes',
          Text(
            _money(advance),
            style: bold?.copyWith(color: advance > 0 ? tones.blocked.fg : null),
          ),
        ),
        if (goldAdvance.isNotEmpty)
          _row(
            context,
            isAr ? 'سلفة ذهب عليه' : 'Gold advance he owes',
            Text(
              goldCustodyText(goldAdvance, isAr: isAr),
              style: bold?.copyWith(color: tones.blocked.fg),
            ),
          ),
        _row(
          context,
          isAr ? 'رواتب مستحقة له' : 'Salary owed to him',
          Text(_money(file['salary_owed']), style: bold),
        ),
        _row(
          context,
          isAr ? 'مكافآت معتمدة' : 'Approved bonuses',
          Text(_money(bonuses['approved_unpaid']), style: bold),
        ),
        if (((bonuses['approved_unpaid'] as num?) ?? 0) !=
            ((bonuses['owed_in_books'] as num?) ?? 0))
          _row(
            context,
            isAr ? 'في الدفاتر' : 'In the books',
            Text(
              _money(bonuses['owed_in_books']),
              style: theme.textTheme.bodySmall?.copyWith(
                color: tones.warning.fg,
              ),
            ),
          ),
        _row(
          context,
          isAr ? 'عهدة ذهب' : 'Gold custody',
          Text(goldCustodyText(gold, isAr: isAr), style: bold),
        ),
      ],
    );
  }

  Widget _leave(BuildContext context) {
    final theme = Theme.of(context);
    final balances =
        ((file['leave'] as Map<String, dynamic>?)?['balances'] as List? ??
                const [])
            .cast<Map<String, dynamic>>();
    return _card(
      context,
      'employee-overview-leave',
      isAr ? 'الإجازات' : 'Leave',
      [
        if (balances.isEmpty)
          Text(isAr ? 'لا أنواع إجازات مضبوطة' : 'No leave kinds set'),
        for (final b in balances)
          _row(
            context,
            '${b['type']}',
            Text(
              b['balance'] == null
                  ? (isAr ? 'لا رصيد مضبوط' : 'not set')
                  : '${ltrIsolate(formatAmount(b['balance'] as num))} ${isAr ? 'يوم' : 'days'}',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        const SizedBox(height: AppSpace.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton(
            key: const ValueKey('employee-overview-leave-go'),
            onPressed: () => onGo('leave'),
            child: Text(isAr ? 'تسجيل إجازة' : 'Record leave'),
          ),
        ),
      ],
    );
  }

  Widget _contract(BuildContext context) {
    final theme = Theme.of(context);
    final contract = file['contract'] as Map<String, dynamic>?;
    final documents = (file['documents'] as List? ?? const []).length;
    return _card(
      context,
      'employee-overview-contract',
      isAr ? 'العقد والوثائق' : 'Contract and documents',
      [
        _row(
          context,
          isAr ? 'العقد' : 'Contract',
          Text(
            contract == null
                ? (isAr ? 'لا عقد مسجّل' : 'None')
                : '${contract['kind'] == 'fixed' ? (isAr ? 'محدد المدة' : 'Fixed-term') : (isAr ? 'غير محدد المدة' : 'Open-ended')}'
                      '${contract['end_date'] == null ? '' : ' · ${ltrIsolate('${contract['end_date']}')}'}',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        _row(
          context,
          isAr ? 'الوثائق' : 'Documents',
          Text(
            documents == 0
                ? (isAr ? 'لا وثائق' : 'None')
                : ltrIsolate('$documents'),
            style: theme.textTheme.bodyMedium,
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Wrap(
          spacing: AppSpace.sm,
          children: [
            OutlinedButton(
              key: const ValueKey('employee-overview-contract-go'),
              onPressed: () => onGo('contract'),
              child: Text(isAr ? '+ عقد' : '+ Contract'),
            ),
            OutlinedButton(
              onPressed: () => onGo('contract'),
              child: Text(isAr ? '+ وثيقة' : '+ Document'),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cards = [
      _salary(context),
      _salaries(context),
      _owes(context),
      _leave(context),
      _contract(context),
    ];
    return ListView(
      padding: const EdgeInsets.all(AppSpace.sm),
      children: [
        _missing(context),
        LayoutBuilder(
          builder: (context, box) {
            final columns = box.maxWidth >= 720 ? 2 : 1;
            final width =
                (box.maxWidth - AppSpace.md * (columns - 1)) / columns;
            return Wrap(
              spacing: AppSpace.md,
              runSpacing: AppSpace.md,
              children: [
                for (final card in cards) SizedBox(width: width, child: card),
              ],
            );
          },
        ),
      ],
    );
  }
}
