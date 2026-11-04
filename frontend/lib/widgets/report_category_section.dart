import 'package:flutter/material.dart';
import '../models/report_models.dart';
import '../theme/app_tokens.dart';
import 'report_card.dart';

/// A question and the reports that answer it: three cards a row on a wide
/// screen, two on a tablet, one on a phone -- all the same height.
class ReportCategorySection extends StatelessWidget {
  final ReportCategory category;
  final bool isArabic;
  final void Function(ReportDescriptor report)? onReportSelected;

  const ReportCategorySection({
    super.key,
    required this.category,
    required this.isArabic,
    this.onReportSelected,
  });

  static int columnsFor(double width) =>
      width >= 900 ? 3 : (width >= 560 ? 2 : 1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(category.icon, color: theme.colorScheme.primary),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Text(
                category.localizedName(isArabic),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.md),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = columnsFor(constraints.maxWidth);
            final width =
                (constraints.maxWidth - AppSpace.md * (columns - 1)) / columns;
            return Wrap(
              spacing: AppSpace.md,
              runSpacing: AppSpace.md,
              children: [
                for (final report in category.reports)
                  SizedBox(
                    width: width,
                    height: ReportCard.height,
                    child: ReportCard(
                      report: report,
                      isArabic: isArabic,
                      onTap: () => onReportSelected?.call(report),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
