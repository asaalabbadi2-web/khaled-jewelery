import 'package:flutter/material.dart';
import '../models/report_models.dart';

/// بطاقة لعرض تقرير واحد داخل القوائم المختلفة
class ReportCard extends StatelessWidget {
  final ReportDescriptor report;
  final bool isArabic;
  final VoidCallback? onTap;

  const ReportCard({
    super.key,
    required this.report,
    required this.isArabic,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaceColor = theme.colorScheme.surface;
    final borderColor = theme.colorScheme.outlineVariant;
    final title = report.localizedTitle(isArabic);
    final description = report.localizedDescription(isArabic);

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Ink(
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor.withValues(alpha: 0.4)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Row(
              textDirection:
                  isArabic ? TextDirection.rtl : TextDirection.ltr,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(report.icon,
                      color: theme.colorScheme.primary, size: 26),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: isArabic
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Align(
              alignment:
                  isArabic ? Alignment.centerLeft : Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                textDirection:
                    isArabic ? TextDirection.rtl : TextDirection.ltr,
                children: [
                  _buildTag(context,
                      report.requiresFilters ? 'فلترة مطلوبة' : 'بدون فلترة'),
                  if (!report.available)
                    _buildTag(context, 'قريباً', isWarning: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTag(BuildContext context, String label, {bool isWarning = false}) {
    final theme = Theme.of(context);
    final bg = isWarning
        ? theme.colorScheme.secondary.withValues(alpha: 0.12)
        : theme.colorScheme.primary.withValues(alpha: 0.12);
    final fg = isWarning
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: fg,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
