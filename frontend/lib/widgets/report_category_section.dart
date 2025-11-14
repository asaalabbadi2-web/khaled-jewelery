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
      crossAxisAlignment:
          isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        _buildHeader(context, title),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth > 840;
            final crossAxisCount = isWide ? 3 : (constraints.maxWidth > 520 ? 2 : 1);

            return GridView.builder(
              itemCount: category.reports.length,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: isWide ? 1.4 : 1.5,
              ),
              itemBuilder: (context, index) {
                final report = category.reports[index];
                return ReportCard(
                  report: report,
                  isArabic: isArabic,
                  onTap: report.available
                      ? () => onReportSelected?.call(report)
                      : null,
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, String title) {
    final theme = Theme.of(context);

    return Row(
      mainAxisAlignment:
          isArabic ? MainAxisAlignment.end : MainAxisAlignment.start,
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
