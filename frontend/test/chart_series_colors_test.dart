// REPORTS ت4-4ب (ADR-083): the chart's series colours, validated by the
// palette checker in both modes (lightness band, chroma, colour-blind and
// normal-vision separation, 3:1 contrast). What a Dart test can keep of it:
// each series reads 3:1 on the chart's surface in its mode, and the two are
// different colours -- a theme change that breaks either is caught here.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  for (final (mode, theme, tones) in [
    ('light', LightTheme.theme, AppSemanticColors.light),
    ('dark', DarkTheme.theme, AppSemanticColors.dark),
  ]) {
    test('$mode: each series reads 3:1 on the surface, and they differ', () {
      final surfaces = [
        theme.colorScheme.surface,
        theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow,
      ];
      expect(tones.chartSeries.length, greaterThanOrEqualTo(2));
      for (final c in tones.chartSeries) {
        for (final s in surfaces) {
          expect(
            _contrast(c, s),
            greaterThanOrEqualTo(3.0),
            reason: '$c on $s',
          );
        }
      }
      expect(tones.chartSeries.toSet().length, tones.chartSeries.length);
    });
  }
}
