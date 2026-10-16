import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../api_service.dart';
import '../screens/reports/weight_position_screen.dart';
import '../theme/app_semantic_colors.dart';

/// «التسكير الآن» في لوحة المدير (ADR-048، المالك 16 أكتوبر 2026): ما ينتظر أن
/// يعود ذهبًا، وما يشتريه بسعر شراء المحل، وأثر السعر عليه، وانتظار أقدم بيع
/// مع تنبيه المالك بعد أيامه، ومحقَّق الشهر. كل رقم وكل تنبيه من الخادم؛ البطاقة
/// تعرض. لا تظهر لمن لا يقرأ التقارير المالية.
class WeightPositionSummaryCard extends StatefulWidget {
  const WeightPositionSummaryCard({super.key, required this.api, this.isArabic = true});

  final ApiService api;
  final bool isArabic;

  @override
  State<WeightPositionSummaryCard> createState() => _WeightPositionSummaryCardState();
}

class _WeightPositionSummaryCardState extends State<WeightPositionSummaryCard> {
  static final _money = NumberFormat('#,##0');
  static final _grams = NumberFormat('#,##0.0');
  static final _price = NumberFormat('#,##0.00');

  late Future<Map<String, dynamic>?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.getWeightPositionSummary();
  }

  @override
  void didUpdateWidget(WeightPositionSummaryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.api, widget.api)) _retry();
  }

  void _retry() {
    setState(() {
      _future = widget.api.getWeightPositionSummary();
    });
  }

  static double _d(dynamic v) => v is num ? v.toDouble() : 0.0;

  /// A number kept left-to-right inside the Arabic line (U+2066..U+2069).
  static String _ltr(String s) => '\u2066$s\u2069';

  static String _g(dynamic v, {bool signed = false}) {
    final x = _d(v);
    final sign = !signed ? '' : (x < 0 ? '−' : '+');
    return '${_ltr('$sign${_grams.format(x.abs())}')} غ';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Card(
            key: ValueKey('wps-loading'),
            child: Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return Card(
            key: const ValueKey('wps-error'),
            child: ListTile(
              leading: const Icon(Icons.error_outline),
              title: const Text('تعذّر تحميل التسكير'),
              trailing: TextButton(onPressed: _retry, child: const Text('إعادة المحاولة')),
            ),
          );
        }
        final s = snap.data;
        if (s == null) return const SizedBox.shrink();
        return _card(context, s);
      },
    );
  }

  Widget _card(BuildContext context, Map<String, dynamic> s) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final alert = (s['alert'] as Map?)?.cast<String, dynamic>() ?? const {};
    final raised = alert['raised'] == true;
    final count = (s['open_count'] as num?)?.toInt() ?? 0;
    final age = (s['oldest_age_days'] as num?)?.toInt();
    final ageTone = raised ? tones.warning : tones.ready;

    Widget line(String text, {Key? key, TextStyle? style}) =>
        Padding(padding: const EdgeInsets.only(top: 4), child: Text(text, key: key, style: style));

    return Card(
      key: const ValueKey('wps-card'),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => WeightPositionScreen(api: widget.api, isArabic: widget.isArabic))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.balance, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text('التسكير الآن', style: theme.textTheme.titleMedium)),
              Text('المركز', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
              Icon(Icons.chevron_left, color: theme.colorScheme.primary),
            ]),
            if (count == 0)
              line('لا شيء ينتظر التسكير', key: const ValueKey('wps-nothing'))
            else ...[
              line('ينتظر ${_ltr(_money.format(_d(s['open_cash'])))} ر.س من ${_ltr('$count')} بيعًا',
                  key: const ValueKey('wps-open'), style: theme.textTheme.titleSmall),
              if (s['buys_now_grams'] != null)
                line('يشتري الآن ${_g(s['buys_now_grams'])} بسعرك ${_ltr(_price.format(_d(s['purchase_price'])))}'),
              line('غير المحقَّق ${_g(s['unrealized'], signed: true)}'),
              line('كل ${_ltr('1%')} صعود في السعر = ${_g(-_d(s['grams_per_price_percent']), signed: true)}'),
              Container(
                key: const ValueKey('wps-oldest'),
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: ageTone.container, borderRadius: BorderRadius.circular(8)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(raised ? Icons.warning_amber_rounded : Icons.schedule, size: 16, color: ageTone.onContainer),
                  const SizedBox(width: 6),
                  Text(
                    raised
                        ? 'أقدم بيع ينتظر منذ ${_ltr('$age')} أيام — تجاوز ${_ltr('${alert['oldest_over_days']}')}'
                        : 'أقدم بيع ينتظر منذ ${_ltr('$age')} أيام',
                    key: const ValueKey('wps-oldest-text'),
                    style: theme.textTheme.labelMedium?.copyWith(color: ageTone.onContainer),
                  ),
                ]),
              ),
            ],
            line('المحقَّق هذا الشهر ${_g(s['month_realized'], signed: true)}', key: const ValueKey('wps-month')),
          ]),
        ),
      ),
    );
  }
}
