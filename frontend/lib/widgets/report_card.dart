import 'package:flutter/material.dart';
import '../models/report_models.dart';
import '../theme/app_tokens.dart';

/// One report in the centre: its icon, its title and one line of what it
/// answers -- every card the same height (REPORTS-HUB, «بطاقة مضغوطة»).
class ReportCard extends StatelessWidget {
  final ReportDescriptor report;
  final bool isArabic;
  final VoidCallback? onTap;

  /// The card's height: a title and one line, and the space around them.
  static const double height = 72;

  const ReportCard({
    super.key,
    required this.report,
    required this.isArabic,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(AppRadius.card);

    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          child: Row(
            children: [
              Container(
                width: kMinTapHeight,
                height: kMinTapHeight,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: Icon(report.icon, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      report.localizedTitle(isArabic),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      report.localizedDescription(isArabic),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                isArabic ? Icons.chevron_left : Icons.chevron_right,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
