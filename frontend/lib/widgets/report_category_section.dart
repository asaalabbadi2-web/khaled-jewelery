import 'package:flutter/material.dart';
import '../models/report_models.dart';
import 'report_card.dart';

/// قسم يعرض فئة تقارير مع قائمة التقارير التابعة لها
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

  @override
  Widget build(BuildContext context) {
    final title = category.localizedName(isArabic);

    return Column(
      crossAxisAlignment: isArabic
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        _buildHeader(context, title),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth > 840;
            final cardWidth = isWide
                ? (constraints.maxWidth - 32) / 3
                : (constraints.maxWidth > 520
                    ? (constraints.maxWidth - 16) / 2
                    : constraints.maxWidth);

            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: category.reports.map((report) {
                return SizedBox(
                  width: cardWidth,
                  child: ReportCard(
                    report: report,
                    isArabic: isArabic,
                    onTap: () => onReportSelected?.call(report),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, String title) {
    final theme = Theme.of(context);

    return Row(
      mainAxisAlignment: isArabic
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: category.accentColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(category.icon, color: category.accentColor, size: 26),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}
