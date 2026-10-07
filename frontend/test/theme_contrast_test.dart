import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';

/// ثيم-٠: كل لون يحمل نصًّا يُقرأ في الوضعين، ولا دور في اللوحة يرجع إلى
/// قيمة Flutter الاحتياطية (الحدّ إلى الأسود/الأبيض، «أعلى حاوية» إلى لون
/// البطاقة، «الثالث» إلى «الثانوي»).
///
/// الحدّ: ٤٫٥:١ للنص (WCAG AA)، و٣:١ لحدود العناصر.
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  for (final (name, theme) in [
    ('light', LightTheme.theme),
    ('dark', DarkTheme.theme),
  ]) {
    final s = theme.colorScheme;
    final card = theme.cardTheme.color!;
    final appBar = theme.appBarTheme;

    group('$name theme', () {
      final textPairs = <String, (Color, Color)>{
        'onPrimary / primary': (s.onPrimary, s.primary),
        'onPrimaryContainer / primaryContainer': (
          s.onPrimaryContainer,
          s.primaryContainer,
        ),
        'onSecondary / secondary': (s.onSecondary, s.secondary),
        'onSecondaryContainer / secondaryContainer': (
          s.onSecondaryContainer,
          s.secondaryContainer,
        ),
        'onTertiary / tertiary': (s.onTertiary, s.tertiary),
        'onTertiaryContainer / tertiaryContainer': (
          s.onTertiaryContainer,
          s.tertiaryContainer,
        ),
        'onError / error': (s.onError, s.error),
        'onErrorContainer / errorContainer': (
          s.onErrorContainer,
          s.errorContainer,
        ),
        'onSurface / surface': (s.onSurface, s.surface),
        'onSurfaceVariant / surface': (s.onSurfaceVariant, s.surface),
        'onSurfaceVariant / card': (s.onSurfaceVariant, card),
        'onSurfaceVariant / surfaceContainerHighest': (
          s.onSurfaceVariant,
          s.surfaceContainerHighest,
        ),
        'primary / card': (s.primary, card),
        'primary / surface': (s.primary, s.surface),
        'error / card': (s.error, card),
        'appBar title / appBar': (
          appBar.foregroundColor!,
          appBar.backgroundColor!,
        ),
      };
      for (final MapEntry(key: label, value: (fg, bg)) in textPairs.entries) {
        test('text: $label >= 4.5', () {
          expect(contrast(fg, bg), greaterThanOrEqualTo(4.5));
        });
      }

      test('outline is visible on the card (>= 3) and is not black/white', () {
        expect(contrast(s.outline, card), greaterThanOrEqualTo(3.0));
        expect(s.outline, isNot(anyOf(Colors.black, Colors.white)));
        expect(s.outlineVariant, isNot(anyOf(Colors.black, Colors.white)));
      });

      test('no role falls back to another', () {
        expect(s.surfaceContainerHighest, isNot(card));
        expect(s.surfaceContainerHighest, isNot(s.surface));
        expect(s.primaryContainer, isNot(s.primary));
        expect(s.tertiary, isNot(s.secondary));
        expect(s.onSurfaceVariant, isNot(s.onSurface));
        expect(theme.dividerColor, s.outlineVariant);
      });

      // The invoice bar of each type reads, and no two types look alike.
      for (final kind in InvoiceKind.values) {
        test('invoice bar ${kind.name} reads', () {
          final tone = theme.extension<AppSemanticColors>()!.invoice(kind);
          final dark = theme.brightness == Brightness.dark;
          final bg = dark ? tone.container : tone.fg;
          final fg = dark ? tone.onContainer : const Color(0xFFFFFFFF);
          expect(contrast(fg, bg), greaterThanOrEqualTo(4.5));
        });
      }
      test('the five invoice types have five different colors', () {
        final sem = theme.extension<AppSemanticColors>()!;
        final colors = {for (final k in InvoiceKind.values) sem.invoice(k).fg};
        expect(colors, hasLength(InvoiceKind.values.length));
      });

      final semantic = theme.extension<AppSemanticColors>();
      test('semantic colors are on the theme', () {
        expect(semantic, isNotNull);
      });
      for (final MapEntry(key: tone, value: t)
          in (semantic?.tones ?? const <String, SemanticTone>{}).entries) {
        test('semantic $tone reads on card, surface and its container', () {
          expect(contrast(t.fg, card), greaterThanOrEqualTo(4.5));
          expect(contrast(t.fg, s.surface), greaterThanOrEqualTo(4.5));
          expect(
            contrast(t.fg, s.surfaceContainerHighest),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            contrast(t.onContainer, t.container),
            greaterThanOrEqualTo(4.5),
          );
        });
      }
    });
  }
}
