import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../api_service.dart';
import '../../theme/app_semantic_colors.dart';
import '../../widgets/sale_closing_card.dart';

/// «مركز التسكير» (ADR-048): المحل يقيس نفسه بالذهب، والنقد حالة مؤقتة. هنا
/// ريالات المبيعات التي تنتظر أن تعود ذهبًا، وما تشتريه الآن بسعر شراء المحل،
/// وأداء الربح الوزني بطبقاته الخمس. كل رقم من الخادم (المحرّك)؛ الشاشة تعرض.
class WeightPositionScreen extends StatefulWidget {
  const WeightPositionScreen({super.key, required this.api, this.isArabic = true});

  final ApiService api;
  final bool isArabic;

  @override
  State<WeightPositionScreen> createState() => _WeightPositionScreenState();
}

enum _Period { thisMonth, threeMonths, yearToDate }

class _WeightPositionScreenState extends State<WeightPositionScreen> {
  static final _money = NumberFormat('#,##0');
  static final _grams = NumberFormat('#,##0.0');
  static final _price = NumberFormat('#,##0.00');

  bool _loading = true;
  String? _error;
  Map<String, dynamic> _position = const {};
  Map<String, dynamic> _performance = const {};
  _Period _period = _Period.yearToDate;

  @override
  void initState() {
    super.initState();
    _load();
  }

  (DateTime, DateTime) _range() {
    final today = DateTime.now();
    final end = DateTime(today.year, today.month, today.day);
    switch (_period) {
      case _Period.thisMonth:
        return (DateTime(end.year, end.month, 1), end);
      case _Period.threeMonths:
        return (DateTime(end.year, end.month - 2, 1), end);
      case _Period.yearToDate:
        return (DateTime(end.year, 1, 1), end);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (start, end) = _range();
      final results = await Future.wait([
        widget.api.getWeightPosition(),
        widget.api.getWeightPerformance(startDate: start, endDate: end),
      ]);
      if (!mounted) return;
      setState(() {
        _position = results[0];
        _performance = results[1];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  static double _d(dynamic v) => v is num ? v.toDouble() : 0.0;

  /// Grams, the number and its sign kept left-to-right inside the Arabic line
  /// (U+2066..U+2069 isolate it), the unit after it.
  String _g(dynamic v, {bool signed = false}) {
    final x = _d(v);
    final sign = !signed ? '' : (x < 0 ? '−' : '+');
    return '\u2066$sign${_grams.format(x.abs())}\u2069 غ';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('مركز التسكير'),
          actions: [
            IconButton(tooltip: 'تحديث', icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load),
          ],
        ),
        body: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('تعذّر تحميل مركز التسكير', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
          ]),
        ),
      );
    }
    final width = MediaQuery.sizeOf(context).width;
    return ListView(
      padding: EdgeInsets.symmetric(horizontal: width > 1132 ? (width - 1100) / 2 : 16, vertical: 16),
      children: [
        _summary(context),
        const SizedBox(height: 12),
        _whereTheRiyalsAre(context),
        const SizedBox(height: 20),
        _performanceSection(context),
        const SizedBox(height: 20),
        _openSales(context),
        const SizedBox(height: 20),
        _recentClosings(context),
      ],
    );
  }

  // ── 1 + 2: what waits, what it buys now, and the price's grip on it ──────

  Widget _summary(BuildContext context) {
    final tones = AppSemanticColors.of(context);
    final p = _position;
    final unrealized = _d(p['unrealized']);
    final tone = unrealized >= 0 ? tones.ready : tones.blocked;
    final oldest = p['oldest'] == null ? null : DateTime.tryParse('${p['oldest']}');
    final text = Theme.of(context).textTheme;
    Widget row(String label, String value, {Key? key, TextStyle? style}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(label, style: text.bodyMedium?.copyWith(color: tone.onContainer))),
            Text(value, key: key,
                style: (style ?? text.bodyMedium)?.copyWith(color: tone.onContainer)),
          ]),
        );
    return Card(
      color: tone.container,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          row('ينتظر التسكير', '${_money.format(_d(p['open_cash']))} ر.س — ${_counts(p)}',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          row('مقابل غرامات مُباعة', _g(p['open_grams_sold'])),
          row('تشتري الآن بسعرك', '${_g(p['buys_now_grams'])} بسعر ${_price.format(_d(p['purchase_price']))}'),
          Text('${p['purchase_price_source'] ?? ''}', style: text.bodySmall?.copyWith(color: tone.onContainer)),
          const Divider(),
          row('غير محقَّق', _g(unrealized, signed: true),
              key: const ValueKey('wp-unrealized'),
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          row('— بسعر السوق ${_price.format(_d(p['market_price']))}', _g(p['unrealized_at_market'], signed: true)),
          if (oldest != null) row('أقدم مفتوح', DateFormat('yyyy-MM-dd').format(oldest)),
          const SizedBox(height: 8),
          Text(
            'كل 1% يصعد فيه سعر شرائك ينقص غير المحقَّق ${_g(p['grams_per_price_percent'])}.',
            key: const ValueKey('wp-sensitivity'),
            style: text.bodySmall?.copyWith(color: tone.onContainer, fontWeight: FontWeight.w600),
          ),
        ]),
      ),
    );
  }

  /// «33 بيعًا و13 يوم إيرادات» -- what the open lots are, counted for the label.
  static String _counts(Map<String, dynamic> p) {
    final lots = ((p['lots'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final revenues = lots.where((l) => l['kind'] == 'revenue').length;
    final sales = lots.length - revenues;
    return revenues == 0 ? '$sales بيعًا' : '$sales بيعًا و$revenues يوم إيرادات';
  }

  // ── 6: beside the position, not a split of it ─────────────────────────────

  Widget _whereTheRiyalsAre(BuildContext context) {
    final w = (_position['where_the_riyals_are'] as Map?)?.cast<String, dynamic>() ?? const {};
    final text = Theme.of(context).textTheme;
    Widget tile(String label, dynamic v) => Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                Text(label, style: text.bodySmall),
                const SizedBox(height: 4),
                Text('${_money.format(_d(v))} ر.س', style: text.titleSmall),
              ]),
            ),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('أين ريالاتك الآن', style: text.titleMedium),
      Text('للعرض بجانب المركز، لا قسمة له: ما يمكنك أن تسكّر به الآن.', style: text.bodySmall),
      const SizedBox(height: 6),
      Row(children: [
        tile('في الصندوق والبنك', w['in_hand']),
        tile('عند العملاء', w['with_customers']),
        tile('عند الموظفين', w['with_employees']),
      ]),
    ]);
  }

  // ── 4: the five layers, for the period and month by month ────────────────

  static const _layerNames = <String, String>{
    'trading': '① المتاجرة: ريالات المُباع التي عادت ذهبًا',
    'revenue': '② إيرادات إضافية',
    'expense_direct': '③ مصاريف وزنية',
    'expense_cash': '④ مصاريف نقدية',
    'price_effect': '⑤ أثر السعر على المفتوح',
  };

  static Map<String, double> _five(Map<String, dynamic>? layers) {
    final l = layers ?? const {};
    return {
      'trading': _d(l['trading']),
      'revenue': _d(l['revenue_converted']) + _d(l['revenue_direct']),
      'expense_direct': _d(l['expense_direct']),
      'expense_cash': _d(l['expense_cash']),
      'price_effect': _d(l['price_effect']),
    };
  }

  Widget _performanceSection(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final period = (_performance['period'] as Map?)?.cast<String, dynamic>() ?? const {};
    final months = ((_performance['months'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final five = _five((period['layers'] as Map?)?.cast<String, dynamic>());
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('الربح الوزني', style: text.titleMedium)),
        SegmentedButton<_Period>(
          segments: const [
            ButtonSegment(value: _Period.thisMonth, label: Text('هذا الشهر')),
            ButtonSegment(value: _Period.threeMonths, label: Text('3 أشهر')),
            ButtonSegment(value: _Period.yearToDate, label: Text('منذ أول السنة')),
          ],
          selected: {_period},
          onSelectionChanged: (s) {
            setState(() => _period = s.first);
            _load();
          },
        ),
      ]),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            for (final e in _layerNames.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Expanded(child: Text(e.value)),
                  Text(_g(five[e.key], signed: true)),
                ]),
              ),
            const Divider(),
            Row(children: [
              Expanded(child: Text('صافي الربح الوزني', style: text.titleSmall)),
              Text(_g(period['weight_profit'], signed: true),
                  key: const ValueKey('wp-period-total'),
                  style: text.titleSmall),
            ]),
          ]),
        ),
      ),
      if (months.length > 1) ...[
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 18,
            columns: [
              const DataColumn(label: Text('الشهر')),
              for (final mark in const ['①', '②', '③', '④', '⑤']) DataColumn(label: Text(mark), numeric: true),
              const DataColumn(label: Text('الصافي'), numeric: true),
            ],
            rows: [
              for (final m in months)
                DataRow(cells: [
                  DataCell(Text('${m['month']}')),
                  for (final v in _five((m['layers'] as Map?)?.cast<String, dynamic>()).values)
                    DataCell(Text(_g(v, signed: true))),
                  DataCell(Text(_g(m['weight_profit'], signed: true))),
                ]),
            ],
          ),
        ),
      ],
    ]);
  }

  // ── 3: the open sales, oldest first ───────────────────────────────────────

  Widget _openSales(BuildContext context) {
    final tones = AppSemanticColors.of(context);
    final text = Theme.of(context).textTheme;
    final lots = ((_position['lots'] as List?) ?? const []).cast<Map<String, dynamic>>();
    SemanticTone ageTone(int days) => days <= 7 ? tones.ready : (days <= 30 ? tones.warning : tones.blocked);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('المفتوح، الأقدم أولًا (${lots.length})', style: text.titleMedium),
      const SizedBox(height: 6),
      if (lots.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('لا شيء ينتظر التسكير')),
      for (final lot in lots)
        Card(
          child: ListTile(
            key: ValueKey('wp-lot-${lot['invoice_id'] ?? lot['ref']}'),
            title: Text(lot['kind'] == 'revenue'
                ? '${lot['ref']}'
                : 'بيع #${lot['invoice_number'] ?? '—'} — ${lot['customer'] ?? ''}'),
            subtitle: Text('${'${lot['date']}'.split('T').first} · '
                '${_money.format(_d(lot['cash_open']))} ر.س من ${_money.format(_d(lot['cash']))} · '
                '${_g(lot['grams_open'])} مُباعة'),
            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_g(lot['unrealized'], signed: true)),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: ageTone((lot['age_days'] as num?)?.toInt() ?? 0).container,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('${lot['age_days']} يوم', style: text.labelSmall?.copyWith(
                        color: ageTone((lot['age_days'] as num?)?.toInt() ?? 0).onContainer)),
                  ),
                ]),
            onTap: () => _showLot(context, lot),
          ),
        ),
    ]);
  }

  void _showLot(BuildContext context, Map<String, dynamic> lot) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(lot['kind'] == 'revenue' ? '${lot['ref']}' : 'بيع #${lot['invoice_number']} — ${lot['customer'] ?? ''}',
                style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('التاريخ: ${'${lot['date']}'.split('T').first} (منذ ${lot['age_days']} يوم)'),
            // A sale: its card says the rest (price, bar, results, what closed it).
            if (lot['invoice_id'] is int)
              SaleClosingCard(api: widget.api, invoiceId: lot['invoice_id'] as int)
            else ...[
              Text('المبلغ: ${_money.format(_d(lot['cash']))}، والمنتظر منه ${_money.format(_d(lot['cash_open']))}'),
              Text('غير المحقَّق الآن: ${_g(lot['unrealized'], signed: true)}'),
            ],
          ]),
        ),
      ),
    );
  }

  // ── 5: what closed lately ─────────────────────────────────────────────────

  static const _closingKinds = {'customer': 'شراء كسر', 'office': 'شراء كسر من مكتب', 'expense': 'مصروفات اليوم'};

  Widget _recentClosings(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final rows = ((_position['recent_closings'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('آخر التسكير', style: text.titleMedium),
      const SizedBox(height: 6),
      if (rows.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('لا تسكير بعد')),
      for (final r in rows)
        Card(
          child: ListTile(
            dense: true,
            title: Text('${_closingKinds[r['kind']] ?? r['kind']} · ${'${r['date']}'.split('T').first}'),
            subtitle: Text('${_money.format(_d(r['cash']))} ر.س · اشترت ${_g(r['grams_in'])} · '
                'نصيبها من المُباع ${_g(r['grams_out'])}'),
            trailing: Text(_g(r['result'], signed: true)),
          ),
        ),
    ]);
  }
}
