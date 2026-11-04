import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../models/report_contract.dart';
import '../theme/app_tokens.dart';
import '../utils/report_export.dart';

/// The one chart a report asks for over its table (REPORTS ت4-2, ADR-083; the
/// owner, 4 Nov 2026): its rows along x, one figure up -- one series, one axis,
/// in the theme's primary, its title naming it (no legend for one series).
/// Time reads left to right, as the figures do. A bar's tooltip says its row
/// as the table writes it; the table stays the record, and what reads it
/// (Excel, PDF, print) is unchanged. Fewer than two points: no chart.
class ReportBarChart extends StatelessWidget {
  const ReportBarChart({super.key, required this.report});

  final ReportData report;

  static bool drawn(ReportData report) =>
      report.chart != null && _points(report).length >= 2;

  static List<(String, double)> _points(ReportData report) {
    final chart = report.chart!;
    return [
      for (final row in report.rows)
        if (row.style == ReportRowStyle.line && row[chart.y] is num)
          ('${row[chart.x] ?? ''}', (row[chart.y] as num).toDouble()),
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
    final yColumn = report.columns.firstWhere((c) => c.key == chart.y);
    final xColumn = report.columns.firstWhere((c) => c.key == chart.x);
    final points = _points(report);
    final high = points.map((p) => p.$2).reduce((a, b) => a > b ? a : b);
    final low = points.map((p) => p.$2).reduce((a, b) => a < b ? a : b);
    final step = _step(math.max(high, 0) - math.min(low, 0));
    final top = high > 0 ? (high / step).ceil() * step : step;
    final bottom = low < 0 ? (low / step).floor() * step : 0.0;
    final every = (points.length / 12).ceil();
    final compact = NumberFormat.compact(locale: 'en');
    final axis = theme.textTheme.labelSmall?.copyWith(
      color: cs.onSurfaceVariant,
    );
    final title = '${yColumn.label} حسب ${xColumn.label}';

    return Card(
      key: const ValueKey('report-chart'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpace.md),
            Semantics(
              label: title,
              child: SizedBox(
                height: 220,
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final slot = box.maxWidth / points.length;
                      final width = (slot * 0.6).clamp(3.0, 24.0);
                      return BarChart(
                        BarChartData(
                          alignment: BarChartAlignment.spaceAround,
                          minY: bottom,
                          maxY: top,
                          gridData: FlGridData(
                            drawVerticalLine: false,
                            horizontalInterval: step,
                            getDrawingHorizontalLine: (_) => FlLine(
                              color: cs.outlineVariant,
                              strokeWidth: 0.5,
                            ),
                          ),
                          borderData: FlBorderData(show: false),
                          titlesData: FlTitlesData(
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
                                getTitlesWidget: (value, meta) {
                                  final i = value.round();
                                  if (i < 0 ||
                                      i >= points.length ||
                                      i % every != 0) {
                                    return const SizedBox.shrink();
                                  }
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      _short(points[i].$1),
                                      style: axis,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          barTouchData: BarTouchData(
                            touchTooltipData: BarTouchTooltipData(
                              getTooltipColor: (_) => cs.inverseSurface,
                              getTooltipItem: (group, _, rod, _) =>
                                  BarTooltipItem(
                                    '${points[group.x].$1}\n'
                                    '${reportCell(yColumn, rod.toY)}',
                                    theme.textTheme.labelMedium!.copyWith(
                                      color: cs.onInverseSurface,
                                    ),
                                  ),
                            ),
                          ),
                          barGroups: [
                            for (final (i, (_, v)) in points.indexed)
                              BarChartGroupData(
                                x: i,
                                barRods: [
                                  BarChartRodData(
                                    toY: v,
                                    color: cs.primary,
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
