import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../api_service.dart';

/// بيع واحد في التسكير (ADR-048 المرحلة 3أ): ما كان أمر التسكير المخزّن
/// وحقوله على الفاتورة يقولانه، من المحرّك المشتق من الدفاتر. كل رقم من
/// الخادم؛ البطاقة تعرض. لا تظهر لما ليس بيعًا مرحَّلًا قائمًا، ولا لمن لا
/// يقرأ التقارير المالية.
class SaleClosingCard extends StatefulWidget {
  const SaleClosingCard({super.key, required this.api, required this.invoiceId});

  final ApiService api;
  final int invoiceId;

  @override
  State<SaleClosingCard> createState() => _SaleClosingCardState();
}

class _SaleClosingCardState extends State<SaleClosingCard> {
  static final _money = NumberFormat('#,##0.00');
  static final _grams = NumberFormat('#,##0.000');

  static const statusLabels = {
    'open': 'ينتظر التسكير',
    'partially_closed': 'مُسكَّر جزئيًّا',
    'closed': 'مُسكَّر',
    'cancelled': 'رُدّ بمرتجع',
  };
  static const kindLabels = {'customer': 'شراء كسر من عميل', 'office': 'تسوية مكتب', 'expense': 'مصروف'};

  late Future<Map<String, dynamic>?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.getSaleWeightClosing(widget.invoiceId);
  }

  void _retry() {
    setState(() {
      _future = widget.api.getSaleWeightClosing(widget.invoiceId);
    });
  }

  static double _d(dynamic v) => v is num ? v.toDouble() : 0.0;

  /// The number and its sign kept left-to-right inside the Arabic line.
  static String _g(dynamic v, {bool signed = false}) {
    final x = _d(v);
    final sign = !signed ? '' : (x < 0 ? '−' : '+');
    return '\u2066$sign${_grams.format(x.abs())}\u2069 غ';
  }

  static String _r(dynamic v) => '\u2066${_money.format(_d(v))}\u2069 ر.س';

  static String _day(dynamic iso) => '\u2066${'$iso'.split('T').first}\u2069';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<Map<String, dynamic>?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            key: ValueKey('sale-closing-loading'),
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          );
        }
        if (snap.hasError) {
          return ListTile(
            key: const ValueKey('sale-closing-error'),
            leading: const Icon(Icons.error_outline),
            title: const Text('تعذّر تحميل التسكير'),
            trailing: TextButton(onPressed: _retry, child: const Text('إعادة المحاولة')),
          );
        }
        final view = snap.data;
        if (view == null) return const SizedBox.shrink();
        final closings = ((view['closings'] as List?) ?? const []).cast<Map<String, dynamic>>();
        return Column(
          key: const ValueKey('sale-closing'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            Row(children: [
              Text('التسكير',
                  style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.primary, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Chip(
                key: const ValueKey('sale-closing-status'),
                label: Text(statusLabels[view['status']] ?? '${view['status']}'),
                visualDensity: VisualDensity.compact,
              ),
            ]),
            Card(
              elevation: 0,
              margin: EdgeInsets.zero,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('ثمنه بلا الضريبة ${_r(view['cash'])} مقابل ${_g(view['grams'])}'),
                  if (view['expected_at_sale'] != null)
                    Text('المتوقَّع وقت البيع ${_g(view['expected_at_sale'], signed: true)}'),
                  if (_d(view['returned_cash']) > 0)
                    Text('رُدّ بمرتجع ${_r(view['returned_cash'])} (${_g(view['returned_grams'])})'),
                  if (_d(view['returned_after_closing_cash']) > 0)
                    Text('رُدّ بعد التسكير ${_r(view['returned_after_closing_cash'])}: كانت ريالاته قد عادت ذهبًا',
                        key: const ValueKey('sale-closing-returned-after')),
                  if (_d(view['closed_cash']) > 0)
                    Text('أُغلق ${_r(view['closed_cash'])}، نتيجته ${_g(view['realized'], signed: true)}',
                        key: const ValueKey('sale-closing-closed')),
                  if (_d(view['cash_open']) > 0)
                    Text('ينتظر ${_r(view['cash_open'])}، يُقدَّر الآن ${_g(view['unrealized'], signed: true)} '
                        'بسعر شراء المحل',
                        key: const ValueKey('sale-closing-open')),
                  if (closings.isNotEmpty) const Divider(),
                  for (final c in closings)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${kindLabels[c['kind']] ?? c['kind']}'
                          '${c['invoice_number'] != null ? ' #${c['invoice_number']}' : ''} · ${_day(c['date'])}'),
                      subtitle: Text('${_r(c['cash'])} · اشترت ${_g(c['grams_in'])} · '
                          'نصيبها من المُباع ${_g(c['grams_out'])}'),
                      trailing: Text(_g(c['result'], signed: true)),
                    ),
                  Text('الربط بين البيع وما أغلقه بترتيب الأقدم أولًا، يُقرأ من الدفاتر في كل مرة.',
                      style: theme.textTheme.bodySmall),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }
}
