import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// The weight in the voucher's own karat for an amount shown in main-karat
/// grams. Sending the main-karat figure as the karat's weight under-attributed
/// every non-main karat: 24.2 g of 18k went as 20.74 g of 18k (2 Oct 2026).
double karatWeightFromMain(double amountMainKarat, double mainKarat, double karat) =>
    double.parse((amountMainKarat * mainKarat / karat).toStringAsFixed(3));

/// One invoice the voucher can be attributed to, as the employee knows it.
class AttributionCandidate {
  const AttributionCandidate({
    required this.invoiceId,
    required this.label,
    required this.open,
    this.date,
    this.details = const [],
  });

  final int invoiceId;

  /// «شراء #187» -- the number people use, not the database id.
  final String label;
  final DateTime? date;

  /// What the invoice still lacks, in the sheet's unit.
  final double open;

  /// Extra lines: what it owes and what was paid, or each karat's remainder.
  final List<String> details;
}

/// An attribution already recorded from this voucher.
class AttributionExisting {
  const AttributionExisting({
    required this.id,
    required this.label,
    required this.amount,
    required this.removable,
    this.lockedReason,
  });

  final int id;
  final String label;
  final double amount;
  final bool removable;
  final String? lockedReason;
}

/// Attributing a voucher's gold or cash to an invoice (2 Oct 2026): the same
/// sheet for both, so the choice reads the same way.
///
/// - each invoice as people know it, with its date and what it still lacks;
/// - a search over number and date;
/// - an invoice whose remainder equals the voucher's unattributed amount is
///   shown first, marked «يطابق تمامًا» -- a suggestion, never a selection;
/// - the amount is the employee's, capped by both sides;
/// - a summary to confirm before anything is written.
class InvoiceAttributionSheet extends StatefulWidget {
  const InvoiceAttributionSheet({
    super.key,
    required this.title,
    required this.unit,
    required this.unattributed,
    required this.existing,
    required this.candidates,
    required this.onAttribute,
    required this.onRemove,
    required this.emptyText,
  });

  final String title;

  /// 'ر.س' or 'جم'.
  final String unit;
  final double unattributed;
  final List<AttributionExisting> existing;
  final List<AttributionCandidate> candidates;
  final Future<void> Function(int invoiceId, double amount) onAttribute;
  final Future<void> Function(AttributionExisting row) onRemove;
  final String emptyText;

  static const double epsilon = 0.005;

  /// Exact matches first (in their given order), then the rest as given.
  static List<AttributionCandidate> ordered(
      List<AttributionCandidate> rows, double unattributed) {
    bool exact(AttributionCandidate c) =>
        unattributed > epsilon && (c.open - unattributed).abs() <= epsilon;
    return [...rows.where(exact), ...rows.where((c) => !exact(c))];
  }

  @override
  State<InvoiceAttributionSheet> createState() => _InvoiceAttributionSheetState();
}

class _InvoiceAttributionSheetState extends State<InvoiceAttributionSheet> {
  final _search = TextEditingController();
  final _amount = TextEditingController();
  AttributionCandidate? _chosen;
  String? _error;
  bool _busy = false;

  static final _dateFmt = DateFormat('yyyy/MM/dd');

  String _fmt(double v) => v.toStringAsFixed(2);

  double _cap(AttributionCandidate c) =>
      widget.unattributed < c.open ? widget.unattributed : c.open;

  bool _isExact(AttributionCandidate c) =>
      widget.unattributed > InvoiceAttributionSheet.epsilon &&
      (c.open - widget.unattributed).abs() <= InvoiceAttributionSheet.epsilon;

  @override
  void dispose() {
    _search.dispose();
    _amount.dispose();
    super.dispose();
  }

  List<AttributionCandidate> get _visible {
    final q = _search.text.trim();
    final rows = InvoiceAttributionSheet.ordered(widget.candidates, widget.unattributed);
    if (q.isEmpty) return rows;
    return rows.where((c) {
      final date = c.date != null ? _dateFmt.format(c.date!) : '';
      return c.label.contains(q) || date.contains(q) || '${c.invoiceId}'.contains(q);
    }).toList();
  }

  void _choose(AttributionCandidate c) {
    setState(() {
      _chosen = c;
      _amount.text = _fmt(_cap(c));
      _error = null;
    });
  }

  Future<void> _confirm() async {
    final c = _chosen;
    if (c == null) return;
    final amount = double.tryParse(_amount.text.trim());
    final cap = _cap(c);
    if (amount == null || amount <= InvoiceAttributionSheet.epsilon) {
      setState(() => _error = 'أدخل مبلغًا أكبر من صفر');
      return;
    }
    if (amount > cap + InvoiceAttributionSheet.epsilon) {
      setState(() => _error = 'الحد الأقصى ${_fmt(cap)} ${widget.unit}');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('تأكيد النسب'),
        content: Text(
          'نسب ${_fmt(amount)} ${widget.unit} من هذا السند إلى ${c.label}'
          '${c.date != null ? ' (${_dateFmt.format(c.date!)})' : ''}؟\n'
          'المتبقي على الفاتورة بعده: ${_fmt(c.open - amount)} ${widget.unit}',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('رجوع')),
          FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('انسب')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.onAttribute(c.invoiceId, amount);
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'فشل النسب: $e';
      });
    }
  }

  Future<void> _remove(AttributionExisting row) async {
    setState(() => _busy = true);
    try {
      await widget.onRemove(row);
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'فشل الإلغاء: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _visible;
    final canAttribute = widget.unattributed > InvoiceAttributionSheet.epsilon;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('غير المنسوب من هذا السند: ${_fmt(widget.unattributed)} ${widget.unit}',
                style: theme.textTheme.bodySmall),
            if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
            if (widget.existing.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('منسوب حاليًا', style: theme.textTheme.labelLarge),
              ...widget.existing.map((row) => ListTile(
                    key: ValueKey('existing-${row.id}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${row.label} · ${_fmt(row.amount)} ${widget.unit}'),
                    trailing: row.removable
                        ? IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            tooltip: 'إلغاء هذا النسب',
                            onPressed: _busy ? null : () => _remove(row),
                          )
                        : Tooltip(
                            message: row.lockedReason ?? 'لا يُلغى من هنا',
                            child: const Icon(Icons.lock_outline, size: 18),
                          ),
                  )),
              const Divider(),
            ],
            if (!canAttribute)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('لا يوجد ${widget.unit == 'جم' ? 'ذهب' : 'نقد'} غير منسوب في هذا السند',
                    style: theme.textTheme.bodySmall),
              )
            else if (widget.candidates.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(widget.emptyText, style: TextStyle(color: theme.colorScheme.error)),
              )
            else ...[
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('attribution-search'),
                controller: _search,
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search),
                  hintText: 'ابحث برقم الفاتورة أو تاريخها',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: visible.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('لا توجد فاتورة تطابق البحث'),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: visible.map((c) {
                          final chosen = _chosen?.invoiceId == c.invoiceId;
                          return Card(
                            key: ValueKey('candidate-${c.invoiceId}'),
                            elevation: chosen ? 2 : 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: BorderSide(
                                color: chosen ? theme.colorScheme.primary : theme.dividerColor,
                              ),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: _busy ? null : () => _choose(c),
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '${c.label}'
                                            '${c.date != null ? ' · ${_dateFmt.format(c.date!)}' : ''}',
                                            style: const TextStyle(fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                        if (_isExact(c))
                                          Chip(
                                            key: ValueKey('exact-${c.invoiceId}'),
                                            label: const Text('يطابق تمامًا'),
                                            visualDensity: VisualDensity.compact,
                                          ),
                                      ],
                                    ),
                                    Text('المتبقي: ${_fmt(c.open)} ${widget.unit}'),
                                    ...c.details.map((d) => Text(d, style: theme.textTheme.bodySmall)),
                                    if (chosen) ...[
                                      const SizedBox(height: 8),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: TextField(
                                              key: const ValueKey('attribution-amount'),
                                              controller: _amount,
                                              keyboardType:
                                                  const TextInputType.numberWithOptions(decimal: true),
                                              decoration: InputDecoration(
                                                isDense: true,
                                                labelText: 'المبلغ (${widget.unit})',
                                                helperText: 'الحد الأقصى ${_fmt(_cap(c))}',
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          FilledButton(
                                            key: const ValueKey('attribution-confirm'),
                                            onPressed: _busy ? null : _confirm,
                                            child: const Text('انسب'),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
          ],
        ),
      ),
    );
  }
}

/// One line of «الفواتير التي يسددها السند»: an invoice and what this voucher
/// paid of it.
class AttributionSummaryRow {
  const AttributionSummaryRow({required this.label, required this.amount, this.date});

  final String label;
  final double amount;
  final DateTime? date;
}

/// The voucher's attributions, shown in the voucher itself rather than behind
/// an icon (2 Oct 2026): what it paid, how much of it names an invoice, which
/// invoices, and the way to attribute the rest -- for its cash and its gold.
class AttributionSummaryCard extends StatelessWidget {
  const AttributionSummaryCard({
    super.key,
    required this.unit,
    required this.kindLabel,
    required this.capacity,
    required this.attributed,
    required this.rows,
    required this.approved,
    required this.onOpen,
  });

  /// 'ر.س' or 'جم'.
  final String unit;

  /// 'النقد' or 'الذهب (بالعيار الرئيسي)'.
  final String kindLabel;
  final double capacity;
  final double attributed;
  final List<AttributionSummaryRow> rows;
  final bool approved;
  final VoidCallback onOpen;

  static final _dateFmt = DateFormat('yyyy/MM/dd');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final left = capacity - attributed;
    final complete = left <= InvoiceAttributionSheet.epsilon;
    String fmt(double v) => v.toStringAsFixed(2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(kindLabel, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            if (complete)
              Row(
                key: const ValueKey('attribution-complete'),
                children: [
                  Icon(Icons.check_circle, size: 18, color: Colors.green.shade700),
                  const SizedBox(width: 4),
                  Text('منسوب كاملًا', style: TextStyle(color: Colors.green.shade700)),
                ],
              ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            Text('المبلغ: ${fmt(capacity)} $unit'),
            Text('منسوب: ${fmt(attributed)} $unit'),
            Text(
              'غير منسوب: ${fmt(left < 0 ? 0 : left)} $unit',
              style: TextStyle(
                color: complete ? null : theme.colorScheme.error,
                fontWeight: complete ? null : FontWeight.w700,
              ),
            ),
          ],
        ),
        if (rows.isNotEmpty) ...[
          const SizedBox(height: 6),
          ...rows.map((r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    const Icon(Icons.receipt_long_outlined, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${r.label}${r.date != null ? ' · ${_dateFmt.format(r.date!)}' : ''}',
                      ),
                    ),
                    Text('${fmt(r.amount)} $unit', style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              )),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('لا فاتورة منسوبة — دفعة على حساب المورد',
                style: theme.textTheme.bodySmall),
          ),
        const SizedBox(height: 8),
        if (!approved)
          Text('النسب متاح بعد اعتماد السند', style: theme.textTheme.bodySmall)
        else
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: complete
                ? TextButton.icon(
                    key: const ValueKey('attribution-open'),
                    onPressed: onOpen,
                    icon: const Icon(Icons.tune, size: 18),
                    label: const Text('إدارة النسب'),
                  )
                : FilledButton.icon(
                    key: const ValueKey('attribution-open'),
                    onPressed: onOpen,
                    icon: const Icon(Icons.add_link, size: 18),
                    label: Text('انسب ${fmt(left)} $unit إلى فاتورة'),
                  ),
          ),
      ],
    );
  }
}
