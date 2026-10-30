import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../../theme/app_tokens.dart';
import '../../../utils/currency_utils.dart' as cu;

/// The manager's dashboard's shared pieces (DASH-10, the owner 30 Oct 2026:
/// «تصميمات احترافية ومبتكرة وليس فقط بطاقات مصمتة»). One look for every
/// section: a quiet panel, a section's heading, a grid that is three columns
/// wide and one on a phone, its shape while it loads, and the amounts said the
/// screen's one way.

/// How an amount and a weight are said -- the screen's formats, passed once.
class DashboardMoney {
  const DashboardMoney({
    required this.format,
    required this.symbol,
    required this.isNewSar,
    required this.weight,
  });

  final NumberFormat format;
  final String symbol;
  final bool isNewSar;
  final NumberFormat weight;

  String cash(num v) => '${format.format(v)} $symbol';

  String grams(num v, {bool isArabic = true}) => '${weight.format(v)} ${isArabic ? 'جم' : 'g'}';

  Widget text(num v, {TextStyle? style}) => cu.SarAwareText(cash(v), isNewSar: isNewSar, style: style);
}

double dashboardNum(dynamic v) => v is num ? v.toDouble() : 0.0;

/// Figures read in columns: the same width for every digit.
TextStyle? dashboardFigure(TextStyle? base, {FontWeight weight = FontWeight.w700, Color? color}) =>
    base?.copyWith(fontWeight: weight, color: color, fontFeatures: const [FontFeature.tabularFigures()]);

/// A section's heading: an accent, its name, what it covers, and what acts on it.
class DashboardSection extends StatelessWidget {
  const DashboardSection({super.key, required this.title, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Container(
          width: AppSpace.xs,
          height: 22,
          decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(AppRadius.pill)),
        ),
        const SizedBox(width: AppSpace.sm + 2),
        Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        if (subtitle != null) ...[
          const SizedBox(width: AppSpace.sm + 2),
          Flexible(
            child: Text(subtitle!,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ],
        const Spacer(),
        ?trailing,
      ],
    );
  }
}

/// A quiet panel: the surface a step above the page, a hairline, no fill of
/// colour -- the colour is the data's. A heading with its icon and its figure.
class DashboardPanel extends StatelessWidget {
  const DashboardPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.figure,
    this.accent,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? figure;
  final Color? accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = accent ?? scheme.primary;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                    ),
                    child: Icon(icon, size: 17, color: tint),
                  ),
                  const SizedBox(width: AppSpace.sm + 2),
                  Expanded(
                    child: Text(title,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                  ?figure,
                ],
              ),
              const SizedBox(height: AppSpace.md + 2),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// A panel's shape while its reading is on the way -- the theme's grey, as
/// AppLoadingView draws a page (ADR-057), not a spinner.
class DashboardPanelSkeleton extends StatelessWidget {
  const DashboardPanelSkeleton({super.key, this.lines = 3});

  final int lines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = scheme.surfaceContainerHighest.withValues(alpha: 0.7);
    Widget bar(double width, double height) => FractionallySizedBox(
          alignment: AlignmentDirectional.centerStart,
          widthFactor: width,
          child: Container(
            height: height,
            decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(AppRadius.chip)),
          ),
        );
    return Semantics(
      label: 'جارٍ التحميل',
      child: Container(
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            bar(0.4, 18),
            for (var i = 0; i < lines; i++) ...[
              const SizedBox(height: AppSpace.md),
              bar(i.isEven ? 0.9 : 0.65, 12),
            ],
          ],
        ),
      ),
    );
  }
}

/// Up to three columns on a wide screen, two on a middle one, one on a phone;
/// the last row's tiles share its width.
class DashboardGrid extends StatelessWidget {
  const DashboardGrid({super.key, required this.children, this.minTileWidth = 340});

  final List<Widget> children;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) {
    const spacing = AppSpace.md;
    return LayoutBuilder(builder: (context, constraints) {
      final columns = ((constraints.maxWidth + spacing) ~/ (minTileWidth + spacing)).clamp(1, 3);
      final rows = <Widget>[];
      for (var i = 0; i < children.length; i += columns) {
        final row = children.sublist(i, (i + columns).clamp(0, children.length));
        rows.add(Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (j, tile) in row.indexed) ...[
              if (j > 0) const SizedBox(width: spacing),
              Expanded(child: tile),
            ],
          ],
        ));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, row) in rows.indexed) ...[
            if (i > 0) const SizedBox(height: spacing),
            row,
          ],
        ],
      );
    });
  }
}
