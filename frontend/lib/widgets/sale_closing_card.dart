import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
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

/// بيع واحد في التسكير (ADR-048 المرحلة 3ب): شريط يقسم ثمن البيع إلى ما أُغلق
/// وما رُدّ وما ينتظر، ونتيجتان (المحقَّقة وتقدير المنتظر)، ثم ما أغلقه في خط
/// زمني. كل رقم ونسبة من الخادم؛ البطاقة ترسم. لا تظهر لما ليس بيعًا مرحَّلًا
/// قائمًا، ولا لمن لا يقرأ التقارير المالية.
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
  static const kindLabels = {'customer': 'شراء كسر من عميل', 'office': 'تسوية مكتب', 'expense': 'مصروفات'};
  static const kindIcons = {
    'customer': Icons.shopping_basket_outlined,
    'office': Icons.apartment_outlined,
    'expense': Icons.receipt_long_outlined,
  };

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

  /// A number kept left-to-right inside the Arabic line (U+2066..U+2069).
  static String _ltr(String s) => '\u2066$s\u2069';

  static String _g(dynamic v, {bool signed = false}) {
    final x = _d(v);
    final sign = !signed ? '' : (x < 0 ? '−' : '+');
    return '${_ltr('$sign${_grams.format(x.abs())}')} غ';
  }

  static String _r(dynamic v) => '${_ltr(_money.format(_d(v)))} ر.س';

  static String _day(dynamic iso) => _ltr('$iso'.split('T').first);

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
            leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
            title: const Text('تعذّر تحميل التسكير'),
            trailing: TextButton(onPressed: _retry, child: const Text('إعادة المحاولة')),
          );
        }
        final view = snap.data;
        if (view == null) return const SizedBox.shrink();
        return _section(context, view);
      },
    );
  }

  SemanticTone _statusTone(AppSemanticColors tones, String? status) => switch (status) {
        'closed' => tones.ready,
        'partially_closed' => tones.warning,
        'cancelled' => tones.silver,
        _ => tones.info,
      };

  Widget _section(BuildContext context, Map<String, dynamic> view) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final status = view['status'] as String?;
    final statusTone = _statusTone(tones, status);
    final closings = ((view['closings'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final waiting = _d(view['cash_open']) > 0;
    final realized = _d(view['realized']);
    final unreal = _d(view['unrealized']);

    return Column(
      key: const ValueKey('sale-closing'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Row(children: [
          Text('التسكير',
              style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.bold)),
          const Spacer(),
          Container(
            key: const ValueKey('sale-closing-status'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: statusTone.container, borderRadius: BorderRadius.circular(20)),
            child: Text(statusLabels[status] ?? '$status',
                style: theme.textTheme.labelMedium?.copyWith(color: statusTone.onContainer, fontWeight: FontWeight.w600)),
          ),
        ]),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            // As the preview's other sections (the payments, the safe edit).
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: theme.brightness == Brightness.dark ? 0.35 : 0.6),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            cu.SarAwareText('ثمنه بلا الضريبة ${_r(view['cash'])} مقابل ${_g(view['grams'])}',
                key: const ValueKey('sale-closing-price'), isNewSar: _newSar(context), style: theme.textTheme.bodyMedium),
            if (view['expected_at_sale'] != null)
              Text('المتوقَّع وقت البيع ${_g(view['expected_at_sale'], signed: true)}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            const SizedBox(height: 12),
            _bar(context, view, tones),
            if (_d(view['returned_after_closing_cash']) > 0) ...[
              const SizedBox(height: 10),
              Container(
                key: const ValueKey('sale-closing-returned-after'),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: tones.info.container, borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 16, color: tones.info.onContainer),
                  const SizedBox(width: 6),
                  Expanded(
                    child: cu.SarAwareText('رُدّ بعد التسكير ${_r(view['returned_after_closing_cash'])}: كانت ريالاته قد عادت ذهبًا',
                        isNewSar: _newSar(context),
                        style: theme.textTheme.labelMedium?.copyWith(color: tones.info.onContainer)),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 12),
            Row(children: [
              if (closings.isNotEmpty)
                Expanded(child: _tile(context, 'النتيجة المحقَّقة', _g(realized, signed: true),
                    realized >= 0 ? tones.ready : tones.blocked, key: const ValueKey('sale-closing-closed'))),
              if (closings.isNotEmpty && waiting) const SizedBox(width: 8),
              if (waiting)
                Expanded(child: _tile(context, 'تقدير المنتظر بسعر شراء المحل', _g(unreal, signed: true),
                    unreal >= 0 ? tones.ready : tones.blocked, key: const ValueKey('sale-closing-open'))),
            ]),
            if (closings.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('ما أغلقه', style: theme.textTheme.labelLarge?.copyWith(color: theme.hintColor)),
              const SizedBox(height: 6),
              for (var i = 0; i < closings.length; i++)
                _step(context, closings[i], tones, last: i == closings.length - 1),
            ],
            const SizedBox(height: 6),
            Text('الربط بين البيع وما أغلقه بترتيب الأقدم أولًا، يُقرأ من الدفاتر في كل مرة.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ]),
        ),
      ],
    );
  }

  Widget _bar(BuildContext context, Map<String, dynamic> view, AppSemanticColors tones) {
    final theme = Theme.of(context);
    final shares = (view['shares'] as Map?)?.cast<String, dynamic>() ?? const {};
    final parts = [
      ('closed', 'أُغلق', view['closed_cash'], theme.colorScheme.primary),
      ('returned', 'رُدّ', view['returned_cash'], tones.silver.fg),
      ('open', 'ينتظر', view['cash_open'], theme.colorScheme.outlineVariant),
    ];
    return Column(key: const ValueKey('sale-closing-bar'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 10,
              child: Row(children: [
                for (final (key, _, _, color) in parts)
                  if (_d(shares[key]) > 0)
                    Expanded(flex: (_d(shares[key]) * 1000).round().clamp(1, 1000), child: Container(color: color)),
              ]),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text('${_ltr('${(_d(shares['closed']) * 100).round()}%')} أُغلق',
            key: const ValueKey('sale-closing-share'),
            style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold)),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 14, runSpacing: 4, children: [
        for (final (key, label, amount, color) in parts)
          if (key != 'returned' || _d(amount) > 0)
            Row(key: ValueKey('sale-closing-part-$key'), mainAxisSize: MainAxisSize.min, children: [
              Container(width: 10, height: 10,
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
              const SizedBox(width: 6),
              cu.SarAwareText('$label ${_r(amount)}', isNewSar: _newSar(context), style: theme.textTheme.labelSmall),
            ]),
      ]),
    ]);
  }

  Widget _tile(BuildContext context, String label, String value, SemanticTone tone, {Key? key}) {
    final theme = Theme.of(context);
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: tone.container.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
        const SizedBox(height: 4),
        Text(value, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: tone.fg)),
      ]),
    );
  }

  Widget _step(BuildContext context, Map<String, dynamic> c, AppSemanticColors tones, {required bool last}) {
    final theme = Theme.of(context);
    final result = _d(c['result']);
    final tone = result >= 0 ? tones.ready : tones.blocked;
    final kind = c['kind'] as String?;
    final title = '${kindLabels[kind] ?? kind}${c['invoice_number'] != null ? ' #${c['invoice_number']}' : ''}';
    final detail = kind == 'expense'
        ? '${_r(c['cash'])} · نصيبها من المُباع ${_g(c['grams_out'])}'
        : '${_r(c['cash'])} · اشترت ${_g(c['grams_in'])} · نصيبها من المُباع ${_g(c['grams_out'])}';
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 28,
          child: Column(children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: tone.container, shape: BoxShape.circle),
              child: Icon(kindIcons[kind] ?? Icons.circle_outlined, size: 16, color: tone.onContainer),
            ),
            if (!last) Expanded(child: Container(width: 2, color: theme.dividerColor.withValues(alpha: 0.5))),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('$title · ${_day(c['date'])}',
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: tone.container, borderRadius: BorderRadius.circular(12)),
                  child: Text(_g(result, signed: true),
                      style: theme.textTheme.labelMedium?.copyWith(color: tone.onContainer, fontWeight: FontWeight.bold)),
                ),
              ]),
              const SizedBox(height: 2),
              cu.SarAwareText(detail, isNewSar: _newSar(context),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ]),
          ),
        ),
      ]),
    );
  }
}
