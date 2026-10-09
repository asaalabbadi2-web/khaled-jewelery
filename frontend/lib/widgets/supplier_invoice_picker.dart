import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';

/// The invoices a supplier payment is for (VOUCHER-ATTR-1, the owner 9 Oct
/// 2026): the supplier's open invoices, oldest first, each with what it still
/// owes; the employee ticks the ones the payment is for. How the payment
/// spreads over them -- oldest first, each taking what it owes, the rest on the
/// supplier's account -- is the server's plan ([plan]); this only shows it.
class SupplierInvoicePicker extends StatelessWidget {
  /// Each: invoice_id, invoice_number, date, open_cash, open_main_karat.
  final List<Map<String, dynamic>> invoices;
  final Set<int> chosen;
  final Map<String, dynamic>? plan;
  final bool loading;
  final String Function(double) formatCash;
  final ValueChanged<int> onToggle;

  /// Fills the payment with what the chosen invoices owe in cash.
  final VoidCallback? onFill;

  /// A gold payment for gold not yet bought: asked only when no invoice is.
  final bool showAdvance;
  final bool advance;
  final ValueChanged<bool>? onAdvance;

  const SupplierInvoicePicker({
    super.key,
    required this.invoices,
    required this.chosen,
    required this.plan,
    required this.loading,
    required this.formatCash,
    required this.onToggle,
    this.onFill,
    this.showAdvance = false,
    this.advance = false,
    this.onAdvance,
  });

  static double _num(Object? v) => v is num ? v.toDouble() : 0.0;

  static String _day(Object? iso) {
    final s = '${iso ?? ''}';
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  static String _grams(double w) => '${w.toStringAsFixed(3)} جم';

  /// The invoices oldest first -- the order the payment fills them in.
  List<Map<String, dynamic>> get _ordered => [...invoices]
    ..sort((a, b) {
      final byDate = '${a['date'] ?? ''}'.compareTo('${b['date'] ?? ''}');
      if (byDate != 0) return byDate;
      return _num(a['invoice_id']).compareTo(_num(b['invoice_id']));
    });

  double get chosenOpenCash => invoices
      .where((r) => chosen.contains(_num(r['invoice_id']).toInt()))
      .fold(0.0, (s, r) => s + _num(r['open_cash']));

  String _share(int id) {
    final p = plan;
    if (p == null) return '…';
    final cash = (p['cash'] as List? ?? const [])
        .where((s) => _num((s as Map)['invoice_id']).toInt() == id)
        .fold(0.0, (t, s) => t + _num((s as Map)['amount']));
    final gold = (p['gold'] as List? ?? const [])
        .where((s) => _num((s as Map)['invoice_id']).toInt() == id)
        .map((s) => s as Map)
        .toList();
    final parts = [
      if (cash > 0) formatCash(cash),
      for (final g in gold)
        '${_grams(_num(g['weight']))} عيار ${_num(g['karat']).toStringAsFixed(0)}',
    ];
    return parts.isEmpty
        ? 'لا يُنسب لها شيء — غطّت ما قبلها الدفعة'
        : 'يُنسب لها: ${parts.join(' • ')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final rows = _ordered;
    final p = plan;
    final cashLeft = _num(p?['cash_on_account']);
    final goldLeft = _num(p?['gold_on_account_main_karat']);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.receipt_long, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'لأي فواتير هذه الدفعة؟',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'اختر الفواتير: تُسدَّد الأقدم فالأحدث، كلٌّ بما بقي عليه، '
              'وما زاد يبقى على حساب المورد.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (loading)
              const LinearProgressIndicator(minHeight: 2)
            else if (rows.isEmpty)
              Text(
                'لا توجد فواتير مفتوحة لهذا المورد — الدفعة على حسابه.',
                style: theme.textTheme.bodyMedium,
              )
            else
              for (final row in rows) _row(context, row),
            if (chosen.isNotEmpty) ...[
              const Divider(),
              Container(
                key: const Key('invoice-on-account'),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (cashLeft > 0 || goldLeft > 0)
                      ? tones.warning.container
                      : tones.ready.container,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  p == null
                      ? 'يُحسب التوزيع…'
                      : (cashLeft > 0 || goldLeft > 0)
                      ? 'يبقى على حساب المورد: ${[
                          if (cashLeft > 0) formatCash(cashLeft),
                          if (goldLeft > 0) '${_grams(goldLeft)} بالعيار الرئيسي',
                        ].join(' و')}'
                      : 'تُوزَّع الدفعة كلها على الفواتير المختارة',
                  style: TextStyle(
                    color: (cashLeft > 0 || goldLeft > 0)
                        ? tones.warning.onContainer
                        : tones.ready.onContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onFill != null && chosenOpenCash > 0)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const Key('fill-from-invoices'),
                    onPressed: onFill,
                    icon: const Icon(Icons.download_done),
                    label: Text(
                      'املأ المبلغ بما تبقّى عليها (${formatCash(chosenOpenCash)})',
                    ),
                  ),
                ),
            ] else if (showAdvance)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: advance,
                onChanged: onAdvance == null
                    ? null
                    : (v) => onAdvance!(v ?? false),
                title: const Text('دفعة ذهب مقدّمة (لذهب لم يُشترَ بعد)'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, Map<String, dynamic> row) {
    final theme = Theme.of(context);
    final id = _num(row['invoice_id']).toInt();
    final isChosen = chosen.contains(id);
    final openCash = _num(row['open_cash']);
    final openGold = _num(row['open_main_karat']);
    final owes = [
      if (openCash > 0) formatCash(openCash),
      if (openGold > 0) _grams(openGold),
    ].join(' • ');
    return CheckboxListTile(
      key: Key('invoice-pick-$id'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: isChosen,
      onChanged: (_) => onToggle(id),
      title: Text(
        '${row['invoice_number'] ?? '#$id'} — ${_day(row['date'])}',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('متبقٍ عليها: $owes', style: theme.textTheme.bodySmall),
          if (isChosen)
            KeyedSubtree(
              key: Key('invoice-share-$id'),
              child: Text(
                _share(id),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
