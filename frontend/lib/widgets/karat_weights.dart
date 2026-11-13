import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';
import '../utils/bidi.dart' show ltrIsolate;
import '../utils/currency_utils.dart' show formatGrams;

/// A weight of gold in one karat.
class KaratWeight {
  const KaratWeight(this.karat, this.grams);

  /// Null where the karat is not one (mixed, unknown).
  final int? karat;
  final double grams;
}

/// Gold as a card says it (the owner, 13 Nov 2026: «طريقة عرض الوزن في البطائق
/// اجعله افضل»): each karat a chip -- its colour's dot, «عيار 21», the grams
/// in three places and «جم» -- and, under them, what they come to in the main
/// karat where that is not what they already say. One unit (جم) and one
/// formatter (formatGrams) for every card; a weight was «غ» on one, «جم» on
/// the next, said twice on the voucher's.
class KaratWeights extends StatelessWidget {
  const KaratWeights({
    super.key,
    required this.weights,
    this.mainKarat,
    this.mainEquivalent,
    this.large = false,
  });

  final List<KaratWeight> weights;
  final int? mainKarat;

  /// The weights in the main karat, the server's.
  final double? mainEquivalent;

  /// The figure the card is about: drawn larger.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final figure = (large ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium)?.copyWith(
      fontWeight: FontWeight.w800,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final shown = [for (final w in weights) if (w.grams != 0) w];
    // the equivalent said only where it adds something: more than one karat,
    // or one that is not the main karat
    final eq = mainEquivalent;
    final sayEquivalent = eq != null &&
        eq != 0 &&
        mainKarat != null &&
        (shown.length != 1 || shown.single.karat != mainKarat);
    return Column(
      key: const Key('karat-weights'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final w in shown)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: w.karat == null ? tones.gold.fg : tones.karat(w.karat!).fg,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      w.karat == null ? 'ذهب' : 'عيار ${w.karat}',
                      style: theme.textTheme.labelMedium?.copyWith(color: muted, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 6),
                    Text(formatGrams(w.grams), textDirection: TextDirection.ltr, style: figure),
                    Text(' جم', style: theme.textTheme.labelMedium?.copyWith(color: muted)),
                  ],
                ),
              ),
          ],
        ),
        if (sayEquivalent)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text.rich(
              key: const Key('karat-weights-equivalent'),
              TextSpan(
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
                children: [
                  const TextSpan(text: '≈ '),
                  TextSpan(
                    text: ltrIsolate(formatGrams(eq)),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: ' جم بعيار $mainKarat'),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
