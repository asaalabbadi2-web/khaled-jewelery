import 'package:flutter/material.dart';

import '../../../theme/app_semantic_colors.dart';
import '../../../theme/app_tokens.dart';
import 'dashboard_kit.dart';

/// What needs the manager, in one line under the header (DASH-10, the owner
/// 30 Oct 2026: «بطاقة التنبيهات حجمها كبير ولونها في الوضع الداكن مزعج، أريد
/// طريقة مبتكرة لعرض التنبيهات»). A pill each -- what is wrong (DASH-7) and
/// what waits for approval (DASH-6) -- a dot of its colour, its count, its
/// name; a tap opens its rows beneath, each marked by a thin rail of colour,
/// not a filled block. Nothing needing him is one quiet pill.
class DashboardAttentionBar extends StatefulWidget {
  const DashboardAttentionBar({
    super.key,
    required this.wrongNow,
    required this.approvals,
    required this.isArabic,
    required this.money,
  });

  final Map<String, dynamic> wrongNow;
  final Map<String, dynamic> approvals;
  final bool isArabic;
  final DashboardMoney money;

  @override
  State<DashboardAttentionBar> createState() => _DashboardAttentionBarState();
}

enum _Open { alerts, approvals }

const _queues = <(String, String, String)>[
  ('invoices', 'فواتير', 'Invoices'),
  ('vouchers', 'سندات', 'Vouchers'),
  ('bonuses', 'مكافآت', 'Bonuses'),
  ('reservations', 'حجوزات المكاتب', 'Office reservations'),
];

class _DashboardAttentionBarState extends State<DashboardAttentionBar> {
  _Open? _open;

  int get _alerts => (widget.wrongNow['total'] as num?)?.toInt() ?? 0;
  int get _waiting => (widget.approvals['total'] as num?)?.toInt() ?? 0;

  void _toggle(_Open which) => setState(() => _open = _open == which ? null : which);

  @override
  Widget build(BuildContext context) {
    final tones = AppSemanticColors.of(context);
    final isArabic = widget.isArabic;
    final pills = <Widget>[
      if (_alerts > 0)
        _Pill(
          key: const Key('dashboard-wrong-now'),
          tone: tones.blocked.fg,
          pulse: true,
          label: isArabic ? 'تنبيهات' : 'Alerts',
          count: _alerts,
          open: _open == _Open.alerts,
          onTap: () => _toggle(_Open.alerts),
        ),
      if (_waiting > 0)
        _Pill(
          key: const Key('dashboard-approvals'),
          tone: tones.warning.fg,
          label: isArabic ? 'بانتظار اعتمادك' : 'Awaiting you',
          count: _waiting,
          open: _open == _Open.approvals,
          onTap: () => _toggle(_Open.approvals),
        ),
      if (_alerts == 0 && _waiting == 0)
        _Pill(
          key: const Key('dashboard-all-clear'),
          tone: tones.ready.fg,
          icon: Icons.check_rounded,
          label: isArabic ? 'لا شيء يحتاجك الآن' : 'Nothing needs you now',
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(spacing: AppSpace.sm, runSpacing: AppSpace.sm, children: pills),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: AlignmentDirectional.topStart,
          child: _open == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: AppSpace.sm),
                  child: _Detail(
                    key: const Key('dashboard-attention-detail'),
                    rows: _open == _Open.alerts ? _alertRows(tones) : _approvalRows(tones),
                  ),
                ),
        ),
      ],
    );
  }

  List<_Row> _alertRows(AppSemanticColors tones) {
    final isArabic = widget.isArabic;
    final findings = ((widget.wrongNow['findings'] as List?) ?? const []).whereType<Map>();
    final safes = ((widget.wrongNow['negative_safes'] as List?) ?? const []).whereType<Map>();
    return [
      for (final f in findings)
        _Row(
          rail: tones.blocked.fg,
          label: '${f['title'] ?? f['kind']}',
          sub: f['since'] == null ? null : (isArabic ? 'منذ ${f['since']}' : 'since ${f['since']}'),
          value: Text('${f['count'] ?? 0}'),
        ),
      for (final s in safes)
        _Row(
          rail: tones.warning.fg,
          label: isArabic ? '${s['safe']} تحت الصفر' : '${s['safe']} below zero',
          value: s['cash'] != null
              ? widget.money.text(dashboardNum(s['cash']))
              : Text(widget.money.grams(dashboardNum(s['grams']), isArabic: isArabic),
                  textDirection: TextDirection.ltr),
        ),
    ];
  }

  List<_Row> _approvalRows(AppSemanticColors tones) {
    final isArabic = widget.isArabic;
    return [
      for (final q in _queues)
        if ((((widget.approvals[q.$1] as Map?)?['count']) as num? ?? 0) > 0)
          _Row(
            rail: tones.warning.fg,
            label: '${(widget.approvals[q.$1] as Map)['count']} ${isArabic ? q.$2 : q.$3}',
            sub: (widget.approvals[q.$1] as Map)['oldest'] == null
                ? null
                : (isArabic
                    ? 'الأقدم ${(widget.approvals[q.$1] as Map)['oldest']}'
                    : 'oldest ${(widget.approvals[q.$1] as Map)['oldest']}'),
            value: widget.money.text(dashboardNum((widget.approvals[q.$1] as Map)['amount'])),
          ),
    ];
  }
}

/// A dot of the pill's colour, its count and its name; outlined, its colour
/// at a whisper behind it -- in the dark theme as in the light.
class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.tone,
    required this.label,
    this.count,
    this.icon,
    this.pulse = false,
    this.open = false,
    this.onTap,
  });

  final Color tone;
  final String label;
  final int? count;
  final IconData? icon;
  final bool pulse;
  final bool open;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Material(
      color: tone.withValues(alpha: open ? (dark ? 0.16 : 0.12) : (dark ? 0.08 : 0.06)),
      shape: StadiumBorder(side: BorderSide(color: tone.withValues(alpha: open ? 0.6 : 0.3))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.md, 6, AppSpace.sm + 2, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null)
                Icon(icon, size: 16, color: tone)
              else
                _Dot(color: tone, pulse: pulse),
              const SizedBox(width: AppSpace.sm),
              if (count != null) ...[
                Text('$count', style: dashboardFigure(theme.textTheme.labelLarge, weight: FontWeight.w800)),
                const SizedBox(width: 6),
              ],
              Text(label, style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurface)),
              if (onTap != null) ...[
                const SizedBox(width: 2),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.expand_more_rounded, size: 18, color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A dot; an alert's breathes -- a ring widening and fading -- unless the
/// device asks for less motion.
class _Dot extends StatefulWidget {
  const _Dot({required this.color, this.pulse = false});

  final Color color;
  final bool pulse;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.pulse && !still) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const size = 8.0;
    return SizedBox(
      width: size * 2,
      height: size * 2,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(
          alignment: Alignment.center,
          children: [
            if (widget.pulse)
              Container(
                width: size + size * _c.value,
                height: size + size * _c.value,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: 0.35 * (1 - _c.value)),
                ),
              ),
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row {
  const _Row({required this.rail, required this.label, required this.value, this.sub});

  final Color rail;
  final String label;
  final String? sub;
  final Widget value;
}

/// An open pill's rows: a thin rail of colour, the line in the text's colour.
class _Detail extends StatelessWidget {
  const _Detail({super.key, required this.rows});

  final List<_Row> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        children: [
          for (final (i, r) in rows.indexed) ...[
            if (i > 0) Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: r.sub == null ? 18 : 32,
                    decoration: BoxDecoration(color: r.rail, borderRadius: BorderRadius.circular(AppRadius.pill)),
                  ),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.label, style: theme.textTheme.bodyMedium),
                        if (r.sub != null)
                          Text(r.sub!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  DefaultTextStyle.merge(
                    style: dashboardFigure(theme.textTheme.bodyMedium),
                    child: r.value,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
