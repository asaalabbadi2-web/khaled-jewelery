import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';

/// The owner (17 Nov 2026): «في الوضع الداكن اللون الأصفر غير مريح بصريًّا».
/// The dark theme's gold was a saturated yellow (#D4AF37, #E6C24F, #FFE08B:
/// OKLCH chroma 0.11-0.14) that glowed on the neutral charcoal, and every app
/// bar's title and icons were drawn in it. Chosen (A+C, of three drawn side
/// by side): a muted brass, and the app bar in the text's color -- the gold
/// kept for what is pressed or matters. The light theme does not change.

/// OKLCH chroma (Björn Ottosson's matrices, from sRGB).
double chroma(Color c) {
  double lin(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  final r = lin(c.r), g = lin(c.g), b = lin(c.b);
  double cbrt(double v) => math.pow(v, 1 / 3).toDouble();
  final l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  final m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  final s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  final a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
  final bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
  return math.sqrt(a * a + bb * bb);
}

void main() {
  final theme = DarkTheme.theme;
  final s = theme.colorScheme;
  final tones = AppSemanticColors.dark;

  test('the dark gold is a muted brass, not a glowing yellow', () {
    final golds = {
      'primary': s.primary,
      'secondary': s.secondary,
      'onPrimaryContainer': s.onPrimaryContainer,
      'onSecondaryContainer': s.onSecondaryContainer,
      'gold.fg': tones.gold.fg,
      'gold.onContainer': tones.gold.onContainer,
      'karat21.fg': tones.karat21.fg,
    };
    for (final MapEntry(key: name, value: c) in golds.entries) {
      expect(chroma(c), lessThanOrEqualTo(0.10), reason: '$name ${c.toARGB32().toRadixString(16)}');
    }
  });

  test('the app bar speaks in the text\'s color, not in gold', () {
    expect(theme.appBarTheme.foregroundColor, s.onSurface);
    expect(theme.appBarTheme.iconTheme?.color, s.onSurface);
  });

  test('the light theme keeps its gold', () {
    expect(LightTheme.theme.colorScheme.primary, const Color(0xFF87600A));
  });
}
