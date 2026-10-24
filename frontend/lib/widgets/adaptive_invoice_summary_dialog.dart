import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum InvoiceSummaryStatusTone { success, due, neutral }

class InvoiceSummaryMetricDetail {
  final String label;
  final String value;
  final Color? accentColor;

  const InvoiceSummaryMetricDetail({
    required this.label,
    required this.value,
    this.accentColor,
  });
}

class InvoiceSummaryMetric {
  final String label;
  final String value;
  final IconData? icon;
  final Color? accentColor;
  final String? badgeLabel;
  final Color? badgeColor;
  final bool highlightCard;
  final bool emphasize;
  final bool fullWidth;
  final List<InvoiceSummaryMetricDetail> details;

  const InvoiceSummaryMetric({
    required this.label,
    required this.value,
    this.icon,
    this.accentColor,
    this.badgeLabel,
    this.badgeColor,
    this.highlightCard = false,
    this.emphasize = false,
    this.fullWidth = false,
    this.details = const [],
  });
}

class InvoiceSummaryAction<T> {
  final String label;
  final IconData icon;
  final T? value;
  final bool isPrimary;

  const InvoiceSummaryAction.primary({
    required this.label,
    required this.icon,
    required this.value,
  }) : isPrimary = true;

  const InvoiceSummaryAction.secondary({
    required this.label,
    required this.icon,
    required this.value,
  }) : isPrimary = false;
}

Future<T?> showAdaptiveInvoiceSummaryDialog<T>({
  required BuildContext context,
  required String title,
  required IconData icon,
  required Color accentColor,
  required String statusTitle,
  required String statusMessage,
  required InvoiceSummaryStatusTone statusTone,
  required List<InvoiceSummaryMetric> metrics,
  required List<InvoiceSummaryAction<T>> actions,
  String? subtitle,
  String? highlightMessage,
  List<String> notices = const [],
  T? closeValue,
  bool barrierDismissible = false,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: 'Invoice summary',
    barrierColor: Colors.black.withValues(alpha: 0.14),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (dialogContext, _, _) {
      return _AdaptiveInvoiceSummaryOverlay<T>(
        title: title,
        subtitle: subtitle,
        icon: icon,
        accentColor: accentColor,
        highlightMessage: highlightMessage,
        statusTitle: statusTitle,
        statusMessage: statusMessage,
        statusTone: statusTone,
        metrics: metrics,
        notices: notices,
        actions: actions,
        closeValue: closeValue,
      );
    },
    transitionBuilder: (dialogContext, animation, _, child) {
      final curve = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curve,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curve),
          child: child,
        ),
      );
    },
  );
}

class _AdaptiveInvoiceSummaryOverlay<T> extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final Color accentColor;
  final String? highlightMessage;
  final String statusTitle;
  final String statusMessage;
  final InvoiceSummaryStatusTone statusTone;
  final List<InvoiceSummaryMetric> metrics;
  final List<String> notices;
  final List<InvoiceSummaryAction<T>> actions;
  final T? closeValue;

  const _AdaptiveInvoiceSummaryOverlay({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    required this.highlightMessage,
    required this.statusTitle,
    required this.statusMessage,
    required this.statusTone,
    required this.metrics,
    required this.notices,
    required this.actions,
    required this.closeValue,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 700;
    final isTablet = size.width >= 700 && size.width < 1100;
    final dialogWidth = isMobile
        ? size.width * 0.90
        : isTablet
        ? size.width * 0.60
        : math.min(520.0, math.max(480.0, size.width * 0.36));

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              ignoring: true,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                child: ColoredBox(
                  color: Colors.white.withValues(alpha: 0.02),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: isMobile ? Alignment.bottomCenter : Alignment.center,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  isMobile ? 16 : 24,
                  16,
                  isMobile ? 16 : 24,
                ),
                child: SizedBox(
                  width: dialogWidth,
                  child: _InvoiceSummaryCard<T>(
                    isMobile: isMobile,
                    title: title,
                    subtitle: subtitle,
                    icon: icon,
                    accentColor: accentColor,
                    highlightMessage: highlightMessage,
                    statusTitle: statusTitle,
                    statusMessage: statusMessage,
                    statusTone: statusTone,
                    metrics: metrics,
                    notices: notices,
                    actions: actions,
                    closeValue: closeValue,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InvoiceSummaryCard<T> extends StatefulWidget {
  final bool isMobile;
  final String title;
  final String? subtitle;
  final IconData icon;
  final Color accentColor;
  final String? highlightMessage;
  final String statusTitle;
  final String statusMessage;
  final InvoiceSummaryStatusTone statusTone;
  final List<InvoiceSummaryMetric> metrics;
  final List<String> notices;
  final List<InvoiceSummaryAction<T>> actions;
  final T? closeValue;

  const _InvoiceSummaryCard({
    required this.isMobile,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    required this.highlightMessage,
    required this.statusTitle,
    required this.statusMessage,
    required this.statusTone,
    required this.metrics,
    required this.notices,
    required this.actions,
    required this.closeValue,
  });

  @override
  State<_InvoiceSummaryCard<T>> createState() => _InvoiceSummaryCardState<T>();
}

// ADR-060 ف٠: the summary opens at its top -- who, what and how much -- and
// its notices are there too, under the title. It scrolled itself to the
// bottom whenever a notice was said, and a credit sale always has one: the
// total and the lines were out of sight, the save button in it.
class _InvoiceSummaryCardState<T> extends State<_InvoiceSummaryCard<T>> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      key: const Key('invoice-summary'),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * (widget.isMobile ? 0.90 : 0.82),
      ),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colorScheme.onSurface.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            fit: FlexFit.loose,
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: EdgeInsets.fromLTRB(20, widget.isMobile ? 16 : 24, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.isMobile)
                    Center(
                      child: Container(
                        width: 44,
                        height: 5,
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                          color: colorScheme.onSurface.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: colorScheme.onSurface.withValues(alpha: 0.035),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: colorScheme.onSurface.withValues(alpha: 0.06),
                          ),
                        ),
                        child: Icon(widget.icon, color: widget.accentColor, size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.title,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w900,
                                color: colorScheme.onSurface,
                              ),
                            ),
                            if ((widget.subtitle ?? '').trim().isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                widget.subtitle!,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color:
                                      colorScheme.onSurface.withValues(alpha: 0.60),
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(widget.closeValue),
                        icon: const Icon(Icons.close_rounded),
                        tooltip: 'إغلاق',
                      ),
                    ],
                  ),
                  if ((widget.highlightMessage ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            widget.accentColor.withValues(alpha: 0.18),
                            widget.accentColor.withValues(alpha: 0.08),
                          ],
                          begin: Alignment.centerRight,
                          end: Alignment.centerLeft,
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        widget.highlightMessage!,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: colorScheme.onSurface,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                  if (widget.notices.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Container(
                      key: const Key('invoice-summary-notices'),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.warning.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: AppColors.warning.withValues(alpha: 0.26),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                color: AppColors.warning,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'تنبيهات',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          ...widget.notices.map(
                            (notice) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                notice,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  height: 1.45,
                                  color:
                                      colorScheme.onSurface.withValues(alpha: 0.84),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    'ملخص الفاتورة',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _InvoiceSummaryGrid(metrics: widget.metrics),
                  const SizedBox(height: 16),
                  _StatusCard(
                    title: widget.statusTitle,
                    message: widget.statusMessage,
                    tone: widget.statusTone,
                  ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                top: BorderSide(
                  color: colorScheme.onSurface.withValues(alpha: 0.06),
                ),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: _InvoiceSummaryActions<T>(actions: widget.actions),
          ),
        ],
      ),
    );
  }
}

class _InvoiceSummaryGrid extends StatelessWidget {
  final List<InvoiceSummaryMetric> metrics;

  const _InvoiceSummaryGrid({required this.metrics});

  bool _shouldSpanFullWidth(int index) {
    final metric = metrics[index];
    if (metric.fullWidth) return true;

    var segmentStart = index;
    while (segmentStart > 0 && !metrics[segmentStart - 1].fullWidth) {
      segmentStart--;
    }

    var segmentEnd = index;
    while (segmentEnd < metrics.length - 1 && !metrics[segmentEnd + 1].fullWidth) {
      segmentEnd++;
    }

    final segmentLength = segmentEnd - segmentStart + 1;
    final isLastInSegment = index == segmentEnd;
    return segmentLength.isOdd && isLastInSegment;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: metrics.asMap().entries.map((entry) {
                final index = entry.key;
                final metric = entry.value;
                final resolvedAccent = metric.accentColor ?? colorScheme.primary;
                final resolvedBadgeColor = metric.badgeColor ?? resolvedAccent;
                final shouldSpanFullWidth = _shouldSpanFullWidth(index);
                return SizedBox(
                  width: shouldSpanFullWidth ? constraints.maxWidth : itemWidth,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: colorScheme.onSurface.withValues(alpha: 0.08),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (metric.icon != null || metric.badgeLabel != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (metric.badgeLabel != null)
                                  Text(
                                    metric.badgeLabel!,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: resolvedBadgeColor,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.1,
                                    ),
                                  )
                                else
                                  const SizedBox.shrink(),
                                if (metric.icon != null)
                                  Icon(
                                    metric.icon,
                                    size: 18,
                                    color: resolvedAccent,
                                  ),
                              ],
                            ),
                          ),
                        Text(
                          metric.label,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: metric.badgeLabel != null
                                ? resolvedBadgeColor
                                : colorScheme.onSurface.withValues(alpha: 0.65),
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          metric.value,
                          style: (metric.emphasize
                                  ? theme.textTheme.titleLarge
                                  : theme.textTheme.titleMedium)
                              ?.copyWith(
                            fontWeight:
                                metric.emphasize ? FontWeight.w900 : FontWeight.w800,
                            fontSize: metric.emphasize ? 20 : 18,
                              color: metric.badgeLabel != null
                                ? resolvedBadgeColor
                                : (metric.emphasize
                                  ? resolvedAccent
                                  : colorScheme.onSurface),
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (metric.details.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: metric.details
                                .map(
                                  (detail) => Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: resolvedAccent.withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: resolvedAccent.withValues(alpha: 0.16),
                                      ),
                                    ),
                                    child: Directionality(
                                      textDirection: TextDirection.ltr,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            detail.label,
                                            style: theme.textTheme.bodySmall?.copyWith(
                                              color: colorScheme.onSurface,
                                              fontWeight: FontWeight.w700,
                                              height: 1.2,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          // Split "1.000 جم" → render unit first (left), then number (right)
                                          // so Arabic RTL readers encounter number first, then unit
                                          () {
                                            final parts = detail.value.split(' ');
                                            if (parts.length >= 2) {
                                              final number = parts[0];
                                              final unit = parts.sublist(1).join(' ');
                                              return Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    unit,
                                                    style: theme.textTheme.bodySmall?.copyWith(
                                                      fontWeight: FontWeight.w600,
                                                      color: resolvedAccent.withValues(alpha: 0.8),
                                                      height: 1.2,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    number,
                                                    style: theme.textTheme.bodySmall?.copyWith(
                                                      fontWeight: FontWeight.w800,
                                                      color: resolvedAccent,
                                                      height: 1.2,
                                                    ),
                                                  ),
                                                ],
                                              );
                                            }
                                            return Text(
                                              detail.value,
                                              style: theme.textTheme.bodySmall?.copyWith(
                                                fontWeight: FontWeight.w800,
                                                color: resolvedAccent,
                                                height: 1.2,
                                              ),
                                            );
                                          }(),
                                        ],
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }).toList(),
        );
      },
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String title;
  final String message;
  final InvoiceSummaryStatusTone tone;

  const _StatusCard({
    required this.title,
    required this.message,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final resolvedColor = switch (tone) {
      InvoiceSummaryStatusTone.success => AppColors.success,
      InvoiceSummaryStatusTone.due => AppColors.error,
      InvoiceSummaryStatusTone.neutral => AppColors.primaryGold,
    };
    final resolvedIcon = switch (tone) {
      InvoiceSummaryStatusTone.success => Icons.check_circle_rounded,
      InvoiceSummaryStatusTone.due => Icons.error_rounded,
      InvoiceSummaryStatusTone.neutral => Icons.info_rounded,
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: resolvedColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: resolvedColor.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: resolvedColor.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(resolvedIcon, color: resolvedColor, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurface.withValues(alpha: 0.65),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: resolvedColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InvoiceSummaryActions<T> extends StatelessWidget {
  final List<InvoiceSummaryAction<T>> actions;

  const _InvoiceSummaryActions({required this.actions});

  @override
  Widget build(BuildContext context) {
    InvoiceSummaryAction<T>? primaryAction;
    final secondaryActions = <InvoiceSummaryAction<T>>[];
    for (final action in actions) {
      if (action.isPrimary) {
        primaryAction = action;
      } else {
        secondaryActions.add(action);
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final primary = primaryAction;
        final showCompactSingleSecondary = secondaryActions.length == 1 && primary != null;
        final secondaryCount = secondaryActions.length;
        final secondaryWidth = secondaryCount <= 1
            ? constraints.maxWidth
            : (constraints.maxWidth - (secondaryCount - 1) * 8) / secondaryCount;
        final compactSecondaryWidth = math.min(
          180.0,
          math.max(132.0, constraints.maxWidth * 0.42),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!showCompactSingleSecondary && secondaryActions.isNotEmpty)
              Row(
                children: [
                  for (int i = 0; i < secondaryActions.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    SizedBox(
                      width: secondaryWidth,
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).pop(secondaryActions[i].value),
                        icon: Icon(secondaryActions[i].icon, size: 18),
                        label: Text(secondaryActions[i].label),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: colorScheme.onSurface,
                          side: BorderSide(
                            color: AppColors.primaryGold.withValues(alpha: 0.48),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          textStyle: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            if (primary != null) ...[
              if (!showCompactSingleSecondary && secondaryActions.isNotEmpty)
                const SizedBox(height: 12),
              SizedBox(
                height: 50,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(primary.value),
                  icon: Icon(primary.icon, size: 18),
                  label: Text(primary.label),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primaryGold,
                    foregroundColor: const Color(0xFF2F2400),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    textStyle: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
            if (showCompactSingleSecondary) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: compactSecondaryWidth,
                  height: 46,
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        Navigator.of(context).pop(secondaryActions.first.value),
                    icon: Icon(secondaryActions.first.icon, size: 18),
                    label: Text(secondaryActions.first.label),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colorScheme.onSurface,
                      side: BorderSide(
                        color: AppColors.primaryGold.withValues(alpha: 0.48),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      textStyle: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}