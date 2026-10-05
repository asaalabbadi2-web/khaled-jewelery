import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/bidi.dart';
import '../utils/journal_balance.dart';

/// One line of the journal entry footer: debit, credit and the difference.
///
/// It takes the numbers, not formatted text, and formats them itself -- the
/// difference was once read back from the formatted string, and «1,500.00»
/// parsed to nothing, so any gap of 1,000 or more showed as zero. A difference
/// is red when it is not zero; success is never shown here, only by the
/// entry's readiness (a balanced entry can still be unsaveable).
class JournalBalanceRow extends StatelessWidget {
  final String label;
  final double debit;
  final double credit;
  final String Function(double) format;
  final String suffix;

  const JournalBalanceRow({
    super.key,
    required this.label,
    required this.debit,
    required this.credit,
    required this.format,
    required this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final gap = (debit - credit).abs();
    final balanced = gap <= kBalanceTolerance;

    Widget pair(String title, double value, {Color? color}) {
      return Padding(
        padding: const EdgeInsetsDirectional.only(end: 16),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '$title ', style: muted),
              TextSpan(
                text: '${ltrIsolate(format(value))} $suffix',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 36,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          pair('مدين', debit),
          pair('دائن', credit),
          pair('الفرق', gap, color: balanced ? null : AppColors.error),
        ],
      ),
    );
  }
}
