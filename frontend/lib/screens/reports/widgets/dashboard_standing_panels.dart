import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../../theme/app_semantic_colors.dart';
import '../../../theme/app_tokens.dart';
import '../../../utils/bidi.dart';
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
              _Legend(color: dashboardMark(context, tones.debit.fg), label: isArabic ? 'لنا' : 'Ours'),
              const Spacer(),
              _Legend(color: dashboardMark(context, tones.credit.fg), label: isArabic ? 'علينا' : 'We owe'),
            ],
          ),
          for (final (name, s) in parties) ...[
            const SizedBox(height: AppSpace.md),
            Text(name, style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            _Balance(
              ours: largest > 0 ? dashboardNum(s['owe_us_cash']) / largest : 0,
              theirs: largest > 0 ? dashboardNum(s['we_owe_cash']) / largest : 0,
              oursColor: dashboardMark(context, tones.debit.fg),
              theirsColor: dashboardMark(context, tones.credit.fg),
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
    Color colorOf(int i, Map s) =>
        dashboardMark(context, s['overdue'] == true ? tones.blocked.fg : palette[i % palette.length]);
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
          // What of it is expected to arrive: each payment's commission and its VAT
          // off (the owner, 14 Nov 2026: «في الطريق يكون صافي»). The figure above
          // stays gross: it is what the settlement matches against the bank.
          if (clearing['total_net'] is num)
            Padding(
              key: const Key('dashboard-clearing-net'),
              padding: const EdgeInsets.only(top: AppSpace.sm),
              child: Row(children: [
                Text(isArabic ? 'يصل منه صافيًا بعد العمولات  ' : 'Arriving net of commissions  ', style: muted),
                money.text(dashboardNum(clearing['total_net']),
                    style: dashboardFigure(theme.textTheme.bodySmall, weight: FontWeight.w700)),
              ]),
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
                            // Late, below its minimum, or its deposit's day -- the
                            // scheduler's own reading, the server's (the 31 Oct copy).
                            TextSpan(
                              text: s['overdue'] == true
                                  ? (isArabic
                                      ? ' — كان ${s['overdue_since'] ?? s['next_deposit'] ?? '—'}'
                                      : ' — due ${s['overdue_since'] ?? s['next_deposit'] ?? '—'}')
                                  : s['below_minimum'] == true
                                      ? (isArabic ? 'دون الحد الأدنى للإيداع' : 'below its minimum to deposit')
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

/// What the shop will pay soon (the owner, 15 Nov 2026): each period expense
/// still to pay -- what is left of it, by its end, what of it is owed now --
/// the salaries owed, the suppliers in riyals and grams, the VAT; their
/// riyals together on its head. *upcoming* null: the server could not read
/// it, and it says so.
class DashboardUpcomingPanel extends StatelessWidget {
  const DashboardUpcomingPanel({super.key, required this.upcoming, required this.isArabic, required this.money});

  final Map<String, dynamic>? upcoming;
  final bool isArabic;
  final DashboardMoney money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final figure = dashboardFigure(theme.textTheme.bodyMedium, weight: FontWeight.w700);
    final notRead = isArabic ? 'غير متاح' : 'Not available';
    final u = upcoming;
    final total = u?['total_cash'];

    DashboardAmountRow row(String key, String name, num? amount, {String? note, String? grams}) => DashboardAmountRow(
          label: Column(
            key: Key('dashboard-upcoming-$key'),
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name, style: theme.textTheme.bodyMedium),
              if (note != null) Text(note, style: muted),
            ],
          ),
          amount: amount == null ? Text(notRead, style: muted) : money.text(amount, style: figure),
          weight: grams,
        );

    final rows = <DashboardAmountRow>[];
    if (u != null) {
      for (final e in ((u['period_expenses'] as List?) ?? const []).whereType<Map>()) {
        final by = DateTime.tryParse('${e['by']}');
        final owed = dashboardNum(e['owed_now']);
        rows.add(row(
          'expense-${e['id']}',
          '${e['name']}',
          dashboardNum(e['to_pay']),
          note: [
            if (by != null) (isArabic ? 'حتى ' : 'by ') + ltrIsolate(DateFormat('dd/MM/yyyy').format(by)),
            if (owed > 0.005) (isArabic ? 'المستحق منه الآن ' : 'owed now ') + money.cash(owed),
          ].join(' · '),
        ));
      }
      final salaries = (u['salaries'] as Map?) ?? const {};
      if (dashboardNum(salaries['amount']) > 0.005) {
        rows.add(row('salaries', isArabic ? 'رواتب مستحقة (${salaries['count']})' : 'Salaries owed (${salaries['count']})',
            dashboardNum(salaries['amount'])));
      }
      final suppliers = (u['suppliers'] as Map?) ?? const {};
      final gold = suppliers['gold'];
      if (suppliers['cash'] == null || dashboardNum(suppliers['cash']) > 0.005 || dashboardNum(gold) > 0.0005) {
        rows.add(row('suppliers', isArabic ? 'للموردين (${suppliers['count'] ?? '—'})' : 'Suppliers',
            suppliers['cash'] as num?, grams: dashboardNum(gold) > 0.0005 ? money.grams(dashboardNum(gold), isArabic: isArabic) : null));
      }
      if (dashboardNum(u['vat']) > 0.005) {
        rows.add(row('vat', isArabic ? 'الضريبة للهيئة' : 'VAT to the authority', dashboardNum(u['vat'])));
      }
    }

    return DashboardPanel(
      key: const Key('dashboard-upcoming'),
      icon: Icons.event_note_outlined,
      accent: tones.warning.fg,
      title: isArabic ? 'التزامات قادمة' : 'Coming payments',
      figure: total is num
          ? money.text(total, style: dashboardFigure(theme.textTheme.titleSmall, weight: FontWeight.w800))
          : Text(notRead, style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
      child: u == null
          ? Text(isArabic ? 'تعذّرت قراءتها' : 'Could not be read', style: muted)
          : rows.isEmpty
              ? Text(isArabic ? 'لا التزامات قادمة' : 'Nothing to pay', style: muted)
              : DashboardAmountTable(rows: rows),
    );
  }
}

/// Is the system doing its own work (the owner, 15 Nov 2026): the scheduler
/// alive, the nightly check's last run, the server's newest backup -- each a
/// line with its state said in words and an icon, never a colour alone.
/// *health* null: the server could not read it.
class DashboardHealthPanel extends StatelessWidget {
  const DashboardHealthPanel({super.key, required this.health, required this.isArabic});

  final Map<String, dynamic>? health;
  final bool isArabic;

  static String _when(dynamic iso) {
    final at = DateTime.tryParse('${iso ?? ''}');
    return at == null ? '' : ltrIsolate(DateFormat('dd/MM HH:mm').format(at.toLocal()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final h = health;

    Widget line(String key, String name, bool ok, String said) => Padding(
          key: Key('dashboard-health-$key'),
          padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
          child: Row(children: [
            Icon(ok ? Icons.check_circle_outline_rounded : Icons.warning_amber_rounded,
                size: 18, color: ok ? tones.ready.fg : tones.warning.fg),
            const SizedBox(width: AppSpace.sm),
            Text(name, style: theme.textTheme.bodyMedium),
            const SizedBox(width: AppSpace.md),
            Expanded(child: Text(said, textAlign: TextAlign.end, style: muted)),
          ]),
        );

    final rows = <Widget>[];
    if (h != null) {
      final scheduler = (h['scheduler'] as Map?) ?? const {};
      final alive = scheduler['alive'] == true;
      rows.add(line(
        'scheduler',
        isArabic ? 'المجدولات' : 'Schedulers',
        alive,
        alive
            ? (isArabic ? 'تعمل' : 'Running')
            : scheduler['silent_minutes'] == null
                ? (isArabic ? 'لم تبدأ قط' : 'Never started')
                : (isArabic ? 'صامتة منذ ${scheduler['silent_minutes']} دقيقة' : 'Silent ${scheduler['silent_minutes']} min'),
      ));
      final nightly = (h['nightly'] as Map?) ?? const {};
      rows.add(line(
        'nightly',
        isArabic ? 'الفحص الليلي' : 'Nightly check',
        nightly['late'] != true,
        nightly['last'] == null
            ? (isArabic ? 'لم يُسجَّل تشغيل' : 'No run recorded')
            : (isArabic ? 'آخر تشغيل ' : 'Last run ') + _when(nightly['last']) +
                (nightly['late'] == true ? (isArabic ? ' — متأخر' : ' — late') : ''),
      ));
      final backup = (h['backup'] as Map?) ?? const {};
      rows.add(line(
        'backup',
        isArabic ? 'النسخ الاحتياطي على الخادم' : 'Server backups',
        backup['last'] != null,
        backup['last'] == null
            ? (isArabic ? 'لا نسخة على الخادم' : 'None on the server')
            : (isArabic ? 'آخر نسخة ' : 'Newest ') + _when(backup['last']),
      ));
      if (backup['auto'] != true) {
        rows.add(Text(isArabic ? 'النسخ التلقائي على الخادم غير مفعّل' : 'Automatic server backups are off',
            style: muted));
      }
      // ADR-098: the shop name's HTTPS certificate -- not said when not configured or not yet on
      final cert = h['certificate'] as Map?;
      if (cert != null && cert['state'] != 'disabled') {
        final reasons = [for (final r in (cert['reasons'] as List? ?? const [])) '$r'];
        final days = cert['days_left'];
        final said = <String>[
          if (reasons.contains('missing')) isArabic ? 'لم تكتب أداة الشهادة حالتها' : 'The certificate tool wrote no status',
          if (reasons.contains('failed'))
            (isArabic ? 'فشل آخر تجديد' : 'The last renewal failed') +
                (cert['error'] == null ? '' : ': ${cert['error']}'),
          if (reasons.contains('stale'))
            (isArabic ? 'أداة التجديد صامتة منذ ' : 'The renewal tool silent since ') +
                (cert['attempt_at'] == null ? '—' : _when(cert['attempt_at'])),
          if (reasons.contains('staging'))
            isArabic ? 'شهادة تجربة لا يثق بها المتصفح' : 'A staging certificate no browser trusts',
          if (days != null) isArabic ? 'تنتهي بعد $days يومًا' : 'Expires in $days days',
          if (reasons.isEmpty && cert['last_renewed_at'] != null)
            (isArabic ? 'آخر تجديد ' : 'Last renewed ') + _when(cert['last_renewed_at']),
        ];
        rows.add(line('certificate', isArabic ? 'شهادة HTTPS' : 'HTTPS certificate', cert['state'] == 'ok',
            said.join(' · ')));
      }
    }

    return DashboardPanel(
      key: const Key('dashboard-health'),
      icon: Icons.monitor_heart_outlined,
      accent: tones.info.fg,
      title: isArabic ? 'صحة النظام' : 'System health',
      child: h == null
          ? Text(isArabic ? 'غير متاح: تعذّرت قراءتها' : 'Not available', style: muted)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
    );
  }
}
