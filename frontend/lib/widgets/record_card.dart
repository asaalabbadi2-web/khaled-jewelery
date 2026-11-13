import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';

/// How a record stands among its list: a line, a section's heading, its total,
/// a finding said apart, a note.
enum RecordStyle { line, heading, subtotal, finding, note }

/// One figure of a record: its column's name and its value -- a figure keeps
/// its decimals lined up and reads left to right; a negative is said in the
/// error tone where its sign means something.
class RecordField {
  const RecordField(this.label, this.value, {this.figure = true, this.negative = false, this.color});

  final String label;
  final String value;
  final bool figure;
  final bool negative;

  /// A colour of its own (a karat's, a kind's) -- never red or green unless it
  /// says down or up.
  final Color? color;
}

/// A table's row as a card, on a phone (the owner, 13 Nov 2026: «في الشاشات
/// الصغيره اجعل العرض كبطاقات وليس جداول»): its title, what else it says
/// under it, then each figure on its own line by its column's name. A record
/// with something behind it opens it. The one card of every list and report
/// that turns its table into cards -- not one per screen.
class RecordCard extends StatelessWidget {
  const RecordCard({
    super.key,
    required this.title,
    this.subtitle,
    this.fields = const [],
    this.style = RecordStyle.line,
    this.onTap,
    this.trailing,
    this.child,
  });

  final String title;
  final String? subtitle;
  final List<RecordField> fields;
  final RecordStyle style;
  final VoidCallback? onTap;

  /// Beside the title: a tag, a state.
  final Widget? trailing;

  /// Under its figures: what the record asks of its reader (a field, a button).
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final strong = style == RecordStyle.heading || style == RecordStyle.subtotal;
    final tabular = theme.textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      color: switch (style) {
        RecordStyle.heading => theme.colorScheme.surfaceContainerLow,
        RecordStyle.finding => tones.warning.container,
        _ => null,
      },
      shape: style == RecordStyle.subtotal
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.outline),
            )
          : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: strong ? FontWeight.w800 : FontWeight.w700,
                        fontStyle: style == RecordStyle.note ? FontStyle.italic : null,
                        color: style == RecordStyle.note ? theme.colorScheme.onSurfaceVariant : null,
                      ),
                    ),
                  ),
                  if (trailing != null) ...[const SizedBox(width: AppSpace.sm), trailing!],
                  if (onTap != null)
                    Icon(Icons.chevron_left_rounded, color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              for (final f in fields)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.xs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          f.label,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                      const SizedBox(width: AppSpace.sm),
                      Flexible(
                        flex: 2,
                        child: Text(
                          f.value,
                          // at the card's far edge, whichever way the screen reads
                          textAlign: rtl ? TextAlign.left : TextAlign.right,
                          textDirection: f.figure ? TextDirection.ltr : null,
                          style: (f.figure ? tabular : theme.textTheme.bodyMedium)?.copyWith(
                            fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
                            color: f.negative ? theme.colorScheme.error : f.color,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (child != null) ...[const SizedBox(height: AppSpace.sm), child!],
            ],
          ),
        ),
      ),
    );
  }
}
