import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_semantic_colors.dart';

/// The karats' colours are never red or green (the owner, 13 Nov 2026): red and
/// green say a price went down or up, and a karat's tag beside a price must
/// not say it. Found: 18's red was the down red itself (ΔE 0.6) and 22's a
/// green. Measured as the perceptual distance in OKLab (×100), both themes:
/// each karat far from «up» (ready) and «down» (blocked), and readable as
/// text on its own container.

double _lin(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

List<double> _oklab(Color c) {
  final r = _lin(c.r), g = _lin(c.g), b = _lin(c.b);
  final l = math.pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1 / 3).toDouble();
  final m = math.pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1 / 3).toDouble();
  final s = math.pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1 / 3).toDouble();
  return [
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  ];
}

double _distance(Color a, Color b) {
  final x = _oklab(a), y = _oklab(b);
  return 100 * math.sqrt(math.pow(x[0] - y[0], 2) + math.pow(x[1] - y[1], 2) + math.pow(x[2] - y[2], 2));
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  for (final (name, tones) in [('light', AppSemanticColors.light), ('dark', AppSemanticColors.dark)]) {
    for (final karat in const [18, 21, 22, 24]) {
      test('$name: karat $karat is neither up nor down, and reads on its container', () {
        final k = tones.karat(karat);
        expect(_distance(k.fg, tones.ready.fg), greaterThanOrEqualTo(10), reason: 'too near «up»');
        expect(_distance(k.fg, tones.blocked.fg), greaterThanOrEqualTo(10), reason: 'too near «down»');
        expect(_contrast(k.fg, k.container), greaterThanOrEqualTo(4.5));
      });
    }
    test('$name: the sale colour is neither up nor down (the owner, 13 Nov 2026: it was the up green)', () {
      final sale = tones.invoiceSale;
      expect(_distance(sale.fg, tones.ready.fg), greaterThanOrEqualTo(10));
      expect(_distance(sale.fg, tones.blocked.fg), greaterThanOrEqualTo(10));
      expect(_contrast(sale.fg, sale.container), greaterThanOrEqualTo(4.5));
      expect(_contrast(sale.onContainer, sale.container), greaterThanOrEqualTo(4.5));
    });
    test('$name: the karats are told apart', () {
      const karats = [18, 21, 22, 24];
      for (var i = 0; i < karats.length; i++) {
        for (var j = i + 1; j < karats.length; j++) {
          expect(_distance(tones.karat(karats[i]).fg, tones.karat(karats[j]).fg), greaterThanOrEqualTo(10),
              reason: '${karats[i]} and ${karats[j]}');
        }
      }
    });
  }
}
