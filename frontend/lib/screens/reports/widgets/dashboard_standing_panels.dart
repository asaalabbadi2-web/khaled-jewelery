import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/app_semantic_colors.dart';
import '../../../theme/app_tokens.dart';
import 'dashboard_kit.dart';

/// Where the business stands, drawn (DASH-10, the owner 30 Oct 2026:
/// «تصميمات احترافية ومبتكرة»). The figures are the server's (DASH-4/5);
/// these only draw them.

/// What is ours and what we owe, as a balance: each party's line grows from
/// the middle -- ours to one side, theirs to the other, by its size against
/// the largest -- the riyals on it, the grams beneath. Our gold at the offices
/// closes it.
class DashboardBalancePanel extends StatelessWidget {
  const DashboardBalancePanel({super.key, required this.positions, required this.isArabic, required this.money});

  final Map<String, dynamic> positions;
  final bool isArabic;
  final DashboardMoney money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    Map side(String k) => (positions[k] as Map?) ?? const {};
    final parties = [
      (isArabic ? 'العملاء' : 'Customers', side('customers')),
      (isArabic ? 'الموردون' : 'Suppliers', side('suppliers')),
    ];
    final largest = parties
        .expand((p) => [dashboardNum(p.$2['owe_us_cash']), dashboardNum(p.$2['we_owe_cash'])])
        .fold<double>(0, math.max);
    final officesGold = dashboardNum(positions['offices_gold']);
    final offices = ((positions['offices'] as List?) ?? const []).whereType<Map>().toList();
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    return DashboardPanel(
      key: const Key('dashboard-positions'),
      icon: Icons.balance_rounded,
      title: isArabic ? 'لنا وعلينا' : 'Ours and owed',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Legend(color: tones.debit.fg, label: isArabic ? 'لنا' : 'Ours'),
              const Spacer(),
              _Legend(color: tones.credit.fg, label: isArabic ? 'علينا' : 'We owe'),
            ],
          ),
          for (final (name, s) in parties) ...[
            const SizedBox(height: AppSpace.md),
            Text(name, style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            _Balance(
              ours: largest > 0 ? dashboardNum(s['owe_us_cash']) / largest : 0,
              theirs: largest > 0 ? dashboardNum(s['we_owe_cash']) / largest : 0,
              oursColor: tones.debit.fg,
              theirsColor: tones.credit.fg,
              track: scheme.surfaceContainerHighest,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      money.text(dashboardNum(s['owe_us_cash']), style: dashboardFigure(theme.textTheme.bodyMedium)),
                      Text(money.grams(dashboardNum(s['owe_us_gold']), isArabic: isArabic),
                          textDirection: TextDirection.ltr, style: dashboardFigure(muted, weight: FontWeight.w500)),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      money.text(dashboardNum(s['we_owe_cash']), style: dashboardFigure(theme.textTheme.bodyMedium)),
                      Text(money.grams(dashboardNum(s['we_owe_gold']), isArabic: isArabic),
                          textDirection: TextDirection.ltr, style: dashboardFigure(muted, weight: FontWeight.w500)),
                    ],
                  ),
                ),
              ],
            ),
          ],
          if (officesGold.abs() >= 0.0005) ...[
            const SizedBox(height: AppSpace.md),
            Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
            const SizedBox(height: AppSpace.md),
            Row(
              children: [
                Icon(Icons.storefront_outlined, size: 18, color: tones.gold.fg),
                const SizedBox(width: AppSpace.sm),
                Expanded(child: Text(isArabic ? 'ذهبنا لدى المكاتب' : 'Our gold at the offices')),
                Text(money.grams(officesGold, isArabic: isArabic),
                    textDirection: TextDirection.ltr, style: dashboardFigure(theme.textTheme.bodyMedium)),
              ],
            ),
            if (offices.length > 1)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 26, top: 2),
                child: Text(
                  offices.take(3).map((o) => '${o['name']} ${money.weight.format(dashboardNum(o['grams']))}').join(' · '),
                  style: muted,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.labelMedium),
        ],
      );
}

/// Two bars growing from the middle, on a track.
class _Balance extends StatelessWidget {
  const _Balance({
    required this.ours,
    required this.theirs,
    required this.oursColor,
    required this.theirsColor,
    required this.track,
  });

  final double ours;
  final double theirs;
  final Color oursColor;
  final Color theirsColor;
  final Color track;

  @override
  Widget build(BuildContext context) {
    Widget half(double share, Color color, AlignmentDirectional toMiddle) => Expanded(
          child: Container(
            height: 10,
            decoration: BoxDecoration(color: track, borderRadius: BorderRadius.circular(AppRadius.pill)),
            alignment: toMiddle,
            child: FractionallySizedBox(
              widthFactor: share.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(AppRadius.pill)),
              ),
            ),
          ),
        );
    return Row(
      children: [
        half(ours, oursColor, AlignmentDirectional.centerEnd),
        Container(width: 2, height: 16, margin: const EdgeInsets.symmetric(horizontal: 3), color: track),
        half(theirs, theirsColor, AlignmentDirectional.centerStart),
      ],
    );
  }
}

/// What the banks and the instalment companies owe us: one bar, each safe its
/// share of it -- a late one in the alarm's colour -- and each safe's line:
/// its payments, the day it deposits or how long it is late, its amount.
class DashboardClearingPanel extends StatelessWidget {
  const DashboardClearingPanel({super.key, required this.clearing, required this.isArabic, required this.money});

  final Map<String, dynamic> clearing;
  final bool isArabic;
  final DashboardMoney money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final safes = ((clearing['safes'] as List?) ?? const []).whereType<Map>().toList();
    final palette = [tones.info.fg, tones.sectionTeal.fg, tones.sectionPurple.fg, tones.sectionIndigo.fg, tones.cash.fg];
    Color colorOf(int i, Map s) => s['overdue'] == true ? tones.blocked.fg : palette[i % palette.length];
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    return DashboardPanel(
      key: const Key('dashboard-clearing'),
      icon: Icons.account_balance_outlined,
      accent: tones.info.fg,
      title: isArabic ? 'التحصيل المنتظر' : 'Awaiting deposit',
      figure: money.text(dashboardNum(clearing['total']),
          style: dashboardFigure(theme.textTheme.titleSmall, weight: FontWeight.w800)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Half the bar's height: a pill.
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: SizedBox(
              height: 10,
              // Stretched: a ColoredBox with no child takes the least height it may.
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, s) in safes.indexed) ...[
                    if (i > 0) SizedBox(width: 2, child: ColoredBox(color: scheme.surfaceContainerLow)),
                    Expanded(
                      flex: math.max(1, (dashboardNum(s['amount']) * 100).round()),
                      child: ColoredBox(color: colorOf(i, s)),
                    ),
                  ],
                ],
              ),
            ),
          ),
          for (final (i, s) in safes.indexed)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.md),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: colorOf(i, s), shape: BoxShape.circle),
                  ),
                  const SizedBox(width: AppSpace.sm + 2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${s['safe'] ?? ''}', style: theme.textTheme.bodyMedium),
                        Text.rich(
                          TextSpan(children: [
                            TextSpan(text: isArabic ? '${s['payments'] ?? 0} دفعة · ' : '${s['payments'] ?? 0} payments · '),
                            if (s['overdue'] == true)
                              TextSpan(
                                text: isArabic ? 'متأخر' : 'Late',
                                style: TextStyle(color: tones.blocked.fg, fontWeight: FontWeight.w800),
                              ),
                            TextSpan(
                              text: s['overdue'] == true
                                  ? (isArabic ? ' — كان ${s['next_deposit'] ?? '—'}' : ' — due ${s['next_deposit'] ?? '—'}')
                                  : (isArabic ? 'الإيداع ${s['next_deposit'] ?? '—'}' : 'deposit ${s['next_deposit'] ?? '—'}'),
                            ),
                          ]),
                          style: muted,
                        ),
                      ],
                    ),
                  ),
                  money.text(dashboardNum(s['amount']), style: dashboardFigure(theme.textTheme.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
