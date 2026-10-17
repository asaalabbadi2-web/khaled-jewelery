import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../screens/reports/weight_position_screen.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/currency_utils.dart' as cu;

/// The shop's currency, as the dashboard shows it (the new SAR graphic when
/// set); «ر.س» where no settings are provided.
bool _newSar(BuildContext context) {
  try {
    return Provider.of<SettingsProvider>(context).currencyIsNewSar;
  } on ProviderNotFoundException {
    return false;
  }
}

/// «التسكير الآن» في لوحة المدير (ADR-048، المالك 16 أكتوبر 2026): ما ينتظر أن
/// يعود ذهبًا رقمًا رئيسيًّا، وما يشتريه بسعر شراء المحل، وثلاثة مؤشرات (غير
/// المحقَّق، وأثر 1% في السعر، ومحقَّق الشهر)، وشريط يقسم المنتظر بعمره ويُبرز
/// ما تجاوز أيام المالك. كل رقم ونسبة وتنبيه من الخادم؛ البطاقة ترسم. لا تظهر
/// لمن لا يقرأ التقارير المالية.
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
          return _frame(
            context,
            key: const ValueKey('wps-loading'),
            accent: Theme.of(context).colorScheme.primary,
            child: const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: LinearProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return _frame(
            context,
            key: const ValueKey('wps-error'),
            accent: Theme.of(context).colorScheme.error,
            child: Row(children: [
              Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 8),
              const Expanded(child: Text('تعذّر تحميل التسكير')),
              TextButton(onPressed: _retry, child: const Text('إعادة المحاولة')),
            ]),
          );
        }
        final s = snap.data;
        if (s == null) return const SizedBox.shrink();
        return _card(context, s);
      },
    );
  }

  Widget _frame(BuildContext context, {required Key key, required Color accent, required Widget child,
      VoidCallback? onTap}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Material(
      key: key,
      color: theme.cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: accent.withValues(alpha: isDark ? 0.30 : 0.50), width: 1.2),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: const EdgeInsets.all(16), child: child)),
    );
  }

  Widget _card(BuildContext context, Map<String, dynamic> s) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final alert = (s['alert'] as Map?)?.cast<String, dynamic>() ?? const {};
    final raised = alert['raised'] == true;
    final count = (s['open_count'] as num?)?.toInt() ?? 0;
    final accent = raised ? tones.warning.fg : theme.colorScheme.primary;

    final header = Row(children: [
      Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
        child: Icon(Icons.balance, color: accent),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('التسكير الآن', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
          Text('ريالات المبيعات التي تنتظر أن تعود ذهبًا',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ]),
      ),
      Row(mainAxisSize: MainAxisSize.min, children: [
        Text('المركز', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
        Icon(Icons.chevron_left, size: 18, color: theme.colorScheme.primary),
      ]),
    ]);

    final hero = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(count == 0 ? 'لا شيء ينتظر التسكير' : 'ينتظر أن يعود ذهبًا',
          key: count == 0 ? const ValueKey('wps-nothing') : null,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600)),
      if (count > 0) ...[
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: cu.SarAwareText('${_ltr(_money.format(_d(s['open_cash'])))} ر.س',
              key: const ValueKey('wps-open'),
              isNewSar: _newSar(context),
              style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold, color: accent)),
        ),
        const SizedBox(height: 2),
        Text('من ${_ltr('$count')} بيعًا', key: const ValueKey('wps-count'),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        if (s['buys_now_grams'] != null) ...[
          const SizedBox(height: 8),
          Text('يشتري الآن ${_g(s['buys_now_grams'])} بسعرك ${_ltr(_price.format(_d(s['purchase_price'])))}',
              key: const ValueKey('wps-buys'), style: theme.textTheme.bodyMedium),
        ],
      ],
    ]);

    final unrealized = _d(s['unrealized']);
    final month = _d(s['month_realized']);
    final tiles = Row(children: [
      if (count > 0) ...[
        Expanded(child: _tile(context, 'غير المحقَّق', _g(unrealized, signed: true),
            unrealized >= 0 ? tones.ready : tones.blocked, key: const ValueKey('wps-unrealized'))),
        const SizedBox(width: 8),
        Expanded(child: _tile(context, 'كل ${_ltr('1%')} صعود في السعر',
            _g(-_d(s['grams_per_price_percent']), signed: true), tones.warning, key: const ValueKey('wps-grip'))),
        const SizedBox(width: 8),
      ],
      Expanded(child: _tile(context, 'المحقَّق هذا الشهر', _g(month, signed: true),
          month >= 0 ? tones.ready : tones.blocked, key: const ValueKey('wps-month'))),
    ]);

    final body = LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 760;
      final right = Column(mainAxisSize: MainAxisSize.min, children: [
        tiles,
        if (count > 0) ...[const SizedBox(height: 14), _ageBar(context, s, tones)],
      ]);
      if (!wide) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          hero, const SizedBox(height: 14), right,
        ]);
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: 4, child: hero),
        const SizedBox(width: 20),
        Expanded(flex: 7, child: right),
      ]);
    });

    return _frame(
      context,
      key: const ValueKey('wps-card'),
      accent: accent,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => WeightPositionScreen(api: widget.api, isArabic: widget.isArabic))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        header,
        if (raised) ...[const SizedBox(height: 10), _alertPill(context, s, alert)],
        const SizedBox(height: 14),
        body,
      ]),
    );
  }

  Widget _alertPill(BuildContext context, Map<String, dynamic> s, Map<String, dynamic> alert) {
    final tone = AppSemanticColors.of(context).warning;
    return Container(
      key: const ValueKey('wps-oldest'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: tone.container, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.warning_amber_rounded, size: 16, color: tone.onContainer),
        const SizedBox(width: 4),
        Flexible(child: Text('أقدم بيع ينتظر منذ ${_ltr('${s['oldest_age_days']}')} أيام — تجاوز ${_ltr('${alert['oldest_over_days']}')}',
            key: const ValueKey('wps-oldest-text'),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: tone.onContainer))),
      ]),
    );
  }

  Widget _tile(BuildContext context, String label, String value, SemanticTone tone, {Key? key}) {
    final theme = Theme.of(context);
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tone.container.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(value, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: tone.fg)),
        ),
      ]),
    );
  }

  Widget _ageBar(BuildContext context, Map<String, dynamic> s, AppSemanticColors tones) {
    final theme = Theme.of(context);
    final buckets = ((s['age_buckets'] as List?) ?? const []).cast<Map<String, dynamic>>();
    SemanticTone toneOf(String? key) => switch (key) {
          'late' => tones.blocked,
          'aging' => tones.warning,
          _ => tones.ready,
        };
    String labelOf(Map<String, dynamic> b) {
      final from = b['from_days'];
      final to = b['to_days'];
      if (to == null) return 'أكثر من ${_ltr('${(from as num) - 1}')} أيام';
      if (from == 0) return 'حتى ${_ltr('$to')} أيام';
      return '${_ltr('$from–$to')} أيام';
    }

    final shown = buckets.where((b) => _d(b['share']) > 0).toList();
    return Column(key: const ValueKey('wps-ages'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('عمر المنتظر', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          height: 10,
          child: Row(children: [
            for (final b in shown)
              Expanded(
                flex: (_d(b['share']) * 1000).round().clamp(1, 1000),
                child: Container(color: toneOf(b['key'] as String?).fg),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 14, runSpacing: 4, children: [
        for (final b in buckets)
          Row(key: ValueKey('wps-age-${b['key']}'), mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10,
                decoration: BoxDecoration(color: toneOf(b['key'] as String?).fg, borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 6),
            Text('${labelOf(b)}  ${_ltr('${(_d(b['share']) * 100).round()}%')}',
                style: theme.textTheme.labelSmall),
          ]),
      ]),
    ]);
  }
}
