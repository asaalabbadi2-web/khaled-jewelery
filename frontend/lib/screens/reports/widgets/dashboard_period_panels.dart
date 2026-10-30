import 'package:flutter/material.dart';

import '../../../theme/app_semantic_colors.dart';
import '../../../theme/app_tokens.dart';
import 'dashboard_kit.dart';

/// The month's and the quarter's, drawn (DASH-10, the owner 30 Oct 2026). The
/// figures are the server's (DASH-8/9) and the race's; these only draw them.

/// The VAT as a line of two stations: the last quarter -- filed, or not yet --
/// and this one so far. Each net by its direction, as the returns screen says
/// it; what the filed returns left, and why an output may be nothing.
class DashboardVatPanel extends StatelessWidget {
  const DashboardVatPanel({super.key, required this.vat, required this.isArabic, required this.money});

  final Map<String, dynamic> vat;
  final bool isArabic;
  final DashboardMoney money;

  String _direction(double net) {
    if (net > 0.005) return isArabic ? 'للهيئة' : 'to the authority';
    if (net < -0.005) return isArabic ? 'لكم' : 'to you';
    return isArabic ? 'لا شيء' : 'nothing';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final last = (vat['last_quarter'] as Map?) ?? const {};
    final quarter = (vat['quarter'] as Map?) ?? const {};
    final owed = dashboardNum(vat['owed']);
    final unfiled = last['filed'] == false && dashboardNum(last['net']).abs() > 0.005;
    final salesCharged = (vat['policy'] as Map?)?['sales_vat_charged'] != false;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    Widget station({
      required String title,
      required String period,
      required double net,
      required Widget node,
      String? status,
      Color? statusColor,
      bool last = false,
    }) =>
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 22,
                child: Column(
                  children: [
                    node,
                    if (!last)
                      Expanded(child: Container(width: 2, color: scheme.outlineVariant)),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: last ? 0 : AppSpace.lg),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                            Text(period, textDirection: TextDirection.ltr, style: muted),
                            if (status != null)
                              Text(status,
                                  style: theme.textTheme.labelMedium
                                      ?.copyWith(color: statusColor, fontWeight: FontWeight.w800)),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          money.text(net.abs(), style: dashboardFigure(theme.textTheme.bodyMedium)),
                          Text(_direction(net), style: muted),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );

    Widget ring(Color color, {bool filled = false}) => Container(
          width: 14,
          height: 14,
          margin: const EdgeInsets.only(top: 3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? color : null,
            border: Border.all(color: color, width: 2),
          ),
        );

    return DashboardPanel(
      key: const Key('dashboard-vat'),
      icon: Icons.receipt_long_outlined,
      accent: tones.sectionIndigo.fg,
      title: isArabic ? 'ضريبة القيمة المضافة' : 'VAT',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          station(
            title: isArabic ? 'الربع الماضي' : 'Last quarter',
            period: '${last['start'] ?? ''} – ${last['end'] ?? ''}',
            net: dashboardNum(last['net']),
            node: ring(unfiled ? tones.warning.fg : tones.ready.fg, filled: !unfiled),
            status: last['filed'] == true
                ? (isArabic ? 'مُقدَّم' : 'Filed')
                : (unfiled ? (isArabic ? 'لم يُقدَّم إقراره' : 'Not filed') : null),
            statusColor: unfiled ? tones.warning.fg : tones.ready.fg,
          ),
          station(
            title: isArabic ? 'هذا الربع حتى اليوم' : 'This quarter so far',
            period: '${quarter['start'] ?? ''} – ${quarter['end'] ?? ''}',
            net: dashboardNum(quarter['net']),
            node: ring(scheme.primary),
            last: true,
          ),
          if (owed.abs() > 0.005) ...[
            const SizedBox(height: AppSpace.md),
            Row(
              children: [
                Expanded(child: Text(isArabic ? 'المتبقي من الإقرارات المقدَّمة' : 'Left by the filed returns')),
                money.text(owed.abs(), style: dashboardFigure(theme.textTheme.bodyMedium)),
                const SizedBox(width: 6),
                Text(_direction(owed), style: muted),
              ],
            ),
          ],
          if (!salesCharged) ...[
            const SizedBox(height: AppSpace.md),
            Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    isArabic ? 'المبيعات لا تُحمَّل ضريبة حسب السياسة السارية' : 'Sales carry no VAT under the policy in force',
                    style: muted,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The month's three leaders on a podium -- the first in the middle and
/// tallest, in gold, silver and bronze -- the race's points on each; beneath,
/// each employee's invoices at a loss.
class DashboardEmployeesPanel extends StatelessWidget {
  const DashboardEmployeesPanel({
    super.key,
    required this.leaders,
    required this.deficits,
    required this.isArabic,
    required this.money,
  });

  final List<Map<String, dynamic>> leaders;
  final Map<String, dynamic> deficits;
  final bool isArabic;
  final DashboardMoney money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final top = leaders.take(3).toList();
    final losers = ((deficits['employees'] as List?) ?? const []).whereType<Map>().toList();
    final medals = [tones.gold.fg, tones.silver.fg, tones.bronze.fg];
    const heights = [100.0, 80.0, 64.0];
    // The podium's order: second, first, third.
    final order = [if (top.length > 1) 1, 0, if (top.length > 2) 2];
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    Widget step(int rank) {
      final r = top[rank];
      return Expanded(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text('${r['name'] ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpace.xs),
            Container(
              height: heights[rank],
              margin: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [medals[rank].withValues(alpha: 0.35), medals[rank].withValues(alpha: 0.08)],
                ),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.control)),
                border: Border(top: BorderSide(color: medals[rank], width: 3)),
              ),
              alignment: Alignment.topCenter,
              padding: const EdgeInsets.only(top: AppSpace.sm),
              child: Column(
                children: [
                  Text('${rank + 1}',
                      style: dashboardFigure(theme.textTheme.titleMedium, weight: FontWeight.w900, color: medals[rank])),
                  Text('${r['score'] ?? 0} ${isArabic ? 'نقطة' : 'pts'}',
                      style: dashboardFigure(theme.textTheme.labelMedium)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return DashboardPanel(
      key: const Key('dashboard-employees'),
      icon: Icons.emoji_events_outlined,
      accent: tones.gold.fg,
      title: isArabic ? 'الموظفون' : 'Employees',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (top.isNotEmpty)
            SizedBox(
              height: 160,
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [for (final i in order) step(i)]),
            ),
          if (losers.isNotEmpty) ...[
            const SizedBox(height: AppSpace.lg),
            Text(isArabic ? 'فواتير بخسارة' : 'Invoices at a loss',
                style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
            for (final e in losers)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Row(
                  children: [
                    Container(
                      width: 3,
                      height: 30,
                      decoration: BoxDecoration(color: scheme.error, borderRadius: BorderRadius.circular(AppRadius.pill)),
                    ),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${e['name'] ?? ''}', style: theme.textTheme.bodyMedium),
                          Text(isArabic ? '${e['count'] ?? 0} فاتورة' : '${e['count'] ?? 0} invoices', style: muted),
                        ],
                      ),
                    ),
                    money.text(dashboardNum(e['loss_cash']),
                        style: dashboardFigure(theme.textTheme.bodyMedium, color: scheme.error)),
                  ],
                ),
              ),
          ] else if (top.isNotEmpty) ...[
            const SizedBox(height: AppSpace.md),
            Text(isArabic ? 'لا فواتير بخسارة هذا الشهر' : 'No invoice at a loss this month', style: muted),
          ],
        ],
      ),
    );
  }
}
