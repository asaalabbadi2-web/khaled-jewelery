// frontend/lib/screens/bonus_analytics_screen.dart
//
// تحليلات المكافآت (bonus study م3و): ما مُنح -- المعتمد والمدفوع، ما تحمله
// الدفاتر -- بفترة المكافأة، من الخادم (`/bonuses/analytics`). المعلّق وحده،
// والمرفوض والمعكوس في لا مبلغ. كانت الشاشة تحسب كل شيء بنفسها من كل
// المكافآت بكل حالاتها، فتعدّ المرفوضة ممنوحة، و«سنة» كانت كل ما كان.
//
// المحتوى:
//   1. الفترة (آخر 30/90/365 يومًا)
//   2. أعلى الموظفين
//   3. التوزيع حسب القاعدة
//   4. الاتجاه شهرًا شهرًا
//   5. معدل الاعتماد
//   6. حسب القسم

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../theme/app_chart_palette.dart';
import '../theme/app_theme.dart';
import '../utils/currency_utils.dart' as cu;
import '../widgets/app_state_views.dart';

enum _AnalyticsPeriod { last30, last90, lastYear }

class BonusAnalyticsScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const BonusAnalyticsScreen({
    super.key,
    required this.api,
    required this.isArabic,
  });

  @override
  State<BonusAnalyticsScreen> createState() => _BonusAnalyticsScreenState();
}

class _BonusAnalyticsScreenState extends State<BonusAnalyticsScreen> {
  bool _loading = false;
  Object? _error;
  Map<String, dynamic>? _data;
  _AnalyticsPeriod _period = _AnalyticsPeriod.lastYear;

  static final _day = DateFormat('yyyy-MM-dd');

  int get _days => switch (_period) {
        _AnalyticsPeriod.last30 => 30,
        _AnalyticsPeriod.last90 => 90,
        _AnalyticsPeriod.lastYear => 365,
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final today = DateTime.now();
    try {
      final data = await widget.api.getBonusAnalytics(
        from: _day.format(today.subtract(Duration(days: _days))),
        to: _day.format(today),
      );
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _choose(_AnalyticsPeriod p) {
    if (p == _period) return;
    setState(() => _period = p);
    _load();
  }

  String get _currency => context.read<SettingsProvider>().currencySymbolText;

  String _money(num v) => '${cu.formatAmount(v, decimals: 0)} $_currency';

  List<Map> _list(String key) => ((_data?[key] as List?) ?? const []).whereType<Map>().toList();

  String _periodLabel() {
    final isAr = widget.isArabic;
    return switch (_period) {
      _AnalyticsPeriod.last30 => isAr ? 'آخر 30 يومًا' : 'Last 30 days',
      _AnalyticsPeriod.last90 => isAr ? 'آخر 90 يومًا' : 'Last 90 days',
      _AnalyticsPeriod.lastYear => isAr ? 'آخر سنة' : 'Last year',
    };
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    if (_loading && _data == null) return const AppLoadingView(summaryBlocks: 2, rows: 4);
    if (_error != null && _data == null) {
      return AppErrorView(title: 'تعذّر تحميل التحليلات', error: _error!, onRetry: _load);
    }
    final statuses = Map<String, dynamic>.from((_data?['statuses'] as Map?) ?? const {});
    final nothing = statuses.values.every((v) => (v as num? ?? 0) == 0);

    return RefreshIndicator(
      onRefresh: _load,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 760;
          final cards = nothing
              ? <Widget>[
                  AppEmptyView(
                    title: 'لا مكافآت في ${_periodLabel()}',
                    hint: 'جرّب فترة أطول.',
                    icon: Icons.insights_outlined,
                    actionLabel: 'آخر سنة',
                    onAction: () => _choose(_AnalyticsPeriod.lastYear),
                  ),
                ]
              : wide
                  ? [
                      _summary(isAr),
                      const SizedBox(height: AppSpace.md),
                      _pair(_topEmployees(isAr), _byRule(isAr)),
                      const SizedBox(height: AppSpace.md),
                      _trend(isAr),
                      const SizedBox(height: AppSpace.md),
                      _pair(_approvalRate(isAr, statuses), _byDepartment(isAr)),
                    ]
                  : [
                      _summary(isAr),
                      for (final card in [
                        _topEmployees(isAr),
                        _byRule(isAr),
                        _trend(isAr),
                        _approvalRate(isAr, statuses),
                        _byDepartment(isAr),
                      ]) ...[const SizedBox(height: AppSpace.md), card],
                    ];
          return ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              _periodSelector(isAr),
              const SizedBox(height: AppSpace.md),
              ...cards,
              const SizedBox(height: AppSpace.lg),
            ],
          );
        },
      ),
    );
  }

  Widget _pair(Widget a, Widget b) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Expanded(child: a), const SizedBox(width: AppSpace.md), Expanded(child: b)],
      );

  Widget _periodSelector(bool isAr) {
    return SegmentedButton<_AnalyticsPeriod>(
      key: const Key('analytics-period'),
      segments: [
        ButtonSegment(value: _AnalyticsPeriod.last30, label: Text(isAr ? '30 يومًا' : '30 days')),
        ButtonSegment(value: _AnalyticsPeriod.last90, label: Text(isAr ? '90 يومًا' : '90 days')),
        ButtonSegment(value: _AnalyticsPeriod.lastYear, label: Text(isAr ? 'سنة' : 'Year')),
      ],
      selected: {_period},
      showSelectedIcon: false,
      onSelectionChanged: (v) => _choose(v.first),
    );
  }

  /// What was granted and what waits, said first.
  Widget _summary(bool isAr) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    Widget figure(String label, String value, SemanticTone tone, Key key) => Expanded(
          child: Container(
            key: key,
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              color: tone.container,
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelMedium?.copyWith(color: tone.onContainer)),
                const SizedBox(height: AppSpace.xs),
                Text(value,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(color: tone.onContainer, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        );
    return Row(children: [
      figure('مُنح (معتمد ومدفوع)', _money((_data?['granted_total'] as num?) ?? 0), tones.gold,
          const Key('analytics-granted')),
      const SizedBox(width: AppSpace.md),
      figure('ينتظر الاعتماد', _money((_data?['pending_total'] as num?) ?? 0), tones.warning,
          const Key('analytics-pending')),
    ]);
  }

  Widget _topEmployees(bool isAr) {
    final rows = _list('by_employee').take(5).toList();
    final max = rows.isEmpty ? 1.0 : ((rows.first['amount'] as num?) ?? 1).toDouble();
    return _AnalyticsCard(
      icon: Icons.emoji_events_outlined,
      title: isAr ? 'أعلى الموظفين مكافآت' : 'Top employees',
      subtitle: _periodLabel(),
      child: rows.isEmpty
          ? _miniEmpty('لا شيء مُنح')
          : Column(children: [
              for (final (i, r) in rows.indexed)
                _BarRow(
                  rank: i + 1,
                  label: '${r['name']}',
                  value: _money((r['amount'] as num?) ?? 0),
                  fraction: max > 0 ? ((r['amount'] as num?) ?? 0) / max : 0,
                ),
            ]),
    );
  }

  Widget _byRule(bool isAr) {
    final theme = Theme.of(context);
    final palette = AppChartPalette.categorical(context);
    final rules = _list('by_rule');
    // Colour follows the rule, not its rank: by its id, manual last.
    final ids = [for (final r in rules) r['rule_id']]..sort((a, b) {
        if (a == null) return 1;
        if (b == null) return -1;
        return (a as num).compareTo(b as num);
      });
    Color colorOf(Map r) {
      final slot = ids.indexOf(r['rule_id']);
      return slot >= 0 && slot < palette.length ? palette[slot] : AppChartPalette.other(context);
    }

    return _AnalyticsCard(
      icon: Icons.donut_large_rounded,
      title: isAr ? 'التوزيع حسب القاعدة' : 'By rule',
      subtitle: '${isAr ? 'الإجمالي' : 'Total'} ${_money((_data?['granted_total'] as num?) ?? 0)}',
      child: rules.isEmpty
          ? _miniEmpty('لا شيء مُنح')
          : Row(children: [
              SizedBox(
                width: 96,
                height: 96,
                child: PieChart(PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: 26,
                  startDegreeOffset: -90,
                  sections: [
                    for (final r in rules)
                      PieChartSectionData(
                        value: ((r['amount'] as num?) ?? 0).toDouble(),
                        color: colorOf(r),
                        radius: 18,
                        showTitle: false,
                      ),
                  ],
                )),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final r in rules)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(color: colorOf(r), shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text('${r['name']}',
                                style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                          ),
                          Text(
                            '${cu.formatAmount((((r['share'] as num?) ?? 0) * 100), decimals: 0)}% · '
                            '${_money((r['amount'] as num?) ?? 0)}',
                            textDirection: TextDirection.ltr,
                            style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ]),
                      ),
                  ],
                ),
              ),
            ]),
    );
  }

  Widget _trend(bool isAr) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final months = _list('by_month');
    final values = [for (final m in months) ((m['amount'] as num?) ?? 0).toDouble()];
    final max = values.fold<double>(0, (a, b) => a > b ? a : b);
    final bar = AppChartPalette.single(context);
    String label(int i) {
      final parts = '${months[i]['month']}'.split('-');
      return parts.length == 2 ? '${int.tryParse(parts[1]) ?? parts[1]}/${parts[0].substring(2)}' : '';
    }

    return _AnalyticsCard(
      icon: Icons.bar_chart_rounded,
      title: isAr ? 'المُنح شهرًا شهرًا' : 'Granted by month',
      subtitle: _periodLabel(),
      child: max == 0
          ? _miniEmpty('لا شيء مُنح')
          : SizedBox(
              height: 150,
              child: BarChart(BarChartData(
                alignment: BarChartAlignment.spaceAround,
                minY: 0,
                maxY: max * 1.15,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: (max / 3).clamp(1.0, 1e12),
                  getDrawingHorizontalLine: (_) => FlLine(color: cs.outlineVariant, strokeWidth: 0.5),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      getTitlesWidget: (value, meta) {
                        final i = value.round();
                        if (i < 0 || i >= months.length) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(label(i),
                              style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                        );
                      },
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  enabled: true,
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) => cs.inverseSurface,
                    getTooltipItem: (group, _, rod, _) => BarTooltipItem(
                      '${label(group.x)}\n${_money(rod.toY)}',
                      theme.textTheme.labelMedium!.copyWith(color: cs.onInverseSurface),
                    ),
                  ),
                ),
                barGroups: [
                  for (final (i, v) in values.indexed)
                    BarChartGroupData(x: i, barRods: [
                      BarChartRodData(
                        toY: v,
                        color: bar,
                        width: months.length > 8 ? 12 : 18,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                      ),
                    ]),
                ],
              )),
            ),
    );
  }

  Widget _approvalRate(bool isAr, Map<String, dynamic> statuses) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final rate = (_data?['approval_rate'] as num?)?.toDouble();
    final tone = rate == null
        ? tones.sectionSlate
        : rate >= 0.75
            ? tones.ready
            : rate >= 0.5
                ? tones.warning
                : tones.blocked;
    int n(String key) => (statuses[key] as num?)?.toInt() ?? 0;
    Widget stat(IconData icon, SemanticTone tone, String label, int value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Icon(icon, size: 14, color: tone.fg),
            const SizedBox(width: 6),
            Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
            Text('$value', style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800)),
          ]),
        );
    return _AnalyticsCard(
      icon: Icons.verified_outlined,
      title: isAr ? 'معدل الاعتماد' : 'Approval rate',
      subtitle: isAr ? 'من المكافآت التي فُصل فيها' : 'of those decided',
      child: Row(children: [
        SizedBox(
          width: 80,
          height: 80,
          child: Stack(alignment: Alignment.center, children: [
            SizedBox(
              width: 80,
              height: 80,
              child: CircularProgressIndicator(
                value: rate ?? 0,
                strokeWidth: 8,
                backgroundColor: theme.colorScheme.outlineVariant,
                valueColor: AlwaysStoppedAnimation<Color>(tone.fg),
              ),
            ),
            Text(
              rate == null ? '—' : '${cu.formatAmount(rate * 100, decimals: 0)}%',
              key: const Key('analytics-rate'),
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ]),
        ),
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Column(children: [
            stat(Icons.check_circle_outline, tones.ready, 'معتمدة', n('approved')),
            stat(Icons.task_alt_rounded, tones.info, 'مدفوعة', n('paid')),
            stat(Icons.cancel_outlined, tones.blocked, 'مرفوضة', n('rejected')),
            stat(Icons.pending_actions_outlined, tones.warning, 'معلّقة', n('pending')),
            if (n('reversed') > 0) stat(Icons.undo_rounded, tones.sectionSlate, 'معكوسة', n('reversed')),
          ]),
        ),
      ]),
    );
  }

  Widget _byDepartment(bool isAr) {
    final rows = _list('by_department').take(5).toList();
    final max = rows.isEmpty ? 1.0 : ((rows.first['amount'] as num?) ?? 1).toDouble();
    return _AnalyticsCard(
      icon: Icons.apartment_rounded,
      title: isAr ? 'حسب القسم' : 'By department',
      subtitle: _periodLabel(),
      child: rows.isEmpty
          ? _miniEmpty('لا شيء مُنح')
          : Column(children: [
              for (final r in rows)
                _BarRow(
                  label: '${r['department']} (${r['employees']})',
                  value: _money((r['amount'] as num?) ?? 0),
                  fraction: max > 0 ? ((r['amount'] as num?) ?? 0) / max : 0,
                ),
            ]),
    );
  }

  Widget _miniEmpty(String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
      child: Center(
        child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ),
    );
  }
}

/// One magnitude as a bar beside its name and figure: one hue, the text in
/// the text colours.
class _BarRow extends StatelessWidget {
  const _BarRow({this.rank, required this.label, required this.value, required this.fraction});

  final int? rank;
  final String label;
  final String value;
  final num fraction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        if (rank != null) ...[
          SizedBox(
            width: 18,
            child: Text('$rank',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        ],
        SizedBox(
          width: 110,
          child: Text(label, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction.toDouble().clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              valueColor: AlwaysStoppedAnimation<Color>(AppChartPalette.single(context)),
            ),
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        Text(value,
            textDirection: TextDirection.ltr,
            style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class _AnalyticsCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;

  const _AnalyticsCard({required this.icon, required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: cs.primary),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    if (subtitle != null)
                      Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: AppSpace.md),
            child,
          ],
        ),
      ),
    );
  }
}
