import 'package:flutter/material.dart';
import 'currency_utils.dart';

/// Formats weight to display with gram unit after the number
/// Handles RTL/LTR context correctly for Arabic and English
class WeightFormatter {
  /// Returns weight string in format: "X.XXX جم"
  /// Suitable for use in regular text contexts
  static String formatWeight(double grams, {int decimals = 3}) {
    return '${formatGrams(grams, decimals: decimals)} جم';
  }

  /// Builds a widget that displays weight with proper LTR ordering
  /// Ensures Arabic readers see the number first, then the unit
  /// Use this in widgets that need proper bidirectional text handling
  static Widget buildWeightDisplay(
    double grams, {
    TextStyle? style,
    int decimals = 3,
  }) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'جم',
            style: style?.copyWith(
              fontWeight: FontWeight.w600,
              color: style.color?.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            formatGrams(grams, decimals: decimals),
            style: style?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
