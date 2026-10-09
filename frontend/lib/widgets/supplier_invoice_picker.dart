import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';

/// The invoices a supplier payment is for (VOUCHER-ATTR-1, the owner 9 Oct
/// 2026): the supplier's open invoices, oldest first, each with what it still
/// owes; the employee ticks the ones the payment is for. How the payment
/// spreads over them -- oldest first, each taking what it owes, the rest on the
/// supplier's account -- is the server's plan ([plan]); this only shows it.
class SupplierInvoicePicker extends StatefulWidget {
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

  /// The card never grows past this height (the owner, 10 Oct 2026): the screen
  /// passes the party card's height beside it, and a long list scrolls inside
  /// the card instead of stretching the page. Null: a fixed fallback.
  final double? maxHeight;

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
    this.maxHeight,
  });

  /// Above this many invoices the list can be searched by number.
  static const searchFrom = 6;

  /// The least room the card is given -- only to keep it from collapsing; the
  /// rule is the party card's height, however short.
  static const minCardHeight = 160.0;
  static const fallbackCardHeight = 380.0;

  @override
  State<SupplierInvoicePicker> createState() => _SupplierInvoicePickerState();
}

class _SupplierInvoicePickerState extends State<SupplierInvoicePicker> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get invoices => widget.invoices;
  Set<int> get chosen => widget.chosen;
  Map<String, dynamic>? get plan => widget.plan;
  String Function(double) get formatCash => widget.formatCash;


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

  List<Map<String, dynamic>> get _shown {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _ordered;
    return _ordered
        .where((r) => '${r['invoice_number'] ?? r['invoice_id']}'.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final all = _ordered;
    final rows = _shown;
    final p = plan;
    final cashLeft = _num(p?['cash_on_account']);
    final goldLeft = _num(p?['gold_on_account_main_karat']);
    final cap = (widget.maxHeight ?? SupplierInvoicePicker.fallbackCardHeight)
        .clamp(SupplierInvoicePicker.minCardHeight, double.infinity)
        .toDouble();

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: cap),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── fixed head ──
              Row(
                children: [
                  Tooltip(
                    message: 'تُسدَّد الأقدم فالأحدث، كلٌّ بما بقي عليه، وما زاد يبقى على حساب المورد.',
                    child: Icon(Icons.receipt_long, color: scheme.primary, size: 20),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'لأي فواتير هذه الدفعة؟',
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (all.isNotEmpty)
                    Text(
                      'مختار ${chosen.length} من ${all.length}',
                      key: const Key('invoice-count'),
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
              if (all.length > SupplierInvoicePicker.searchFrom) ...[
                const SizedBox(height: 6),
                SizedBox(
                  height: 36,
                  child: TextField(
                    key: const Key('invoice-search'),
                    controller: _search,
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: 'ابحث برقم الفاتورة',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: () {
                                _search.clear();
                                setState(() => _query = '');
                              },
                            ),
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 4),

              // ── the list: takes what room is left, and scrolls inside it ──
              if (widget.loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(minHeight: 2),
                )
              else if (all.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'لا توجد فواتير مفتوحة لهذا المورد — الدفعة على حسابه.',
                    style: theme.textTheme.bodyMedium,
                  ),
                )
              else if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('لا فاتورة بهذا الرقم.', style: theme.textTheme.bodySmall),
                )
              else
                Flexible(
                  child: Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: ListView(
                      controller: _scroll,
                      shrinkWrap: true,
                      children: [for (final row in rows) _row(context, row)],
                    ),
                  ),
                ),

              // ── fixed foot ──
              if (chosen.isNotEmpty) ...[
                const Divider(height: 12),
                Container(
                  key: const Key('invoice-on-account'),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                      fontSize: 13,
                    ),
                  ),
                ),
                if (widget.onFill != null && chosenOpenCash > 0)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      key: const Key('fill-from-invoices'),
                      onPressed: widget.onFill,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.download_done, size: 18),
                      label: Text(
                        'املأ المبلغ بما تبقّى عليها (${formatCash(chosenOpenCash)})',
                      ),
                    ),
                  ),
              ] else if (widget.showAdvance)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: widget.advance,
                  onChanged: widget.onAdvance == null
                      ? null
                      : (v) => widget.onAdvance!(v ?? false),
                  title: const Text('دفعة ذهب مقدّمة (لذهب لم يُشترَ بعد)'),
                ),
            ],
          ),
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
      visualDensity: VisualDensity.compact,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: isChosen,
      onChanged: (_) => widget.onToggle(id),
      title: Row(
        children: [
          Expanded(
            child: Text(
              '${row['invoice_number'] ?? '#$id'} — ${_day(row['date'])}',
              style: const TextStyle(fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(owes, style: theme.textTheme.bodySmall),
        ],
      ),
      subtitle: isChosen
          ? KeyedSubtree(
              key: Key('invoice-share-$id'),
              child: Text(
                _share(id),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : null,
    );
  }
}
