import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// One figure of a list's summary: what it counts, and the count.
class SummaryItem {
  const SummaryItem(this.label, this.value, {this.valueColor, this.key});

  final String label;

  /// The figure with its unit after it (a sum's sign, «جم»), as the cards say it.
  final String value;

  /// Where it asks something of the reader (pending, unposted): its tone.
  final Color? valueColor;
  final Key? key;
}

/// A list's summary on a phone (the owner, 13 Nov 2026: «اصلح ملخصات في اعلى
/// الشاشات ... على الشاشه الصغيره»): one panel, two figures a row, the last
/// alone across it -- each its name small over its figure large. No icon and
/// no line of explanation: they took the width, and the names were cut
/// («إجمالي...») or the cards slid off the screen's edge. What one needs is
/// said in its unit («جم بعيار 21»).
class SummaryStrip extends StatelessWidget {
  const SummaryStrip({super.key, required this.items});

  final List<SummaryItem> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('summary-strip'),
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          const gap = AppSpace.md;
          final half = (box.maxWidth - gap) / 2;
          return Wrap(
            spacing: gap,
            runSpacing: AppSpace.sm,
            children: [
              for (final (i, item) in items.indexed)
                SizedBox(
                  key: item.key,
                  // two a row; the last alone across the panel
                  width: i == items.length - 1 && items.length.isOdd ? box.maxWidth : half,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          item.value,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: item.valueColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
