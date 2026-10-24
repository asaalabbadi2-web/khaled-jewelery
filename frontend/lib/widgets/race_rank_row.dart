import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/currency_utils.dart' as cu;
import 'goal_progress_ring.dart';
import 'race_honours_badges.dart';
import 'user_avatar_widget.dart';

/// The label beside an employee's rank in the race.
String raceRankRoleLabel(int index, bool isAr) => switch (index) {
  0 => isAr ? 'المتصدر' : 'Leader',
  1 => isAr ? 'الثاني' : 'Second',
  2 => isAr ? 'الثالث' : 'Third',
  _ => isAr ? 'مشارك' : 'Ranked',
};

/// One employee in the race (bonus study م3): the rank's medal, the avatar in
/// its goal ring, the name, its rank and honours, the invoices, sales and
/// purchases, the share bar and the score. The home card and the race board
/// draw it alike -- they were two boards for one race.
class RaceRankRow extends StatefulWidget {
  const RaceRankRow({
    super.key,
    required this.row,
    required this.index,
    required this.metric,
    required this.isAr,
    this.showInvoiceCount = true,
    this.showAmounts = true,
    this.showPoints = true,
  });

  final Map row;
  final int index;

  /// 'points', 'count' or a weight metric.
  final String metric;
  final bool isAr;
  final bool showInvoiceCount;
  final bool showAmounts;
  final bool showPoints;

  @override
  State<RaceRankRow> createState() => _RaceRankRowState();
}

class _RaceRankRowState extends State<RaceRankRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final index = widget.index;
    final metric = widget.metric;
    final isAr = widget.isAr;
    final showInvoiceCount = widget.showInvoiceCount;
    final showAmounts = widget.showAmounts;
    final showPoints = widget.showPoints;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final type = theme.textTheme;
    final tone = AppSemanticColors.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final name = (row['name'] ?? '').toString();
    final photo = row['photo'] as String?;
    final score = (row['score'] as num?)?.toDouble() ?? 0.0;
    final share = (row['share'] as num?)?.toDouble() ?? 0.0;
    final count = (row['count'] as num?)?.toInt() ?? 0;
    final salesAmount = (row['sales_amount'] as num?)?.toDouble() ?? 0.0;
    final purchaseAmount = (row['purchase_amount'] as num?)?.toDouble() ?? 0.0;
    final pointsSales = (row['points_sales'] as num?)?.toInt() ?? 0;
    final pointsPurchase = (row['points_purchase'] as num?)?.toInt() ?? 0;
    // تقدم الهدف الشخصي للموظف (null = لم يُضبط هدف)
    final goalProgress = (row['goal_progress'] as num?)?.toDouble();

    final isLeader = index == 0;
    final valueColor = isLeader ? cs.primary : cs.secondary;
    final progressColor = switch (index) {
      1 => tone.silver.fg,
      2 => tone.bronze.fg,
      _ => valueColor,
    };
    final medalAccent = switch (index) {
      0 => cs.primary,
      1 => tone.silver.fg,
      2 => tone.bronze.fg,
      _ => valueColor,
    };
    final roleBadgeColor = index == 0
        ? tone.gold.fg
        : cs.onSurface.withValues(alpha: 0.62);
    final invoiceLabelEn = count == 1 ? 'invoice' : 'invoices';
    final invoiceLabelAr = count == 1 ? 'فاتورة بيع' : 'فواتير بيع';
    final invoiceLabelPointsAr = count == 1 ? 'فاتورة' : 'فواتير';
    final invoiceSummary = showInvoiceCount
        ? (metric == 'points'
              ? (isAr ? '$count $invoiceLabelPointsAr' : '$count transactions')
              : (isAr
                    ? '$count $invoiceLabelAr'
                    : '$count sales $invoiceLabelEn'))
        : (metric == 'points'
              ? (isAr
                    ? 'فواتير مبيعات ومشتريات'
                    : 'Sales and purchases activity')
              : (isAr ? 'فواتير بيع' : 'Sales activity'));
    final scoreValueText = switch (metric) {
      'count' => count.toString(),
      'points' => cu.formatAmount(score, decimals: 0),
      _ => cu.formatGrams(score, decimals: 1),
    };
    final scoreUnitText = switch (metric) {
      'count' => isAr ? 'فاتورة' : 'Invoices',
      'points' => isAr ? 'نقطة' : 'Points',
      _ => isAr ? 'جم' : 'g',
    };
    final numberFormat = NumberFormat('#,##0', 'en');
    final pointsUnitAr = isAr ? 'نقطة' : 'pts';
    final currencySymbolText = context
        .read<SettingsProvider>()
        .currencySymbolText;
    final isNewSar = context.read<SettingsProvider>().currencyIsNewSar;

    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: 8),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedScale(
          duration: const Duration(milliseconds: 170),
          curve: Curves.easeOutCubic,
          scale: _hovered ? 1.015 : 1.0,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 170),
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(0, _hovered ? -2.0 : 0, 0),
            decoration: BoxDecoration(
              color: _hovered
                  ? (index == 0
                        ? (isDark
                              ? cs.surfaceContainerHigh
                              : Color.alphaBlend(
                                  tone.gold.container.withValues(alpha: 0.30),
                                  cs.surfaceContainerLowest,
                                ))
                        : (isDark
                              ? cs.surfaceContainerHigh
                              : cs.surfaceContainerLowest))
                  : (isDark
                        ? cs.surfaceContainerHigh
                        : (index == 0
                              ? Color.alphaBlend(
                                  tone.gold.container.withValues(alpha: 0.30),
                                  cs.surfaceContainerLowest,
                                )
                              : cs.surfaceContainerLowest)),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _hovered
                    ? cs.primary.withValues(alpha: 0.42)
                    : (index == 0
                          ? cs.primary.withValues(alpha: 0.22)
                          : index == 1
                          ? tone.silver.fg.withValues(alpha: 0.20)
                          : index == 2
                          ? tone.bronze.fg.withValues(alpha: 0.18)
                          : cs.onSurface.withValues(alpha: 0.07)),
                width: _hovered ? 1.2 : (index == 0 ? 1.1 : 1.0),
              ),
              boxShadow: _hovered
                  ? [
                      BoxShadow(
                        color: cs.primary.withValues(alpha: 0.11),
                        blurRadius: 14,
                        spreadRadius: 0,
                        offset: const Offset(0, 4),
                      ),
                      BoxShadow(
                        color: cs.shadow.withValues(
                          alpha: isDark ? 0.13 : 0.07,
                        ),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : (index == 0
                        ? [
                            BoxShadow(
                              color: cs.primary.withValues(alpha: 0.08),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ]
                        : null),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Medal rank badge with crown for rank 1
                  _buildRankBadge(index, medalAccent),
                  const SizedBox(width: 8),
                  // Avatar + حلقة تقدم الهدف الشخصي
                  GoalProgressRing(
                    progress: goalProgress,
                    avatarRadius: 19,
                    strokeWidth: 3.0,
                    child: EmployeeAvatarWidget(
                      name: name,
                      photoBase64: photo,
                      radius: 19,
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Employee info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontWeight: FontWeight.w700,
                                  fontSize: type.bodyLarge?.fontSize,
                                  color: cs.onSurface,
                                ),
                              ),
                            ),
                            const SizedBox(width: 5),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: roleBadgeColor.withValues(alpha: 0.09),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                raceRankRoleLabel(index, isAr),
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontWeight: FontWeight.w700,
                                  fontSize: type.labelSmall?.fontSize,
                                  color: roleBadgeColor,
                                ),
                              ),
                            ),
                            const SizedBox(width: 5),
                            RaceHonoursBadges.of(row),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            _buildStatChip(
                              icon: Icons.receipt_long_rounded,
                              value: invoiceSummary,
                              label: '',
                              valueColor: cs.onSurface.withValues(alpha: 0.55),
                            ),
                            _buildCategoryChip(
                              dotColor: tone.ready.fg,
                              valueColor: tone.ready.fg,
                              label: isAr ? 'مبيعات' : 'Sales',
                              amount: showAmounts ? salesAmount : null,
                              points: showPoints && metric == 'points'
                                  ? pointsSales
                                  : null,
                              pointsUnit: pointsUnitAr,
                              currencySymbolText: currencySymbolText,
                              isNewSar: isNewSar,
                              numberFormat: numberFormat,
                            ),
                            _buildCategoryChip(
                              dotColor: tone.invoicePurchase.fg,
                              valueColor: tone.invoicePurchase.fg,
                              label: isAr ? 'مشتريات' : 'Purch',
                              amount: showAmounts ? purchaseAmount : null,
                              points: showPoints && metric == 'points'
                                  ? pointsPurchase
                                  : null,
                              pointsUnit: pointsUnitAr,
                              currencySymbolText: currencySymbolText,
                              isNewSar: isNewSar,
                              numberFormat: numberFormat,
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        // Progress bar
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: Container(
                            height: 4,
                            color: cs.onSurface.withValues(alpha: 0.07),
                            child: TweenAnimationBuilder<double>(
                              tween: Tween<double>(
                                begin: 0,
                                end: share.clamp(0.0, 1.0),
                              ),
                              duration: Duration(
                                milliseconds: 600 + (index * 100),
                              ),
                              curve: Curves.easeOutCubic,
                              builder: (context, value, _) =>
                                  FractionallySizedBox(
                                    alignment: AlignmentDirectional.centerStart,
                                    widthFactor: value,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin:
                                              AlignmentDirectional.centerStart,
                                          end: AlignmentDirectional.centerEnd,
                                          colors: [
                                            progressColor.withValues(
                                              alpha: 0.65,
                                            ),
                                            medalAccent,
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (showPoints || metric != 'points') ...[
                    const SizedBox(width: 10),
                    // Score box
                    Container(
                      constraints: const BoxConstraints(minWidth: 52),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        gradient: index == 0
                            ? LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  cs.primary.withValues(alpha: 0.18),
                                  cs.primary.withValues(alpha: 0.07),
                                ],
                              )
                            : null,
                        color: index != 0
                            ? medalAccent.withValues(alpha: 0.07)
                            : null,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: index == 0
                              ? cs.primary.withValues(alpha: 0.30)
                              : medalAccent.withValues(alpha: 0.18),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            scoreValueText,
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.w900,
                              fontSize: index == 0
                                  ? type.displaySmall?.fontSize
                                  : type.headlineSmall?.fontSize,
                              color: index == 0 ? tone.gold.fg : medalAccent,
                              height: 1.1,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            scoreUnitText,
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: type.labelSmall?.fontSize,
                              color: cs.onSurface.withValues(alpha: 0.44),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// PATCH 4: شارة الترتيب — 50×50 مع تاج للمتصدر
  Widget _buildRankBadge(int index, Color medalAccent) {
    final cs = Theme.of(context).colorScheme;
    final tone = AppSemanticColors.of(context);
    final type = Theme.of(context).textTheme;
    final medal = switch (index) {
      0 => tone.gold,
      1 => tone.silver,
      _ => tone.bronze,
    };
    final gradientColors = index < 3
        ? [medal.fg, Color.lerp(medal.fg, medal.onContainer, 0.5)!]
        : [
            medalAccent.withValues(alpha: 0.18),
            medalAccent.withValues(alpha: 0.08),
          ];
    final shadowColor = index < 3 ? medal.fg : medalAccent;

    final Widget badge = CustomPaint(
      painter: _RankBadgeNotchPainter(
        gradientColors: gradientColors,
        shadowColor: index < 3 ? shadowColor : Colors.transparent,
        notchRadius: 0,
      ),
      child: SizedBox(
        width: 54,
        height: 54,
        child: Align(
          alignment: Alignment.center,
          child: Text(
            '${index + 1}',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontWeight: FontWeight.w900,
              fontSize: type.headlineMedium?.fontSize,
              color: index < 3 ? cs.onPrimary : medalAccent,
              shadows: index < 3
                  ? [
                      Shadow(
                        color: cs.shadow.withValues(alpha: 0.45),
                        blurRadius: 5,
                      ),
                    ]
                  : null,
            ),
          ),
        ),
      ),
    );

    if (index != 0) return badge;

    // Rank-1: التاج يطفو فوق الـ badge بدون إضافة ارتفاع للبطاقة.
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        badge,
        Positioned(
          top: -26,
          child: Text(
            '👑',
            style: TextStyle(
              fontSize: type.displaySmall?.fontSize,
              height: 1.0,
              shadows: [
                Shadow(
                  color: cs.shadow.withValues(alpha: 0.38),
                  blurRadius: 5,
                  offset: const Offset(0, 3),
                ),
                Shadow(color: tone.gold.fg, blurRadius: 20),
                Shadow(color: tone.gold.container, blurRadius: 10),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// PATCH 5: stat chip — dot/icon + value + label
  Widget _buildStatChip({
    IconData? icon,
    Color? dotColor,
    required String value,
    required String label,
    required Color valueColor,
  }) {
    final cs = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    final isNewSar = context.read<SettingsProvider>().currencyIsNewSar;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 3),
            child: Icon(icon, size: 12, color: valueColor),
          )
        else if (dotColor != null)
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsetsDirectional.only(end: 3),
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
        RichText(
          text: TextSpan(
            style: TextStyle(
              fontSize: type.labelSmall?.fontSize,
              fontFamily: 'Cairo',
            ),
            children: [
              ...cu.sarAwareSpans(
                value,
                isNewSar: isNewSar,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: valueColor,
                ),
              ),
              if (label.isNotEmpty)
                TextSpan(
                  text: ' $label',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Sales/purchase stat chip — label first ("مبيعات: "), then points in a
  /// color unified across both chips (not the category color, so the points
  /// figure is recognizable at a glance regardless of sales vs purchase),
  /// then the amount with its currency symbol rendered a notch smaller than
  /// the amount digits themselves.
  Widget _buildCategoryChip({
    required Color dotColor,
    required Color valueColor,
    required String label,
    required String currencySymbolText,
    required bool isNewSar,
    required NumberFormat numberFormat,
    double? amount,
    int? points,
    String? pointsUnit,
  }) {
    final cs = Theme.of(context).colorScheme;
    final tone = AppSemanticColors.of(context);
    final type = Theme.of(context).textTheme;
    if (amount == null && points == null) return const SizedBox.shrink();
    final pointsColor = tone.gold.fg;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          margin: const EdgeInsetsDirectional.only(end: 4),
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        RichText(
          text: TextSpan(
            style: TextStyle(
              fontSize: type.labelSmall?.fontSize,
              fontFamily: 'Cairo',
            ),
            children: [
              TextSpan(
                text: '$label: ',
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (points != null) ...[
                TextSpan(
                  text: '$points ',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: pointsColor,
                  ),
                ),
                TextSpan(
                  text: pointsUnit,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: pointsColor,
                    fontSize: type.labelSmall?.fontSize,
                  ),
                ),
                if (amount != null)
                  TextSpan(
                    text: '  •  ',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
              ],
              if (amount != null) ...[
                TextSpan(
                  text: numberFormat.format(amount.round()),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: valueColor,
                  ),
                ),
                const TextSpan(text: ' '),
                ...cu.sarAwareSpans(
                  currencySymbolText,
                  isNewSar: isNewSar,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: valueColor,
                    fontSize: type.labelSmall?.fontSize,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Paints a rounded-rectangle badge with an optional concave notch
/// cut from the top-center edge — used for rank-1 in the leaderboard.
class _RankBadgeNotchPainter extends CustomPainter {
  final List<Color> gradientColors;
  final Color shadowColor;
  final double notchRadius;

  const _RankBadgeNotchPainter({
    required this.gradientColors,
    required this.shadowColor,
    this.notchRadius = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const r = 14.0;
    final nx = size.width / 2;
    final nr = notchRadius;

    final path = Path();
    path.moveTo(r, 0);

    if (nr > 0) {
      // Flatten the sides of the notch so it looks like a smooth scallop
      path.lineTo(nx - nr * 1.4, 0);
      path.arcToPoint(
        Offset(nx + nr * 1.4, 0),
        radius: Radius.circular(nr),
        clockwise: false,
      );
    }

    path.lineTo(size.width - r, 0);
    path.arcToPoint(Offset(size.width, r), radius: Radius.circular(r));
    path.lineTo(size.width, size.height - r);
    path.arcToPoint(
      Offset(size.width - r, size.height),
      radius: Radius.circular(r),
    );
    path.lineTo(r, size.height);
    path.arcToPoint(Offset(0, size.height - r), radius: Radius.circular(r));
    path.lineTo(0, r);
    path.arcToPoint(Offset(r, 0), radius: Radius.circular(r));
    path.close();

    // Shadow
    canvas.drawShadow(path, shadowColor, 8, false);

    // Gradient fill
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: gradientColors,
      ).createShader(Offset.zero & size);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _RankBadgeNotchPainter old) =>
      old.gradientColors != gradientColors || old.notchRadius != notchRadius;
}
