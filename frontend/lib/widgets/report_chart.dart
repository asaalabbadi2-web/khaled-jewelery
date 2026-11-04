import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../models/report_contract.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils/report_export.dart';

/// The one chart a report asks for over its table (REPORTS ت4-2, ADR-083; the
/// owner, 4 Nov 2026): its rows along x, its figures up -- one axis for all,
/// each series in the theme's chart colours in fixed order (ت4-4ب; validated
/// in both modes), side by side in a row's group. One series: its title names
/// it, no legend; more: a legend names each, and a bar's tooltip says its
/// series -- identity never by colour alone. Time reads left to right, as the
/// figures do. A tooltip writes its value as the table does; the table stays
/// the record, and what reads it (Excel, PDF, print) is unchanged. Fewer than
/// two points: no chart.
class ReportBarChart extends StatelessWidget {
  const ReportBarChart({super.key, required this.report});

  final ReportData report;

  static bool drawn(ReportData report) =>
      report.chart != null && _points(report).length >= 2;

  /// (x, its figures in series order -- 0 where a row has none).
  static List<(String, List<double>)> _points(ReportData report) {
    final chart = report.chart!;
    return [
      for (final row in report.rows)
        if (row.style == ReportRowStyle.line &&
            chart.series.any((y) => row[y] is num))
          (
            '${row[chart.x] ?? ''}',
            [for (final y in chart.series) (row[y] as num?)?.toDouble() ?? 0],
          ),
    ];
  }

  /// A round step for about four ticks: 1, 2, 2.5 or 5 times a power of ten.
  static double _step(double span) {
    final raw = span / 4;
    if (raw <= 0) return 1;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final norm = raw / mag;
    final nice = norm <= 1
        ? 1.0
        : norm <= 2
        ? 2.0
        : norm <= 2.5
        ? 2.5
        : norm <= 5
        ? 5.0
        : 10.0;
    return nice * mag;
  }

  /// A day's own date, a month as MM/YY: the axis's words, short.
  static String _short(String x) {
    final parts = x.split('-');
    if (parts.length == 3) return parts[2];
    if (parts.length == 2 && parts[0].length == 4) {
      return '${parts[1]}/${parts[0].substring(2)}';
    }
    return x;
  }

  @override
  Widget build(BuildContext context) {
    final chart = report.chart!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final series = [
      for (final y in chart.series)
        report.columns.firstWhere((c) => c.key == y),
    ];
    final colors = AppSemanticColors.of(context).chartSeries;
    final xColumn = report.columns.firstWhere((c) => c.key == chart.x);
    final points = _points(report);
    final values = [for (final p in points) ...p.$2];
    final high = values.reduce((a, b) => a > b ? a : b);
    final low = values.reduce((a, b) => a < b ? a : b);
    // bars stand on zero; a line's axis spans its values (a price over time)
    final line = chart.kind == 'line';
    final step = line
        ? _step(high - low > 0 ? high - low : high.abs() + 1)
        : _step(math.max(high, 0) - math.min(low, 0));
    final top = line
        ? (high / step).ceil() * step
        : high > 0
        ? (high / step).ceil() * step
        : step;
    final bottom = line
        ? (low / step).floor() * step
        : low < 0
        ? (low / step).floor() * step
        : 0.0;
    final every = (points.length / 12).ceil();
    final compact = NumberFormat.compact(locale: 'en');
    final axis = theme.textTheme.labelSmall?.copyWith(
      color: cs.onSurfaceVariant,
    );
    final title =
        '${series.map((c) => c.label).join(' و')} حسب ${xColumn.label}';
    final grid = FlGridData(
      drawVerticalLine: false,
      horizontalInterval: step,
      getDrawingHorizontalLine: (_) =>
          FlLine(color: cs.outlineVariant, strokeWidth: 0.5),
    );
    final titles = FlTitlesData(
      rightTitles: const AxisTitles(),
      topTitles: const AxisTitles(),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 44,
          interval: step,
          getTitlesWidget: (value, meta) =>
              Text(compact.format(value), style: axis),
        ),
      ),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 22,
          interval: every.toDouble(),
          getTitlesWidget: (value, meta) {
            final i = value.round();
            if (i < 0 || i >= points.length || i % every != 0) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_short(points[i].$1), style: axis),
            );
          },
        ),
      ),
    );
    final tooltipStyle = theme.textTheme.labelMedium!.copyWith(
      color: cs.onInverseSurface,
    );
    String tip(int x, int s, double v) =>
        '${points[x].$1}\n'
        '${series.length > 1 ? '${series[s].label}: ' : ''}'
        '${reportCell(series[s], v)}';

    return Card(
      key: const ValueKey('report-chart'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            if (series.length > 1) ...[
              const SizedBox(height: AppSpace.sm),
              Wrap(
                key: const ValueKey('report-chart-legend'),
                spacing: AppSpace.md,
                children: [
                  for (final (i, c) in series.indexed)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: colors[i % colors.length],
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: AppSpace.xs),
                        Text(c.label, style: axis),
                      ],
                    ),
                ],
              ),
            ],
            const SizedBox(height: AppSpace.md),
            Semantics(
              label: title,
              child: SizedBox(
                height: 220,
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: LayoutBuilder(
                    builder: (context, box) {
                      if (line) {
                        return LineChart(
                          LineChartData(
                            minX: 0,
                            maxX: (points.length - 1).toDouble(),
                            minY: bottom,
                            maxY: top,
                            gridData: grid,
                            borderData: FlBorderData(show: false),
                            titlesData: titles,
                            lineTouchData: LineTouchData(
                              touchTooltipData: LineTouchTooltipData(
                                getTooltipColor: (_) => cs.inverseSurface,
                                getTooltipItems: (spots) => [
                                  for (final spot in spots)
                                    LineTooltipItem(
                                      tip(
                                        spot.x.round(),
                                        spot.barIndex,
                                        spot.y,
                                      ),
                                      tooltipStyle,
                                    ),
                                ],
                              ),
                            ),
                            lineBarsData: [
                              for (final s in series.indexed)
                                LineChartBarData(
                                  spots: [
                                    for (final (i, (_, vs)) in points.indexed)
                                      FlSpot(i.toDouble(), vs[s.$1]),
                                  ],
                                  color: colors[s.$1 % colors.length],
                                  barWidth: 2,
                                  dotData: const FlDotData(show: false),
                                ),
                            ],
                          ),
                        );
                      }
                      final slot = box.maxWidth / points.length;
                      // a row's bars share 60 % of its slot, 2px apart
                      final width = (slot * 0.6 / series.length).clamp(
                        2.0,
                        24.0,
                      );
                      return BarChart(
                        BarChartData(
                          alignment: BarChartAlignment.spaceAround,
                          minY: bottom,
                          maxY: top,
                          gridData: grid,
                          borderData: FlBorderData(show: false),
                          titlesData: titles,
                          barTouchData: BarTouchData(
                            touchTooltipData: BarTouchTooltipData(
                              getTooltipColor: (_) => cs.inverseSurface,
                              getTooltipItem: (group, _, rod, index) =>
                                  BarTooltipItem(
                                    tip(group.x, index, rod.toY),
                                    tooltipStyle,
                                  ),
                            ),
                          ),
                          barGroups: [
                            for (final (i, (_, vs)) in points.indexed)
                              BarChartGroupData(
                                x: i,
                                barsSpace: 2,
                                barRods: [
                                  for (final (s, v) in vs.indexed)
                                    BarChartRodData(
                                      toY: v,
                                      color: colors[s % colors.length],
                                      width: width,
                                      borderRadius: v >= 0
                                          ? const BorderRadius.vertical(
                                              top: Radius.circular(4),
                                            )
                                          : const BorderRadius.vertical(
                                              bottom: Radius.circular(4),
                                            ),
                                    ),
                                ],
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
